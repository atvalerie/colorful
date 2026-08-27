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
    void setEnabled(bool enabled);
    void setTrackButtonEnabled(bool enabled);
    void setAskToJoinEnabled(bool enabled);
    void respondToJoinRequest(const QString &userId, bool approved);
    void update(const QString &title,
                const QString &artist,
                const QString &album,
                const QString &artworkUrl,
                qint64 positionMs,
                qint64 durationMs,
                bool playing,
                const QString &trackUrl = {},
                const QString &partyId = {},
                int partySize = 0,
                const QString &joinPartyUrl = {},
                const QString &joinSecret = {});
    void clear();

    // Kept pure so the activity contract can be tested without a Discord
    // process or IPC socket.
    static QJsonObject buildActivity(const QString &title,
                                     const QString &artist,
                                     const QString &album,
                                     const QString &artworkUrl,
                                     qint64 positionMs,
                                     qint64 durationMs,
                                     bool playing,
                                     const QString &trackUrl,
                                     bool trackButtonEnabled,
                                     const QString &partyId = {},
                                     int partySize = 0,
                                     const QString &joinPartyUrl = {},
                                     const QString &joinSecret = {});

signals:
    void activityJoinRequested(const QVariantMap &user);
    void activityJoin(const QString &joinSecret);

private:
    enum class Opcode : quint32 { Handshake = 0, Frame = 1, Close = 2, Ping = 3, Pong = 4 };

    void connectToDiscord();
    void handleConnected();
    void handleDisconnected();
    void handleReadyRead();
    void handleFrame(Opcode opcode, const QByteArray &payload);
    void beginAuthentication();
    void exchangeAuthorizationCode(const QString &code);
    void subscribeToPartyEvents();
    void publishDesiredActivity();
    void rebuildButtons();
    void clearActivityForProcess(qint64 processId);
    bool flushActivity(int timeoutMs);
    void writeFrame(Opcode opcode, const QJsonObject &payload);
    void scheduleReconnect();

    QLocalSocket m_socket;
    QNetworkAccessManager m_network;
    QTimer m_reconnectTimer;
    QByteArray m_readBuffer;
    QJsonObject m_desiredActivity;
    QString m_applicationId;
    QStringList m_candidates;
    qsizetype m_candidateIndex = 0;
    quint64 m_nonce = 0;
    qint64 m_staleProcessId = 0;
    bool m_enabled = true;
    bool m_trackButtonEnabled = true;
    bool m_askToJoinEnabled = false;
    bool m_ready = false;
    bool m_authenticated = false;
    bool m_authorizationRequested = false;
    bool m_authorizationFailed = false;
    bool m_hasDesiredActivity = false;
    bool m_shuttingDown = false;
    bool m_unavailableLogged = false;
    QString m_trackUrl;
    QString m_partyId;
    int m_partySize = 0;
    QString m_joinPartyUrl;
    QString m_joinSecret;
};
