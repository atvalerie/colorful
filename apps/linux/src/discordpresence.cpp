#include "discordpresence.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QProcessEnvironment>
#include <QSettings>
#include <QtEndian>
#include <algorithm>

namespace {
constexpr auto defaultApplicationId = "1528095256820842606";
constexpr quint32 maximumFrameSize = 1024 * 1024;

QString discordRuntimeDirectory()
{
#if defined(Q_OS_WIN)
    return QStringLiteral("\\\\?\\pipe");
#else
    const auto environment = QProcessEnvironment::systemEnvironment();
    for (const auto &name : {QStringLiteral("XDG_RUNTIME_DIR"), QStringLiteral("TMPDIR"),
                             QStringLiteral("TMP"), QStringLiteral("TEMP")}) {
        const auto value = environment.value(name);
        if (!value.isEmpty()) return value;
    }
    return QStringLiteral("/tmp");
#endif
}
}

DiscordPresence::DiscordPresence(QObject *parent)
    : QObject(parent)
{
    QSettings settings;
    m_applicationId = settings.value(QStringLiteral("discord/applicationId"),
                                     QString::fromLatin1(defaultApplicationId)).toString();
    const auto currentProcessId = QCoreApplication::applicationPid();
    const auto previousProcessId = settings.value(QStringLiteral("discord/lastRpcProcessId"), 0).toLongLong();
    if (previousProcessId > 0 && previousProcessId != currentProcessId) {
        m_staleProcessId = previousProcessId;
    }
    settings.setValue(QStringLiteral("discord/lastRpcProcessId"), currentProcessId);
    m_enabled = !qEnvironmentVariableIsSet("COLORFUL_DISABLE_DISCORD_RPC");
    if (!m_enabled) return;
    m_reconnectTimer.setSingleShot(true);
    m_reconnectTimer.setInterval(15000);
    connect(&m_reconnectTimer, &QTimer::timeout, this, &DiscordPresence::connectToDiscord);
    connect(&m_socket, &QLocalSocket::connected, this, &DiscordPresence::handleConnected);
    connect(&m_socket, &QLocalSocket::disconnected, this, &DiscordPresence::handleDisconnected);
    connect(&m_socket, &QLocalSocket::readyRead, this, &DiscordPresence::handleReadyRead);
    connect(&m_socket, &QLocalSocket::errorOccurred, this, [this](QLocalSocket::LocalSocketError) {
        if (m_shuttingDown || m_socket.state() != QLocalSocket::UnconnectedState) return;
        ++m_candidateIndex;
        QTimer::singleShot(0, this, &DiscordPresence::connectToDiscord);
    });
    connectToDiscord();
}

DiscordPresence::~DiscordPresence()
{
    shutdown();
}

void DiscordPresence::setApplicationId(const QString &applicationId)
{
    const auto trimmed = applicationId.trimmed();
    if (trimmed == m_applicationId) return;
    if (m_ready && m_socket.state() == QLocalSocket::ConnectedState) {
        clearActivityForProcess(QCoreApplication::applicationPid());
        flushActivity(300);
    }
    m_applicationId = trimmed;
    m_ready = false;
    m_readBuffer.clear();
    m_candidates.clear();
    m_candidateIndex = 0;
    m_reconnectTimer.stop();
    m_socket.abort();
    QTimer::singleShot(0, this, &DiscordPresence::connectToDiscord);
}

void DiscordPresence::shutdown()
{
    if (m_shuttingDown) return;
    m_shuttingDown = true;
    bool cleared = false;
    if (m_socket.state() == QLocalSocket::ConnectedState && m_ready) {
        clearActivityForProcess(QCoreApplication::applicationPid());
        cleared = flushActivity(500);
    }
    if (cleared) {
        QSettings settings;
        settings.remove(QStringLiteral("discord/lastRpcProcessId"));
        settings.sync();
    }
    m_hasDesiredActivity = false;
    m_desiredActivity = {};
    m_socket.abort();
}

