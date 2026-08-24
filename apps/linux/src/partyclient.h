#pragma once

#include "partycorebridge.h"
#include "websocketclient.h"

#include <QJsonArray>
#include <QElapsedTimer>
#include <QHash>
#include <QNetworkAccessManager>
#include <QObject>
#include <QTimer>
#include <QVariantList>
#include <QVector>
#include <QUrl>
#include <cmath>

class Backend;

class PartyClient final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool active READ active NOTIFY stateChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY stateChanged)
    Q_PROPERTY(QString role READ role NOTIFY stateChanged)
    Q_PROPERTY(QString status READ status NOTIFY stateChanged)
    Q_PROPERTY(QString shareUrl READ shareUrl NOTIFY stateChanged)
    Q_PROPERTY(qint64 expiresAtMs READ expiresAtMs NOTIFY stateChanged)
    Q_PROPERTY(bool joinEnabled READ joinEnabled NOTIFY stateChanged)
    Q_PROPERTY(QVariantList participants READ participants NOTIFY stateChanged)
    Q_PROPERTY(QVariantList queue READ queue NOTIFY stateChanged)
    Q_PROPERTY(QVariantList playbackQueue READ playbackQueue NOTIFY stateChanged)
    Q_PROPERTY(int currentQueueIndex READ currentQueueIndex NOTIFY stateChanged)
    Q_PROPERTY(bool clockSynchronized READ clockSynchronized NOTIFY timingChanged)
    Q_PROPERTY(int latencyMs READ latencyMs NOTIFY timingChanged)
    Q_PROPERTY(qint64 driftMs READ driftMs NOTIFY timingChanged)
    Q_PROPERTY(qint64 clockOffsetMs READ clockOffsetMs NOTIFY timingChanged)
    Q_PROPERTY(double correctionRate READ correctionRate NOTIFY timingChanged)
    Q_PROPERTY(QString correctionMode READ correctionMode NOTIFY timingChanged)
    Q_PROPERTY(quint64 clockSampleCount READ clockSampleCount NOTIFY timingChanged)
    Q_PROPERTY(quint64 hardResyncCount READ hardResyncCount NOTIFY timingChanged)
    Q_PROPERTY(quint64 playbackGeneration READ playbackGeneration NOTIFY timingChanged)

public:
    explicit PartyClient(Backend *backend, QObject *parent = nullptr);
    bool active() const { return m_active; }
    bool connected() const { return m_socket.connected(); }
    QString role() const { return m_role; }
    QString status() const { return m_status; }
    QString shareUrl() const { return m_shareUrl; }
    qint64 expiresAtMs() const { return m_expiresAtMs; }
    bool joinEnabled() const { return m_joinEnabled; }
    QVariantList participants() const { return m_participants; }
    QVariantList queue() const { return m_queue; }
    QVariantList playbackQueue() const;
    int currentQueueIndex() const;
    bool clockSynchronized() const { return m_role == QStringLiteral("host") || m_clockSynchronized; }
    int latencyMs() const { return m_role == QStringLiteral("host") ? 0 : int(qMax<qint64>(0, m_bestClockRttMs)); }
    qint64 driftMs() const { return m_lastDriftMs; }
    qint64 clockOffsetMs() const { return qint64(std::llround(m_hostClockOffsetMs)); }
    double correctionRate() const { return m_correctionRate; }
    QString correctionMode() const {
        if (m_role == QStringLiteral("host")) return QStringLiteral("authority");
        if (!m_clockSynchronized) return QStringLiteral("sampling");
        if (m_correctionRate > 1.0) return QStringLiteral("catching up");
        if (m_correctionRate < 1.0) return QStringLiteral("easing back");
        return QStringLiteral("locked");
    }
    quint64 clockSampleCount() const { return m_clockSampleCount; }
    quint64 hardResyncCount() const { return m_hardResyncCount; }
    quint64 playbackGeneration() const { return m_role == QStringLiteral("host") ? m_generation : m_remoteGeneration; }

    Q_INVOKABLE void createParty(const QString &displayName, const QString &relayBaseUrl);
    Q_INVOKABLE void joinParty(const QString &link, const QString &displayName,
                               const QString &relayBaseUrl);
    Q_INVOKABLE bool handlePartyLink(const QString &link);
    Q_INVOKABLE void suggestTrack(const QVariantMap &track);
    Q_INVOKABLE void enqueueTrack(const QVariantMap &track);
    Q_INVOKABLE void setJoinEnabled(bool enabled);
    Q_INVOKABLE void setCoHost(const QString &participantId, bool enabled);
    Q_INVOKABLE void kick(const QString &participantId);
    Q_INVOKABLE void leave();

