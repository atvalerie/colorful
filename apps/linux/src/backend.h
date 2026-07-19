#pragma once

#include "discordpresence.h"
#include "corebridge.h"

#include <QAudioOutput>
#include <QColor>
#include <QElapsedTimer>
#include <QHash>
#include <QJsonObject>
#include <QMediaPlayer>
#include <QNetworkAccessManager>
#include <QObject>
#include <QProcess>
#include <QTimer>
#include <QVariantList>
#include <QVariantAnimation>
#include <functional>

class Backend final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool providerReady READ providerReady NOTIFY providerReadyChanged)
    Q_PROPERTY(bool linked READ linked NOTIFY linkedChanged)
    Q_PROPERTY(bool authPending READ authPending NOTIFY authPendingChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(bool entitlementWarningVisible READ entitlementWarningVisible NOTIFY entitlementChanged)
    Q_PROPERTY(QString entitlementMessage READ entitlementMessage NOTIFY entitlementChanged)
    Q_PROPERTY(QString userCode READ userCode NOTIFY authDetailsChanged)
    Q_PROPERTY(QString verificationUrl READ verificationUrl NOTIFY authDetailsChanged)
    Q_PROPERTY(QString statusMessage READ statusMessage NOTIFY statusMessageChanged)
    Q_PROPERTY(QVariantList searchResults READ searchResults NOTIFY searchResultsChanged)
    Q_PROPERTY(QVariantList queue READ queue NOTIFY queueChanged)
    Q_PROPERTY(QVariantList library READ library NOTIFY libraryChanged)
    Q_PROPERTY(int currentQueueIndex READ currentQueueIndex NOTIFY currentTrackChanged)
    Q_PROPERTY(QVariantMap currentTrack READ currentTrack NOTIFY currentTrackChanged)
    Q_PROPERTY(bool playing READ playing NOTIFY playbackChanged)
    Q_PROPERTY(qint64 position READ position NOTIFY positionChanged)
    Q_PROPERTY(qint64 duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(QColor accent READ accent NOTIFY accentChanged)
    Q_PROPERTY(bool autoplayEnabled READ autoplayEnabled WRITE setAutoplayEnabled NOTIFY autoplayEnabledChanged)

public:
    explicit Backend(QObject *parent = nullptr);
    ~Backend() override;

    bool providerReady() const { return m_providerReady; }
    bool linked() const { return m_linked; }
    bool authPending() const { return m_authPending; }
    bool busy() const { return m_busy; }
    bool entitlementWarningVisible() const { return m_entitlementWarningVisible; }
    QString entitlementMessage() const { return m_entitlementMessage; }
    QString userCode() const { return m_userCode; }
    QString verificationUrl() const { return m_verificationUrl; }
    QString statusMessage() const { return m_statusMessage; }
    QVariantList searchResults() const { return m_searchResults; }
    QVariantList queue() const { return m_queue; }
    QVariantList library() const { return m_library; }
    int currentQueueIndex() const { return m_currentIndex; }
    QVariantMap currentTrack() const;
    bool playing() const;
    qint64 position() const;
    qint64 duration() const;
    double volume() const { return m_audioOutput.volume(); }
    QColor accent() const { return m_accent; }
    bool autoplayEnabled() const { return m_autoplayEnabled; }

    QString playbackStatus() const;
    QVariantMap mprisMetadata() const;
    bool canGoNext() const;
    bool canGoPrevious() const;

    Q_INVOKABLE void startLogin();
    Q_INVOKABLE void openVerificationUrl();
    Q_INVOKABLE void unlink();
    Q_INVOKABLE void dismissEntitlementWarning();
    Q_INVOKABLE void openTidalAccount();
    Q_INVOKABLE void search(const QString &query);
    Q_INVOKABLE void enqueueSearchResult(int index);
    Q_INVOKABLE void playSearchResult(int index);
    Q_INVOKABLE void playQueueIndex(int index);
    Q_INVOKABLE void removeQueueIndex(int index);
    Q_INVOKABLE void addSearchResultToLibrary(int index);
    Q_INVOKABLE void playLibraryIndex(int index);
    Q_INVOKABLE void removeLibraryIndex(int index);
    Q_INVOKABLE void togglePlay();
    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void next();
    Q_INVOKABLE void previous();
    Q_INVOKABLE void seek(qint64 positionMs);
    Q_INVOKABLE void seekBy(qint64 offsetMs);
    Q_INVOKABLE void setVolume(double volume);
    Q_INVOKABLE void setAutoplayEnabled(bool enabled);

signals:
    void providerReadyChanged();
    void linkedChanged();
    void authPendingChanged();
    void busyChanged();
    void entitlementChanged();
    void authDetailsChanged();
    void statusMessageChanged();
    void searchResultsChanged();
    void queueChanged();
    void libraryChanged();
    void currentTrackChanged();
    void playbackChanged();
    void positionChanged();
    void durationChanged();
    void volumeChanged();
    void accentChanged();
    void autoplayEnabledChanged();
    void seeked(qint64 positionMs);
    void quitRequested();
    void raiseRequested();

private:
    using ReplyHandler = std::function<void(const QJsonObject &)>;

    void startProviderHost();
    int request(const QString &type, const QJsonObject &payload, ReplyHandler handler);
    void processProviderOutput();
    void handleProviderMessage(const QJsonObject &message);
    void handleProviderEvent(const QString &event, const QJsonObject &message);
    void setProviderReady(bool ready);
    void setLinked(bool linked);
    void setBusy(bool busy);
    void setStatus(const QString &message);
    void setEntitlementWarning(bool visible, const QString &message = {});
    void playTrackAt(int index);
    void resolveCurrentSource(qint64 startPositionMs = 0, bool autoplay = true);
    void requestRelatedAndContinue();
    bool openCore();
    QJsonObject dispatchCore(const QJsonObject &command);
    void refreshCoreSnapshot();
    static QJsonObject variantTrackToCore(const QVariantMap &track);
    static QVariantMap coreTrackToVariant(const QJsonObject &track);
    void loadAccent(const QString &artworkUrl);
    void updateDiscordPresence();
    void resetPositionClock(qint64 positionMs, bool running);
    QColor paletteColor(const QImage &image) const;
    static QVariantMap jsonTrackToVariant(const QJsonObject &track);

    QProcess m_provider;
    QByteArray m_providerBuffer;
    QHash<int, ReplyHandler> m_replies;
    int m_nextRequestId = 1;

    QMediaPlayer m_player;
    QElapsedTimer m_positionClock;
    QTimer m_positionTicker;
    QTimer m_checkpointTimer;
    qint64 m_positionAnchor = 0;
    bool m_positionClockRunning = false;
    bool m_sourceTransitionPending = false;
    bool m_sourceLoadingObserved = false;
    qint64 m_pendingSourcePosition = 0;
    quint64 m_sourceGeneration = 0;
    QAudioOutput m_audioOutput;
    DiscordPresence m_discordPresence;
    QNetworkAccessManager m_network;
    QVariantAnimation m_accentAnimation;
    QVariantList m_searchResults;
    QVariantList m_queue;
    QVariantList m_library;
    QList<qint64> m_queueEntryIds;
    int m_currentIndex = -1;
    qint64 m_currentEntryId = -1;
    CoreBridge m_core;
    bool m_providerReady = false;
    bool m_linked = false;
    bool m_authPending = false;
    bool m_busy = false;
    bool m_entitlementWarningVisible = false;
    QString m_userCode;
    QString m_verificationUrl;
    QString m_statusMessage = QStringLiteral("Starting colorful…");
    QString m_entitlementMessage;
    QColor m_accent = QColor(QStringLiteral("#ff4f91"));
    QString m_pendingArtworkUrl;
    bool m_autoplayEnabled = true;
    bool m_relatedPending = false;
};
