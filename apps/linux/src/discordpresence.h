#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QLocalSocket>
#include <QObject>
#include <QTimer>

class DiscordPresence final : public QObject
{
    Q_OBJECT

public:
    explicit DiscordPresence(QObject *parent = nullptr);
    ~DiscordPresence() override;

    void setApplicationId(const QString &applicationId);
    void shutdown();
    void update(const QString &title,
                const QString &artist,
                const QString &album,
                const QString &artworkUrl,
                qint64 positionMs,
                qint64 durationMs,
                bool playing);
    void clear();

signals:
    void userIdResolved(const QString &userId);

private:
    enum class Opcode : quint32 { Handshake = 0, Frame = 1, Close = 2, Ping = 3, Pong = 4 };

    void connectToDiscord();
    void handleConnected();
    void handleDisconnected();
    void handleReadyRead();
    void handleFrame(Opcode opcode, const QByteArray &payload);
    void publishDesiredActivity();
    void clearActivityForProcess(qint64 processId);
    bool flushActivity(int timeoutMs);
    void writeFrame(Opcode opcode, const QJsonObject &payload);
    void scheduleReconnect();

    QLocalSocket m_socket;
    QTimer m_reconnectTimer;
    QByteArray m_readBuffer;
    QJsonObject m_desiredActivity;
    QString m_applicationId;
    QStringList m_candidates;
    qsizetype m_candidateIndex = 0;
    quint64 m_nonce = 0;
    qint64 m_staleProcessId = 0;
    bool m_enabled = true;
    bool m_ready = false;
    bool m_hasDesiredActivity = false;
    bool m_shuttingDown = false;
};
