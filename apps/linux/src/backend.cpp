#include "backend.h"
#include "buildinfo.h"

#include <QCoreApplication>
#include <QDesktopServices>
#include <QDateTime>
#include <QDBusObjectPath>
#include <QDir>
#include <QCryptographicHash>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QProcessEnvironment>
#include <QSet>
#include <QSettings>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUrl>
#include <QUuid>
#include <algorithm>
#include <array>
#include <cmath>

namespace {
QString safeTrackPath(const QVariantMap &track)
{
    const auto id = track.value(QStringLiteral("id")).toString();
    QString safe;
    safe.reserve(id.size());
    for (const auto character : id) safe.append(character.isLetterOrNumber() ? character : QChar('_'));
    return QStringLiteral("/org/mpris/MediaPlayer2/track/%1").arg(safe.isEmpty() ? QStringLiteral("unknown") : safe);
}

double linearRgbChannel(int value)
{
    const double normalized = value / 255.0;
    return normalized <= 0.03928
        ? normalized / 12.92
        : std::pow((normalized + 0.055) / 1.055, 2.4);
}

double relativeLuminance(const QColor &color)
{
    return linearRgbChannel(color.red()) * 0.2126
        + linearRgbChannel(color.green()) * 0.7152
        + linearRgbChannel(color.blue()) * 0.0722;
}

double contrastRatio(const QColor &first, const QColor &second)
{
    const auto firstLuminance = relativeLuminance(first);
    const auto secondLuminance = relativeLuminance(second);
    const auto lighter = std::max(firstLuminance, secondLuminance);
    const auto darker = std::min(firstLuminance, secondLuminance);
    return (lighter + 0.05) / (darker + 0.05);
}

QColor mixToward(const QColor &color, int target, double amount)
{
    const auto mix = [target, amount](int value) {
        return qRound(value + (target - value) * amount);
    };
    return QColor(mix(color.red()), mix(color.green()), mix(color.blue()));
}

QColor normalizeAlbumAccent(const QColor &sampled)
{
    float hue = 0;
    float saturation = 0;
    float lightness = 0;
    float alpha = 1;
    sampled.getHslF(&hue, &saturation, &lightness, &alpha);
    if (saturation < 0.08) return QColor(QStringLiteral("#f5f5f5"));

    const auto base = QColor::fromHslF(
        hue,
        std::max(0.3f, saturation),
        std::clamp(lightness, 0.34f, 0.64f),
        alpha);
    const QColor background(QStringLiteral("#121212"));
    for (double amount = 0; amount <= 0.72 + 0.001; amount += 0.08) {
        const auto candidate = mixToward(base, 255, amount);
        if (contrastRatio(candidate, background) >= 4.5) return candidate;
    }
    return Qt::white;
}

std::optional<double> normalizationNumber(const QJsonObject &source, const QString &group,
                                          const QString &field)
{
    const auto value = source.value(group).toObject().value(field);
    if (!value.isDouble() || !std::isfinite(value.toDouble())) return std::nullopt;
    return value.toDouble();
}
}

Backend::Backend(QObject *parent)
    : QObject(parent)
{
    QSettings settings;
    m_deviceId = settings.value(QStringLiteral("identity/deviceId")).toString();
    if (m_deviceId.isEmpty()) {
        m_deviceId = QUuid::createUuid().toString(QUuid::WithoutBraces);
        settings.setValue(QStringLiteral("identity/deviceId"), m_deviceId);
    }
    const QColor restoredAccent(settings.value(QStringLiteral("appearance/accent")).toString());
    if (restoredAccent.isValid()) m_accent = restoredAccent;
    m_accentMode = settings.value(QStringLiteral("appearance/accentMode"), QStringLiteral("album")).toString();
    if (m_accentMode != QStringLiteral("album") && m_accentMode != QStringLiteral("fixed")) m_accentMode = QStringLiteral("album");
    const QColor restoredFixedAccent(settings.value(QStringLiteral("appearance/fixedAccent"), QStringLiteral("#a970ff")).toString());
    if (restoredFixedAccent.isValid()) m_fixedAccent = normalizeAlbumAccent(restoredFixedAccent);
    m_lowDataMode = settings.value(QStringLiteral("appearance/lowDataMode"), false).toBool();
    if (m_accentMode == QStringLiteral("fixed")) m_accent = m_fixedAccent;
    m_autoplayEnabled = settings.value(QStringLiteral("playback/autoplay"), true).toBool();
    m_streamQuality = settings.value(QStringLiteral("playback/streamQuality"), QStringLiteral("best")).toString();
    if (m_streamQuality != QStringLiteral("best") && m_streamQuality != QStringLiteral("lossless")
        && m_streamQuality != QStringLiteral("high")) m_streamQuality = QStringLiteral("best");
    m_normalizationEnabled = settings.value(QStringLiteral("playback/normalization"), false).toBool();
    m_offlineStorageLimitBytes = std::max<qint64>(0, settings.value(QStringLiteral("storage/offlineLimitBytes"), 0).toLongLong());
    m_playback.setVolume(std::clamp(settings.value(QStringLiteral("playback/volume"), 0.78).toDouble(), 0.0, 1.0));
    m_playback.setMuted(settings.value(QStringLiteral("playback/muted"), false).toBool());
    m_playback.setAudioDevice(settings.value(QStringLiteral("playback/audioDevice"), QStringLiteral("auto")).toString());
    const auto storedEq = settings.value(QStringLiteral("playback/equalizerBands")).toList();
    if (storedEq.size() == 10) {
        for (const auto &gain : storedEq)
            m_equalizerBands.append(std::clamp(gain.toDouble(), -12.0, 12.0));
    } else {
        for (int index = 0; index < 10; ++index) m_equalizerBands.append(0.0);
    }
    m_equalizerPreset = settings.value(QStringLiteral("playback/equalizerPreset"), QStringLiteral("Flat")).toString();
    QList<double> initialEq;
    initialEq.reserve(m_equalizerBands.size());
    for (const auto &gain : std::as_const(m_equalizerBands)) initialEq.append(gain.toDouble());
    m_playback.setReplayGain(m_normalizationEnabled);
    m_playback.setEqualizer(initialEq);

    m_accentAnimation.setDuration(720);
    m_accentAnimation.setEasingCurve(QEasingCurve::OutCubic);
    connect(&m_accentAnimation, &QVariantAnimation::valueChanged, this, [this](const QVariant &value) {
        const auto color = value.value<QColor>();
        if (!color.isValid() || color == m_accent) return;
        m_accent = color;
        emit accentChanged();
    });
    connect(&m_accentAnimation, &QVariantAnimation::finished, this, [this] {
        QSettings().setValue(QStringLiteral("appearance/accent"), m_accent.name(QColor::HexRgb));
    });

    m_checkpointTimer.setInterval(10'000);
    connect(&m_checkpointTimer, &QTimer::timeout, this, [this] {
        if (m_currentIndex < 0 || !playing()) return;
        suspendListeningSession();
        resumeListeningSession();
        dispatchCore({{QStringLiteral("command"), QStringLiteral("checkpoint_position")},
                      {QStringLiteral("position_ms"), position()}});
    });
    m_checkpointTimer.start();

    // YouTube source resolution may launch yt-dlp and cannot be cancelled once
    // it has entered the provider host. Collapse a burst of manual Next clicks
    // into one final resolver instead of spawning one process per skipped item.
    m_manualSkipTimer.setSingleShot(true);
    m_manualSkipTimer.setInterval(140);
    connect(&m_manualSkipTimer, &QTimer::timeout, this, [this] {
        resolveCurrentSource(0, m_manualSkipAutoplay && playing());
    });

    connect(&m_discordWidget, &DiscordWidgetExporter::stateChanged,
            this, &Backend::discordWidgetChanged);
    connect(&m_discordPresence, &DiscordPresence::userIdResolved,
            &m_discordWidget, &DiscordWidgetExporter::setUserId);
    m_discordPresence.setApplicationId(m_discordWidget.applicationId());
    connect(this, &Backend::listenStatsChanged, this, [this] {
        m_discordWidget.setStats(m_listenStats);
    });

    connect(&m_provider, &QProcess::readyReadStandardOutput, this, &Backend::processProviderOutput);
    connect(&m_provider, &QProcess::readyReadStandardError, this, [this] {
        const auto detail = QString::fromUtf8(m_provider.readAllStandardError()).trimmed();
        if (!detail.isEmpty()) setStatus(QStringLiteral("Provider: %1").arg(detail));
    });
    connect(&m_provider, &QProcess::errorOccurred, this, [this](QProcess::ProcessError) {
        setProviderReady(false);
        setStatus(QStringLiteral("Could not start the TIDAL provider host: %1").arg(m_provider.errorString()));
    });
    connect(&m_provider, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
            [this](int exitCode, QProcess::ExitStatus) {
        setProviderReady(false);
        if (QCoreApplication::closingDown()) return;
        setStatus(QStringLiteral("TIDAL provider stopped (exit %1)").arg(exitCode));
    });

    m_downloadProgressTimer.setInterval(1000);
    connect(&m_downloadProgressTimer, &QTimer::timeout, this, [this] {
        if (m_activeDownloadTrack.isEmpty() || m_downloadProcess.state() == QProcess::NotRunning) return;
        const auto size = downloadWorkingBytes(m_activeDownloadTrack);
        const auto previousSize = downloadForTrack(
            m_activeDownloadTrack.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString(),
            m_activeDownloadTrack.value(QStringLiteral("id")).toString())
                                  .value(QStringLiteral("bytesDownloaded")).toLongLong();
        const auto projectedUsage = std::max<qint64>(0, offlineStorageUsed() - previousSize) + size;
        if ((m_downloadProcessStage == DownloadProcessStage::Transfer
             || m_downloadProcessStage == DownloadProcessStage::YouTubeTransfer)
            && m_offlineStorageLimitBytes > 0 && projectedUsage >= m_offlineStorageLimitBytes) {
            m_pauseDownloadForQuota = true;
            m_cancelActiveDownload = true;
            m_downloadProcess.terminate();
            return;
        }
        saveDownloadState(m_activeDownloadTrack, QStringLiteral("downloading"), {}, std::max<qint64>(0, size));
    });
    connect(&m_downloadProcess, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
            [this](int exitCode, QProcess::ExitStatus status) {
        const auto detail = QString::fromUtf8(m_downloadProcess.readAllStandardError()).trimmed();
        const bool succeeded = status == QProcess::NormalExit && exitCode == 0;
        if ((m_downloadProcessStage == DownloadProcessStage::Transfer
             || m_downloadProcessStage == DownloadProcessStage::YouTubeTransfer) && succeeded
            && !m_cancelActiveDownload && !m_removeActiveDownload) {
            startDownloadFinalization();
            return;
        }
        const auto downloader = m_downloadProcessStage == DownloadProcessStage::YouTubeTransfer
            ? QStringLiteral("yt-dlp") : QStringLiteral("ffmpeg");
        finishDownloadTransfer(succeeded,
                               detail.isEmpty() ? QString{} : QStringLiteral("%1 could not download the source").arg(downloader));
    });
    connect(&m_downloadProcess, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error != QProcess::FailedToStart) return;
        QTimer::singleShot(0, this, [this] {
            if (!m_activeDownloadTrack.isEmpty()) finishDownloadTransfer(false, m_downloadProcess.errorString());
        });
    });

    connect(&m_playback, &LinuxPlayback::stateChanged, this, [this] {
        if (playing()) resumeListeningSession();
        else suspendListeningSession();
        emit playbackChanged();
        updateDiscordPresence();
    });
    connect(this, &Backend::currentTrackChanged, this, [this] {
        emit durationChanged();
        updateDiscordPresence();
    });
    connect(this, &Backend::seeked, this, [this] { updateDiscordPresence(); });
    connect(&m_playback, &LinuxPlayback::positionChanged, this, [this] { emit positionChanged(); });
    connect(&m_playback, &LinuxPlayback::durationChanged, this, &Backend::durationChanged);
    connect(&m_playback, &LinuxPlayback::volumeChanged, this, &Backend::volumeChanged);
    connect(&m_playback, &LinuxPlayback::mutedChanged, this, &Backend::mutedChanged);
    connect(&m_playback, &LinuxPlayback::bufferingChanged, this, &Backend::playbackConditionChanged);
    connect(&m_playback, &LinuxPlayback::audioDevicesChanged, this, &Backend::audioDevicesChanged);
    connect(&m_playback, &LinuxPlayback::audioDeviceChanged, this, &Backend::audioDeviceChanged);
    connect(&m_playback, &LinuxPlayback::loadingChanged, this, [this](bool loading) {
        if (loading && !m_playbackError.isEmpty()) {
            m_playbackError.clear();
            emit playbackConditionChanged();
        }
        if (loading) {
            suspendListeningSession();
            m_playbackReady = false;
        } else {
            m_playbackReady = true;
            resumeListeningSession();
        }
        setBusy(loading);
        setStatus(loading ? (m_playingLocalSource ? QStringLiteral("Opening offline file…")
                                                  : QStringLiteral("Opening lossless stream…"))
                          : (m_playingLocalSource ? QStringLiteral("Playing offline")
                                                  : QStringLiteral("Playing from TIDAL")));
        // A track-to-track URI swap keeps the logical state Playing, so there
        // is intentionally no stateChanged signal to refresh integrations.
        // Publish the new timeline once its preroll (and restore seek) ends.
        if (!loading) {
            updateDiscordPresence();
            prepareNextSource();
        }
        emit playbackConditionChanged();
    });
    connect(&m_playback, &LinuxPlayback::errorOccurred, this, [this](const QString &error) {
        suspendListeningSession();
        m_playbackReady = false;
        setBusy(false);
        setStatus(QStringLiteral("Playback error: %1").arg(error));
        m_playbackError = error;
        emit playbackConditionChanged();
        notify(error, QStringLiteral("error"));
    });
    connect(&m_playback, &LinuxPlayback::seekCompleted, this, [this](qint64 confirmedPositionMs) {
        m_resumePositionMs = confirmedPositionMs;
        m_displayPositionOverride = -1;
        dispatchCore({{QStringLiteral("command"), QStringLiteral("seek_to")},
                      {QStringLiteral("position_ms"), confirmedPositionMs}});
        emit positionChanged();
        emit seeked(confirmedPositionMs);
        resumeListeningSession();
    });
    connect(&m_playback, &LinuxPlayback::seekFailed, this, [this](qint64, const QString &reason) {
        m_displayPositionOverride = -1;
        setStatus(QStringLiteral("Seek failed: %1").arg(reason));
        emit positionChanged();
        resumeListeningSession();
    });
    connect(&m_playback, &LinuxPlayback::endOfMedia, this, [this] { advanceToNext(false); });
    connect(&m_playback, &LinuxPlayback::preparedNextStarted, this, &Backend::advancePreparedTrack);
    connect(&m_playback, &LinuxPlayback::preparedNextFailed, this, [this](const QString &) {
        ++m_prepareGeneration;
        m_preparedEntryId = -1;
        m_preparedLocalSource = false;
    });
    connect(&m_playback, &LinuxPlayback::preparedPlaybackFailed, this, [this](const QString &) {
        m_playbackReady = false;
        setStatus(QStringLiteral("Refreshing the next playback source…"));
        resolveCurrentSource(0, playing());
    });

    openCore();
    m_playback.refreshAudioDevices();
    const auto restoredDownloads = m_downloads;
    for (const auto &value : restoredDownloads) {
        const auto entry = value.toMap();
        const auto state = entry.value(QStringLiteral("downloadState")).toString();
        if (state == QStringLiteral("queued") || state == QStringLiteral("resolving")
            || state == QStringLiteral("downloading")) {
            saveDownloadState(entry, QStringLiteral("paused"), {},
                              entry.value(QStringLiteral("bytesDownloaded")).toLongLong());
        }
    }
    startProviderHost();
}

Backend::~Backend()
{
    finishListeningSession();
    if (m_currentIndex >= 0) {
        dispatchCore({{QStringLiteral("command"), QStringLiteral("checkpoint_position")},
                      {QStringLiteral("position_ms"), position()}});
    }
    if (m_provider.state() != QProcess::NotRunning) {
        m_provider.closeWriteChannel();
        m_provider.terminate();
        if (!m_provider.waitForFinished(1200)) m_provider.kill();
    }
    if (m_downloadProcess.state() != QProcess::NotRunning) {
        m_cancelActiveDownload = true;
        m_downloadProcess.terminate();
        if (!m_downloadProcess.waitForFinished(1200)) {
            m_downloadProcess.kill();
            m_downloadProcess.waitForFinished(1200);
        }
    }
}

QVariantMap Backend::currentTrack() const
{
    return m_currentIndex >= 0 && m_currentIndex < m_queue.size()
        ? m_queue.at(m_currentIndex).toMap()
        : QVariantMap{};
}

qint64 Backend::offlineStorageUsed() const
{
    qint64 total = 0;
    for (const auto &value : m_downloads)
        total += std::max<qint64>(0, value.toMap().value(QStringLiteral("bytesDownloaded")).toLongLong());
    return total;
}

QVariantMap Backend::buildInfo() const
{
    return colorfulBuildInfo();
}

bool Backend::openCore()
{
    const auto dataDirectory = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (!QDir().mkpath(dataDirectory)) {
        setStatus(QStringLiteral("Could not create colorful's data directory"));
        return false;
    }
    QString error;
    if (!m_core.open(QDir(dataDirectory).filePath(QStringLiteral("colorful.sqlite3")), &error)) {
        setStatus(QStringLiteral("Could not open the local library: %1").arg(error));
        return false;
    }
    refreshCoreSnapshot();
    return true;
}

QJsonObject Backend::dispatchCore(const QJsonObject &command)
{
    QString error;
    const auto response = m_core.dispatch(command, &error);
    if (!response.value(QStringLiteral("ok")).toBool()) {
        if (!error.isEmpty()) setStatus(QStringLiteral("Local engine: %1").arg(error));
        return {};
    }
    refreshCoreSnapshot();
    return response.value(QStringLiteral("value")).toObject();
}

