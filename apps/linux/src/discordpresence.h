#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QLocalSocket>
#include <QNetworkAccessManager>
#include <QObject>
#include <QTimer>
#include <QVariantMap>

class DiscordPresence final : public QObject
{
    Q_OBJECT

public:
    explicit DiscordPresence(QObject *parent = nullptr);
    ~DiscordPresence() override;

    void shutdown();
    void update(const QString &title,
                const QString &artist,
                const QString &album,
                const QString &artworkUrl,
                qint64 positionMs,
                qint64 durationMs,
                bool playing);
    void setParty(const QString &partyId, int currentSize, int maximumSize,
                  const QString &joinSecret, bool joinEnabled);
    void setPartyInvitesEnabled(bool enabled);
    void respondToJoinRequest(const QString &userId, bool accepted);
    void clear();
    bool partyJoinEnabled() const { return m_partyJoinEnabled; }

signals:
    void activityJoinRequested(const QVariantMap &request);
    void activityJoin(const QString &secret);

private:
    enum class Opcode : quint32 { Handshake = 0, Frame = 1, Close = 2, Ping = 3, Pong = 4 };

    void connectToDiscord();
    void handleConnected();
    void handleDisconnected();
    void handleReadyRead();
    void handleFrame(Opcode opcode, const QByteArray &payload);
    void publishDesiredActivity();
    void beginAuthorization();
    void exchangeAuthorizationCode(const QString &code);
    void subscribe(const QString &event);
    void clearActivityForProcess(qint64 processId);
    bool flushActivity(int timeoutMs);
    void writeFrame(Opcode opcode, const QJsonObject &payload);
    void scheduleReconnect();

    QLocalSocket m_socket;
    QNetworkAccessManager m_network;
    QTimer m_reconnectTimer;
    QByteArray m_readBuffer;
    QJsonObject m_desiredActivity;
    QString m_partyId;
    QString m_partyJoinSecret;
    int m_partyCurrentSize = 1;
    int m_partyMaximumSize = 16;
    QString m_applicationId;
    QStringList m_candidates;
    qsizetype m_candidateIndex = 0;
    quint64 m_nonce = 0;
    QString m_authorizeNonce;
    QString m_authenticateNonce;
    qint64 m_staleProcessId = 0;
    bool m_enabled = true;
    bool m_ready = false;
    bool m_authorizing = false;
    bool m_authenticated = false;
    bool m_partyJoinEnabled = false;
    bool m_partyInvitesEnabled = false;
    bool m_hasDesiredActivity = false;
    bool m_shuttingDown = false;
    bool m_unavailableLogged = false;
};