void DiscordPresence::update(const QString &title,
                             const QString &artist,
                             const QString &album,
                             const QString &artworkUrl,
                             qint64 positionMs,
                             qint64 durationMs,
                             bool playing)
{
    if (title.trimmed().isEmpty()) {
        clear();
        return;
    }

    QJsonObject activity{
        {QStringLiteral("type"), 2}, // Listening
        {QStringLiteral("details"), title.left(128)},
        {QStringLiteral("state"), (playing ? artist
                                            : artist.isEmpty() ? QStringLiteral("Paused")
                                                               : artist + QStringLiteral(" · Paused")).left(128)},
        {QStringLiteral("instance"), false},
    };
    if (playing) {
        const auto nowSeconds = QDateTime::currentSecsSinceEpoch();
        const auto startSeconds = nowSeconds - std::max<qint64>(0, positionMs) / 1000;
        QJsonObject timestamps{{QStringLiteral("start"), startSeconds}};
        if (durationMs > 0) timestamps.insert(QStringLiteral("end"), startSeconds + durationMs / 1000);
        activity.insert(QStringLiteral("timestamps"), timestamps);
    }

    QJsonObject assets;
    if (artworkUrl.startsWith(QStringLiteral("https://"), Qt::CaseInsensitive)) {
        assets.insert(QStringLiteral("large_image"), artworkUrl);
        assets.insert(QStringLiteral("large_text"), album.isEmpty() ? title : album.left(128));
    }
    if (!assets.isEmpty()) activity.insert(QStringLiteral("assets"), assets);

    m_desiredActivity = activity;
    m_hasDesiredActivity = true;
    publishDesiredActivity();
}

void DiscordPresence::clear()
{
    if (!m_hasDesiredActivity && m_desiredActivity.isEmpty()) return;
    m_hasDesiredActivity = false;
    m_desiredActivity = {};
    publishDesiredActivity();
}

void DiscordPresence::connectToDiscord()
{
    if (!m_enabled || m_shuttingDown || m_socket.state() != QLocalSocket::UnconnectedState) return;

    if (!m_candidates.isEmpty() && m_candidateIndex >= m_candidates.size()) {
        m_candidates.clear();
        m_candidateIndex = 0;
        scheduleReconnect();
        return;
    }
    if (m_candidates.isEmpty()) {
        m_candidates.clear();
        m_candidateIndex = 0;
        for (int index = 0; index < 10; ++index) {
#if defined(Q_OS_WIN)
            const auto path = discordRuntimeDirectory() + QStringLiteral("\\discord-ipc-%1").arg(index);
            m_candidates.append(path);
#else
            const QDir runtime(discordRuntimeDirectory());
            const auto path = runtime.filePath(QStringLiteral("discord-ipc-%1").arg(index));
            if (QFileInfo::exists(path)) m_candidates.append(path);
#endif
        }
        if (m_candidates.isEmpty()) {
            scheduleReconnect();
            return;
        }
    }

    m_socket.connectToServer(m_candidates.at(m_candidateIndex));
}

void DiscordPresence::handleConnected()
{
    m_ready = false;
    m_readBuffer.clear();
    writeFrame(Opcode::Handshake, {
        {QStringLiteral("v"), 1},
        {QStringLiteral("client_id"), m_applicationId},
    });
}

void DiscordPresence::handleDisconnected()
{
    m_ready = false;
    m_readBuffer.clear();
    if (!m_shuttingDown) scheduleReconnect();
}

void DiscordPresence::handleReadyRead()
{
    m_readBuffer.append(m_socket.readAll());
    while (m_readBuffer.size() >= 8) {
        const auto *header = reinterpret_cast<const uchar *>(m_readBuffer.constData());
        const auto opcode = static_cast<Opcode>(qFromLittleEndian<quint32>(header));
        const auto length = qFromLittleEndian<quint32>(header + 4);
        if (length > maximumFrameSize) {
            m_socket.abort();
            return;
        }
        if (m_readBuffer.size() < 8 + static_cast<qsizetype>(length)) return;
        const auto payload = m_readBuffer.mid(8, length);
        m_readBuffer.remove(0, 8 + length);
        handleFrame(opcode, payload);
    }
}