void Backend::refreshCoreSnapshot()
{
    QString error;
    const auto response = m_core.snapshot(&error);
    if (!response.value(QStringLiteral("ok")).toBool()) {
        if (!error.isEmpty()) setStatus(QStringLiteral("Local engine: %1").arg(error));
        return;
    }
    const auto snapshot = response.value(QStringLiteral("value")).toObject();
    const auto playback = snapshot.value(QStringLiteral("playback")).toObject();
    const auto queue = snapshot.value(QStringLiteral("queue")).toObject();
    const auto entries = queue.value(QStringLiteral("entries")).toArray();
    const auto playOrder = queue.value(QStringLiteral("playOrder")).toArray();
    const auto tracks = snapshot.value(QStringLiteral("queueTracks")).toArray();
    const auto currentEntryId = queue.value(QStringLiteral("current")).toInteger(-1);
    const auto nextRepeatMode = playback.value(QStringLiteral("repeat")).toString(QStringLiteral("off"));
    const bool nextShuffleEnabled = playback.value(QStringLiteral("shuffle")).toBool(false);

    QVariantList nextQueue;
    QList<qint64> nextEntryIds;
    QList<qint64> nextPlayOrderEntryIds;
    int nextCurrentIndex = -1;
    const auto count = std::min(entries.size(), tracks.size());
    for (qsizetype index = 0; index < count; ++index) {
        const auto entryId = entries.at(index).toObject().value(QStringLiteral("id")).toInteger();
        nextEntryIds.append(entryId);
        nextQueue.append(coreTrackToVariant(tracks.at(index).toObject()));
        if (entryId == currentEntryId) nextCurrentIndex = static_cast<int>(index);
    }
    for (const auto &entryId : playOrder) nextPlayOrderEntryIds.append(entryId.toInteger());

    QVariantList nextLibrary;
    for (const auto &track : snapshot.value(QStringLiteral("library")).toArray()) {
        nextLibrary.append(coreTrackToVariant(track.toObject()));
    }

    QVariantList nextDownloads;
    const auto downloadJobs = snapshot.value(QStringLiteral("downloads")).toArray();
    const auto downloadTracks = snapshot.value(QStringLiteral("downloadTracks")).toArray();
    const auto downloadCount = std::min(downloadJobs.size(), downloadTracks.size());
    for (qsizetype index = 0; index < downloadCount; ++index) {
        auto entry = coreTrackToVariant(downloadTracks.at(index).toObject());
        const auto job = downloadJobs.at(index).toObject();
        entry.insert(QStringLiteral("downloadState"), job.value(QStringLiteral("state")).toString());
        entry.insert(QStringLiteral("localPath"), job.value(QStringLiteral("localPath")).toString());
        entry.insert(QStringLiteral("bytesDownloaded"), job.value(QStringLiteral("bytesDownloaded")).toInteger());
        entry.insert(QStringLiteral("bytesTotal"), job.value(QStringLiteral("bytesTotal")).toInteger());
        entry.insert(QStringLiteral("downloadError"), job.value(QStringLiteral("errorCode")).toString());
        nextDownloads.append(entry);
    }

    const auto previousArtworkUrl = currentTrack().value(QStringLiteral("coverUrl")).toString();
    const bool queueWasChanged = nextQueue != m_queue || nextEntryIds != m_queueEntryIds
        || nextPlayOrderEntryIds != m_playOrderEntryIds;
    const bool currentWasChanged = currentEntryId != m_currentEntryId;
    const bool libraryWasChanged = nextLibrary != m_library;
    const bool downloadsWereChanged = nextDownloads != m_downloads;
    const auto nextListenStats = snapshot.value(QStringLiteral("listenStats")).toObject().toVariantMap();
    const bool listenStatsWereChanged = nextListenStats != m_listenStats;
    const bool playbackOptionsWereChanged = nextRepeatMode != m_repeatMode
        || nextShuffleEnabled != m_shuffleEnabled;
    m_queue = std::move(nextQueue);
    m_queueEntryIds = std::move(nextEntryIds);
    m_playOrderEntryIds = std::move(nextPlayOrderEntryIds);
    m_currentIndex = nextCurrentIndex;
    m_currentEntryId = currentEntryId;
    m_library = std::move(nextLibrary);
    m_downloads = std::move(nextDownloads);
    m_listenStats = nextListenStats;
    m_repeatMode = nextRepeatMode;
    m_shuffleEnabled = nextShuffleEnabled;
    const auto currentArtworkUrl = currentTrack().value(QStringLiteral("coverUrl")).toString();
    if (!currentArtworkUrl.isEmpty() && currentArtworkUrl != previousArtworkUrl) loadAccent(currentArtworkUrl);
    if (currentWasChanged) {
        m_resumePositionMs = playback.value(QStringLiteral("positionMs")).toInteger();
        m_displayPositionOverride = m_resumePositionMs;
        emit positionChanged();
    }
    if (queueWasChanged) emit queueChanged();
    if (currentWasChanged || queueWasChanged) emit currentTrackChanged();
    if (libraryWasChanged) emit libraryChanged();
    if (downloadsWereChanged) emit downloadsChanged();
    if (listenStatsWereChanged) emit listenStatsChanged();
    if (playbackOptionsWereChanged) emit playbackOptionsChanged();
}

QJsonObject Backend::variantTrackToCore(const QVariantMap &track)
{
    QJsonArray artists;
    const auto artistCredits = track.value(QStringLiteral("artistCredits")).toList();
    if (!artistCredits.isEmpty()) {
        for (const auto &value : artistCredits) {
            const auto credit = value.toMap();
            const auto artistId = credit.value(QStringLiteral("id")).toString();
            artists.append(QJsonObject{
                {QStringLiteral("id"), artistId.isEmpty() ? QJsonValue(QJsonValue::Null)
                    : QJsonValue(QJsonObject{{QStringLiteral("provider"), track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()},
                                             {QStringLiteral("providerId"), artistId}})},
                {QStringLiteral("name"), credit.value(QStringLiteral("name")).toString()},
            });
        }
    } else {
        for (const auto &name : track.value(QStringLiteral("artists")).toStringList()) {
            artists.append(QJsonObject{{QStringLiteral("id"), QJsonValue::Null},
                                       {QStringLiteral("name"), name}});
        }
    }
    const auto albumId = track.value(QStringLiteral("albumId")).toString();
    const auto coverUrl = track.value(QStringLiteral("coverRemoteUrl"),
                                      track.value(QStringLiteral("coverUrl"))).toString();
    const auto coverLocalPath = track.value(QStringLiteral("coverLocalPath")).toString();
    const auto durationMs = track.value(QStringLiteral("durationMs")).toLongLong();
    return {
        {QStringLiteral("id"), QJsonObject{{QStringLiteral("provider"), track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()},
                                           {QStringLiteral("providerId"), track.value(QStringLiteral("id")).toString()}}},
        {QStringLiteral("title"), track.value(QStringLiteral("title")).toString()},
        {QStringLiteral("version"), track.value(QStringLiteral("version")).toString().isEmpty()
                                           ? QJsonValue(QJsonValue::Null) : QJsonValue(track.value(QStringLiteral("version")).toString())},
        {QStringLiteral("artists"), artists},
        {QStringLiteral("albumId"), albumId.isEmpty() ? QJsonValue(QJsonValue::Null)
            : QJsonValue(QJsonObject{{QStringLiteral("provider"), track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()},
                                     {QStringLiteral("providerId"), albumId}})},
        {QStringLiteral("albumTitle"), track.value(QStringLiteral("albumTitle")).toString().isEmpty()
                                                ? QJsonValue(QJsonValue::Null) : QJsonValue(track.value(QStringLiteral("albumTitle")).toString())},
        {QStringLiteral("artwork"), coverUrl.isEmpty() && coverLocalPath.isEmpty() ? QJsonValue(QJsonValue::Null)
            : QJsonValue(QJsonObject{{QStringLiteral("url"), coverUrl},
                                     {QStringLiteral("localKey"), coverLocalPath.isEmpty()
                                          ? QJsonValue(QJsonValue::Null) : QJsonValue(coverLocalPath)},
                                     {QStringLiteral("width"), QJsonValue::Null},
                                     {QStringLiteral("height"), QJsonValue::Null}})},
        {QStringLiteral("durationMs"), durationMs > 0 ? QJsonValue(durationMs) : QJsonValue(QJsonValue::Null)},
        {QStringLiteral("isrc"), track.value(QStringLiteral("isrc")).toString().isEmpty()
                                        ? QJsonValue(QJsonValue::Null) : QJsonValue(track.value(QStringLiteral("isrc")).toString())},
        {QStringLiteral("explicit"), QJsonValue::Null},
    };
}

QVariantMap Backend::coreTrackToVariant(const QJsonObject &track)
{
    QStringList artists;
    QVariantList artistCredits;
    for (const auto &artist : track.value(QStringLiteral("artists")).toArray()) {
        const auto object = artist.toObject();
        const auto name = object.value(QStringLiteral("name")).toString();
        artists.append(name);
        artistCredits.append(QVariantMap{
            {QStringLiteral("id"), object.value(QStringLiteral("id")).toObject().value(QStringLiteral("providerId")).toString()},
            {QStringLiteral("name"), name},
        });
    }
    const auto artwork = track.value(QStringLiteral("artwork")).toObject();
    const auto coverRemoteUrl = artwork.value(QStringLiteral("url")).toString();
    const auto coverLocalPath = artwork.value(QStringLiteral("localKey")).toString();
    const auto coverUrl = !coverLocalPath.isEmpty() && QFileInfo::exists(coverLocalPath)
        ? QUrl::fromLocalFile(coverLocalPath).toString() : coverRemoteUrl;
    const auto id = track.value(QStringLiteral("id")).toObject();
    return {
        {QStringLiteral("provider"), id.value(QStringLiteral("provider")).toString()},
        {QStringLiteral("id"), id.value(QStringLiteral("providerId")).toString()},
        {QStringLiteral("title"), track.value(QStringLiteral("title")).toString()},
        {QStringLiteral("version"), track.value(QStringLiteral("version")).toString()},
        {QStringLiteral("artists"), artists},
        {QStringLiteral("artistCredits"), artistCredits},
        {QStringLiteral("artistText"), artists.join(QStringLiteral(", "))},
        {QStringLiteral("albumId"), track.value(QStringLiteral("albumId")).toObject().value(QStringLiteral("providerId")).toString()},
        {QStringLiteral("albumTitle"), track.value(QStringLiteral("albumTitle")).toString()},
        {QStringLiteral("durationMs"), track.value(QStringLiteral("durationMs")).toInteger()},
        {QStringLiteral("isrc"), track.value(QStringLiteral("isrc")).toString()},
        {QStringLiteral("coverUrl"), coverUrl},
        {QStringLiteral("coverRemoteUrl"), coverRemoteUrl},
        {QStringLiteral("coverLocalPath"), coverLocalPath},
    };
}

bool Backend::playing() const
{
    return m_playback.playing();
}

qint64 Backend::position() const
{
    if (m_displayPositionOverride >= 0) return m_displayPositionOverride;
    return !m_playback.hasSource() ? m_resumePositionMs : m_playback.position();
}

qint64 Backend::duration() const
{
    // HLS backends sometimes expose only the duration of the currently parsed
    // media window even though playback continues past it. TIDAL's catalog
    // duration describes the complete track and is stable for the timeline,
    // seeking, and MPRIS metadata.
    const auto catalogDuration = currentTrack().value(QStringLiteral("durationMs")).toLongLong();
    return catalogDuration > 0 ? catalogDuration : m_playback.duration();
}

QString Backend::playbackStatus() const
{
    switch (m_playback.state()) {
    case LinuxPlayback::State::Playing: return QStringLiteral("Playing");
    case LinuxPlayback::State::Paused: return QStringLiteral("Paused");
    case LinuxPlayback::State::Stopped: return QStringLiteral("Stopped");
    }
    return QStringLiteral("Stopped");
}

QVariantMap Backend::mprisMetadata() const
{
    const auto track = currentTrack();
    if (track.isEmpty()) return {};
    QVariantMap metadata;
    metadata.insert(QStringLiteral("mpris:trackid"), QVariant::fromValue(QDBusObjectPath(safeTrackPath(track))));
    metadata.insert(QStringLiteral("xesam:title"), track.value(QStringLiteral("title")));
    metadata.insert(QStringLiteral("xesam:artist"), track.value(QStringLiteral("artists")));
    metadata.insert(QStringLiteral("xesam:album"), track.value(QStringLiteral("albumTitle")));
    if (!m_lowDataMode)
        metadata.insert(QStringLiteral("mpris:artUrl"), track.value(QStringLiteral("coverUrl")));
    metadata.insert(QStringLiteral("mpris:length"), track.value(QStringLiteral("durationMs")).toLongLong() * 1000);
    return metadata;
}

int Backend::nextQueueIndex() const
{
    const auto playIndex = m_playOrderEntryIds.indexOf(m_currentEntryId);
    if (playIndex < 0 || m_playOrderEntryIds.isEmpty()) return -1;
    if (m_repeatMode == QStringLiteral("one")) return m_currentIndex;
    if (playIndex + 1 >= m_playOrderEntryIds.size()) {
        return m_repeatMode == QStringLiteral("all")
            ? m_queueEntryIds.indexOf(m_playOrderEntryIds.first()) : -1;
    }
    return m_queueEntryIds.indexOf(m_playOrderEntryIds.at(playIndex + 1));
}

bool Backend::canGoNext() const { return nextQueueIndex() >= 0; }
bool Backend::canGoPrevious() const
{
    if (position() > 3000) return m_currentIndex >= 0;
    const auto playIndex = m_playOrderEntryIds.indexOf(m_currentEntryId);
    return playIndex > 0 || (playIndex == 0 && m_repeatMode == QStringLiteral("all"));
}

void Backend::startProviderHost()
{
    const auto bun = qEnvironmentVariable("COLORFUL_BUN", QStandardPaths::findExecutable(QStringLiteral("bun")));
    if (bun.isEmpty()) {
        setStatus(QStringLiteral("Bun was not found. Install Bun or set COLORFUL_BUN."));
        return;
    }
    const auto sourceRoot = QString::fromUtf8(COLORFUL_SOURCE_DIR);
    const auto host = qEnvironmentVariable(
        "COLORFUL_PROVIDER_HOST",
        sourceRoot + QStringLiteral("/packages/provider-host/src/main.ts"));
    m_provider.setWorkingDirectory(sourceRoot);
    m_provider.setProcessChannelMode(QProcess::SeparateChannels);
    m_provider.start(bun, {host});
    if (!m_provider.waitForStarted(3000)) {
        setStatus(QStringLiteral("Could not launch provider host: %1").arg(m_provider.errorString()));
        return;
    }
    request(QStringLiteral("status"), {}, [this](const QJsonObject &message) {
        if (!message.value(QStringLiteral("ok")).toBool()) return;
        const auto data = message.value(QStringLiteral("data")).toObject();
        setProviderReady(true);
        setLinked(data.value(QStringLiteral("linked")).toBool());
        const auto youtubeLinked = data.value(QStringLiteral("youtubeLinked")).toBool();
        if (m_youtubeLinked != youtubeLinked) {
            m_youtubeLinked = youtubeLinked;
            emit youtubeAccountChanged();
        }
        const auto soundcloudLinked = data.value(QStringLiteral("soundcloudLinked")).toBool();
        if (m_soundcloudLinked != soundcloudLinked) {
            m_soundcloudLinked = soundcloudLinked;
            emit soundcloudAccountChanged();
        }
        if (!data.value(QStringLiteral("browseConfigured")).toBool()) {
            setStatus(QStringLiteral("TIDAL browse credentials are missing. Launch with scripts/run-linux.sh."));
        } else if (!data.value(QStringLiteral("deviceConfigured")).toBool()) {
            setStatus(QStringLiteral("TIDAL device-login credentials are missing."));
        } else {
            setStatus(m_linked ? QStringLiteral("TIDAL account restored") : QStringLiteral("Connect TIDAL, then search for something good"));
        }
        const auto smokeSearch = qEnvironmentVariable("COLORFUL_SMOKE_SEARCH");
        if (!smokeSearch.isEmpty()) search(smokeSearch);
    });
}

int Backend::request(const QString &type, const QJsonObject &payload, ReplyHandler handler)
{
    if (m_provider.state() != QProcess::Running) {
        setStatus(QStringLiteral("Provider host is not running"));
        return -1;
    }
    const int id = m_nextRequestId++;
    m_replies.insert(id, std::move(handler));
    const QJsonObject request{{QStringLiteral("id"), id}, {QStringLiteral("type"), type}, {QStringLiteral("payload"), payload}};
    m_provider.write(QJsonDocument(request).toJson(QJsonDocument::Compact));
    m_provider.write("\n");
    return id;
}

void Backend::processProviderOutput()
{
    m_providerBuffer.append(m_provider.readAllStandardOutput());
    for (;;) {
        const auto newline = m_providerBuffer.indexOf('\n');
        if (newline < 0) return;
        const auto line = m_providerBuffer.left(newline).trimmed();
        m_providerBuffer.remove(0, newline + 1);
        if (line.isEmpty()) continue;
        QJsonParseError error;
        const auto document = QJsonDocument::fromJson(line, &error);
        if (error.error != QJsonParseError::NoError || !document.isObject()) {
            setStatus(QStringLiteral("Provider sent malformed data"));
            continue;
        }
        handleProviderMessage(document.object());
    }
}

void Backend::handleProviderMessage(const QJsonObject &message)
{
    if (message.contains(QStringLiteral("event"))) {
        handleProviderEvent(message.value(QStringLiteral("event")).toString(), message);
        return;
    }
    const int id = message.value(QStringLiteral("id")).toInt(-1);
    if (auto handler = m_replies.take(id)) handler(message);
}

void Backend::handleProviderEvent(const QString &event, const QJsonObject &message)
{
    if (event == QStringLiteral("auth.restored") || event == QStringLiteral("auth.completed")) {
        setLinked(true);
        m_authPending = false;
        emit authPendingChanged();
        setStatus(event.endsWith(QStringLiteral("completed"))
                      ? QStringLiteral("TIDAL connected — search is ready")
                      : QStringLiteral("TIDAL account restored securely"));
        if (event.endsWith(QStringLiteral("completed"))) {
            emit toastRequested(QStringLiteral("TIDAL connected"), QStringLiteral("success"));
            loadTidalHub(false);
        }
    } else if (event == QStringLiteral("auth.failed")) {
        m_authPending = false;
        emit authPendingChanged();
        setStatus(message.value(QStringLiteral("error")).toString());
    } else if (event == QStringLiteral("youtube.auth.restored")
               || event == QStringLiteral("youtube.auth.completed")) {
        const auto completed = event.endsWith(QStringLiteral("completed"));
        m_youtubeLinked = true;
        // A newly pasted browser session may select a different YouTube
        // profile. Never retain the previous profile's cached library.
        if (completed) m_youtubeHub.clear();
        const auto account = message.value(QStringLiteral("data")).toObject()
                                 .value(QStringLiteral("account")).toObject();
        if (!account.isEmpty()) m_youtubeHub.insert(QStringLiteral("account"), account.toVariantMap());
        if (m_authProvider == QStringLiteral("youtube")) {
            m_authPending = false;
            emit authPendingChanged();
        }
        emit youtubeAccountChanged();
        setStatus(completed
                      ? QStringLiteral("YouTube Music connected")
                      : QStringLiteral("YouTube Music account restored securely"));
        if (completed) {
            emit toastRequested(QStringLiteral("YouTube Music connected"), QStringLiteral("success"));
            loadYouTubeHub(true);
        }
    } else if (event == QStringLiteral("youtube.auth.failed")) {
        if (m_authProvider == QStringLiteral("youtube")) {
            m_authPending = false;
            emit authPendingChanged();
        }
        setStatus(message.value(QStringLiteral("error")).toString());
    } else if (event == QStringLiteral("soundcloud.auth.restored")
               || event == QStringLiteral("soundcloud.auth.completed")) {
        const auto completed = event.endsWith(QStringLiteral("completed"));
        m_soundcloudLinked = true;
        if (completed) m_soundcloudHub.clear();
        const auto account = message.value(QStringLiteral("data")).toObject()
                                 .value(QStringLiteral("account")).toObject();
        if (!account.isEmpty()) m_soundcloudHub.insert(QStringLiteral("account"), account.toVariantMap());
        emit soundcloudAccountChanged();
        setStatus(completed
                      ? QStringLiteral("SoundCloud connected")
                      : QStringLiteral("SoundCloud account restored securely"));
        if (completed) {
            emit toastRequested(QStringLiteral("SoundCloud connected"), QStringLiteral("success"));
            loadSoundCloudHub(true);
        }
    } else if (event == QStringLiteral("warning")) {
        setStatus(message.value(QStringLiteral("error")).toString());
    } else if (event == QStringLiteral("subscription.status")) {
        const auto data = message.value(QStringLiteral("data")).toObject();
        m_tidalHub.insert(QStringLiteral("account"), data.toVariantMap());
        emit tidalHubChanged();
        if (data.value(QStringLiteral("canStreamFull")).toBool()) {
            setEntitlementWarning(false);
        } else {
            const auto overdue = data.value(QStringLiteral("paymentOverdue")).toBool();
            setEntitlementWarning(
                true,
                overdue
                    ? QStringLiteral("TIDAL reports that payment is overdue, so only track previews are available.")
                    : QStringLiteral("TIDAL is only granting preview playback to this account. Check the subscription before trying again."));
        }
    }
}

void Backend::startLogin()
{
    setBusy(true);
    setStatus(QStringLiteral("Starting TIDAL device login…"));
    request(QStringLiteral("auth.start"), {}, [this](const QJsonObject &message) {
        setBusy(false);
        if (!message.value(QStringLiteral("ok")).toBool()) {
            setStatus(message.value(QStringLiteral("error")).toString());
            return;
        }
        const auto data = message.value(QStringLiteral("data")).toObject();
        m_userCode = data.value(QStringLiteral("userCode")).toString();
        m_verificationUrl = data.value(QStringLiteral("verificationUriComplete")).toString();
        if (m_verificationUrl.isEmpty()) m_verificationUrl = data.value(QStringLiteral("verificationUri")).toString();
        m_authProvider = QStringLiteral("tidal");
        m_authPending = true;
        emit authDetailsChanged();
        emit authPendingChanged();
        setStatus(QStringLiteral("Approve colorful in TIDAL"));
    });
}