signals:
    void stateChanged();
    void notification(const QString &message, const QString &kind);
    void joinLinkReceived(const QString &link);
    void timingChanged();

private:
    void connectRelay(const QString &baseUrl, const QString &sessionId,
                      const QString &capability);
    void dispatch(const QJsonObject &command);
    QJsonObject dispatchCore(const QJsonObject &command, bool reportError = true);
    void applyResult(const QJsonObject &value);
    void flushOutbound();
    void receiveFrame(const QByteArray &payload);
    void publishCurrentTrack();
    void publishQueue();
    void publishPlayback();
    void applyRemoteEvent(const QJsonObject &event);
    void sendClockPing();
    void applyClockPong(const QJsonObject &body);
    void correctPlayback();
    void preloadFollowingTrack();
    qint64 clockNowMs() const;
    QJsonObject trackForEntry(const QString &entryId) const;
    void updateState(const QJsonObject &state);
    static QJsonObject partyTrack(const QVariantMap &track);
    static QVariantMap backendTrack(const QJsonObject &track);
    void setStatus(const QString &status);
    void refreshPublicJoinTicket();
    void revokePublicJoinHandle(const QString &sessionId, const QString &handleLookup,
                                const QString &relayBaseUrl = {},
                                const QString &hostCapability = {});
    void publishDiscordPartyState();
    void mintPublicJoinTicket(const QString &ticket, const QString &displayName,
                              quint64 requestGeneration);
    void redeemPublicJoinTicket(const QString &ticket, const QString &displayName,
                                quint64 requestGeneration);
    void joinPartyWithFragment(const QString &session, const QString &fragment,
                               const QString &displayName);
    static QString publicJoinTicketFromUrl(const QUrl &url);

    Backend *m_backend = nullptr;
    PartyCoreBridge m_core;
    WebSocketClient m_socket;
    QNetworkAccessManager m_network;
    QTimer m_hostClock;
    QTimer m_clockSampler;
    QTimer m_driftController;
    QTimer m_publicHandleRetryTimer;
    QElapsedTimer m_monotonicClock;
    QList<QByteArray> m_pendingFrames;
    qsizetype m_pendingFrameBytes = 0;
    QString m_relayBaseUrl;
    QString m_relaySessionId;
    QString m_relayHostCapability;
    QString m_inviteFragment;
    QString m_publicJoinTicket;
    QString m_publicJoinTicketLookup;
    QString m_role;
    QString m_status = QStringLiteral("No active party");
    QString m_shareUrl;
    QString m_currentEntryId;
    QString m_lastTrackKey;
    QString m_participantId;
    QVariantList m_participants;
    QVariantList m_queue;
    QJsonObject m_lastPlayback;
    QHash<QString, QString> m_entryByTrackKey;
    QStringList m_partyEntryIds;
    // Index in the local queue for each wire entry.  Party entries are
    // deliberately fresh on every queue replacement, while local queue
    // entries remain the only reliable identity when the same track appears
    // more than once (or a malformed item has no provider id).
    QVector<int> m_partyBackendIndexes;
    QByteArray m_lastQueueSignature;
    QHash<quint64, qint64> m_clockRequests;
    qint64 m_clockEpochMs = 0;
    qint64 m_expiresAtMs = 0;
    qint64 m_publicJoinTicketExpiresAtMs = 0;
    qint64 m_lastHardSeekMs = 0;
    qint64 m_lastDriftMs = 0;
    qint64 m_lastRateChangeMs = 0;
    quint64 m_clockNonce = 0;
    quint64 m_clockSampleCount = 0;
    quint64 m_hardResyncCount = 0;
    quint64 m_generation = 0;
    quint64 m_remoteGeneration = 0;
    double m_hostClockOffsetMs = 0.0;
    double m_filteredDriftMs = 0.0;
    double m_correctionRate = 1.0;
    qint64 m_bestClockRttMs = -1;
    int m_excessiveDriftSamples = 0;
    int m_clockOutlierSamples = 0;
    bool m_clockSynchronized = false;
    bool m_joinEnabled = true;
    bool m_active = false;
    bool m_applyingRemote = false;
    bool m_everConnected = false;
    bool m_needsResync = false;
    bool m_resyncPending = false;
    bool m_creatingParty = false;
    bool m_publicTicketRequestInFlight = false;
    bool m_joinTicketRedemptionInFlight = false;
    quint64 m_ticketGeneration = 0;
};
