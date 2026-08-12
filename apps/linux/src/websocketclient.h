#pragma once

#include <QByteArray>
#include <QObject>
#include <QSslSocket>
#include <QTimer>
#include <QUrl>

class WebSocketClient final : public QObject
{
    Q_OBJECT
public:
    explicit WebSocketClient(QObject *parent = nullptr);
    ~WebSocketClient() override;
    void open(const QUrl &url, const QString &bearerToken);
    void close();
    void closeGracefully();
    void sendBinary(const QByteArray &payload);
    bool connected() const { return m_upgraded; }

signals:
    void connectedChanged(bool connected);
    void binaryMessage(const QByteArray &payload);
    void failed(const QString &message);

private:
    void connectSocket();
    void scheduleReconnect();
    void connectedToHost();
    void readAvailable();
    void parseFrames();
    void sendFrame(quint8 opcode, const QByteArray &payload);
    void reset();

    QSslSocket m_socket;
    QUrl m_url;
    QString m_bearerToken;
    QByteArray m_webSocketKey;
    QByteArray m_buffer;
    QTimer m_reconnectTimer;
    int m_reconnectAttempt = 0;
    bool m_upgraded = false;
    bool m_shouldReconnect = false;
};