void Backend::startYouTubeLogin(const QString &clientId, const QString &clientSecret)
{
    if (clientId.trimmed().isEmpty() || clientSecret.trimmed().isEmpty()) {
        notify(QStringLiteral("Enter your Google OAuth client ID and client secret"), QStringLiteral("error"));
        return;
    }
    setBusy(true);
    setStatus(QStringLiteral("Starting YouTube Music device login…"));
    request(QStringLiteral("youtube.auth.start"), {
        {QStringLiteral("clientId"), clientId.trimmed()},
        {QStringLiteral("clientSecret"), clientSecret.trimmed()},
    }, [this](const QJsonObject &message) {
        setBusy(false);
        if (!message.value(QStringLiteral("ok")).toBool()) {
            notify(message.value(QStringLiteral("error")).toString(), QStringLiteral("error"));
            return;
        }
        const auto data = message.value(QStringLiteral("data")).toObject();
        m_userCode = data.value(QStringLiteral("userCode")).toString();
        m_verificationUrl = data.value(QStringLiteral("verificationUriComplete")).toString();
        if (m_verificationUrl.isEmpty()) m_verificationUrl = data.value(QStringLiteral("verificationUri")).toString();
        m_authProvider = QStringLiteral("youtube");
        m_authPending = true;
        emit authDetailsChanged();
        emit authPendingChanged();
        setStatus(QStringLiteral("Approve colorful for YouTube Music"));
    });
}

void Backend::connectYouTubeBrowserSession(const QString &headers)
{
    if (headers.trimmed().isEmpty()) {
        notify(QStringLiteral("Paste the request headers from a logged-in YouTube Music /browse request"), QStringLiteral("error"));
        return;
    }
    setBusy(true);
    setStatus(QStringLiteral("Checking YouTube Music browser session…"));
    request(QStringLiteral("youtube.auth.browser"), {
        {QStringLiteral("headers"), headers},
    }, [this](const QJsonObject &message) {
        setBusy(false);
        if (!message.value(QStringLiteral("ok")).toBool()) {
            notify(message.value(QStringLiteral("error")).toString(), QStringLiteral("error"));
        }
    });
}

void Backend::unlinkYouTube()
{
    request(QStringLiteral("youtube.auth.unlink"), {}, [this](const QJsonObject &message) {
        if (!message.value(QStringLiteral("ok")).toBool()) {
            notify(message.value(QStringLiteral("error")).toString(), QStringLiteral("error"));
            return;
        }
        m_youtubeLinked = false;
        m_youtubeHub.clear();
        emit youtubeAccountChanged();
        notify(QStringLiteral("YouTube Music account disconnected"));
    });
}

void Backend::openYouTubeSetupGuide()
{
    QDesktopServices::openUrl(QUrl(QStringLiteral(
        "https://github.com/atvalerie/colorful/blob/main/docs/youtube-music-login.md")));
}

void Backend::connectSoundCloudSession(const QString &requestText)
{
    if (requestText.trimmed().isEmpty()) {
        notify(QStringLiteral("Paste a logged-in SoundCloud API request copied as cURL"), QStringLiteral("error"));
        return;
    }
    setBusy(true);
    setStatus(QStringLiteral("Checking SoundCloud session…"));
    request(QStringLiteral("soundcloud.auth.browser"), {
        {QStringLiteral("request"), requestText},
    }, [this](const QJsonObject &message) {
        setBusy(false);
        if (!message.value(QStringLiteral("ok")).toBool())
            notify(message.value(QStringLiteral("error")).toString(), QStringLiteral("error"));
    });
}

void Backend::unlinkSoundCloud()
{
    request(QStringLiteral("soundcloud.auth.unlink"), {}, [this](const QJsonObject &message) {
        if (!message.value(QStringLiteral("ok")).toBool()) {
            notify(message.value(QStringLiteral("error")).toString(), QStringLiteral("error"));
            return;
        }
        m_soundcloudLinked = false;
        m_soundcloudHub.clear();
        emit soundcloudAccountChanged();
        notify(QStringLiteral("SoundCloud account disconnected"));
    });
}

void Backend::openSoundCloudSetupGuide()
{
    QDesktopServices::openUrl(QUrl(QStringLiteral(
        "https://github.com/atvalerie/colorful/blob/main/docs/soundcloud-login.md")));
}

void Backend::loadSoundCloudHub(bool refresh)
{
    if (!m_soundcloudLinked || m_soundcloudHubLoading) return;
    if (!refresh && m_soundcloudHub.contains(QStringLiteral("tracks"))) return;
    m_soundcloudHubLoading = true;
    emit soundcloudAccountChanged();
    request(QStringLiteral("soundcloud.account"), {}, [this](const QJsonObject &message) {
        if (message.value(QStringLiteral("ok")).toBool()) {
            m_soundcloudHub.insert(QStringLiteral("account"), message.value(QStringLiteral("data")).toObject().toVariantMap());
            emit soundcloudAccountChanged();
        }
    });
    request(QStringLiteral("soundcloud.collection"), {}, [this](const QJsonObject &message) {
        m_soundcloudHubLoading = false;
        if (!message.value(QStringLiteral("ok")).toBool()) {
            notify(message.value(QStringLiteral("error")).toString(), QStringLiteral("error"));
            emit soundcloudAccountChanged();
            return;
        }
        const auto data = message.value(QStringLiteral("data")).toObject();
        const auto tracksFrom = [](const QJsonArray &array) {
            QVariantList result;
            for (const auto &value : array) {
                auto object = value.toObject(); object.insert(QStringLiteral("provider"), QStringLiteral("soundcloud"));
                result.append(jsonTrackToVariant(object));
            }
            return result;
        };
        const auto albumsFrom = [](const QJsonArray &array) {
            QVariantList result;
            for (const auto &value : array) {
                auto object = value.toObject(); object.insert(QStringLiteral("provider"), QStringLiteral("soundcloud"));
                result.append(jsonAlbumToVariant(object));
            }
            return result;
        };
        const auto artistsFrom = [](const QJsonArray &array) {
            QVariantList result;
            for (const auto &value : array) {
                auto object = value.toObject(); object.insert(QStringLiteral("provider"), QStringLiteral("soundcloud"));
                result.append(jsonArtistToVariant(object));
            }
            return result;
        };
        m_soundcloudHub.insert(QStringLiteral("tracks"), tracksFrom(data.value(QStringLiteral("tracks")).toArray()));
        m_soundcloudHub.insert(QStringLiteral("albums"), albumsFrom(data.value(QStringLiteral("albums")).toArray()));
        m_soundcloudHub.insert(QStringLiteral("artists"), artistsFrom(data.value(QStringLiteral("artists")).toArray()));
        m_soundcloudHub.insert(QStringLiteral("suggestedArtists"), artistsFrom(data.value(QStringLiteral("suggestedArtists")).toArray()));
        m_soundcloudHub.insert(QStringLiteral("likedTrackIds"), data.value(QStringLiteral("likedTrackIds")).toArray().toVariantList());
        m_soundcloudHub.insert(QStringLiteral("followingIds"), data.value(QStringLiteral("followingIds")).toArray().toVariantList());
        m_soundcloudHub.insert(QStringLiteral("likedTrackIdsCursor"), data.value(QStringLiteral("likedTrackIdsCursor")).toString());
        QVariantList homeSections;
        for (const auto &sectionValue : data.value(QStringLiteral("homeSections")).toArray()) {
            const auto sectionObject = sectionValue.toObject();
            QVariantMap section;
            section.insert(QStringLiteral("title"), sectionObject.value(QStringLiteral("title")).toString());
            section.insert(QStringLiteral("items"), albumsFrom(sectionObject.value(QStringLiteral("items")).toArray()));
            homeSections.append(section);
        }
        m_soundcloudHub.insert(QStringLiteral("homeSections"), homeSections);
        m_soundcloudHub.insert(QStringLiteral("cursors"), data.value(QStringLiteral("cursors")).toObject().toVariantMap());
        setStatus(QStringLiteral("SoundCloud home and library are ready"));
        emit soundcloudAccountChanged();
    });
}

void Backend::loadMoreSoundCloud(const QString &section)
{
    if (m_soundcloudMoreLoading) return;
    const auto cursors = m_soundcloudHub.value(QStringLiteral("cursors")).toMap();
    const auto cursor = cursors.value(section).toString();
    if (cursor.isEmpty()) return;
    m_soundcloudMoreLoading = true;
    emit soundcloudAccountChanged();
    request(QStringLiteral("soundcloud.collection.more"), {
        {QStringLiteral("section"), section}, {QStringLiteral("cursor"), cursor},
    }, [this, section](const QJsonObject &message) {
        m_soundcloudMoreLoading = false;
        if (!message.value(QStringLiteral("ok")).toBool()) {
            notify(message.value(QStringLiteral("error")).toString(), QStringLiteral("error"));
            emit soundcloudAccountChanged();
            return;
        }
        const auto data = message.value(QStringLiteral("data")).toObject();
        auto entries = m_soundcloudHub.value(section).toList();
        QSet<QString> ids;
        for (const auto &entry : entries) ids.insert(entry.toMap().value(QStringLiteral("id")).toString());
        const auto values = data.value(section).toArray();
        for (const auto &value : values) {
            auto object = value.toObject();
            object.insert(QStringLiteral("provider"), QStringLiteral("soundcloud"));
            QVariantMap mapped;
            if (section == QStringLiteral("tracks")) mapped = jsonTrackToVariant(object);
            else if (section == QStringLiteral("albums")) mapped = jsonAlbumToVariant(object);
            else mapped = jsonArtistToVariant(object);
            const auto id = mapped.value(QStringLiteral("id")).toString();
            if (!id.isEmpty() && !ids.contains(id)) { ids.insert(id); entries.append(mapped); }
        }
        m_soundcloudHub.insert(section, entries);
        auto cursors = m_soundcloudHub.value(QStringLiteral("cursors")).toMap();
        cursors.insert(section, data.value(QStringLiteral("cursor")).toString());
        m_soundcloudHub.insert(QStringLiteral("cursors"), cursors);
        emit soundcloudAccountChanged();
    });
}

void Backend::loadYouTubeHub(bool refresh)
{
    if (!m_youtubeLinked || m_youtubeHubLoading) return;
    if (!refresh && m_youtubeHub.contains(QStringLiteral("tracks"))) return;
    m_youtubeHubLoading = true;
    emit youtubeAccountChanged();
    request(QStringLiteral("youtube.account"), {}, [this](const QJsonObject &message) {
        if (message.value(QStringLiteral("ok")).toBool()) {
            m_youtubeHub.insert(QStringLiteral("account"), message.value(QStringLiteral("data")).toObject().toVariantMap());
            emit youtubeAccountChanged();
        }
    });
    request(QStringLiteral("youtube.collection"), {}, [this](const QJsonObject &message) {
        m_youtubeHubLoading = false;
        if (!message.value(QStringLiteral("ok")).toBool()) {
            notify(message.value(QStringLiteral("error")).toString(), QStringLiteral("error"));
            emit youtubeAccountChanged();
            return;
        }
        const auto data = message.value(QStringLiteral("data")).toObject();
        const auto tracksFrom = [](const QJsonArray &array) {
            QVariantList result;
            for (const auto &value : array) {
                auto object = value.toObject(); object.insert(QStringLiteral("provider"), QStringLiteral("youtube"));
                result.append(jsonTrackToVariant(object));
            }
            return result;
        };
        const auto albumsFrom = [](const QJsonArray &array) {
            QVariantList result;
            for (const auto &value : array) {
                auto object = value.toObject(); object.insert(QStringLiteral("provider"), QStringLiteral("youtube"));
                result.append(jsonAlbumToVariant(object));
            }
            return result;
        };
        const auto artistsFrom = [](const QJsonArray &array) {
            QVariantList result;
            for (const auto &value : array) {
                auto object = value.toObject(); object.insert(QStringLiteral("provider"), QStringLiteral("youtube"));
                result.append(jsonArtistToVariant(object));
            }
            return result;
        };
        const auto playlistsFrom = [](const QJsonArray &array) {
            QVariantList result;
            for (const auto &value : array) {
                auto object = value.toObject(); object.insert(QStringLiteral("provider"), QStringLiteral("youtube"));
                result.append(jsonPlaylistToVariant(object));
            }
            return result;
        };
        m_youtubeHub.insert(QStringLiteral("tracks"), tracksFrom(data.value(QStringLiteral("tracks")).toArray()));
        m_youtubeHub.insert(QStringLiteral("albums"), albumsFrom(data.value(QStringLiteral("albums")).toArray()));
        m_youtubeHub.insert(QStringLiteral("artists"), artistsFrom(data.value(QStringLiteral("artists")).toArray()));
        m_youtubeHub.insert(QStringLiteral("playlists"), playlistsFrom(data.value(QStringLiteral("playlists")).toArray()));
        m_youtubeHub.insert(QStringLiteral("mixes"), playlistsFrom(data.value(QStringLiteral("mixes")).toArray()));
        setStatus(QStringLiteral("YouTube Music library is ready"));
        emit youtubeAccountChanged();
    });
}

void Backend::openVerificationUrl()
{
    if (!m_verificationUrl.isEmpty()) QDesktopServices::openUrl(QUrl(m_verificationUrl));
}

void Backend::cancelLogin()
{
    if (!m_authPending) return;
    const auto type = m_authProvider == QStringLiteral("youtube")
        ? QStringLiteral("youtube.auth.cancel") : QStringLiteral("auth.cancel");
    m_authPending = false;
    m_userCode.clear();
    m_verificationUrl.clear();
    emit authPendingChanged();
    emit authDetailsChanged();
    request(type, {}, [this](const QJsonObject &message) {
        if (!message.value(QStringLiteral("ok")).toBool()) {
            setStatus(message.value(QStringLiteral("error")).toString());
            return;
        }
        setStatus(QStringLiteral("Account connection cancelled"));
    });
}

void Backend::unlink()
{
    request(QStringLiteral("auth.unlink"), {}, [this](const QJsonObject &message) {
        if (!message.value(QStringLiteral("ok")).toBool()) {
            setStatus(message.value(QStringLiteral("error")).toString());
            return;
        }
        setLinked(false);
        m_tidalHub.clear();
        emit tidalHubChanged();
        setEntitlementWarning(false);
        stop();
        notify(QStringLiteral("TIDAL account disconnected"));
    });
}

void Backend::loadTidalHub(bool refresh)
{
    if (!m_linked || m_tidalHubLoading) return;
    if (!refresh && m_tidalHub.contains(QStringLiteral("tracks"))) return;
    m_tidalHubLoading = true;
    emit tidalHubChanged();
    request(QStringLiteral("account"), {{QStringLiteral("refresh"), refresh}}, [this](const QJsonObject &message) {
        if (!message.value(QStringLiteral("ok")).toBool()) {
            setStatus(message.value(QStringLiteral("error")).toString());
            return;
        }
        m_tidalHub.insert(QStringLiteral("account"), message.value(QStringLiteral("data")).toObject().toVariantMap());
        emit tidalHubChanged();
    });
    request(QStringLiteral("collection"), {}, [this](const QJsonObject &message) {
        m_tidalHubLoading = false;
        if (!message.value(QStringLiteral("ok")).toBool()) {
            setStatus(message.value(QStringLiteral("error")).toString());
            emit tidalHubChanged();
            return;
        }
        const auto data = message.value(QStringLiteral("data")).toObject();
        const auto tracksFrom = [](const QJsonArray &array) {
            QVariantList result;
            for (const auto &value : array) result.append(jsonTrackToVariant(value.toObject()));
            return result;
        };
        const auto albumsFrom = [](const QJsonArray &array) {
            QVariantList result;
            for (const auto &value : array) result.append(jsonAlbumToVariant(value.toObject()));
            return result;
        };
        const auto artistsFrom = [](const QJsonArray &array) {
            QVariantList result;
            for (const auto &value : array) result.append(jsonArtistToVariant(value.toObject()));
            return result;
        };
        const auto playlistsFrom = [](const QJsonArray &array) {
            QVariantList result;
            for (const auto &value : array) result.append(jsonPlaylistToVariant(value.toObject()));
            return result;
        };
        m_tidalHub.insert(QStringLiteral("tracks"), tracksFrom(data.value(QStringLiteral("tracks")).toArray()));
        m_tidalHub.insert(QStringLiteral("albums"), albumsFrom(data.value(QStringLiteral("albums")).toArray()));
        m_tidalHub.insert(QStringLiteral("artists"), artistsFrom(data.value(QStringLiteral("artists")).toArray()));
        m_tidalHub.insert(QStringLiteral("playlists"), playlistsFrom(data.value(QStringLiteral("playlists")).toArray()));
        m_tidalHub.insert(QStringLiteral("mixes"), playlistsFrom(data.value(QStringLiteral("mixes")).toArray()));
        m_tidalHub.insert(QStringLiteral("cursors"), data.value(QStringLiteral("cursors")).toObject().toVariantMap());
        setStatus(QStringLiteral("TIDAL collection is ready"));
        emit tidalHubChanged();
    });
}

void Backend::loadMoreTidal(const QString &section)
{
    if (m_tidalMoreLoading) return;
    const auto cursors = m_tidalHub.value(QStringLiteral("cursors")).toMap();
    const auto cursor = cursors.value(section).toString();
    if (cursor.isEmpty()) return;
    m_tidalMoreLoading = true;
    emit tidalHubChanged();
    request(QStringLiteral("collection.more"), {
        {QStringLiteral("section"), section}, {QStringLiteral("cursor"), cursor},
    }, [this, section](const QJsonObject &message) {
        m_tidalMoreLoading = false;
        if (!message.value(QStringLiteral("ok")).toBool()) {
            setStatus(message.value(QStringLiteral("error")).toString());
            emit tidalHubChanged();
            return;
        }
        const auto data = message.value(QStringLiteral("data")).toObject();
        auto items = m_tidalHub.value(section).toList();
        for (const auto &value : data.value(QStringLiteral("items")).toArray()) {
            const auto object = value.toObject();
            if (section == QStringLiteral("tracks")) items.append(jsonTrackToVariant(object));
            else if (section == QStringLiteral("albums")) items.append(jsonAlbumToVariant(object));
            else if (section == QStringLiteral("artists")) items.append(jsonArtistToVariant(object));
            else items.append(jsonPlaylistToVariant(object));
        }
        m_tidalHub.insert(section, items);
        auto cursors = m_tidalHub.value(QStringLiteral("cursors")).toMap();
        cursors.insert(section, data.value(QStringLiteral("cursor")).toString());
        m_tidalHub.insert(QStringLiteral("cursors"), cursors);
        emit tidalHubChanged();
    });
}

void Backend::dismissEntitlementWarning()
{
    setEntitlementWarning(false);
}

void Backend::openTidalAccount()
{
    QDesktopServices::openUrl(QUrl(QStringLiteral("https://account.tidal.com")));
}

void Backend::search(const QString &query)
{
    if (query.trimmed().isEmpty()) return;
    const auto wantedQuery = query.trimmed();
    m_searchQuery = wantedQuery;
    m_searchCursors.clear();
    m_searchMoreLoading = false;
    setBusy(true);
    setStatus(QStringLiteral("Searching…"));
    request(QStringLiteral("search"), {{QStringLiteral("query"), wantedQuery}}, [this, wantedQuery](const QJsonObject &message) {
        if (m_searchQuery != wantedQuery) return;
        setBusy(false);
        if (!message.value(QStringLiteral("ok")).toBool()) {
            setStatus(message.value(QStringLiteral("error")).toString());
            return;
        }
        m_searchResults.clear();
        m_searchAlbums.clear();
        m_searchArtists.clear();
        const auto data = message.value(QStringLiteral("data")).toObject();
        m_searchCursors = data.value(QStringLiteral("cursors")).toObject().toVariantMap();
        for (const auto &value : data.value(QStringLiteral("tracks")).toArray()) {
            m_searchResults.append(jsonTrackToVariant(value.toObject()));
        }
        for (const auto &value : data.value(QStringLiteral("albums")).toArray()) {
            m_searchAlbums.append(jsonAlbumToVariant(value.toObject()));
        }
        for (const auto &value : data.value(QStringLiteral("artists")).toArray()) {
            m_searchArtists.append(jsonArtistToVariant(value.toObject()));
        }
        emit searchResultsChanged();
        const auto total = m_searchResults.size() + m_searchAlbums.size() + m_searchArtists.size();
        setStatus(total == 0 ? QStringLiteral("Nothing found")
                             : QStringLiteral("Found %1 results").arg(total));
        if (qEnvironmentVariableIsSet("COLORFUL_SMOKE_DETAIL") && !m_searchResults.isEmpty()) {
            openTrack(m_searchResults.first().toMap().value(QStringLiteral("id")).toString());
        }
    });
}

