#include "websocketclient.h"

#include <QCryptographicHash>
#include <QRandomGenerator>

namespace {
constexpr auto WebSocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
}

WebSocketClient::WebSocketClient(QObject *parent) : QObject(parent)
{
    m_reconnectTimer.setSingleShot(true);
    connect(&m_reconnectTimer, &QTimer::timeout, this, &WebSocketClient::connectSocket);
    connect(&m_socket, &QSslSocket::connected, this, [this] {
        if (m_url.scheme() == QStringLiteral("wss")) m_socket.startClientEncryption();
        else connectedToHost();
    });
    connect(&m_socket, &QSslSocket::encrypted, this, &WebSocketClient::connectedToHost);
    connect(&m_socket, &QSslSocket::readyRead, this, &WebSocketClient::readAvailable);
    connect(&m_socket, &QSslSocket::disconnected, this, [this] {
        const bool wasConnected = m_upgraded;
        reset();
        if (wasConnected) emit connectedChanged(false);
        scheduleReconnect();
    });
    connect(&m_socket, &QSslSocket::errorOccurred, this, [this](QAbstractSocket::SocketError) {
        emit failed(m_socket.errorString());
        scheduleReconnect();
    });
    connect(&m_socket, &QSslSocket::sslErrors, this, [this](const QList<QSslError> &errors) {
        QStringList messages;
        for (const auto &error : errors) messages.append(error.errorString());
        emit failed(messages.join(QStringLiteral("; ")));
    });
}

WebSocketClient::~WebSocketClient()
{
    close();
    m_socket.disconnect(this);
}

void WebSocketClient::open(const QUrl &url, const QString &bearerToken)
{
    close();
    m_url = url;
    m_bearerToken = bearerToken;
    if ((url.scheme() != QStringLiteral("ws") && url.scheme() != QStringLiteral("wss"))
        || url.host().isEmpty()) {
        emit failed(QStringLiteral("Party relay WebSocket URL is invalid"));
        return;
    }
    m_shouldReconnect = true;
    m_reconnectAttempt = 0;
    connectSocket();
}

void WebSocketClient::connectSocket()
{
    if (!m_shouldReconnect || m_url.host().isEmpty()
        || m_socket.state() != QAbstractSocket::UnconnectedState) return;
    m_socket.connectToHost(m_url.host(), m_url.port(m_url.scheme() == QStringLiteral("wss") ? 443 : 80));
}

void WebSocketClient::close()
{
    m_shouldReconnect = false;
    m_reconnectTimer.stop();
    if (m_upgraded) sendFrame(0x8, {});
    m_socket.abort();
    reset();
}

void WebSocketClient::closeGracefully()
{
    m_shouldReconnect = false;
    m_reconnectTimer.stop();
    if (!m_upgraded) {
        close();
        return;
    }
    sendFrame(0x8, {});
    m_socket.flush();
    m_socket.disconnectFromHost();
    QTimer::singleShot(1500, this, [this] {
        if (m_socket.state() != QAbstractSocket::UnconnectedState) m_socket.abort();
    });
}