void DiscordPresence::handleFrame(Opcode opcode, const QByteArray &payload)
{
    if (opcode == Opcode::Ping) {
        QJsonParseError error;
        const auto document = QJsonDocument::fromJson(payload, &error);
        if (error.error == QJsonParseError::NoError && document.isObject()) {
            writeFrame(Opcode::Pong, document.object());
        }
        return;
    }
    if (opcode == Opcode::Close) {
        m_socket.abort();
        return;
    }
    if (opcode != Opcode::Frame) return;

    QJsonParseError error;
    const auto document = QJsonDocument::fromJson(payload, &error);
    if (error.error != QJsonParseError::NoError || !document.isObject()) return;
    const auto message = document.object();
    if (message.value(QStringLiteral("cmd")).toString() == QStringLiteral("DISPATCH")
        && message.value(QStringLiteral("evt")).toString() == QStringLiteral("READY")) {
        const auto userId = message.value(QStringLiteral("data")).toObject()
                                .value(QStringLiteral("user")).toObject()
                                .value(QStringLiteral("id")).toString();
        if (!userId.isEmpty()) emit userIdResolved(userId);
        m_ready = true;
        if (m_staleProcessId > 0) {
            clearActivityForProcess(m_staleProcessId);
            m_staleProcessId = 0;
        }
        publishDesiredActivity();
    }
}

void DiscordPresence::publishDesiredActivity()
{
    if (!m_ready || m_socket.state() != QLocalSocket::ConnectedState) return;
    QJsonObject arguments{{QStringLiteral("pid"), QCoreApplication::applicationPid()}};
    if (m_hasDesiredActivity) arguments.insert(QStringLiteral("activity"), m_desiredActivity);
    writeFrame(Opcode::Frame, {
        {QStringLiteral("cmd"), QStringLiteral("SET_ACTIVITY")},
        {QStringLiteral("args"), arguments},
        {QStringLiteral("nonce"), QString::number(++m_nonce)},
    });
}

void DiscordPresence::clearActivityForProcess(qint64 processId)
{
    if (!m_ready || m_socket.state() != QLocalSocket::ConnectedState || processId <= 0) return;
    writeFrame(Opcode::Frame, {
        {QStringLiteral("cmd"), QStringLiteral("SET_ACTIVITY")},
        {QStringLiteral("args"), QJsonObject{
            {QStringLiteral("pid"), processId},
            {QStringLiteral("activity"), QJsonValue(QJsonValue::Null)},
        }},
        {QStringLiteral("nonce"), QString::number(++m_nonce)},
    });
}

bool DiscordPresence::flushActivity(int timeoutMs)
{
    if (!m_socket.flush()) return false;
    if (m_socket.bytesToWrite() > 0 && !m_socket.waitForBytesWritten(timeoutMs)) return false;
    // Discord acknowledges SET_ACTIVITY. Waiting for that response prevents
    // process teardown from racing the clear frame on a busy IPC connection.
    if (!m_socket.waitForReadyRead(timeoutMs)) return false;
    handleReadyRead();
    return true;
}

void DiscordPresence::writeFrame(Opcode opcode, const QJsonObject &payload)
{
    if (m_socket.state() != QLocalSocket::ConnectedState) return;
    const auto json = QJsonDocument(payload).toJson(QJsonDocument::Compact);
    QByteArray frame(8, Qt::Uninitialized);
    qToLittleEndian(static_cast<quint32>(opcode), reinterpret_cast<uchar *>(frame.data()));
    qToLittleEndian(static_cast<quint32>(json.size()), reinterpret_cast<uchar *>(frame.data() + 4));
    frame.append(json);
    m_socket.write(frame);
}

void DiscordPresence::scheduleReconnect()
{
    if (!m_shuttingDown && !m_reconnectTimer.isActive()) m_reconnectTimer.start();
}