void Backend::loadMoreSearch(const QString &provider)
{
    if (m_searchMoreLoading || m_searchQuery.isEmpty()) return;
    const auto cursor = m_searchCursors.value(provider);
    if (!cursor.isValid() || cursor.isNull()
        || (cursor.metaType().id() == QMetaType::QString && cursor.toString().isEmpty())
        || (cursor.metaType().id() == QMetaType::QVariantMap && cursor.toMap().isEmpty())) return;
    const auto wantedQuery = m_searchQuery;
    m_searchMoreLoading = true;
    emit searchResultsChanged();
    request(QStringLiteral("search.more"), {
        {QStringLiteral("provider"), provider},
        {QStringLiteral("query"), wantedQuery},
        {QStringLiteral("cursor"), QJsonValue::fromVariant(cursor)},
    }, [this, provider, wantedQuery](const QJsonObject &message) {
        if (m_searchQuery != wantedQuery) return;
        m_searchMoreLoading = false;
        if (!message.value(QStringLiteral("ok")).toBool()) {
            notify(message.value(QStringLiteral("error")).toString(), QStringLiteral("error"));
            emit searchResultsChanged();
            return;
        }
        const auto data = message.value(QStringLiteral("data")).toObject();
        const auto appendUnique = [provider](QVariantList &target, const QJsonArray &values,
                                             const auto &mapper) {
            QSet<QString> identities;
            for (const auto &entry : target) {
                const auto item = entry.toMap();
                identities.insert(item.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()
                                  + QLatin1Char(':') + item.value(QStringLiteral("id")).toString());
            }
            for (const auto &value : values) {
                auto document = value.toObject();
                if (!document.contains(QStringLiteral("provider"))) document.insert(QStringLiteral("provider"), provider);
                const auto item = mapper(document);
                const auto identity = item.value(QStringLiteral("provider")).toString()
                    + QLatin1Char(':') + item.value(QStringLiteral("id")).toString();
                if (!item.value(QStringLiteral("id")).toString().isEmpty() && !identities.contains(identity)) {
                    identities.insert(identity);
                    target.append(item);
                }
            }
        };
        appendUnique(m_searchResults, data.value(QStringLiteral("tracks")).toArray(), jsonTrackToVariant);
        appendUnique(m_searchAlbums, data.value(QStringLiteral("albums")).toArray(), jsonAlbumToVariant);
        appendUnique(m_searchArtists, data.value(QStringLiteral("artists")).toArray(), jsonArtistToVariant);
        m_searchCursors.insert(provider, data.value(QStringLiteral("cursor")).toVariant());
        emit searchResultsChanged();
        setStatus(QStringLiteral("Loaded more %1 results").arg(provider));
    });
}

void Backend::openTrack(const QString &id) { openCatalog(QStringLiteral("track"), id); }
void Backend::openTrackItem(const QVariantMap &track)
{
    openCatalog(QStringLiteral("track"), track.value(QStringLiteral("id")).toString(), true,
                track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString());
}
void Backend::openAlbum(const QString &id) { openCatalog(QStringLiteral("album"), id); }
void Backend::openAlbumItem(const QVariantMap &album)
{
    openCatalog(QStringLiteral("album"), album.value(QStringLiteral("id")).toString(), true,
                album.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString());
}
void Backend::openArtist(const QString &id) { openCatalog(QStringLiteral("artist"), id); }
void Backend::openArtistItem(const QVariantMap &artist)
{
    openCatalog(QStringLiteral("artist"), artist.value(QStringLiteral("id")).toString(), true,
                artist.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString());
}
void Backend::openPlaylist(const QString &id, const QString &provider)
{
    openCatalog(QStringLiteral("playlist"), id, true, provider);
}

void Backend::openTrackArtist(const QVariantMap &track, int artistIndex)
{
    const auto credits = track.value(QStringLiteral("artistCredits")).toList();
    if (artistIndex >= 0 && artistIndex < credits.size()) {
        const auto artistId = credits.at(artistIndex).toMap().value(QStringLiteral("id")).toString();
        if (!artistId.isEmpty()) {
            openCatalog(QStringLiteral("artist"), artistId, true,
                        track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString());
            return;
        }
    }
    const auto names = track.value(QStringLiteral("artists")).toStringList();
    if (artistIndex < 0 || artistIndex >= names.size() || names.at(artistIndex).trimmed().isEmpty()) return;
    const auto wantedName = names.at(artistIndex).trimmed();
    const auto provider = track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString();
    setStatus(QStringLiteral("Finding %1…").arg(wantedName));
    request(QStringLiteral("search"), {{QStringLiteral("query"), wantedName}}, [this, wantedName, provider](const QJsonObject &message) {
        if (!message.value(QStringLiteral("ok")).toBool()) {
            setStatus(message.value(QStringLiteral("error")).toString());
            return;
        }
        const auto artists = message.value(QStringLiteral("data")).toObject().value(QStringLiteral("artists")).toArray();
        QJsonObject selected;
        for (const auto &value : artists) {
            const auto candidate = value.toObject();
            if (candidate.value(QStringLiteral("provider")).toString(QStringLiteral("tidal")) == provider
                && candidate.value(QStringLiteral("name")).toString().compare(wantedName, Qt::CaseInsensitive) == 0) {
                selected = candidate;
                break;
            }
        }
        if (selected.isEmpty()) {
            for (const auto &value : artists) {
                const auto candidate = value.toObject();
                if (candidate.value(QStringLiteral("provider")).toString(QStringLiteral("tidal")) == provider) {
                    selected = candidate;
                    break;
                }
            }
        }
        const auto artistId = selected.value(QStringLiteral("id")).toString();
        if (artistId.isEmpty()) setStatus(QStringLiteral("Could not find that artist"));
        else openCatalog(QStringLiteral("artist"), artistId, true, provider);
    });
}

void Backend::openCatalog(const QString &kind, const QString &id, bool preserveCurrent,
                          const QString &provider)
{
    if (id.trimmed().isEmpty()) return;
    const auto generation = ++m_catalogGeneration;
    m_catalogLoading = true;
    m_catalogMoreLoading = false;
    emit catalogPageChanged();
    request(QStringLiteral("detail"), {
        {QStringLiteral("provider"), provider},
        {QStringLiteral("kind"), kind},
        {QStringLiteral("id"), id.trimmed()},
    }, [this, generation, preserveCurrent](const QJsonObject &message) {
        if (generation != m_catalogGeneration) return;
        m_catalogLoading = false;
        if (!message.value(QStringLiteral("ok")).toBool()) {
            const auto error = message.value(QStringLiteral("error")).toString();
            setStatus(error);
            notify(error.isEmpty() ? QStringLiteral("Could not open that TIDAL page") : error,
                   QStringLiteral("error"));
            emit catalogPageChanged();
            return;
        }
        const auto nextPage = jsonCatalogPageToVariant(message.value(QStringLiteral("data")).toObject());
        if (preserveCurrent && !m_catalogPage.isEmpty()) m_catalogHistory.append(m_catalogPage);
        m_catalogPage = nextPage;
        emit catalogPageChanged();
    });
}

void Backend::navigateCatalogBack()
{
    if (m_catalogHistory.isEmpty()) {
        closeCatalog();
        return;
    }
    ++m_catalogGeneration;
    m_catalogLoading = false;
    m_catalogMoreLoading = false;
    m_catalogPage = m_catalogHistory.takeLast().toMap();
    emit catalogPageChanged();
}

void Backend::closeCatalog()
{
    ++m_catalogGeneration;
    m_catalogLoading = false;
    m_catalogMoreLoading = false;
    m_catalogPage.clear();
    m_catalogHistory.clear();
    emit catalogPageChanged();
}

void Backend::loadMoreCatalog(const QString &section)
{
    if (m_catalogPage.isEmpty() || m_catalogMoreLoading) return;
    const auto cursorKey = section == QStringLiteral("albums")
        ? QStringLiteral("albumCursor") : QStringLiteral("trackCursor");
    const auto cursor = m_catalogPage.value(cursorKey).toString();
    const auto kind = m_catalogPage.value(QStringLiteral("kind")).toString();
    const auto resourceId = m_catalogPage.value(QStringLiteral("resourceId")).toString();
    if (cursor.isEmpty() || resourceId.isEmpty()) return;
    const auto pageProvider = m_catalogPage.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString();
    if (kind == QStringLiteral("playlist") && pageProvider == QStringLiteral("youtube")
        && resourceId == m_playlistId && cursor == m_playlistCursor) {
        requestPlaylistContinuation(false);
        return;
    }
    const auto generation = m_catalogGeneration;
    m_catalogMoreLoading = true;
    emit catalogPageChanged();
    request(QStringLiteral("detail.more"), {
        {QStringLiteral("provider"), pageProvider},
        {QStringLiteral("kind"), kind},
        {QStringLiteral("id"), resourceId},
        {QStringLiteral("section"), section},
        {QStringLiteral("cursor"), cursor},
    }, [this, generation, section, cursorKey](const QJsonObject &message) {
        if (generation != m_catalogGeneration) return;
        m_catalogMoreLoading = false;
        if (!message.value(QStringLiteral("ok")).toBool()) {
            setStatus(message.value(QStringLiteral("error")).toString());
            emit catalogPageChanged();
            return;
        }
        const auto data = message.value(QStringLiteral("data")).toObject();
        if (section == QStringLiteral("albums")) {
            auto albums = m_catalogPage.value(QStringLiteral("albums")).toList();
            QHash<QString, qsizetype> releasePositions;
            const auto releaseKey = [](const QVariantMap &album) {
                return album.value(QStringLiteral("title")).toString().toCaseFolded()
                    + QLatin1Char('\n') + album.value(QStringLiteral("artistText")).toString().toCaseFolded()
                    + QLatin1Char('\n') + album.value(QStringLiteral("releaseDate")).toString()
                    + QLatin1Char('\n') + album.value(QStringLiteral("numberOfTracks")).toString();
            };
            const auto preference = [](const QVariantMap &album) {
                const auto tags = album.value(QStringLiteral("mediaTags")).toStringList();
                return (album.value(QStringLiteral("explicit")).toBool() ? 1000 : 0)
                    + (tags.contains(QStringLiteral("HIRES_LOSSLESS")) ? 300 : 0)
                    + (tags.contains(QStringLiteral("LOSSLESS")) ? 200 : 0)
                    + (tags.contains(QStringLiteral("DOLBY_ATMOS")) ? 50 : 0)
                    + (!album.value(QStringLiteral("coverUrl")).toString().isEmpty() ? 10 : 0);
            };
            for (qsizetype index = 0; index < albums.size(); ++index) {
                const auto value = albums.at(index);
                const auto album = value.toMap();
                releasePositions.insert(releaseKey(album), index);
            }
            for (const auto &value : data.value(QStringLiteral("albums")).toArray()) {
                const auto album = jsonAlbumToVariant(value.toObject());
                const auto key = releaseKey(album);
                if (!releasePositions.contains(key)) {
                    releasePositions.insert(key, albums.size());
                    albums.append(album);
                } else {
                    const auto index = releasePositions.value(key);
                    if (preference(album) > preference(albums.at(index).toMap())) albums[index] = album;
                }
            }
            m_catalogPage.insert(QStringLiteral("albums"), albums);
        } else {
            const auto pageProvider = m_catalogPage.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString();
            const auto pageKind = m_catalogPage.value(QStringLiteral("kind")).toString();
            const auto listKey = pageKind == QStringLiteral("artist")
                ? QStringLiteral("topTracks") : QStringLiteral("tracks");
            auto tracks = m_catalogPage.value(listKey).toList();
            QSet<QString> ids;
            if (pageKind != QStringLiteral("playlist"))
                for (const auto &value : tracks) ids.insert(value.toMap().value(QStringLiteral("id")).toString());
            for (const auto &value : data.value(QStringLiteral("tracks")).toArray()) {
                auto document = value.toObject();
                if (!document.contains(QStringLiteral("provider"))) {
                    document.insert(QStringLiteral("provider"), pageProvider);
                }
                const auto track = jsonTrackToVariant(document);
                const auto id = track.value(QStringLiteral("id")).toString();
                if (pageKind == QStringLiteral("playlist") || !ids.contains(id)) {
                    ids.insert(id);
                    tracks.append(track);
                }
            }
            m_catalogPage.insert(listKey, tracks);
        }
        m_catalogPage.insert(cursorKey, data.value(QStringLiteral("cursor")).toString());
        emit catalogPageChanged();
    });
}

void Backend::enqueueTrack(const QVariantMap &track)
{
    if (track.value(QStringLiteral("id")).toString().isEmpty()) return;
    dispatchCore({{QStringLiteral("command"), QStringLiteral("enqueue")},
                  {QStringLiteral("track"), variantTrackToCore(track)}});
    prepareNextSource();
}

void Backend::saveTrack(const QVariantMap &track)
{
    if (track.value(QStringLiteral("id")).toString().isEmpty()) return;
    dispatchCore({{QStringLiteral("command"), QStringLiteral("add_to_library")},
                  {QStringLiteral("track"), variantTrackToCore(track)}});
    notify(QStringLiteral("Saved %1 to your library").arg(track.value(QStringLiteral("title")).toString()),
           QStringLiteral("success"));
}

void Backend::enqueueCatalogTrack(const QVariantMap &track)
{
    enqueueTrack(track);
    notify(QStringLiteral("Added %1 to the queue").arg(track.value(QStringLiteral("title")).toString()));
}

void Backend::playNextCatalogTrack(const QVariantMap &track)
{
    if (track.value(QStringLiteral("id")).toString().isEmpty()) return;
    dispatchCore({{QStringLiteral("command"), QStringLiteral("play_next")},
                  {QStringLiteral("track"), variantTrackToCore(track)}});
    prepareNextSource();
    notify(QStringLiteral("%1 will play next").arg(track.value(QStringLiteral("title")).toString()));
}

void Backend::playCatalogTrack(const QVariantMap &track)
{
    playSingleTrack(track);
}

void Backend::startRadio(const QVariantMap &track)
{
    if (track.value(QStringLiteral("id")).toString().isEmpty()) return;
    setAutoplayEnabled(true);
    playSingleTrack(track);
    requestRelated(false);
    notify(QStringLiteral("Starting radio from %1")
               .arg(track.value(QStringLiteral("title")).toString()));
}

void Backend::saveCatalogTrack(const QVariantMap &track) { saveTrack(track); }

void Backend::playCatalogCollection()
{
    QVariantList tracks;
    const auto kind = m_catalogPage.value(QStringLiteral("kind")).toString();
    if (kind == QStringLiteral("album") || kind == QStringLiteral("playlist")) tracks = m_catalogPage.value(QStringLiteral("tracks")).toList();
    else if (kind == QStringLiteral("artist")) tracks = m_catalogPage.value(QStringLiteral("topTracks")).toList();
    else if (kind == QStringLiteral("track")) {
        playSingleTrack(m_catalogPage.value(QStringLiteral("track")).toMap());
        return;
    }
    const auto pageProvider = m_catalogPage.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString();
    if (kind == QStringLiteral("playlist") && pageProvider == QStringLiteral("youtube")) {
        const auto playlistId = m_catalogPage.value(QStringLiteral("resourceId")).toString();
        if (!m_shuffleEnabled) {
            if (tracks.isEmpty()) return;
            const auto cursor = m_catalogPage.value(QStringLiteral("trackCursor")).toString();
            playTracks(tracks);
            activatePlaylistContinuation(playlistId, cursor);
            return;
        }
        clearPlaylistContinuation();
        const auto generation = m_playlistContinuationGeneration;
        setStatus(QStringLiteral("Starting shuffled playlist…"));
        request(QStringLiteral("detail.youtubePlaylistShuffle"), {
            {QStringLiteral("id"), playlistId},
        }, [this, generation, playlistId](const QJsonObject &message) {
            if (generation != m_playlistContinuationGeneration) return;
            if (!message.value(QStringLiteral("ok")).toBool()) {
                const auto error = message.value(QStringLiteral("error")).toString();
                setStatus(error);
                notify(error, QStringLiteral("error"));
                return;
            }
            const auto data = message.value(QStringLiteral("data")).toObject();
            QVariantList shuffledTracks;
            for (const auto &value : data.value(QStringLiteral("tracks")).toArray()) {
                auto document = value.toObject();
                document.insert(QStringLiteral("provider"), QStringLiteral("youtube"));
                shuffledTracks.append(jsonTrackToVariant(document));
            }
            if (shuffledTracks.isEmpty()) {
                notify(QStringLiteral("YouTube Music returned an empty shuffled playlist"), QStringLiteral("error"));
                return;
            }
            playTracks(shuffledTracks, true);
            activatePlaylistContinuation(playlistId, data.value(QStringLiteral("cursor")).toString());
            setStatus(QStringLiteral("Shuffled playlist started"));
        });
        return;
    }
    if (kind == QStringLiteral("album") && !m_catalogPage.value(QStringLiteral("trackCursor")).toString().isEmpty()) {
        const auto generation = m_catalogGeneration;
        m_catalogMoreLoading = true;
        emit catalogPageChanged();
        request(QStringLiteral("detail.albumTracks"), {
            {QStringLiteral("provider"), QStringLiteral("tidal")},
            {QStringLiteral("id"), m_catalogPage.value(QStringLiteral("resourceId")).toString()},
        }, [this, generation](const QJsonObject &message) {
            if (generation != m_catalogGeneration) return;
            m_catalogMoreLoading = false;
            if (!message.value(QStringLiteral("ok")).toBool()) {
                setStatus(message.value(QStringLiteral("error")).toString());
                emit catalogPageChanged();
                return;
            }
            QVariantList allTracks;
            for (const auto &value : message.value(QStringLiteral("data")).toObject().value(QStringLiteral("tracks")).toArray()) {
                allTracks.append(jsonTrackToVariant(value.toObject()));
            }
            m_catalogPage.insert(QStringLiteral("tracks"), allTracks);
            m_catalogPage.insert(QStringLiteral("trackCursor"), QString{});
            emit catalogPageChanged();
            if (allTracks.isEmpty()) return;
            playTracks(allTracks);
        });
        return;
    }
    if (tracks.isEmpty()) return;
    playTracks(tracks);
}

void Backend::enqueueSearchResult(int index)
{
    if (index < 0 || index >= m_searchResults.size()) return;
    enqueueTrack(m_searchResults.at(index).toMap());
    notify(QStringLiteral("Added %1 to the queue")
               .arg(m_searchResults.at(index).toMap().value(QStringLiteral("title")).toString()));
}

void Backend::playSearchResult(int index)
{
    if (index < 0 || index >= m_searchResults.size()) return;
    playSingleTrack(m_searchResults.at(index).toMap());
}

void Backend::playQueueIndex(int index) { playTrackAt(index); }

void Backend::removeQueueIndex(int index)
{
    if (index < 0 || index >= m_queueEntryIds.size()) return;
    const auto title = m_queue.at(index).toMap().value(QStringLiteral("title")).toString();
    const bool removingCurrent = index == m_currentIndex;
    const bool wasPlaying = playing();
    if (removingCurrent) finishListeningSession();
    dispatchCore({{QStringLiteral("command"), QStringLiteral("remove")},
                  {QStringLiteral("entry_id"), m_queueEntryIds.at(index)}});
    if (removingCurrent) {
        if (m_currentIndex >= 0) resolveCurrentSource(0, wasPlaying);
        else m_playback.clearSource();
    } else prepareNextSource();
    notify(QStringLiteral("Removed %1 from the queue").arg(title));
}

void Backend::moveQueueIndex(int fromIndex, int toIndex)
{
    if (fromIndex < 0 || fromIndex >= m_queueEntryIds.size() || toIndex < 0
        || toIndex >= m_queueEntryIds.size() || fromIndex == toIndex) return;
    dispatchCore({{QStringLiteral("command"), QStringLiteral("move")},
                  {QStringLiteral("entry_id"), m_queueEntryIds.at(fromIndex)},
                  {QStringLiteral("target_index"), toIndex}});
    prepareNextSource();
}

void Backend::clearQueue()
{
    clearPlaylistContinuation();
    if (m_queue.isEmpty()) return;
    finishListeningSession();
    ++m_sourceGeneration;
    m_relatedContinueWhenReady = false;
    invalidatePreparedNext();
    dispatchCore({{QStringLiteral("command"), QStringLiteral("play_tracks")},
                  {QStringLiteral("tracks"), QJsonArray{}}});
    m_playback.clearSource();
    m_playbackReady = false;
    m_playingLocalSource = false;
    m_resumePositionMs = 0;
    m_displayPositionOverride = -1;
    setBusy(false);
    setStatus(QStringLiteral("Queue cleared"));
    notify(QStringLiteral("Cleared the queue"));
}