void WebSocketClient::scheduleReconnect()
{
    if (!m_shouldReconnect || m_reconnectTimer.isActive()) return;
    const auto delay = qMin(15'000, 500 * (1 << qMin(m_reconnectAttempt, 5)));
    ++m_reconnectAttempt;
    m_reconnectTimer.start(delay);
}

void WebSocketClient::reset()
{
    m_buffer.clear();
    m_webSocketKey.clear();
    m_upgraded = false;
}

void WebSocketClient::connectedToHost()
{
    QByteArray random;
    random.reserve(16);
    for (int index = 0; index < 4; ++index) {
        const auto value = QRandomGenerator::system()->generate();
        random.append(reinterpret_cast<const char *>(&value), sizeof(value));
    }
    m_webSocketKey = random.toBase64();
    auto path = m_url.path(QUrl::FullyEncoded).toUtf8();
    if (path.isEmpty()) path = "/";
    if (m_url.hasQuery()) path += '?' + m_url.query(QUrl::FullyEncoded).toUtf8();
    QByteArray request = "GET " + path + " HTTP/1.1\r\nHost: " + m_url.host().toUtf8();
    const int port = m_url.port();
    if (port > 0) request += ':' + QByteArray::number(port);
    request += "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: "
        + m_webSocketKey + "\r\nAuthorization: Bearer " + m_bearerToken.toUtf8() + "\r\n\r\n";
    m_socket.write(request);
}

void WebSocketClient::readAvailable()
{
    m_buffer += m_socket.readAll();
    if (!m_upgraded) {
        const auto end = m_buffer.indexOf("\r\n\r\n");
        if (end < 0) return;
        const auto headers = m_buffer.left(end + 4);
        m_buffer.remove(0, end + 4);
        const auto expected = QCryptographicHash::hash(
            m_webSocketKey + WebSocketGuid, QCryptographicHash::Sha1).toBase64();
        const auto lower = headers.toLower();
        if (!headers.startsWith("HTTP/1.1 101")
            || !lower.contains("sec-websocket-accept: " + expected.toLower())) {
            emit failed(QStringLiteral("Party relay rejected the WebSocket upgrade"));
            m_socket.abort();
            return;
        }
        m_upgraded = true;
        m_reconnectAttempt = 0;
        m_reconnectTimer.stop();
        emit connectedChanged(true);
    }
    parseFrames();
}

void WebSocketClient::parseFrames()
{
    while (m_buffer.size() >= 2) {
        const auto first = quint8(m_buffer[0]);
        const auto second = quint8(m_buffer[1]);
        if ((first & 0x80) == 0 || (second & 0x80) != 0) {
            emit failed(QStringLiteral("Unsupported fragmented or masked relay frame"));
            m_socket.abort();
            return;
        }
        quint64 length = second & 0x7f;
        int header = 2;
        if (length == 126) {
            if (m_buffer.size() < 4) return;
            length = (quint8(m_buffer[2]) << 8) | quint8(m_buffer[3]);
            header = 4;
        } else if (length == 127) {
            if (m_buffer.size() < 10) return;
            length = 0;
            for (int index = 2; index < 10; ++index) length = (length << 8) | quint8(m_buffer[index]);
            header = 10;
        }
        if (length > 512 * 1024) {
            emit failed(QStringLiteral("Party relay frame exceeds the client limit"));
            m_socket.abort();
            return;
        }
        if (m_buffer.size() < header + qint64(length)) return;
        const auto payload = m_buffer.mid(header, qsizetype(length));
        m_buffer.remove(0, header + qsizetype(length));
        const auto opcode = first & 0x0f;
        if (opcode == 0x2) emit binaryMessage(payload);
        else if (opcode == 0x9) sendFrame(0xA, payload);
        else if (opcode == 0x8) { m_socket.disconnectFromHost(); return; }
        else if (opcode != 0xA) { emit failed(QStringLiteral("Unexpected relay frame type")); }
    }
}

void WebSocketClient::sendBinary(const QByteArray &payload)
{
    if (m_upgraded) sendFrame(0x2, payload);
}

void WebSocketClient::sendFrame(quint8 opcode, const QByteArray &payload)
{
    if (payload.size() > 512 * 1024) { emit failed(QStringLiteral("Party frame is too large")); return; }
    QByteArray frame;
    frame.append(char(0x80 | opcode));
    const quint64 length = payload.size();
    if (length < 126) frame.append(char(0x80 | length));
    else if (length <= 0xffff) {
        frame.append(char(0x80 | 126));
        frame.append(char((length >> 8) & 0xff)); frame.append(char(length & 0xff));
    } else {
        frame.append(char(0x80 | 127));
        for (int shift = 56; shift >= 0; shift -= 8) frame.append(char((length >> shift) & 0xff));
    }
    quint32 mask = QRandomGenerator::system()->generate();
    QByteArray maskBytes(reinterpret_cast<const char *>(&mask), 4);
    frame += maskBytes;
    for (qsizetype index = 0; index < payload.size(); ++index)
        frame.append(payload[index] ^ maskBytes[index % 4]);
    m_socket.write(frame);
}
