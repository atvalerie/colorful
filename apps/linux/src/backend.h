#pragma once

#include "discordpresence.h"
#include "discordwidget.h"
#include "corebridge.h"
#include "linuxplayback.h"

#include <QColor>
#include <QElapsedTimer>
#include <QHash>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QObject>
#include <QProcess>
#include <QPointer>
#include <QTimer>
#include <QVariantList>
#include <QVariantAnimation>
#include <functional>
#include <optional>

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
    Q_PROPERTY(QString authProvider READ authProvider NOTIFY authDetailsChanged)
    Q_PROPERTY(bool youtubeLinked READ youtubeLinked NOTIFY youtubeAccountChanged)
    Q_PROPERTY(QVariantMap youtubeHub READ youtubeHub NOTIFY youtubeAccountChanged)
    Q_PROPERTY(bool youtubeHubLoading READ youtubeHubLoading NOTIFY youtubeAccountChanged)
    Q_PROPERTY(QString statusMessage READ statusMessage NOTIFY statusMessageChanged)
    Q_PROPERTY(QVariantList searchResults READ searchResults NOTIFY searchResultsChanged)
    Q_PROPERTY(QVariantList searchAlbums READ searchAlbums NOTIFY searchResultsChanged)
    Q_PROPERTY(QVariantList searchArtists READ searchArtists NOTIFY searchResultsChanged)
    Q_PROPERTY(QVariantMap catalogPage READ catalogPage NOTIFY catalogPageChanged)
    Q_PROPERTY(bool catalogLoading READ catalogLoading NOTIFY catalogPageChanged)
    Q_PROPERTY(bool catalogMoreLoading READ catalogMoreLoading NOTIFY catalogPageChanged)
    Q_PROPERTY(bool canNavigateCatalogBack READ canNavigateCatalogBack NOTIFY catalogPageChanged)
    Q_PROPERTY(QVariantList queue READ queue NOTIFY queueChanged)
    Q_PROPERTY(QVariantList library READ library NOTIFY libraryChanged)
    Q_PROPERTY(QVariantList downloads READ downloads NOTIFY downloadsChanged)
    Q_PROPERTY(qint64 offlineStorageUsed READ offlineStorageUsed NOTIFY downloadsChanged)
    Q_PROPERTY(qint64 offlineStorageLimitBytes READ offlineStorageLimitBytes WRITE setOfflineStorageLimitBytes NOTIFY offlineStorageLimitChanged)
    Q_PROPERTY(QVariantMap tidalHub READ tidalHub NOTIFY tidalHubChanged)
    Q_PROPERTY(bool tidalHubLoading READ tidalHubLoading NOTIFY tidalHubChanged)
    Q_PROPERTY(bool tidalMoreLoading READ tidalMoreLoading NOTIFY tidalHubChanged)
    Q_PROPERTY(int currentQueueIndex READ currentQueueIndex NOTIFY currentTrackChanged)
    Q_PROPERTY(QVariantMap currentTrack READ currentTrack NOTIFY currentTrackChanged)
    Q_PROPERTY(bool playing READ playing NOTIFY playbackChanged)
    Q_PROPERTY(qint64 position READ position NOTIFY positionChanged)
    Q_PROPERTY(qint64 duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(bool muted READ muted WRITE setMuted NOTIFY mutedChanged)
    Q_PROPERTY(QString repeatMode READ repeatMode WRITE setRepeatMode NOTIFY playbackOptionsChanged)
    Q_PROPERTY(bool shuffleEnabled READ shuffleEnabled WRITE setShuffleEnabled NOTIFY playbackOptionsChanged)
    Q_PROPERTY(bool playbackLoading READ playbackLoading NOTIFY playbackConditionChanged)
    Q_PROPERTY(bool buffering READ buffering NOTIFY playbackConditionChanged)
    Q_PROPERTY(int bufferingPercent READ bufferingPercent NOTIFY playbackConditionChanged)
    Q_PROPERTY(QString playbackError READ playbackError NOTIFY playbackConditionChanged)
    Q_PROPERTY(QVariantList audioDevices READ audioDevices NOTIFY audioDevicesChanged)
    Q_PROPERTY(QString audioDevice READ audioDevice WRITE setAudioDevice NOTIFY audioDeviceChanged)
    Q_PROPERTY(QColor accent READ accent NOTIFY accentChanged)
    Q_PROPERTY(QString accentMode READ accentMode WRITE setAccentMode NOTIFY appearanceChanged)
    Q_PROPERTY(QColor fixedAccent READ fixedAccent WRITE setFixedAccent NOTIFY appearanceChanged)
    Q_PROPERTY(bool lowDataMode READ lowDataMode WRITE setLowDataMode NOTIFY appearanceChanged)
    Q_PROPERTY(bool autoplayEnabled READ autoplayEnabled WRITE setAutoplayEnabled NOTIFY autoplayEnabledChanged)
    Q_PROPERTY(QString streamQuality READ streamQuality WRITE setStreamQuality NOTIFY streamQualityChanged)
    Q_PROPERTY(bool normalizationEnabled READ normalizationEnabled WRITE setNormalizationEnabled NOTIFY audioProcessingChanged)
    Q_PROPERTY(QVariantList equalizerBands READ equalizerBands NOTIFY audioProcessingChanged)
    Q_PROPERTY(QString equalizerPreset READ equalizerPreset NOTIFY audioProcessingChanged)
    Q_PROPERTY(QVariantMap listenStats READ listenStats NOTIFY listenStatsChanged)
    Q_PROPERTY(QVariantMap buildInfo READ buildInfo CONSTANT)
    Q_PROPERTY(bool discordWidgetEnabled READ discordWidgetEnabled WRITE setDiscordWidgetEnabled NOTIFY discordWidgetChanged)
    Q_PROPERTY(bool discordWidgetConfigured READ discordWidgetConfigured NOTIFY discordWidgetChanged)
    Q_PROPERTY(bool discordWidgetBusy READ discordWidgetBusy NOTIFY discordWidgetChanged)
    Q_PROPERTY(QString discordWidgetStatus READ discordWidgetStatus NOTIFY discordWidgetChanged)
    Q_PROPERTY(QString discordApplicationId READ discordApplicationId WRITE setDiscordApplicationId NOTIFY discordWidgetChanged)
    Q_PROPERTY(QString discordRedirectUri READ discordRedirectUri WRITE setDiscordRedirectUri NOTIFY discordWidgetChanged)
    Q_PROPERTY(QString discordWidgetUserId READ discordWidgetUserId WRITE setDiscordWidgetUserId NOTIFY discordWidgetChanged)
    Q_PROPERTY(bool discordWidgetUserIdAutomatic READ discordWidgetUserIdAutomatic NOTIFY discordWidgetChanged)

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
    QString authProvider() const { return m_authProvider; }
    bool youtubeLinked() const { return m_youtubeLinked; }
    QVariantMap youtubeHub() const { return m_youtubeHub; }
    bool youtubeHubLoading() const { return m_youtubeHubLoading; }
    QString statusMessage() const { return m_statusMessage; }
    QVariantList searchResults() const { return m_searchResults; }
    QVariantList searchAlbums() const { return m_searchAlbums; }
    QVariantList searchArtists() const { return m_searchArtists; }
    QVariantMap catalogPage() const { return m_catalogPage; }
    bool catalogLoading() const { return m_catalogLoading; }
    bool catalogMoreLoading() const { return m_catalogMoreLoading; }
    bool canNavigateCatalogBack() const { return !m_catalogHistory.isEmpty(); }
    QVariantList queue() const { return m_queue; }
    QVariantList library() const { return m_library; }
    QVariantList downloads() const { return m_downloads; }
    qint64 offlineStorageUsed() const;
    qint64 offlineStorageLimitBytes() const { return m_offlineStorageLimitBytes; }
    QVariantMap tidalHub() const { return m_tidalHub; }
    bool tidalHubLoading() const { return m_tidalHubLoading; }
    bool tidalMoreLoading() const { return m_tidalMoreLoading; }
    int currentQueueIndex() const { return m_currentIndex; }
    QVariantMap currentTrack() const;
    bool playing() const;
    qint64 position() const;
    qint64 duration() const;
    double volume() const { return m_playback.volume(); }
    bool muted() const { return m_playback.muted(); }
    QString repeatMode() const { return m_repeatMode; }
    bool shuffleEnabled() const { return m_shuffleEnabled; }
    bool playbackLoading() const { return m_playback.loading(); }
    bool buffering() const { return m_playback.buffering(); }
    int bufferingPercent() const { return m_playback.bufferingPercent(); }
    QString playbackError() const { return m_playbackError; }
    QVariantList audioDevices() const { return m_playback.audioDevices(); }
    QString audioDevice() const { return m_playback.audioDevice(); }
    QColor accent() const { return m_accent; }
    QString accentMode() const { return m_accentMode; }
    QColor fixedAccent() const { return m_fixedAccent; }
    bool lowDataMode() const { return m_lowDataMode; }
    bool autoplayEnabled() const { return m_autoplayEnabled; }
    QString streamQuality() const { return m_streamQuality; }
    bool normalizationEnabled() const { return m_normalizationEnabled; }
    QVariantList equalizerBands() const { return m_equalizerBands; }
    QString equalizerPreset() const { return m_equalizerPreset; }
    QVariantMap listenStats() const { return m_listenStats; }
    QVariantMap buildInfo() const;
    bool discordWidgetEnabled() const { return m_discordWidget.enabled(); }
    bool discordWidgetConfigured() const { return m_discordWidget.configured(); }
    bool discordWidgetBusy() const { return m_discordWidget.busy(); }
    QString discordWidgetStatus() const { return m_discordWidget.status(); }
    QString discordApplicationId() const { return m_discordWidget.applicationId(); }
    QString discordRedirectUri() const { return m_discordWidget.redirectUri(); }
    QString discordWidgetUserId() const { return m_discordWidget.userId(); }
    bool discordWidgetUserIdAutomatic() const { return m_discordWidget.userIdAutomatic(); }

    QString playbackStatus() const;
    QVariantMap mprisMetadata() const;
    bool canGoNext() const;
    bool canGoPrevious() const;

    Q_INVOKABLE void startLogin();
    Q_INVOKABLE void openVerificationUrl();
    Q_INVOKABLE void cancelLogin();
    Q_INVOKABLE void unlink();
    Q_INVOKABLE void startYouTubeLogin(const QString &clientId, const QString &clientSecret);
    Q_INVOKABLE void connectYouTubeBrowserSession(const QString &headers);
    Q_INVOKABLE void unlinkYouTube();
    Q_INVOKABLE void loadYouTubeHub(bool refresh = false);
    Q_INVOKABLE void openYouTubeSetupGuide();
    Q_INVOKABLE void dismissEntitlementWarning();
    Q_INVOKABLE void openTidalAccount();
    Q_INVOKABLE void search(const QString &query);
    Q_INVOKABLE void openTrack(const QString &id);
    Q_INVOKABLE void openTrackItem(const QVariantMap &track);
    Q_INVOKABLE void openAlbum(const QString &id);
    Q_INVOKABLE void openAlbumItem(const QVariantMap &album);
    Q_INVOKABLE void openArtist(const QString &id);
    Q_INVOKABLE void openArtistItem(const QVariantMap &artist);
    Q_INVOKABLE void openPlaylist(const QString &id, const QString &provider = QStringLiteral("tidal"));
    Q_INVOKABLE void openTrackArtist(const QVariantMap &track, int artistIndex);
    Q_INVOKABLE void navigateCatalogBack();
    Q_INVOKABLE void closeCatalog();
    Q_INVOKABLE void loadMoreCatalog(const QString &section);
    Q_INVOKABLE void enqueueCatalogTrack(const QVariantMap &track);
    Q_INVOKABLE void playNextCatalogTrack(const QVariantMap &track);
    Q_INVOKABLE void playCatalogTrack(const QVariantMap &track);
    Q_INVOKABLE void startRadio(const QVariantMap &track);
    Q_INVOKABLE void saveCatalogTrack(const QVariantMap &track);
    Q_INVOKABLE void playCatalogCollection();
    Q_INVOKABLE void enqueueSearchResult(int index);
    Q_INVOKABLE void playSearchResult(int index);
    Q_INVOKABLE void playQueueIndex(int index);
    Q_INVOKABLE void removeQueueIndex(int index);
    Q_INVOKABLE void moveQueueIndex(int fromIndex, int toIndex);
    Q_INVOKABLE void clearQueue();
    Q_INVOKABLE void addSearchResultToLibrary(int index);
    Q_INVOKABLE void playLibraryIndex(int index);
    Q_INVOKABLE void removeLibraryIndex(int index);
    Q_INVOKABLE void downloadTrack(const QVariantMap &track);
    Q_INVOKABLE void pauseDownload(const QString &trackId, const QString &provider = QStringLiteral("tidal"));
    Q_INVOKABLE void removeDownload(const QString &trackId, const QString &provider = QStringLiteral("tidal"));
    Q_INVOKABLE void removeCompletedDownloads();
    Q_INVOKABLE void removeUnfinishedDownloads();
    Q_INVOKABLE void setOfflineStorageLimitBytes(qint64 bytes);
    Q_INVOKABLE void openDownloadsFolder();
    Q_INVOKABLE void loadTidalHub(bool refresh = false);
    Q_INVOKABLE void loadMoreTidal(const QString &section);
    Q_INVOKABLE void togglePlay();
    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void next();
    Q_INVOKABLE void previous();
    Q_INVOKABLE void seek(qint64 positionMs);
    Q_INVOKABLE void seekBy(qint64 offsetMs);
    Q_INVOKABLE void setVolume(double volume);
    Q_INVOKABLE void setMuted(bool muted);
    Q_INVOKABLE void setRepeatMode(const QString &mode);
    Q_INVOKABLE void setShuffleEnabled(bool enabled);
    Q_INVOKABLE void setAudioDevice(const QString &device);
    Q_INVOKABLE void refreshAudioDevices();
    Q_INVOKABLE void retryPlayback();
    Q_INVOKABLE void setAutoplayEnabled(bool enabled);
    Q_INVOKABLE void setStreamQuality(const QString &quality);
    Q_INVOKABLE void setNormalizationEnabled(bool enabled);
    Q_INVOKABLE void setEqualizerBand(int index, double gainDb);
    Q_INVOKABLE void applyEqualizerPreset(const QString &preset);
    Q_INVOKABLE void setAccentMode(const QString &mode);
    Q_INVOKABLE void setFixedAccent(const QColor &color);
    Q_INVOKABLE void setLowDataMode(bool enabled);
    Q_INVOKABLE void setDiscordWidgetEnabled(bool enabled);
    Q_INVOKABLE void setDiscordApplicationId(const QString &applicationId);
    Q_INVOKABLE void setDiscordRedirectUri(const QString &redirectUri);
    Q_INVOKABLE void setDiscordWidgetUserId(const QString &userId);
    Q_INVOKABLE void useDetectedDiscordWidgetUserId();
    Q_INVOKABLE void authorizeDiscordWidget();
    Q_INVOKABLE void storeDiscordWidgetToken(const QString &token);
    Q_INVOKABLE void forgetDiscordWidgetToken();
    Q_INVOKABLE void publishDiscordWidgetNow();

signals:
    void providerReadyChanged();
    void linkedChanged();
    void authPendingChanged();
    void busyChanged();
    void entitlementChanged();
    void authDetailsChanged();
    void youtubeAccountChanged();
    void statusMessageChanged();
    void searchResultsChanged();
    void catalogPageChanged();
    void queueChanged();
    void libraryChanged();
    void downloadsChanged();
    void offlineStorageLimitChanged();
    void tidalHubChanged();
    void currentTrackChanged();
    void playbackChanged();
    void positionChanged();
    void durationChanged();
    void volumeChanged();
    void mutedChanged();
    void playbackOptionsChanged();
    void playbackConditionChanged();
    void audioDevicesChanged();
    void audioDeviceChanged();
    void accentChanged();
    void appearanceChanged();
    void autoplayEnabledChanged();
    void streamQualityChanged();
    void audioProcessingChanged();
    void listenStatsChanged();
    void discordWidgetChanged();
    void toastRequested(const QString &message, const QString &kind);
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
    void notify(const QString &message, const QString &kind = QStringLiteral("info"));
    void setEntitlementWarning(bool visible, const QString &message = {});
    void playTrackAt(int index);
    void playSingleTrack(const QVariantMap &track);
    void playTracks(const QVariantList &tracks, bool preserveProvidedOrder = false);
    void clearPlaylistContinuation();
    void activatePlaylistContinuation(const QString &playlistId, const QString &cursor);
    void requestPlaylistContinuation(bool continueWhenReady);
    bool playlistNeedsRefill() const;
    bool atLoadedQueueEnd() const;
    void openCatalog(const QString &kind, const QString &id, bool preserveCurrent = true,
                     const QString &provider = QStringLiteral("tidal"));
    void enqueueTrack(const QVariantMap &track);
    void saveTrack(const QVariantMap &track);
    void resolveCurrentSource(qint64 startPositionMs = 0, bool autoplay = true);
    void prepareNextSource();
    void advancePreparedTrack();
    void invalidatePreparedNext();
    int nextQueueIndex() const;
    void beginNextDownload();
    void startDownloadTransfer(const QJsonObject &source);
    void startYouTubeDownload();
    void startDownloadFinalization();
    void finishDownloadTransfer(bool succeeded, const QString &error = {});
    void saveDownloadState(const QVariantMap &track, const QString &state,
                           const QString &localPath = {}, qint64 bytesDownloaded = 0,
                           std::optional<qint64> bytesTotal = std::nullopt,
                           const QString &errorCode = {});
    QVariantMap downloadForTrack(const QString &provider, const QString &trackId) const;
    QString downloadPath(const QVariantMap &track, bool partial) const;
    QString downloadPartsDirectory(const QVariantMap &track) const;
    QString downloadAssemblyPath(const QVariantMap &track) const;
    QStringList downloadPartFiles(const QVariantMap &track) const;
    qint64 downloadWorkingBytes(const QVariantMap &track) const;
    qint64 mediaDurationMs(const QString &path) const;
    void removeDownloadWorkingFiles(const QVariantMap &track);
    QString downloadArtworkPath(const QVariantMap &track) const;
    void downloadArtwork(const QVariantMap &track);
    QString downloadsDirectory() const;
    void requestRelated(bool continueWhenReady);
    bool openCore();
    QJsonObject dispatchCore(const QJsonObject &command);
    void refreshCoreSnapshot();
    static QJsonObject variantTrackToCore(const QVariantMap &track);
    static QVariantMap coreTrackToVariant(const QJsonObject &track);
    void loadAccent(const QString &artworkUrl);
    void animateAccent(const QColor &color);
    void updateDiscordPresence();
    void resumeListeningSession();
    void suspendListeningSession();
    void finishListeningSession();
    QString trackKey(const QVariantMap &track) const;
    QColor paletteColor(const QImage &image) const;
    static QVariantMap jsonTrackToVariant(const QJsonObject &track);
    static QVariantMap jsonAlbumToVariant(const QJsonObject &album);
    static QVariantMap jsonArtistToVariant(const QJsonObject &artist);
    static QVariantMap jsonPlaylistToVariant(const QJsonObject &playlist);
    static QVariantMap jsonCatalogPageToVariant(const QJsonObject &page);

    QProcess m_provider;
    QByteArray m_providerBuffer;
    QHash<int, ReplyHandler> m_replies;
    int m_nextRequestId = 1;

    LinuxPlayback m_playback;
    QTimer m_checkpointTimer;
    quint64 m_sourceGeneration = 0;
    quint64 m_prepareGeneration = 0;
    qint64 m_preparedEntryId = -1;
    bool m_preparedLocalSource = false;
    qint64 m_resumePositionMs = 0;
    qint64 m_displayPositionOverride = -1;
    DiscordPresence m_discordPresence;
    DiscordWidgetExporter m_discordWidget;
    QNetworkAccessManager m_network;
    QVariantAnimation m_accentAnimation;
    QVariantList m_searchResults;
    QVariantList m_searchAlbums;
    QVariantList m_searchArtists;
    QVariantMap m_catalogPage;
    QVariantList m_catalogHistory;
    bool m_catalogLoading = false;
    bool m_catalogMoreLoading = false;
    quint64 m_catalogGeneration = 0;
    QVariantList m_queue;
    QVariantList m_library;
    QVariantList m_downloads;
    QList<QVariantMap> m_downloadQueue;
    QVariantMap m_activeDownloadTrack;
    QProcess m_downloadProcess;
    QTimer m_downloadProgressTimer;
    enum class DownloadProcessStage { Idle, Transfer, YouTubeTransfer, Finalize };
    DownloadProcessStage m_downloadProcessStage = DownloadProcessStage::Idle;
    QString m_activeDownloadPartPath;
    quint64 m_downloadGeneration = 0;
    bool m_cancelActiveDownload = false;
    bool m_removeActiveDownload = false;
    bool m_pauseDownloadForQuota = false;
    qint64 m_offlineStorageLimitBytes = 0;
    bool m_playingLocalSource = false;
    QVariantMap m_tidalHub;
    bool m_tidalHubLoading = false;
    bool m_tidalMoreLoading = false;
    QVariantMap m_youtubeHub;
    bool m_youtubeHubLoading = false;
    bool m_youtubeLinked = false;
    QVariantMap m_listenStats;
    QList<qint64> m_queueEntryIds;
    QList<qint64> m_playOrderEntryIds;
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
    QString m_authProvider = QStringLiteral("tidal");
    QString m_statusMessage = QStringLiteral("Starting colorful…");
    QString m_entitlementMessage;
    QColor m_accent = QColor(QStringLiteral("#ff4f91"));
    QString m_accentMode = QStringLiteral("album");
    QColor m_fixedAccent = QColor(QStringLiteral("#a970ff"));
    bool m_lowDataMode = false;
    QString m_pendingArtworkUrl;
    QPointer<QNetworkReply> m_accentReply;
    bool m_autoplayEnabled = true;
    QString m_streamQuality = QStringLiteral("best");
    QString m_repeatMode = QStringLiteral("off");
    bool m_shuffleEnabled = false;
    QString m_playbackError;
    bool m_normalizationEnabled = false;
    QVariantList m_equalizerBands;
    QString m_equalizerPreset = QStringLiteral("Flat");
    bool m_relatedPending = false;
    bool m_relatedContinueWhenReady = false;
    qint64 m_relatedSeedEntryId = -1;
    quint64 m_relatedGeneration = 0;
    QString m_playlistId;
    QString m_playlistCursor;
    bool m_playlistContinuationPending = false;
    bool m_playlistContinueWhenReady = false;
    quint64 m_playlistContinuationGeneration = 0;
    QElapsedTimer m_listenClock;
    QVariantMap m_listenTrack;
    QString m_listenTrackKey;
    QString m_deviceId;
    qint64 m_listenStartedAtMs = 0;
    qint64 m_listenedMs = 0;
    bool m_playbackReady = false;
};