void Backend::addSearchResultToLibrary(int index)
{
    if (index < 0 || index >= m_searchResults.size()) return;
    const auto track = m_searchResults.at(index).toMap();
    saveTrack(track);
}

void Backend::playLibraryIndex(int index)
{
    if (index < 0 || index >= m_library.size()) return;
    playSingleTrack(m_library.at(index).toMap());
}

void Backend::removeLibraryIndex(int index)
{
    if (index < 0 || index >= m_library.size()) return;
    const auto track = m_library.at(index).toMap();
    dispatchCore({{QStringLiteral("command"), QStringLiteral("remove_from_library")},
                  {QStringLiteral("id"), QJsonObject{{QStringLiteral("provider"), track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()},
                                                     {QStringLiteral("providerId"), track.value(QStringLiteral("id")).toString()}}}});
    notify(QStringLiteral("Removed %1 from your library").arg(track.value(QStringLiteral("title")).toString()));
}

QString Backend::downloadsDirectory() const
{
    return QDir(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation))
        .filePath(QStringLiteral("offline"));
}

QString Backend::downloadPath(const QVariantMap &track, bool partial) const
{
    const auto identity = track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()
        + QLatin1Char(':') + track.value(QStringLiteral("id")).toString();
    const auto digest = QCryptographicHash::hash(identity.toUtf8(), QCryptographicHash::Sha256).toHex();
    return QDir(downloadsDirectory()).filePath(QString::fromLatin1(digest)
        + (partial ? QStringLiteral(".part.mka") : QStringLiteral(".mka")));
}

QString Backend::downloadPartsDirectory(const QVariantMap &track) const
{
    const auto identity = track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()
        + QLatin1Char(':') + track.value(QStringLiteral("id")).toString();
    const auto digest = QCryptographicHash::hash(identity.toUtf8(), QCryptographicHash::Sha256).toHex();
    return QDir(downloadsDirectory()).filePath(QString::fromLatin1(digest) + QStringLiteral(".parts"));
}

QString Backend::downloadAssemblyPath(const QVariantMap &track) const
{
    const auto identity = track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()
        + QLatin1Char(':') + track.value(QStringLiteral("id")).toString();
    const auto digest = QCryptographicHash::hash(identity.toUtf8(), QCryptographicHash::Sha256).toHex();
    return QDir(downloadsDirectory()).filePath(QString::fromLatin1(digest) + QStringLiteral(".assembling.mka"));
}

QStringList Backend::downloadPartFiles(const QVariantMap &track) const
{
    const QDir directory(downloadPartsDirectory(track));
    QStringList files;
    for (const auto &name : directory.entryList({QStringLiteral("*.mka")}, QDir::Files, QDir::Name))
        files.append(directory.filePath(name));
    return files;
}

qint64 Backend::downloadWorkingBytes(const QVariantMap &track) const
{
    qint64 total = 0;
    const QDir directory(downloadPartsDirectory(track));
    for (const auto &name : directory.entryList(QDir::Files | QDir::NoDotAndDotDot)) {
        if (name == QStringLiteral("concat.txt")) continue;
        total += std::max<qint64>(0, QFileInfo(directory.filePath(name)).size());
    }
    return total;
}

qint64 Backend::mediaDurationMs(const QString &path) const
{
    const auto ffprobe = QStandardPaths::findExecutable(QStringLiteral("ffprobe"));
    if (ffprobe.isEmpty() || path.isEmpty() || !QFileInfo::exists(path)) return 0;
    QProcess probe;
    probe.setProgram(ffprobe);
    probe.setArguments({
        QStringLiteral("-v"), QStringLiteral("error"),
        QStringLiteral("-show_entries"), QStringLiteral("format=duration"),
        QStringLiteral("-of"), QStringLiteral("default=noprint_wrappers=1:nokey=1"),
        path,
    });
    probe.start();
    if (!probe.waitForStarted(2000) || !probe.waitForFinished(10'000)
        || probe.exitStatus() != QProcess::NormalExit || probe.exitCode() != 0) return 0;
    bool valid = false;
    const auto seconds = QString::fromUtf8(probe.readAllStandardOutput()).trimmed().toDouble(&valid);
    return valid && seconds > 0 ? qRound64(seconds * 1000.0) : 0;
}

void Backend::removeDownloadWorkingFiles(const QVariantMap &track)
{
    QFile::remove(downloadPath(track, true));
    QFile::remove(downloadAssemblyPath(track));
    QDir(downloadPartsDirectory(track)).removeRecursively();
}

QString Backend::downloadArtworkPath(const QVariantMap &track) const
{
    const auto identity = track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()
        + QLatin1Char(':') + track.value(QStringLiteral("id")).toString();
    const auto digest = QCryptographicHash::hash(identity.toUtf8(), QCryptographicHash::Sha256).toHex();
    return QDir(downloadsDirectory()).filePath(QString::fromLatin1(digest) + QStringLiteral(".cover"));
}

void Backend::downloadArtwork(const QVariantMap &track)
{
    if (m_lowDataMode) return;
    const auto remoteUrl = track.value(QStringLiteral("coverRemoteUrl"),
                                       track.value(QStringLiteral("coverUrl"))).toString();
    if (remoteUrl.isEmpty() || !QUrl(remoteUrl).isValid()) return;
    auto *reply = m_network.get(QNetworkRequest(QUrl(remoteUrl)));
    connect(reply, &QNetworkReply::finished, this, [this, reply, track] {
        const auto data = reply->readAll();
        const bool succeeded = reply->error() == QNetworkReply::NoError && !data.isEmpty();
        reply->deleteLater();
        const auto existing = downloadForTrack(
            track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString(),
            track.value(QStringLiteral("id")).toString());
        if (!succeeded || existing.value(QStringLiteral("downloadState")).toString() != QStringLiteral("complete")) return;
        const auto artworkPath = downloadArtworkPath(track);
        QSaveFile file(artworkPath);
        if (!file.open(QIODevice::WriteOnly) || file.write(data) != data.size() || !file.commit()) {
            return;
        }
        auto persistedTrack = track;
        persistedTrack.insert(QStringLiteral("coverLocalPath"), artworkPath);
        saveDownloadState(persistedTrack, QStringLiteral("complete"),
                          existing.value(QStringLiteral("localPath")).toString(),
                          existing.value(QStringLiteral("bytesDownloaded")).toLongLong(),
                          existing.value(QStringLiteral("bytesDownloaded")).toLongLong());
    });
}

QVariantMap Backend::downloadForTrack(const QString &provider, const QString &trackId) const
{
    for (const auto &value : m_downloads) {
        const auto entry = value.toMap();
        if (entry.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString() == provider
            && entry.value(QStringLiteral("id")).toString() == trackId) return entry;
    }
    return {};
}

void Backend::saveDownloadState(const QVariantMap &track, const QString &state,
                                const QString &localPath, qint64 bytesDownloaded,
                                std::optional<qint64> bytesTotal, const QString &errorCode)
{
    const auto provider = track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString();
    const auto trackId = track.value(QStringLiteral("id")).toString();
    if (trackId.isEmpty()) return;
    const auto previous = downloadForTrack(provider, trackId);
    if (state == QStringLiteral("downloading")) {
        bytesDownloaded = std::max(bytesDownloaded, previous.value(QStringLiteral("bytesDownloaded")).toLongLong());
    }
    QJsonObject job{
        {QStringLiteral("mediaId"), QJsonObject{{QStringLiteral("provider"), provider},
                                                 {QStringLiteral("providerId"), trackId}}},
        {QStringLiteral("state"), state},
        {QStringLiteral("localPath"), localPath.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(localPath)},
        {QStringLiteral("bytesDownloaded"), bytesDownloaded},
        {QStringLiteral("bytesTotal"), bytesTotal ? QJsonValue(*bytesTotal) : QJsonValue(QJsonValue::Null)},
        {QStringLiteral("sourceExpiresAtMs"), QJsonValue(QJsonValue::Null)},
        {QStringLiteral("errorCode"), errorCode.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(errorCode)},
        {QStringLiteral("updatedAtMs"), QDateTime::currentMSecsSinceEpoch()},
    };
    dispatchCore({{QStringLiteral("command"), QStringLiteral("save_download")},
                  {QStringLiteral("track"), variantTrackToCore(track)},
                  {QStringLiteral("job"), job}});
}

void Backend::downloadTrack(const QVariantMap &track)
{
    const auto trackId = track.value(QStringLiteral("id")).toString();
    const auto provider = track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString();
    if (trackId.isEmpty()) return;
    if (m_offlineStorageLimitBytes > 0 && offlineStorageUsed() >= m_offlineStorageLimitBytes) {
        notify(QStringLiteral("Offline storage limit reached. Remove downloads or raise the limit in Settings."),
               QStringLiteral("warning"));
        return;
    }
    if (provider != QStringLiteral("tidal") && provider != QStringLiteral("youtube")) {
        notify(QStringLiteral("Offline downloads are not implemented for %1 yet").arg(provider),
               QStringLiteral("warning"));
        return;
    }
    const auto existing = downloadForTrack(provider, trackId);
    if (existing.value(QStringLiteral("downloadState")).toString() == QStringLiteral("complete")
        && QFileInfo::exists(existing.value(QStringLiteral("localPath")).toString())) {
        notify(QStringLiteral("%1 is already available offline").arg(track.value(QStringLiteral("title")).toString()));
        return;
    }
    if (!m_activeDownloadTrack.isEmpty()
        && m_activeDownloadTrack.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString() == provider
        && m_activeDownloadTrack.value(QStringLiteral("id")).toString() == trackId) return;
    for (const auto &queued : m_downloadQueue) {
        if (queued.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString() == provider
            && queued.value(QStringLiteral("id")).toString() == trackId) return;
    }
    saveDownloadState(track, QStringLiteral("queued"));
    m_downloadQueue.append(track);
    notify(QStringLiteral("Queued %1 for offline download").arg(track.value(QStringLiteral("title")).toString()));
    beginNextDownload();
}

void Backend::beginNextDownload()
{
    if (!m_activeDownloadTrack.isEmpty() || m_downloadProcess.state() != QProcess::NotRunning
        || m_downloadQueue.isEmpty()) return;
    m_activeDownloadTrack = m_downloadQueue.takeFirst();
    m_cancelActiveDownload = false;
    m_removeActiveDownload = false;
    m_pauseDownloadForQuota = false;
    const auto generation = ++m_downloadGeneration;
    const auto trackId = m_activeDownloadTrack.value(QStringLiteral("id")).toString();
    const auto provider = m_activeDownloadTrack.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString();
    saveDownloadState(m_activeDownloadTrack, QStringLiteral("resolving"));
    if (!m_providerReady || (provider == QStringLiteral("tidal") && !m_linked)) {
        finishDownloadTransfer(false, provider == QStringLiteral("tidal")
            ? QStringLiteral("Connect TIDAL before starting a new download")
            : QStringLiteral("The provider host is not ready"));
        return;
    }
    if (provider == QStringLiteral("youtube")) {
        startYouTubeDownload();
        return;
    }
    setStatus(QStringLiteral("Preparing offline download for %1…")
                  .arg(m_activeDownloadTrack.value(QStringLiteral("title")).toString()));
    const auto requestId = request(QStringLiteral("source"), {
        {QStringLiteral("provider"), provider},
        {QStringLiteral("trackId"), trackId},
        {QStringLiteral("manifestType"), QStringLiteral("MPEG_DASH")},
        {QStringLiteral("quality"), m_streamQuality},
    }, [this, generation, trackId, provider](const QJsonObject &message) {
        if (generation != m_downloadGeneration || m_activeDownloadTrack.isEmpty()
            || m_activeDownloadTrack.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString() != provider
            || m_activeDownloadTrack.value(QStringLiteral("id")).toString() != trackId) return;
        if (!message.value(QStringLiteral("ok")).toBool()) {
            finishDownloadTransfer(false, message.value(QStringLiteral("error")).toString());
            return;
        }
        const auto source = message.value(QStringLiteral("data")).toObject();
        const auto uri = source.value(QStringLiteral("uri")).toString();
        if (uri.isEmpty()) {
            finishDownloadTransfer(false, QStringLiteral("The provider returned an empty download source"));
            return;
        }
        const auto copyNormalization = [&source, this](const QString &group, const QString &prefix) {
            const auto replayGain = normalizationNumber(source, group, QStringLiteral("replayGain"));
            const auto peak = normalizationNumber(source, group, QStringLiteral("peakAmplitude"));
            if (replayGain) m_activeDownloadTrack.insert(prefix + QStringLiteral("ReplayGain"), *replayGain);
            if (peak && *peak > 0) m_activeDownloadTrack.insert(prefix + QStringLiteral("PeakAmplitude"), *peak);
        };
        copyNormalization(QStringLiteral("trackAudioNormalizationData"), QStringLiteral("track"));
        copyNormalization(QStringLiteral("albumAudioNormalizationData"), QStringLiteral("album"));
        startDownloadTransfer(source);
    });
    if (requestId < 0) finishDownloadTransfer(false, QStringLiteral("Provider host is not running"));
}

void Backend::startYouTubeDownload()
{
    if (m_activeDownloadTrack.isEmpty()) return;
    const auto configured = qEnvironmentVariable("COLORFUL_YT_DLP").trimmed();
    const auto executable = configured.isEmpty()
        ? QStandardPaths::findExecutable(QStringLiteral("yt-dlp")) : configured;
    if (executable.isEmpty()) {
        finishDownloadTransfer(false, QStringLiteral("yt-dlp is required for YouTube downloads"));
        return;
    }
    const auto partsDirectory = downloadPartsDirectory(m_activeDownloadTrack);
    if (!QDir().mkpath(partsDirectory)) {
        finishDownloadTransfer(false, QStringLiteral("Could not create the download checkpoint directory"));
        return;
    }
    m_activeDownloadPartPath = QDir(partsDirectory).filePath(QStringLiteral("000000.mka"));
    if (QFileInfo::exists(m_activeDownloadPartPath)) {
        saveDownloadState(m_activeDownloadTrack, QStringLiteral("downloading"), {},
                          downloadWorkingBytes(m_activeDownloadTrack));
        startDownloadFinalization();
        return;
    }

    QStringList arguments{
        QStringLiteral("--no-warnings"), QStringLiteral("--no-playlist"),
        QStringLiteral("--continue"), QStringLiteral("--part"), QStringLiteral("--no-mtime"),
        QStringLiteral("--newline"), QStringLiteral("--progress-delta"), QStringLiteral("1"),
    };
    const auto extraArguments = qEnvironmentVariable("COLORFUL_YT_DLP_ARGS").trimmed();
    if (!extraArguments.isEmpty()) arguments.append(QProcess::splitCommand(extraArguments));
    arguments.append({QStringLiteral("--format"), QStringLiteral("bestaudio/best"),
                      QStringLiteral("--output"), m_activeDownloadPartPath});
    arguments.append(QStringLiteral("--"));
    arguments.append(QStringLiteral("https://music.youtube.com/watch?v=%1")
                         .arg(m_activeDownloadTrack.value(QStringLiteral("id")).toString()));

    saveDownloadState(m_activeDownloadTrack, QStringLiteral("downloading"), {},
                      downloadWorkingBytes(m_activeDownloadTrack));
    m_downloadProcess.setProgram(executable);
    m_downloadProcess.setArguments(arguments);
    m_downloadProcess.setProcessChannelMode(QProcess::SeparateChannels);
    m_downloadProcessStage = DownloadProcessStage::YouTubeTransfer;
    m_downloadProcess.start();
    m_downloadProgressTimer.start();
    setStatus(QFileInfo::exists(m_activeDownloadPartPath + QStringLiteral(".part"))
        ? QStringLiteral("Resuming %1 with yt-dlp…").arg(m_activeDownloadTrack.value(QStringLiteral("title")).toString())
        : QStringLiteral("Downloading %1 with yt-dlp…").arg(m_activeDownloadTrack.value(QStringLiteral("title")).toString()));
}

void Backend::startDownloadTransfer(const QJsonObject &source)
{
    if (m_activeDownloadTrack.isEmpty()) return;
    const auto sourceUrl = QUrl(source.value(QStringLiteral("uri")).toString());
    if (!sourceUrl.isValid() || sourceUrl.isEmpty()) {
        finishDownloadTransfer(false, QStringLiteral("The download source URL is invalid"));
        return;
    }
    if (!QDir().mkpath(downloadsDirectory())) {
        finishDownloadTransfer(false, QStringLiteral("Could not create the offline music directory"));
        return;
    }
    const auto ffmpeg = QStandardPaths::findExecutable(QStringLiteral("ffmpeg"));
    if (ffmpeg.isEmpty()) {
        finishDownloadTransfer(false, QStringLiteral("ffmpeg is required to assemble offline audio"));
        return;
    }
    if (QStandardPaths::findExecutable(QStringLiteral("ffprobe")).isEmpty()) {
        finishDownloadTransfer(false, QStringLiteral("ffprobe is required for resumable offline audio"));
        return;
    }

    const auto partsDirectory = downloadPartsDirectory(m_activeDownloadTrack);
    if (!QDir().mkpath(partsDirectory)) {
        finishDownloadTransfer(false, QStringLiteral("Could not create the download checkpoint directory"));
        return;
    }
    const auto legacyPartial = downloadPath(m_activeDownloadTrack, true);
    if (QFileInfo::exists(legacyPartial) && downloadPartFiles(m_activeDownloadTrack).isEmpty()) {
        const auto migratedPath = QDir(partsDirectory).filePath(QStringLiteral("000000.mka"));
        if (!QFile::rename(legacyPartial, migratedPath)) QFile::remove(legacyPartial);
    }

    qint64 resumePositionMs = 0;
    bool discardRemainder = false;
    const auto existingParts = downloadPartFiles(m_activeDownloadTrack);
    for (const auto &part : existingParts) {
        const auto partDurationMs = discardRemainder ? 0 : mediaDurationMs(part);
        if (partDurationMs <= 0) {
            discardRemainder = true;
            QFile::remove(part);
        } else {
            resumePositionMs += partDurationMs;
        }
    }

    const auto catalogDurationMs = m_activeDownloadTrack.value(QStringLiteral("durationMs")).toLongLong();
    if (!downloadPartFiles(m_activeDownloadTrack).isEmpty() && catalogDurationMs > 0
        && resumePositionMs >= catalogDurationMs - 500) {
        saveDownloadState(m_activeDownloadTrack, QStringLiteral("downloading"), {},
                          downloadWorkingBytes(m_activeDownloadTrack));
        startDownloadFinalization();
        return;
    }

    const auto partNumber = downloadPartFiles(m_activeDownloadTrack).size();
    m_activeDownloadPartPath = QDir(partsDirectory).filePath(
        QStringLiteral("%1.mka").arg(partNumber, 6, 10, QLatin1Char('0')));
    QFile::remove(m_activeDownloadPartPath);
    saveDownloadState(m_activeDownloadTrack, QStringLiteral("downloading"), {},
                      downloadWorkingBytes(m_activeDownloadTrack));
    m_downloadProcess.setProgram(ffmpeg);
    QStringList arguments{
        QStringLiteral("-nostdin"), QStringLiteral("-hide_banner"), QStringLiteral("-loglevel"), QStringLiteral("error"),
        QStringLiteral("-y"),
    };
    const auto fastSeekMs = std::max<qint64>(0, resumePositionMs - 8'000);
    const auto preciseTrimMs = resumePositionMs - fastSeekMs;
    if (fastSeekMs > 0) {
        arguments.append({QStringLiteral("-ss"),
                          QString::number(fastSeekMs / 1000.0, 'f', 3)});
    }
    const auto userAgent = source.value(QStringLiteral("userAgent")).toString();
    const auto referrer = source.value(QStringLiteral("referrer")).toString();
    if (!userAgent.isEmpty()) arguments.append({QStringLiteral("-user_agent"), userAgent});
    if (!referrer.isEmpty()) arguments.append({QStringLiteral("-referer"), referrer});
    QStringList headerLines;
    const auto headers = source.value(QStringLiteral("httpHeaders")).toObject();
    for (auto iterator = headers.constBegin(); iterator != headers.constEnd(); ++iterator) {
        if (iterator.value().isString()
            && iterator.key().compare(QStringLiteral("User-Agent"), Qt::CaseInsensitive) != 0
            && iterator.key().compare(QStringLiteral("Referer"), Qt::CaseInsensitive) != 0) {
            headerLines.append(iterator.key() + QStringLiteral(": ") + iterator.value().toString());
        }
    }
    if (!headerLines.isEmpty()) {
        arguments.append({QStringLiteral("-headers"), headerLines.join(QStringLiteral("\r\n")) + QStringLiteral("\r\n")});
    }
    arguments.append({QStringLiteral("-i"), sourceUrl.toString()});
    // DASH input seeking lands on a segment boundary. A small output-side
    // trim removes that overlap exactly while only re-reading a few seconds.
    if (preciseTrimMs > 0) {
        arguments.append({QStringLiteral("-ss"),
                          QString::number(preciseTrimMs / 1000.0, 'f', 3)});
    }
    arguments.append({
        QStringLiteral("-map"), QStringLiteral("0:a:0"), QStringLiteral("-vn"),
        QStringLiteral("-c:a"), QStringLiteral("copy"), QStringLiteral("-f"), QStringLiteral("matroska"),
        m_activeDownloadPartPath,
    });
    m_downloadProcess.setArguments(arguments);
    m_downloadProcess.setProcessChannelMode(QProcess::SeparateChannels);
    m_downloadProcessStage = DownloadProcessStage::Transfer;
    m_downloadProcess.start();
    m_downloadProgressTimer.start();
    setStatus(resumePositionMs > 0
        ? QStringLiteral("Resuming %1…").arg(m_activeDownloadTrack.value(QStringLiteral("title")).toString())
        : QStringLiteral("Downloading %1…").arg(m_activeDownloadTrack.value(QStringLiteral("title")).toString()));
}

void Backend::startDownloadFinalization()
{
    if (m_activeDownloadTrack.isEmpty()) return;
    const auto parts = downloadPartFiles(m_activeDownloadTrack);
    if (parts.isEmpty()) {
        finishDownloadTransfer(false, QStringLiteral("No completed download chunks were found"));
        return;
    }
    const auto ffmpeg = QStandardPaths::findExecutable(QStringLiteral("ffmpeg"));
    if (ffmpeg.isEmpty()) {
        finishDownloadTransfer(false, QStringLiteral("ffmpeg is required to finalize offline audio"));
        return;
    }

    const auto listPath = QDir(downloadPartsDirectory(m_activeDownloadTrack)).filePath(QStringLiteral("concat.txt"));
    QSaveFile listFile(listPath);
    if (!listFile.open(QIODevice::WriteOnly | QIODevice::Text)) {
        finishDownloadTransfer(false, QStringLiteral("Could not create the download assembly plan"));
        return;
    }
    for (const auto &part : parts) {
        auto escaped = part;
        escaped.replace(QLatin1Char('\''), QStringLiteral("'\\''"));
        const auto line = QStringLiteral("file '%1'\n").arg(escaped).toUtf8();
        if (listFile.write(line) != line.size()) {
            listFile.cancelWriting();
            finishDownloadTransfer(false, QStringLiteral("Could not write the download assembly plan"));
            return;
        }
    }
    if (!listFile.commit()) {
        finishDownloadTransfer(false, QStringLiteral("Could not save the download assembly plan"));
        return;
    }

    const auto assemblyPath = downloadAssemblyPath(m_activeDownloadTrack);
    QFile::remove(assemblyPath);
    m_downloadProcess.setProgram(ffmpeg);
    QStringList arguments{
        QStringLiteral("-nostdin"), QStringLiteral("-hide_banner"), QStringLiteral("-loglevel"), QStringLiteral("error"),
        QStringLiteral("-y"), QStringLiteral("-f"), QStringLiteral("concat"), QStringLiteral("-safe"), QStringLiteral("0"),
        QStringLiteral("-i"), listPath, QStringLiteral("-map"), QStringLiteral("0:a:0"), QStringLiteral("-vn"),
        QStringLiteral("-c:a"), QStringLiteral("copy"),
    };
    const auto addReplayGainTag = [&arguments, this](const QString &key, const QString &tag, bool gain) {
        if (!m_activeDownloadTrack.contains(key)) return;
        const auto value = m_activeDownloadTrack.value(key).toDouble();
        arguments.append({QStringLiteral("-metadata"),
                          tag + QLatin1Char('=') + QString::number(value, 'f', gain ? 2 : 6)
                              + (gain ? QStringLiteral(" dB") : QString{})});
    };
    addReplayGainTag(QStringLiteral("trackReplayGain"), QStringLiteral("REPLAYGAIN_TRACK_GAIN"), true);
    addReplayGainTag(QStringLiteral("trackPeakAmplitude"), QStringLiteral("REPLAYGAIN_TRACK_PEAK"), false);
    addReplayGainTag(QStringLiteral("albumReplayGain"), QStringLiteral("REPLAYGAIN_ALBUM_GAIN"), true);
    addReplayGainTag(QStringLiteral("albumPeakAmplitude"), QStringLiteral("REPLAYGAIN_ALBUM_PEAK"), false);
    arguments.append({QStringLiteral("-f"), QStringLiteral("matroska"), assemblyPath});
    m_downloadProcess.setArguments(arguments);
    m_downloadProcess.setProcessChannelMode(QProcess::SeparateChannels);
    m_downloadProcessStage = DownloadProcessStage::Finalize;
    m_downloadProcess.start();
    m_downloadProgressTimer.start();
    setStatus(QStringLiteral("Finalizing %1…")
                  .arg(m_activeDownloadTrack.value(QStringLiteral("title")).toString()));
}

void Backend::finishDownloadTransfer(bool succeeded, const QString &error)
{
    if (m_activeDownloadTrack.isEmpty()) return;
    m_downloadProgressTimer.stop();
    const auto track = m_activeDownloadTrack;
    const auto assemblyPath = downloadAssemblyPath(track);
    const auto finalPath = downloadPath(track, false);
    const auto assemblySize = std::max<qint64>(0, QFileInfo(assemblyPath).size());
    const bool remove = m_removeActiveDownload;
    const bool cancel = m_cancelActiveDownload;
    const bool quotaPause = m_pauseDownloadForQuota;
    m_activeDownloadTrack.clear();
    m_activeDownloadPartPath.clear();
    m_downloadProcessStage = DownloadProcessStage::Idle;
    m_cancelActiveDownload = false;
    m_removeActiveDownload = false;
    m_pauseDownloadForQuota = false;

    if (remove) {
        removeDownloadWorkingFiles(track);
        QFile::remove(finalPath);
        QFile::remove(downloadArtworkPath(track));
        dispatchCore({{QStringLiteral("command"), QStringLiteral("remove_download")},
                      {QStringLiteral("id"), QJsonObject{{QStringLiteral("provider"), track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()},
                                                         {QStringLiteral("providerId"), track.value(QStringLiteral("id")).toString()}}}});
        notify(QStringLiteral("Removed offline copy of %1").arg(track.value(QStringLiteral("title")).toString()));
    } else if (cancel) {
        QFile::remove(assemblyPath);
        saveDownloadState(track, QStringLiteral("paused"), {}, downloadWorkingBytes(track));
        notify(quotaPause
                   ? QStringLiteral("Paused %1 because the offline storage limit was reached")
                         .arg(track.value(QStringLiteral("title")).toString())
                   : QStringLiteral("Paused offline download for %1")
                         .arg(track.value(QStringLiteral("title")).toString()),
               quotaPause ? QStringLiteral("warning") : QStringLiteral("info"));
    } else if (!succeeded || assemblySize <= 0) {
        QFile::remove(assemblyPath);
        saveDownloadState(track, QStringLiteral("failed"), {}, downloadWorkingBytes(track), std::nullopt,
                          QStringLiteral("transfer_failed"));
        notify(QStringLiteral("Download failed: %1").arg(error.isEmpty() ? QStringLiteral("empty output") : error),
               QStringLiteral("error"));
    } else {
        QFile::remove(finalPath);
        if (!QFile::rename(assemblyPath, finalPath)) {
            saveDownloadState(track, QStringLiteral("failed"), {}, downloadWorkingBytes(track), std::nullopt,
                              QStringLiteral("finalize_failed"));
            notify(QStringLiteral("Could not finalize the offline file"), QStringLiteral("error"));
        } else {
            const auto finalSize = std::max<qint64>(0, QFileInfo(finalPath).size());
            QDir(downloadPartsDirectory(track)).removeRecursively();
            QFile::remove(downloadPath(track, true));
            saveDownloadState(track, QStringLiteral("complete"), finalPath, finalSize, finalSize);
            downloadArtwork(track);
            notify(QStringLiteral("%1 is ready offline").arg(track.value(QStringLiteral("title")).toString()),
                   QStringLiteral("success"));
        }
    }
    QTimer::singleShot(0, this, &Backend::beginNextDownload);
}

void Backend::pauseDownload(const QString &trackId, const QString &provider)
{
    for (qsizetype index = 0; index < m_downloadQueue.size(); ++index) {
        if (m_downloadQueue.at(index).value(QStringLiteral("provider"), QStringLiteral("tidal")).toString() != provider
            || m_downloadQueue.at(index).value(QStringLiteral("id")).toString() != trackId) continue;
        const auto track = m_downloadQueue.takeAt(index);
        saveDownloadState(track, QStringLiteral("paused"), {}, downloadWorkingBytes(track));
        notify(QStringLiteral("Paused offline download for %1")
                   .arg(track.value(QStringLiteral("title")).toString()));
        return;
    }
    if (m_activeDownloadTrack.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString() != provider
        || m_activeDownloadTrack.value(QStringLiteral("id")).toString() != trackId) return;
    ++m_downloadGeneration;
    m_cancelActiveDownload = true;
    if (m_downloadProcess.state() == QProcess::NotRunning) finishDownloadTransfer(false);
    else {
        m_downloadProcess.terminate();
        const auto generation = m_downloadGeneration;
        QTimer::singleShot(2000, this, [this, generation] {
            if (generation == m_downloadGeneration && m_cancelActiveDownload
                && m_downloadProcess.state() != QProcess::NotRunning) m_downloadProcess.kill();
        });
    }
}

void Backend::removeDownload(const QString &trackId, const QString &provider)
{
    for (qsizetype index = 0; index < m_downloadQueue.size(); ++index) {
        if (m_downloadQueue.at(index).value(QStringLiteral("provider"), QStringLiteral("tidal")).toString() != provider
            || m_downloadQueue.at(index).value(QStringLiteral("id")).toString() != trackId) continue;
        const auto track = m_downloadQueue.takeAt(index);
        removeDownloadWorkingFiles(track);
        QFile::remove(downloadPath(track, false));
        QFile::remove(downloadArtworkPath(track));
        dispatchCore({{QStringLiteral("command"), QStringLiteral("remove_download")},
                      {QStringLiteral("id"), QJsonObject{{QStringLiteral("provider"), track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()},
                                                         {QStringLiteral("providerId"), trackId}}}});
        notify(QStringLiteral("Removed offline download for %1")
                   .arg(track.value(QStringLiteral("title")).toString()));
        return;
    }
    if (m_activeDownloadTrack.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString() == provider
        && m_activeDownloadTrack.value(QStringLiteral("id")).toString() == trackId) {
        ++m_downloadGeneration;
        m_removeActiveDownload = true;
        if (m_downloadProcess.state() == QProcess::NotRunning) finishDownloadTransfer(false);
        else m_downloadProcess.kill();
        return;
    }
    const auto existing = downloadForTrack(provider, trackId);
    if (existing.isEmpty()) return;
    QFile::remove(existing.value(QStringLiteral("localPath")).toString());
    removeDownloadWorkingFiles(existing);
    QFile::remove(downloadArtworkPath(existing));
    dispatchCore({{QStringLiteral("command"), QStringLiteral("remove_download")},
                  {QStringLiteral("id"), QJsonObject{{QStringLiteral("provider"), existing.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()},
                                                     {QStringLiteral("providerId"), trackId}}}});
    notify(QStringLiteral("Removed offline copy of %1").arg(existing.value(QStringLiteral("title")).toString()));
}

void Backend::removeCompletedDownloads()
{
    const auto downloads = m_downloads;
    int removed = 0;
    for (const auto &value : downloads) {
        const auto track = value.toMap();
        if (track.value(QStringLiteral("downloadState")).toString() != QStringLiteral("complete")) continue;
        QFile::remove(track.value(QStringLiteral("localPath")).toString());
        removeDownloadWorkingFiles(track);
        QFile::remove(downloadArtworkPath(track));
        dispatchCore({{QStringLiteral("command"), QStringLiteral("remove_download")},
                      {QStringLiteral("id"), QJsonObject{
                          {QStringLiteral("provider"), track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()},
                          {QStringLiteral("providerId"), track.value(QStringLiteral("id")).toString()},
                      }}});
        ++removed;
    }
    if (removed > 0)
        notify(QStringLiteral("Removed %1 completed offline %2")
                   .arg(removed)
                   .arg(removed == 1 ? QStringLiteral("track") : QStringLiteral("tracks")));
}

void Backend::removeUnfinishedDownloads()
{
    const auto downloads = m_downloads;
    int removed = 0;
    for (const auto &value : downloads) {
        const auto track = value.toMap();
        if (track.value(QStringLiteral("downloadState")).toString() == QStringLiteral("complete")) continue;
        const auto provider = track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString();
        const auto id = track.value(QStringLiteral("id")).toString();
        for (qsizetype index = m_downloadQueue.size() - 1; index >= 0; --index) {
            if (m_downloadQueue.at(index).value(QStringLiteral("provider"), QStringLiteral("tidal")).toString() == provider
                && m_downloadQueue.at(index).value(QStringLiteral("id")).toString() == id)
                m_downloadQueue.removeAt(index);
        }
        if (!m_activeDownloadTrack.isEmpty()
            && m_activeDownloadTrack.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString() == provider
            && m_activeDownloadTrack.value(QStringLiteral("id")).toString() == id) {
            ++m_downloadGeneration;
            m_removeActiveDownload = true;
            if (m_downloadProcess.state() == QProcess::NotRunning) finishDownloadTransfer(false);
            else m_downloadProcess.kill();
            ++removed;
            continue;
        }
        removeDownloadWorkingFiles(track);
        QFile::remove(downloadArtworkPath(track));
        dispatchCore({{QStringLiteral("command"), QStringLiteral("remove_download")},
                      {QStringLiteral("id"), QJsonObject{{QStringLiteral("provider"), provider},
                                                         {QStringLiteral("providerId"), id}}}});
        ++removed;
    }
    if (removed > 0)
        notify(QStringLiteral("Removed %1 unfinished download %2")
                   .arg(removed).arg(removed == 1 ? QStringLiteral("entry") : QStringLiteral("entries")));
}

void Backend::setOfflineStorageLimitBytes(qint64 bytes)
{
    const auto next = std::max<qint64>(0, bytes);
    if (next == m_offlineStorageLimitBytes) return;
    m_offlineStorageLimitBytes = next;
    QSettings().setValue(QStringLiteral("storage/offlineLimitBytes"), next);
    emit offlineStorageLimitChanged();
}

void Backend::openDownloadsFolder()
{
    QDir().mkpath(downloadsDirectory());
    QDesktopServices::openUrl(QUrl::fromLocalFile(downloadsDirectory()));
}

void Backend::playTrackAt(int index)
{
    if (index < 0 || index >= m_queueEntryIds.size()) return;
    finishListeningSession();
    dispatchCore({{QStringLiteral("command"), QStringLiteral("select")},
                  {QStringLiteral("entry_id"), m_queueEntryIds.at(index)}});
    resolveCurrentSource();
}

void Backend::playSingleTrack(const QVariantMap &track)
{
    playTracks(QVariantList{track});
}

void Backend::playTracks(const QVariantList &tracks, bool preserveProvidedOrder)
{
    QJsonArray coreTracks;
    for (const auto &value : tracks) {
        const auto track = value.toMap();
        if (!track.value(QStringLiteral("id")).toString().isEmpty())
            coreTracks.append(variantTrackToCore(track));
    }
    if (coreTracks.isEmpty()) return;
    clearPlaylistContinuation();
    finishListeningSession();
    dispatchCore({{QStringLiteral("command"), preserveProvidedOrder
                                                ? QStringLiteral("play_tracks_in_order")
                                                : QStringLiteral("play_tracks")},
                  {QStringLiteral("tracks"), coreTracks}});
    resolveCurrentSource();
}

void Backend::clearPlaylistContinuation()
{
    ++m_playlistContinuationGeneration;
    m_playlistId.clear();
    m_playlistCursor.clear();
    m_playlistContinuationPending = false;
    m_playlistContinueWhenReady = false;
}

void Backend::activatePlaylistContinuation(const QString &playlistId, const QString &cursor)
{
    m_playlistId = playlistId;
    m_playlistCursor = cursor;
    m_playlistContinuationPending = false;
    m_playlistContinueWhenReady = false;
}

bool Backend::atLoadedQueueEnd() const
{
    const auto playIndex = m_playOrderEntryIds.indexOf(m_currentEntryId);
    return playIndex >= 0 && playIndex + 1 >= m_playOrderEntryIds.size();
}

bool Backend::playlistNeedsRefill() const
{
    if (m_repeatMode == QStringLiteral("one") || m_playlistCursor.isEmpty() || m_currentEntryId < 0) return false;
    const auto playIndex = m_playOrderEntryIds.indexOf(m_currentEntryId);
    return playIndex >= 0 && playIndex + 3 >= m_playOrderEntryIds.size();
}

void Backend::requestPlaylistContinuation(bool continueWhenReady)
{
    if (m_playlistContinuationPending) {
        m_playlistContinueWhenReady = m_playlistContinueWhenReady || continueWhenReady;
        return;
    }
    if (m_playlistCursor.isEmpty() || m_playlistId.isEmpty()) {
        if (continueWhenReady) {
            if (m_autoplayEnabled && m_currentIndex >= 0) requestRelated(true);
            else stop();
        }
        return;
    }
    m_playlistContinuationPending = true;
    m_playlistContinueWhenReady = continueWhenReady;
    const auto generation = m_playlistContinuationGeneration;
    const auto requestedCursor = m_playlistCursor;
    request(QStringLiteral("detail.more"), {
        {QStringLiteral("provider"), QStringLiteral("youtube")},
        {QStringLiteral("kind"), QStringLiteral("playlist")},
        {QStringLiteral("id"), m_playlistId},
        {QStringLiteral("section"), QStringLiteral("tracks")},
        {QStringLiteral("cursor"), requestedCursor},
    }, [this, generation, requestedCursor](const QJsonObject &message) {
        if (generation != m_playlistContinuationGeneration) return;
        const bool continueWhenReady = m_playlistContinueWhenReady;
        m_playlistContinuationPending = false;
        m_playlistContinueWhenReady = false;
        if (!message.value(QStringLiteral("ok")).toBool()) {
            const auto error = message.value(QStringLiteral("error")).toString();
            m_playlistCursor.clear();
            notify(error.isEmpty() ? QStringLiteral("Could not continue the YouTube Music playlist") : error,
                   QStringLiteral("error"));
            if (continueWhenReady) {
                if (m_autoplayEnabled && m_currentIndex >= 0) requestRelated(true);
                else stop();
            }
            return;
        }
        const auto data = message.value(QStringLiteral("data")).toObject();
        const auto nextCursor = data.value(QStringLiteral("cursor")).toString();
        m_playlistCursor = nextCursor == requestedCursor ? QString{} : nextCursor;
        QJsonArray coreTracks;
        QVariantList pageTracks;
        for (const auto &value : data.value(QStringLiteral("tracks")).toArray()) {
            auto document = value.toObject();
            document.insert(QStringLiteral("provider"), QStringLiteral("youtube"));
            const auto track = jsonTrackToVariant(document);
            if (track.value(QStringLiteral("id")).toString().isEmpty()) continue;
            coreTracks.append(variantTrackToCore(track));
            pageTracks.append(track);
        }
        if (!coreTracks.isEmpty()) {
            dispatchCore({{QStringLiteral("command"), QStringLiteral("enqueue_tracks")},
                          {QStringLiteral("tracks"), coreTracks}});
            if (requestedCursor.startsWith(QStringLiteral("youtube-music-browse:"))
                && m_catalogPage.value(QStringLiteral("kind")).toString() == QStringLiteral("playlist")
                && m_catalogPage.value(QStringLiteral("provider")).toString() == QStringLiteral("youtube")
                && m_catalogPage.value(QStringLiteral("resourceId")).toString() == m_playlistId) {
                auto visibleTracks = m_catalogPage.value(QStringLiteral("tracks")).toList();
                visibleTracks.append(pageTracks);
                m_catalogPage.insert(QStringLiteral("tracks"), visibleTracks);
                m_catalogPage.insert(QStringLiteral("trackCursor"), m_playlistCursor);
                emit catalogPageChanged();
            }
        }
        if (continueWhenReady) {
            if (canGoNext()) advanceToNext(false);
            else requestPlaylistContinuation(true);
        } else {
            prepareNextSource();
        }
    });
}

void Backend::resolveCurrentSource(qint64 startPositionMs, bool autoplay)
{
    m_manualSkipTimer.stop();
    const auto track = currentTrack();
    if (track.isEmpty()) return;
    const auto requestedTrackId = track.value(QStringLiteral("id")).toString();
    const auto sourceGeneration = ++m_sourceGeneration;
    invalidatePreparedNext();
    suspendListeningSession();
    m_playbackReady = false;
    const auto offline = downloadForTrack(
        track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString(), requestedTrackId);
    const auto localPath = offline.value(QStringLiteral("localPath")).toString();
    if (offline.value(QStringLiteral("downloadState")).toString() == QStringLiteral("complete")
        && !localPath.isEmpty() && QFileInfo::exists(localPath)) {
        m_playingLocalSource = true;
        m_displayPositionOverride = startPositionMs > 0 ? startPositionMs : -1;
        loadAccent(track.value(QStringLiteral("coverUrl")).toString());
        m_playback.setSource(QUrl::fromLocalFile(localPath), startPositionMs, autoplay);
        return;
    }
    m_playingLocalSource = false;
    setBusy(true);
    setStatus(QStringLiteral("Getting playback source for %1…").arg(track.value(QStringLiteral("title")).toString()));
    loadAccent(track.value(QStringLiteral("coverUrl")).toString());
    request(QStringLiteral("source"), {{QStringLiteral("provider"), track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()},
                                        {QStringLiteral("trackId"), requestedTrackId},
                                        {QStringLiteral("manifestType"), QStringLiteral("MPEG_DASH")},
                                        {QStringLiteral("quality"), m_streamQuality}},
            [this, requestedTrackId, startPositionMs, autoplay, sourceGeneration](const QJsonObject &message) {
        if (sourceGeneration != m_sourceGeneration
            || currentTrack().value(QStringLiteral("id")).toString() != requestedTrackId) return;
        if (!message.value(QStringLiteral("ok")).toBool()) {
            setBusy(false);
            const auto error = message.value(QStringLiteral("error")).toString();
            setStatus(error);
            m_playbackError = error.isEmpty() ? QStringLiteral("Could not resolve a playback source") : error;
            emit playbackConditionChanged();
            if (error.contains(QStringLiteral("only returned a preview"), Qt::CaseInsensitive)) {
                setEntitlementWarning(
                    true,
                    QStringLiteral("TIDAL is only granting preview playback to this account. Check the subscription before trying again."));
            }
            return;
        }
        const auto source = message.value(QStringLiteral("data")).toObject();
        const auto uri = source.value(QStringLiteral("uri")).toString();
        if (uri.isEmpty()) {
            setBusy(false);
            setStatus(QStringLiteral("The provider returned an empty playback source"));
            m_playbackError = QStringLiteral("The provider returned an empty playback source");
            emit playbackConditionChanged();
            return;
        }
        m_displayPositionOverride = startPositionMs > 0 ? startPositionMs : -1;
        m_playback.setSource(
            QUrl(uri), startPositionMs, autoplay,
            normalizationNumber(source, QStringLiteral("trackAudioNormalizationData"), QStringLiteral("replayGain")),
            normalizationNumber(source, QStringLiteral("trackAudioNormalizationData"), QStringLiteral("peakAmplitude")),
            source.value(QStringLiteral("userAgent")).toString(),
            source.value(QStringLiteral("referrer")).toString());
    });
}

void Backend::invalidatePreparedNext()
{
    ++m_prepareGeneration;
    m_preparedEntryId = -1;
    m_preparedLocalSource = false;
    m_playback.clearPreparedNext();
}

void Backend::prepareNextSource()
{
    if (!m_playback.hasSource() || !m_playbackReady) {
        if (m_preparedEntryId >= 0 || m_playback.hasPreparedNext()) invalidatePreparedNext();
        return;
    }
    if (playlistNeedsRefill()) requestPlaylistContinuation(false);
    if (!canGoNext()) {
        if (m_preparedEntryId >= 0 || m_playback.hasPreparedNext()) invalidatePreparedNext();
        if (!m_playlistCursor.isEmpty() || m_playlistContinuationPending) requestPlaylistContinuation(false);
        else if (m_autoplayEnabled && m_currentIndex >= 0) requestRelated(false);
        return;
    }

    const auto nextIndex = nextQueueIndex();
    if (nextIndex < 0) return;
    const auto entryId = m_queueEntryIds.value(nextIndex, -1);
    if (entryId < 0) return;
    if (entryId == m_preparedEntryId && m_playback.hasPreparedNext()) return;

    invalidatePreparedNext();
    const auto generation = m_prepareGeneration;
    const auto track = m_queue.at(nextIndex).toMap();
    const auto trackId = track.value(QStringLiteral("id")).toString();
    const auto offline = downloadForTrack(
        track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString(), trackId);
    const auto localPath = offline.value(QStringLiteral("localPath")).toString();
    if (offline.value(QStringLiteral("downloadState")).toString() == QStringLiteral("complete")
        && !localPath.isEmpty() && QFileInfo::exists(localPath)) {
        m_preparedEntryId = entryId;
        m_preparedLocalSource = true;
        m_playback.prepareNextSource(QUrl::fromLocalFile(localPath));
        return;
    }

    request(QStringLiteral("source"), {
        {QStringLiteral("provider"), track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()},
        {QStringLiteral("trackId"), trackId},
        {QStringLiteral("manifestType"), QStringLiteral("MPEG_DASH")},
        {QStringLiteral("quality"), m_streamQuality},
    }, [this, generation, entryId, trackId](const QJsonObject &message) {
        const auto nextIndex = nextQueueIndex();
        if (generation != m_prepareGeneration || nextIndex < 0
            || m_queueEntryIds.value(nextIndex, -1) != entryId
            || m_queue.value(nextIndex).toMap().value(QStringLiteral("id")).toString() != trackId)
            return;
        if (!message.value(QStringLiteral("ok")).toBool()) return;
        const auto source = message.value(QStringLiteral("data")).toObject();
        const auto uri = source.value(QStringLiteral("uri")).toString();
        if (uri.isEmpty()) return;
        m_preparedEntryId = entryId;
        m_preparedLocalSource = false;
        m_playback.prepareNextSource(
            QUrl(uri),
            normalizationNumber(source, QStringLiteral("trackAudioNormalizationData"), QStringLiteral("replayGain")),
            normalizationNumber(source, QStringLiteral("trackAudioNormalizationData"), QStringLiteral("peakAmplitude")),
            source.value(QStringLiteral("userAgent")).toString(),
            source.value(QStringLiteral("referrer")).toString());
    });
}

void Backend::advancePreparedTrack()
{
    if (m_preparedEntryId < 0) {
        advanceToNext(false);
        return;
    }
    const auto expectedEntryId = m_preparedEntryId;
    const auto localSource = m_preparedLocalSource;
    m_preparedEntryId = -1;
    m_preparedLocalSource = false;
    ++m_prepareGeneration;

    finishListeningSession();
    dispatchCore({{QStringLiteral("command"), QStringLiteral("checkpoint_position")},
                  {QStringLiteral("position_ms"), duration()}});
    dispatchCore({{QStringLiteral("command"), QStringLiteral("skip_next")}});
    if (m_currentEntryId != expectedEntryId) {
        resolveCurrentSource();
        return;
    }
    m_playingLocalSource = localSource;
    m_resumePositionMs = 0;
    m_displayPositionOverride = -1;
    emit positionChanged();
}

void Backend::togglePlay() { playing() ? pause() : play(); }
void Backend::play()
{
    if (m_currentIndex < 0 && !m_queue.isEmpty()) {
        playTrackAt(0);
        return;
    }
    if (m_currentIndex < 0) return;
    dispatchCore({{QStringLiteral("command"), QStringLiteral("play")}});
    if (!m_playback.hasSource()) resolveCurrentSource(m_resumePositionMs, true);
    else m_playback.play();
}
void Backend::pause()
{
    suspendListeningSession();
    dispatchCore({{QStringLiteral("command"), QStringLiteral("checkpoint_position")},
                  {QStringLiteral("position_ms"), position()}});
    dispatchCore({{QStringLiteral("command"), QStringLiteral("pause")}});
    m_playback.pause();
}
void Backend::stop()
{
    finishListeningSession();
    m_manualSkipTimer.stop();
    ++m_sourceGeneration;
    dispatchCore({{QStringLiteral("command"), QStringLiteral("stop")}});
    m_resumePositionMs = 0;
    m_displayPositionOverride = -1;
    m_playback.stop();
}

void Backend::next() { advanceToNext(true); }

void Backend::scheduleCurrentSourceAfterSkip(bool autoplay)
{
    // Invalidate any response for an earlier queue selection immediately. The
    // timer itself is restarted by every click, so only the final selection
    // reaches the provider host.
    ++m_sourceGeneration;
    invalidatePreparedNext();
    m_manualSkipAutoplay = autoplay;
    if (autoplay) m_playback.suspendForSourceChange();
    m_manualSkipTimer.start();
}

void Backend::advanceToNext(bool coalesceSourceResolution)
{
    finishListeningSession();
    if (m_repeatMode != QStringLiteral("one") && atLoadedQueueEnd()
        && (!m_playlistCursor.isEmpty() || m_playlistContinuationPending)) {
        requestPlaylistContinuation(true);
        return;
    }
    if (!canGoNext()) {
        if (m_autoplayEnabled && m_currentIndex >= 0) requestRelated(true);
        else stop();
        return;
    }
    const bool autoplay = playing();
    const auto nextIndex = nextQueueIndex();
    const auto nextEntryId = m_queueEntryIds.value(nextIndex, -1);
    dispatchCore({{QStringLiteral("command"), QStringLiteral("checkpoint_position")},
                  {QStringLiteral("position_ms"), position()}});
    dispatchCore({{QStringLiteral("command"), QStringLiteral("skip_next")}});
    if (nextEntryId >= 0 && nextEntryId == m_preparedEntryId) {
        const auto localSource = m_preparedLocalSource;
        m_preparedEntryId = -1;
        m_preparedLocalSource = false;
        ++m_prepareGeneration;
        if (m_playback.playPreparedNext(autoplay)) {
            m_playingLocalSource = localSource;
            m_resumePositionMs = 0;
            m_displayPositionOverride = -1;
            emit positionChanged();
            return;
        }
    }
    if (coalesceSourceResolution) scheduleCurrentSourceAfterSkip(autoplay);
    else resolveCurrentSource(0, autoplay);
}

void Backend::requestRelated(bool continueWhenReady)
{
    if (m_relatedPending) {
        if (m_relatedSeedEntryId == m_currentEntryId) {
            m_relatedContinueWhenReady = m_relatedContinueWhenReady || continueWhenReady;
            if (continueWhenReady) setStatus(QStringLiteral("Finding something related…"));
            return;
        }
        ++m_relatedGeneration;
        m_relatedPending = false;
        m_relatedContinueWhenReady = false;
        m_relatedSeedEntryId = -1;
    }
    const auto seed = currentTrack();
    if (seed.isEmpty()) {
        if (continueWhenReady) stop();
        return;
    }
    m_relatedPending = true;
    m_relatedContinueWhenReady = continueWhenReady;
    m_relatedSeedEntryId = m_currentEntryId;
    const auto generation = ++m_relatedGeneration;
    const auto seedEntryId = m_relatedSeedEntryId;
    const auto seedProvider = seed.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString();
    if (continueWhenReady) setStatus(QStringLiteral("Finding something related…"));
    request(QStringLiteral("related"), {{QStringLiteral("provider"), seedProvider},
                                         {QStringLiteral("trackId"), seed.value(QStringLiteral("id")).toString()},
                                         {QStringLiteral("limit"), 20}}, [this, seedEntryId, generation, seedProvider](const QJsonObject &message) {
        if (generation != m_relatedGeneration) return;
        const bool continueWhenReady = m_relatedContinueWhenReady;
        m_relatedPending = false;
        m_relatedContinueWhenReady = false;
        m_relatedSeedEntryId = -1;
        if (seedEntryId != m_currentEntryId || !m_autoplayEnabled) {
            prepareNextSource();
            return;
        }
        if (!message.value(QStringLiteral("ok")).toBool()) {
            if (continueWhenReady) {
                setStatus(message.value(QStringLiteral("error")).toString());
                stop();
            }
            return;
        }
        const auto identity = [](const QVariantMap &track) {
            return track.value(QStringLiteral("provider"), QStringLiteral("tidal")).toString()
                + QLatin1Char(':') + track.value(QStringLiteral("id")).toString();
        };
        QSet<QString> queuedIds;
        for (const auto &value : m_queue) queuedIds.insert(identity(value.toMap()));
        int added = 0;
        for (const auto &value : message.value(QStringLiteral("data")).toObject().value(QStringLiteral("tracks")).toArray()) {
            auto document = value.toObject();
            if (!document.contains(QStringLiteral("provider"))) {
                document.insert(QStringLiteral("provider"), seedProvider);
            }
            const auto track = jsonTrackToVariant(document);
            const auto id = track.value(QStringLiteral("id")).toString();
            const auto key = identity(track);
            if (id.isEmpty() || queuedIds.contains(key)) continue;
            dispatchCore({{QStringLiteral("command"), QStringLiteral("enqueue")},
                          {QStringLiteral("track"), variantTrackToCore(track)}});
            queuedIds.insert(key);
            if (++added >= 20) break;
        }
        if (canGoNext()) {
            setStatus(QStringLiteral("Autoplay added %1 related tracks").arg(added));
            if (continueWhenReady) advanceToNext(false);
            else prepareNextSource();
        } else {
            if (continueWhenReady) {
                setStatus(QStringLiteral("No new related tracks were available"));
                stop();
            }
        }
    });
}

void Backend::previous()
{
    if (position() > 3000 || !canGoPrevious()) seek(0);
    else {
        finishListeningSession();
        dispatchCore({{QStringLiteral("command"), QStringLiteral("checkpoint_position")},
                      {QStringLiteral("position_ms"), position()}});
        dispatchCore({{QStringLiteral("command"), QStringLiteral("skip_previous")}});
        resolveCurrentSource();
    }
}

void Backend::seek(qint64 positionMs)
{
    suspendListeningSession();
    const auto target = std::clamp<qint64>(positionMs, 0, std::max<qint64>(0, duration()));
    if (m_playback.seek(target)) {
        m_displayPositionOverride = target;
        emit positionChanged();
    } else {
        resumeListeningSession();
    }
}

void Backend::seekBy(qint64 offsetMs) { seek(position() + offsetMs); }

void Backend::setVolume(double volume)
{
    m_playback.setVolume(volume);
    QSettings().setValue(QStringLiteral("playback/volume"), m_playback.volume());
}

void Backend::setMuted(bool muted)
{
    m_playback.setMuted(muted);
    QSettings().setValue(QStringLiteral("playback/muted"), m_playback.muted());
}

void Backend::setRepeatMode(const QString &mode)
{
    const auto next = mode == QStringLiteral("all") || mode == QStringLiteral("one")
        ? mode : QStringLiteral("off");
    if (next == m_repeatMode) return;
    dispatchCore({{QStringLiteral("command"), QStringLiteral("set_repeat")},
                  {QStringLiteral("repeat"), next}});
    prepareNextSource();
}

void Backend::setShuffleEnabled(bool enabled)
{
    if (enabled == m_shuffleEnabled) return;
    dispatchCore({{QStringLiteral("command"), QStringLiteral("set_shuffle")},
                  {QStringLiteral("enabled"), enabled},
                  {QStringLiteral("seed"), QDateTime::currentMSecsSinceEpoch()}});
    prepareNextSource();
}

void Backend::setAudioDevice(const QString &device)
{
    m_playback.setAudioDevice(device);
    QSettings().setValue(QStringLiteral("playback/audioDevice"), m_playback.audioDevice());
}

void Backend::refreshAudioDevices() { m_playback.refreshAudioDevices(); }

void Backend::retryPlayback()
{
    if (currentTrack().isEmpty()) return;
    const auto retryPosition = position();
    m_playbackError.clear();
    emit playbackConditionChanged();
    resolveCurrentSource(retryPosition, playing());
}

void Backend::setAutoplayEnabled(bool enabled)
{
    if (m_autoplayEnabled == enabled) return;
    m_autoplayEnabled = enabled;
    QSettings().setValue(QStringLiteral("playback/autoplay"), enabled);
    emit autoplayEnabledChanged();
    if (enabled) prepareNextSource();
}

void Backend::setStreamQuality(const QString &quality)
{
    if (quality != QStringLiteral("best") && quality != QStringLiteral("lossless")
        && quality != QStringLiteral("high")) return;
    if (m_streamQuality == quality) return;
    m_streamQuality = quality;
    QSettings().setValue(QStringLiteral("playback/streamQuality"), quality);
    emit streamQualityChanged();
    notify(QStringLiteral("Stream quality will apply to the next track"));
}

void Backend::setNormalizationEnabled(bool enabled)
{
    if (m_normalizationEnabled == enabled) return;
    m_normalizationEnabled = enabled;
    QSettings().setValue(QStringLiteral("playback/normalization"), enabled);
    m_playback.setReplayGain(enabled);
    invalidatePreparedNext();
    prepareNextSource();
    emit audioProcessingChanged();
    notify(enabled ? QStringLiteral("Track normalization enabled")
                   : QStringLiteral("Track normalization disabled"));
}

void Backend::setEqualizerBand(int index, double gainDb)
{
    if (index < 0 || index >= m_equalizerBands.size()) return;
    const auto normalized = std::clamp(gainDb, -12.0, 12.0);
    if (qFuzzyCompare(m_equalizerBands.at(index).toDouble() + 13.0, normalized + 13.0)) return;
    m_equalizerBands[index] = normalized;
    m_equalizerPreset = QStringLiteral("Custom");
    QSettings settings;
    settings.setValue(QStringLiteral("playback/equalizerBands"), m_equalizerBands);
    settings.setValue(QStringLiteral("playback/equalizerPreset"), m_equalizerPreset);
    QList<double> gains;
    gains.reserve(m_equalizerBands.size());
    for (const auto &gain : std::as_const(m_equalizerBands)) gains.append(gain.toDouble());
    m_playback.setEqualizer(gains);
    emit audioProcessingChanged();
}

void Backend::applyEqualizerPreset(const QString &preset)
{
    static const QHash<QString, QList<double>> presets = {
        {QStringLiteral("Flat"), {0, 0, 0, 0, 0, 0, 0, 0, 0, 0}},
        {QStringLiteral("Bass boost"), {6, 5, 4, 2, 1, 0, 0, 0, 0, 0}},
        {QStringLiteral("Treble boost"), {0, 0, 0, 0, 0, 1, 2, 4, 5, 6}},
        {QStringLiteral("Vocal"), {-2, -1, 0, 2, 4, 5, 4, 2, 0, -1}},
        {QStringLiteral("V-shaped"), {5, 4, 2, 0, -2, -1, 1, 3, 4, 5}},
    };
    const auto found = presets.constFind(preset);
    if (found == presets.cend()) return;
    m_equalizerBands.clear();
    for (const auto gain : found.value()) m_equalizerBands.append(gain);
    m_equalizerPreset = preset;
    QSettings settings;
    settings.setValue(QStringLiteral("playback/equalizerBands"), m_equalizerBands);
    settings.setValue(QStringLiteral("playback/equalizerPreset"), preset);
    m_playback.setEqualizer(found.value());
    emit audioProcessingChanged();
}

void Backend::setAccentMode(const QString &mode)
{
    if (mode != QStringLiteral("album") && mode != QStringLiteral("fixed")) return;
    if (m_accentMode == mode) return;
    m_accentMode = mode;
    QSettings().setValue(QStringLiteral("appearance/accentMode"), mode);
    emit appearanceChanged();
    if (mode == QStringLiteral("fixed")) animateAccent(m_fixedAccent);
    else loadAccent(currentTrack().value(QStringLiteral("coverUrl")).toString());
}

void Backend::setFixedAccent(const QColor &color)
{
    if (!color.isValid()) return;
    const auto normalized = normalizeAlbumAccent(color);
    if (m_fixedAccent == normalized) return;
    m_fixedAccent = normalized;
    QSettings().setValue(QStringLiteral("appearance/fixedAccent"), normalized.name(QColor::HexRgb));
    emit appearanceChanged();
    if (m_accentMode == QStringLiteral("fixed")) animateAccent(normalized);
}

void Backend::setLowDataMode(bool enabled)
{
    if (m_lowDataMode == enabled) return;
    m_lowDataMode = enabled;
    QSettings().setValue(QStringLiteral("appearance/lowDataMode"), enabled);
    if (enabled) {
        m_pendingArtworkUrl.clear();
        if (m_accentReply) {
            auto *reply = m_accentReply.data();
            m_accentReply.clear();
            reply->abort();
        }
    } else if (m_accentMode == QStringLiteral("album")) {
        loadAccent(currentTrack().value(QStringLiteral("coverUrl")).toString());
    }
    emit appearanceChanged();
    emit currentTrackChanged();
}

void Backend::setDiscordWidgetEnabled(bool enabled)
{
    m_discordWidget.setEnabled(enabled);
}

void Backend::setDiscordApplicationId(const QString &applicationId)
{
    m_discordWidget.setApplicationId(applicationId);
    m_discordPresence.setApplicationId(m_discordWidget.applicationId());
}

void Backend::setDiscordRedirectUri(const QString &redirectUri)
{
    m_discordWidget.setRedirectUri(redirectUri);
}

void Backend::setDiscordWidgetUserId(const QString &userId)
{
    m_discordWidget.setUserIdOverride(userId);
}

void Backend::useDetectedDiscordWidgetUserId()
{
    m_discordWidget.setUserIdOverride({});
}

void Backend::authorizeDiscordWidget()
{
    m_discordWidget.authorize();
}

void Backend::storeDiscordWidgetToken(const QString &token)
{
    m_discordWidget.storeToken(token);
}

void Backend::forgetDiscordWidgetToken()
{
    m_discordWidget.forgetToken();
}

void Backend::publishDiscordWidgetNow()
{
    m_discordWidget.publishNow();
}

void Backend::updateDiscordPresence()
{
    const auto track = currentTrack();
    if (track.isEmpty() || m_playback.state() == LinuxPlayback::State::Stopped) {
        m_discordPresence.clear();
        return;
    }
    m_discordPresence.update(
        track.value(QStringLiteral("title")).toString(),
        track.value(QStringLiteral("artistText")).toString(),
        track.value(QStringLiteral("albumTitle")).toString(),
        m_lowDataMode ? QString()
                      : track.value(QStringLiteral("coverRemoteUrl"),
                                    track.value(QStringLiteral("coverUrl"))).toString(),
        m_playback.position(),
        duration(),
        playing());
}

QString Backend::trackKey(const QVariantMap &track) const
{
    return track.value(QStringLiteral("provider")).toString()
        + QLatin1Char(':') + track.value(QStringLiteral("id")).toString();
}

void Backend::resumeListeningSession()
{
    if (!playing() || !m_playbackReady) return;
    const auto track = currentTrack();
    if (track.isEmpty()) return;
    const auto key = trackKey(track);
    if (key.isEmpty()) return;
    if (!m_listenTrackKey.isEmpty() && m_listenTrackKey != key) finishListeningSession();
    if (m_listenTrackKey.isEmpty()) {
        m_listenTrack = track;
        m_listenTrackKey = key;
        m_listenStartedAtMs = QDateTime::currentMSecsSinceEpoch();
        m_listenedMs = 0;
    }
    if (!m_listenClock.isValid()) m_listenClock.start();
}

void Backend::suspendListeningSession()
{
    if (!m_listenClock.isValid()) return;
    // The ten-second checkpoint normally bounds this delta. The cap prevents
    // a suspended machine or blocked event loop from manufacturing hours of
    // listening time when it wakes up.
    m_listenedMs += std::min<qint64>(m_listenClock.elapsed(), 15'000);
    m_listenClock.invalidate();
}

void Backend::finishListeningSession()
{
    suspendListeningSession();
    if (m_listenTrackKey.isEmpty()) return;

    const auto durationMs = m_listenTrack.value(QStringLiteral("durationMs")).toLongLong();
    const auto thresholdMs = durationMs > 0
        ? std::min<qint64>(durationMs / 2, 4 * 60 * 1000)
        : 4 * 60 * 1000;
    if (m_listenedMs >= thresholdMs && thresholdMs > 0) {
        const auto endedAtMs = QDateTime::currentMSecsSinceEpoch();
        const auto eventId = QUuid::createUuid().toString(QUuid::WithoutBraces);
        dispatchCore({
            {QStringLiteral("command"), QStringLiteral("record_listen")},
            {QStringLiteral("track"), variantTrackToCore(m_listenTrack)},
            {QStringLiteral("event"), QJsonObject{
                {QStringLiteral("eventId"), eventId},
                {QStringLiteral("deviceId"), m_deviceId},
                {QStringLiteral("mediaId"), QJsonObject{
                    {QStringLiteral("provider"), m_listenTrack.value(QStringLiteral("provider")).toString()},
                    {QStringLiteral("providerId"), m_listenTrack.value(QStringLiteral("id")).toString()},
                }},
                {QStringLiteral("startedAtMs"), m_listenStartedAtMs},
                {QStringLiteral("endedAtMs"), endedAtMs},
                {QStringLiteral("listenedMs"), m_listenedMs},
                {QStringLiteral("trackDurationMs"), durationMs > 0
                    ? QJsonValue(durationMs) : QJsonValue(QJsonValue::Null)},
            }},
        });
    }

    m_listenClock.invalidate();
    m_listenTrack.clear();
    m_listenTrackKey.clear();
    m_listenStartedAtMs = 0;
    m_listenedMs = 0;
}

void Backend::loadAccent(const QString &artworkUrl)
{
    if (m_accentMode == QStringLiteral("fixed")) {
        animateAccent(m_fixedAccent);
        return;
    }
    if (m_lowDataMode || artworkUrl.isEmpty()) {
        m_pendingArtworkUrl.clear();
        return;
    }
    m_pendingArtworkUrl = artworkUrl;
    if (m_accentReply) m_accentReply->abort();
    auto *reply = m_network.get(QNetworkRequest(QUrl(artworkUrl)));
    m_accentReply = reply;
    connect(reply, &QNetworkReply::finished, this, [this, reply, artworkUrl] {
        const auto bytes = reply->readAll();
        if (m_accentReply == reply) m_accentReply.clear();
        reply->deleteLater();
        if (artworkUrl != m_pendingArtworkUrl) return;
        QImage image;
        if (!image.loadFromData(bytes)) return;
        const auto color = paletteColor(image);
        animateAccent(color);
    });
}

void Backend::animateAccent(const QColor &color)
{
    const auto target = m_accentAnimation.endValue().value<QColor>();
    if (color == m_accent || (m_accentAnimation.state() == QAbstractAnimation::Running && color == target)) return;
    m_accentAnimation.stop();
    m_accentAnimation.setStartValue(m_accent);
    m_accentAnimation.setEndValue(color);
    m_accentAnimation.start();
}

QColor Backend::paletteColor(const QImage &source) const
{
    const auto image = source.scaled(96, 96, Qt::IgnoreAspectRatio, Qt::SmoothTransformation).convertToFormat(QImage::Format_RGB32);
    struct Bucket { double red = 0; double green = 0; double blue = 0; int count = 0; };
    struct HueBin { double red = 0; double green = 0; double blue = 0; double weight = 0; };
    QHash<int, Bucket> buckets;
    std::array<HueBin, 24> hueBins{};
    int usefulPixelCount = 0;
    int chromaticPixelCount = 0;

    for (int y = 0; y < image.height(); ++y) {
        for (int x = 0; x < image.width(); ++x) {
            const QColor color(image.pixel(x, y));
            const int maximum = std::max({color.red(), color.green(), color.blue()});
            const int minimum = std::min({color.red(), color.green(), color.blue()});
            if (maximum <= 8) continue;
            ++usefulPixelCount;

            const int chroma = maximum - minimum;
            if (maximum >= 40 && chroma >= 16 && color.hsvHueF() >= 0) {
                const auto binIndex = std::min(23, static_cast<int>(std::floor(color.hsvHueF() * 24.0)));
                auto &bin = hueBins.at(binIndex);
                bin.red += color.red() * chroma;
                bin.green += color.green() * chroma;
                bin.blue += color.blue() * chroma;
                bin.weight += chroma;
                ++chromaticPixelCount;
            }

            const int key = (qRound(color.red() / 24.0) << 16)
                | (qRound(color.green() / 24.0) << 8)
                | qRound(color.blue() / 24.0);
            auto bucket = buckets.value(key);
            bucket.red += color.red();
            bucket.green += color.green();
            bucket.blue += color.blue();
            bucket.count++;
            buckets.insert(key, bucket);
        }
    }

    if (buckets.isEmpty()) return m_accent;
    QColor sampled = m_accent;
    int bestCount = -1;
    for (const auto &bucket : buckets) {
        if (bucket.count > bestCount) {
            bestCount = bucket.count;
            sampled = QColor(qRound(bucket.red / bucket.count), qRound(bucket.green / bucket.count), qRound(bucket.blue / bucket.count));
        }
    }

    if (chromaticPixelCount >= std::max(12, qRound(usefulPixelCount * 0.01))) {
        int bestStart = 0;
        double bestWeight = -1;
        for (int start = 0; start < 24; ++start) {
            const auto weight = hueBins.at(start).weight
                + hueBins.at((start + 1) % 24).weight
                + hueBins.at((start + 2) % 24).weight;
            if (weight > bestWeight) {
                bestWeight = weight;
                bestStart = start;
            }
        }

        HueBin cluster;
        for (int offset = 0; offset < 3; ++offset) {
            const auto &bin = hueBins.at((bestStart + offset) % 24);
            cluster.red += bin.red;
            cluster.green += bin.green;
            cluster.blue += bin.blue;
            cluster.weight += bin.weight;
        }
        if (cluster.weight > 0) {
            sampled = QColor(
                qRound(cluster.red / cluster.weight),
                qRound(cluster.green / cluster.weight),
                qRound(cluster.blue / cluster.weight));
        }
    }

    return normalizeAlbumAccent(sampled);
}

QVariantMap Backend::jsonTrackToVariant(const QJsonObject &track)
{
    QStringList artists;
    for (const auto &artist : track.value(QStringLiteral("artists")).toArray()) artists.append(artist.toString());
    QVariantList artistCredits;
    for (const auto &credit : track.value(QStringLiteral("artistCredits")).toArray()) {
        artistCredits.append(credit.toObject().toVariantMap());
    }
    const auto uploader = track.value(QStringLiteral("uploader")).toObject();
    return {
        {QStringLiteral("provider"), track.value(QStringLiteral("provider")).toString(QStringLiteral("tidal"))},
        {QStringLiteral("id"), track.value(QStringLiteral("id")).toString()},
        {QStringLiteral("title"), track.value(QStringLiteral("title")).toString()},
        {QStringLiteral("version"), track.value(QStringLiteral("version")).toString()},
        {QStringLiteral("artists"), artists},
        {QStringLiteral("artistCredits"), artistCredits},
        {QStringLiteral("artistText"), artists.join(QStringLiteral(", "))},
        {QStringLiteral("uploader"), uploader.toVariantMap()},
        {QStringLiteral("albumId"), track.value(QStringLiteral("albumId")).toString()},
        {QStringLiteral("albumTitle"), track.value(QStringLiteral("albumTitle")).toString()},
        {QStringLiteral("durationMs"), track.value(QStringLiteral("durationMs")).toInteger()},
        {QStringLiteral("isrc"), track.value(QStringLiteral("isrc")).toString()},
        {QStringLiteral("coverUrl"), track.value(QStringLiteral("coverUrl")).toString()},
    };
}

QVariantMap Backend::jsonAlbumToVariant(const QJsonObject &album)
{
    QStringList artists;
    for (const auto &artist : album.value(QStringLiteral("artists")).toArray()) artists.append(artist.toString());
    QVariantList artistCredits;
    for (const auto &credit : album.value(QStringLiteral("artistCredits")).toArray()) {
        artistCredits.append(credit.toObject().toVariantMap());
    }
    QStringList mediaTags;
    for (const auto &tag : album.value(QStringLiteral("mediaTags")).toArray()) mediaTags.append(tag.toString());
    return {
        {QStringLiteral("provider"), album.value(QStringLiteral("provider")).toString(QStringLiteral("tidal"))},
        {QStringLiteral("id"), album.value(QStringLiteral("id")).toString()},
        {QStringLiteral("title"), album.value(QStringLiteral("title")).toString()},
        {QStringLiteral("version"), album.value(QStringLiteral("version")).toString()},
        {QStringLiteral("artists"), artists},
        {QStringLiteral("artistCredits"), artistCredits},
        {QStringLiteral("artistText"), artists.join(QStringLiteral(", "))},
        {QStringLiteral("coverUrl"), album.value(QStringLiteral("coverUrl")).toString()},
        {QStringLiteral("releaseDate"), album.value(QStringLiteral("releaseDate")).toString()},
        {QStringLiteral("durationMs"), album.value(QStringLiteral("durationMs")).toInteger()},
        {QStringLiteral("numberOfTracks"), album.value(QStringLiteral("numberOfTracks")).toInteger()},
        {QStringLiteral("albumType"), album.value(QStringLiteral("albumType")).toString()},
        {QStringLiteral("explicit"), album.value(QStringLiteral("explicit")).toBool()},
        {QStringLiteral("mediaTags"), mediaTags},
    };
}

QVariantMap Backend::jsonArtistToVariant(const QJsonObject &artist)
{
    return {
        {QStringLiteral("provider"), artist.value(QStringLiteral("provider")).toString(QStringLiteral("tidal"))},
        {QStringLiteral("id"), artist.value(QStringLiteral("id")).toString()},
        {QStringLiteral("name"), artist.value(QStringLiteral("name")).toString()},
        {QStringLiteral("pictureUrl"), artist.value(QStringLiteral("pictureUrl")).toString()},
        {QStringLiteral("isChannel"), artist.value(QStringLiteral("isChannel")).toBool()},
    };
}

QVariantMap Backend::jsonPlaylistToVariant(const QJsonObject &playlist)
{
    return {
        {QStringLiteral("provider"), playlist.value(QStringLiteral("provider")).toString(QStringLiteral("tidal"))},
        {QStringLiteral("id"), playlist.value(QStringLiteral("id")).toString()},
        {QStringLiteral("name"), playlist.value(QStringLiteral("name")).toString()},
        {QStringLiteral("description"), playlist.value(QStringLiteral("description")).toString()},
        {QStringLiteral("coverUrl"), playlist.value(QStringLiteral("coverUrl")).toString()},
        {QStringLiteral("durationMs"), playlist.value(QStringLiteral("durationMs")).toInteger()},
        {QStringLiteral("numberOfItems"), playlist.value(QStringLiteral("numberOfItems")).toInteger()},
        {QStringLiteral("playlistType"), playlist.value(QStringLiteral("playlistType")).toString()},
        {QStringLiteral("createdAt"), playlist.value(QStringLiteral("createdAt")).toString()},
        {QStringLiteral("lastModifiedAt"), playlist.value(QStringLiteral("lastModifiedAt")).toString()},
    };
}

QVariantMap Backend::jsonCatalogPageToVariant(const QJsonObject &page)
{
    const auto pageProvider = page.value(QStringLiteral("provider")).toString(QStringLiteral("tidal"));
    QVariantMap result{{QStringLiteral("kind"), page.value(QStringLiteral("kind")).toString()},
                       {QStringLiteral("provider"), page.value(QStringLiteral("provider")).toString(QStringLiteral("tidal"))}};
    const auto mapTracks = [&page, &pageProvider](const QString &key) {
        QVariantList tracks;
        for (const auto &value : page.value(key).toArray()) {
            auto object = value.toObject();
            if (!object.contains(QStringLiteral("provider"))) object.insert(QStringLiteral("provider"), pageProvider);
            tracks.append(jsonTrackToVariant(object));
        }
        return tracks;
    };
    const auto mapAlbums = [&page, &pageProvider](const QString &key) {
        QVariantList albums;
        for (const auto &value : page.value(key).toArray()) {
            auto object = value.toObject();
            if (!object.contains(QStringLiteral("provider"))) object.insert(QStringLiteral("provider"), pageProvider);
            albums.append(jsonAlbumToVariant(object));
        }
        return albums;
    };
    const auto kind = result.value(QStringLiteral("kind")).toString();
    if (kind == QStringLiteral("track")) {
        auto document = page.value(QStringLiteral("track")).toObject();
        if (!document.contains(QStringLiteral("provider"))) document.insert(QStringLiteral("provider"), pageProvider);
        const auto track = jsonTrackToVariant(document);
        result.insert(QStringLiteral("track"), track);
        result.insert(QStringLiteral("resourceId"), track.value(QStringLiteral("id")));
        result.insert(QStringLiteral("relatedTracks"), mapTracks(QStringLiteral("relatedTracks")));
    } else if (kind == QStringLiteral("album")) {
        auto document = page.value(QStringLiteral("album")).toObject();
        if (!document.contains(QStringLiteral("provider"))) document.insert(QStringLiteral("provider"), pageProvider);
        const auto album = jsonAlbumToVariant(document);
        result.insert(QStringLiteral("album"), album);
        result.insert(QStringLiteral("resourceId"), album.value(QStringLiteral("id")));
        result.insert(QStringLiteral("tracks"), mapTracks(QStringLiteral("tracks")));
        result.insert(QStringLiteral("trackCursor"), page.value(QStringLiteral("trackCursor")).toString());
    } else if (kind == QStringLiteral("artist")) {
        auto document = page.value(QStringLiteral("artist")).toObject();
        if (!document.contains(QStringLiteral("provider"))) document.insert(QStringLiteral("provider"), pageProvider);
        const auto artist = jsonArtistToVariant(document);
        result.insert(QStringLiteral("artist"), artist);
        result.insert(QStringLiteral("resourceId"), artist.value(QStringLiteral("id")));
        result.insert(QStringLiteral("topTracks"), mapTracks(QStringLiteral("topTracks")));
        result.insert(QStringLiteral("albums"), mapAlbums(QStringLiteral("albums")));
        result.insert(QStringLiteral("trackCursor"), page.value(QStringLiteral("trackCursor")).toString());
        result.insert(QStringLiteral("albumCursor"), page.value(QStringLiteral("albumCursor")).toString());
    } else if (kind == QStringLiteral("playlist")) {
        const auto playlist = jsonPlaylistToVariant(page.value(QStringLiteral("playlist")).toObject());
        result.insert(QStringLiteral("playlist"), playlist);
        result.insert(QStringLiteral("resourceId"), playlist.value(QStringLiteral("id")));
        result.insert(QStringLiteral("tracks"), mapTracks(QStringLiteral("tracks")));
        result.insert(QStringLiteral("trackCursor"), page.value(QStringLiteral("trackCursor")).toString());
    }
    return result;
}

void Backend::setProviderReady(bool ready) { if (m_providerReady != ready) { m_providerReady = ready; emit providerReadyChanged(); } }
void Backend::setLinked(bool linked) { if (m_linked != linked) { m_linked = linked; emit linkedChanged(); } }
void Backend::setBusy(bool busy) { if (m_busy != busy) { m_busy = busy; emit busyChanged(); } }
void Backend::setStatus(const QString &message) { if (m_statusMessage != message) { m_statusMessage = message; emit statusMessageChanged(); } }

void Backend::notify(const QString &message, const QString &kind)
{
    setStatus(message);
    emit toastRequested(message, kind);
}
void Backend::setEntitlementWarning(bool visible, const QString &message)
{
    const auto nextMessage = visible ? message : QString{};
    if (m_entitlementWarningVisible == visible && m_entitlementMessage == nextMessage) return;
    m_entitlementWarningVisible = visible;
    m_entitlementMessage = nextMessage;
    emit entitlementChanged();
}
