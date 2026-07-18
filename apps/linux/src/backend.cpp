#include "backend.h"

#include <QCoreApplication>
#include <QDesktopServices>
#include <QDBusObjectPath>
#include <QFileInfo>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QProcessEnvironment>
#include <QStandardPaths>
#include <QUrl>
#include <algorithm>
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
}

Backend::Backend(QObject *parent)
    : QObject(parent)
{
    m_audioOutput.setVolume(0.78);
    m_player.setAudioOutput(&m_audioOutput);

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

    connect(&m_player, &QMediaPlayer::playbackStateChanged, this, [this] { emit playbackChanged(); });
    connect(&m_player, &QMediaPlayer::positionChanged, this, [this](qint64 value) {
        Q_UNUSED(value)
        emit positionChanged();
    });
    connect(&m_player, &QMediaPlayer::durationChanged, this, [this] { emit durationChanged(); });
    connect(&m_audioOutput, &QAudioOutput::volumeChanged, this, &Backend::volumeChanged);
    connect(&m_player, &QMediaPlayer::errorOccurred, this,
            [this](QMediaPlayer::Error, const QString &error) {
        if (!error.isEmpty()) setStatus(QStringLiteral("Playback error: %1").arg(error));
    });
    connect(&m_player, &QMediaPlayer::mediaStatusChanged, this, [this](QMediaPlayer::MediaStatus status) {
        if (status == QMediaPlayer::LoadingMedia) setStatus(QStringLiteral("Opening lossless stream…"));
        if (status == QMediaPlayer::BufferedMedia || status == QMediaPlayer::LoadedMedia) {
            setBusy(false);
            setStatus(QStringLiteral("Playing from TIDAL"));
        }
        if (status == QMediaPlayer::EndOfMedia) next();
    });

    startProviderHost();
}

Backend::~Backend()
{
    if (m_provider.state() != QProcess::NotRunning) {
        m_provider.closeWriteChannel();
        m_provider.terminate();
        if (!m_provider.waitForFinished(1200)) m_provider.kill();
    }
}

QVariantMap Backend::currentTrack() const
{
    return m_currentIndex >= 0 && m_currentIndex < m_queue.size()
        ? m_queue.at(m_currentIndex).toMap()
        : QVariantMap{};
}

bool Backend::playing() const
{
    return m_player.playbackState() == QMediaPlayer::PlayingState;
}

QString Backend::playbackStatus() const
{
    switch (m_player.playbackState()) {
    case QMediaPlayer::PlayingState: return QStringLiteral("Playing");
    case QMediaPlayer::PausedState: return QStringLiteral("Paused");
    case QMediaPlayer::StoppedState: return QStringLiteral("Stopped");
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
    metadata.insert(QStringLiteral("mpris:artUrl"), track.value(QStringLiteral("coverUrl")));
    metadata.insert(QStringLiteral("mpris:length"), track.value(QStringLiteral("durationMs")).toLongLong() * 1000);
    return metadata;
}

bool Backend::canGoNext() const { return m_currentIndex >= 0 && m_currentIndex + 1 < m_queue.size(); }
bool Backend::canGoPrevious() const { return m_currentIndex > 0 || (m_currentIndex == 0 && m_player.position() > 3000); }

void Backend::startProviderHost()
{
    const auto bun = qEnvironmentVariable("COLORFUL_BUN", QStandardPaths::findExecutable(QStringLiteral("bun")));
    if (bun.isEmpty()) {
        setStatus(QStringLiteral("Bun was not found. Install Bun or set COLORFUL_BUN."));
        return;
    }
    const auto sourceRoot = QString::fromUtf8(COLORFUL_SOURCE_DIR);
    const auto host = sourceRoot + QStringLiteral("/packages/provider-host/src/main.ts");
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
        if (!data.value(QStringLiteral("browseConfigured")).toBool()) {
            setStatus(QStringLiteral("TIDAL browse credentials are missing. Launch with scripts/run-linux.sh."));
        } else if (!data.value(QStringLiteral("deviceConfigured")).toBool()) {
            setStatus(QStringLiteral("TIDAL device-login credentials are missing."));
        } else {
            setStatus(m_linked ? QStringLiteral("TIDAL account restored") : QStringLiteral("Connect TIDAL, then search for something good"));
        }
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
    } else if (event == QStringLiteral("auth.failed")) {
        m_authPending = false;
        emit authPendingChanged();
        setStatus(message.value(QStringLiteral("error")).toString());
    } else if (event == QStringLiteral("warning")) {
        setStatus(message.value(QStringLiteral("error")).toString());
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
        m_authPending = true;
        emit authDetailsChanged();
        emit authPendingChanged();
        setStatus(QStringLiteral("Approve Colorful in TIDAL"));
    });
}

void Backend::openVerificationUrl()
{
    if (!m_verificationUrl.isEmpty()) QDesktopServices::openUrl(QUrl(m_verificationUrl));
}

void Backend::unlink()
{
    request(QStringLiteral("auth.unlink"), {}, [this](const QJsonObject &message) {
        if (!message.value(QStringLiteral("ok")).toBool()) {
            setStatus(message.value(QStringLiteral("error")).toString());
            return;
        }
        setLinked(false);
        stop();
        setStatus(QStringLiteral("TIDAL account disconnected"));
    });
}

void Backend::search(const QString &query)
{
    if (query.trimmed().isEmpty()) return;
    setBusy(true);
    setStatus(QStringLiteral("Searching TIDAL…"));
    request(QStringLiteral("search"), {{QStringLiteral("query"), query.trimmed()}}, [this](const QJsonObject &message) {
        setBusy(false);
        if (!message.value(QStringLiteral("ok")).toBool()) {
            setStatus(message.value(QStringLiteral("error")).toString());
            return;
        }
        m_searchResults.clear();
        for (const auto &value : message.value(QStringLiteral("data")).toObject().value(QStringLiteral("tracks")).toArray()) {
            m_searchResults.append(jsonTrackToVariant(value.toObject()));
        }
        emit searchResultsChanged();
        setStatus(m_searchResults.isEmpty() ? QStringLiteral("No tracks found")
                                             : QStringLiteral("Found %1 tracks").arg(m_searchResults.size()));
    });
}

void Backend::enqueueSearchResult(int index)
{
    if (index < 0 || index >= m_searchResults.size()) return;
    m_queue.append(m_searchResults.at(index));
    emit queueChanged();
    setStatus(QStringLiteral("Added %1 to the queue")
                  .arg(m_searchResults.at(index).toMap().value(QStringLiteral("title")).toString()));
}

void Backend::playSearchResult(int index)
{
    if (index < 0 || index >= m_searchResults.size()) return;
    m_queue.append(m_searchResults.at(index));
    emit queueChanged();
    playTrackAt(m_queue.size() - 1);
}

void Backend::playQueueIndex(int index) { playTrackAt(index); }

void Backend::removeQueueIndex(int index)
{
    if (index < 0 || index >= m_queue.size()) return;
    const bool removingCurrent = index == m_currentIndex;
    m_queue.removeAt(index);
    if (index < m_currentIndex) --m_currentIndex;
    else if (removingCurrent) {
        m_player.stop();
        if (m_queue.isEmpty()) m_currentIndex = -1;
        else {
            m_currentIndex = std::min(index, static_cast<int>(m_queue.size() - 1));
            resolveCurrentSource();
        }
        emit currentTrackChanged();
    }
    emit queueChanged();
}

void Backend::playTrackAt(int index)
{
    if (index < 0 || index >= m_queue.size()) return;
    m_currentIndex = index;
    emit currentTrackChanged();
    emit queueChanged();
    resolveCurrentSource();
}

void Backend::resolveCurrentSource()
{
    const auto track = currentTrack();
    if (track.isEmpty()) return;
    const auto requestedTrackId = track.value(QStringLiteral("id")).toString();
    setBusy(true);
    setStatus(QStringLiteral("Getting playback source for %1…").arg(track.value(QStringLiteral("title")).toString()));
    loadAccent(track.value(QStringLiteral("coverUrl")).toString());
    request(QStringLiteral("source"), {{QStringLiteral("trackId"), requestedTrackId}},
            [this, requestedTrackId](const QJsonObject &message) {
        if (currentTrack().value(QStringLiteral("id")).toString() != requestedTrackId) return;
        if (!message.value(QStringLiteral("ok")).toBool()) {
            setBusy(false);
            setStatus(message.value(QStringLiteral("error")).toString());
            return;
        }
        const auto source = message.value(QStringLiteral("data")).toObject();
        const auto uri = source.value(QStringLiteral("uri")).toString();
        if (uri.isEmpty()) {
            setBusy(false);
            setStatus(QStringLiteral("TIDAL returned an empty playback source"));
            return;
        }
        m_player.setSource(QUrl(uri));
        m_player.play();
    });
}

void Backend::togglePlay() { playing() ? pause() : play(); }
void Backend::play() { if (m_currentIndex < 0 && !m_queue.isEmpty()) playTrackAt(0); else m_player.play(); }
void Backend::pause() { m_player.pause(); }
void Backend::stop() { m_player.stop(); }

void Backend::next()
{
    if (canGoNext()) playTrackAt(m_currentIndex + 1);
    else stop();
}

void Backend::previous()
{
    if (m_player.position() > 3000 || m_currentIndex <= 0) seek(0);
    else playTrackAt(m_currentIndex - 1);
}

void Backend::seek(qint64 positionMs)
{
    const auto target = std::clamp<qint64>(positionMs, 0, std::max<qint64>(0, m_player.duration()));
    m_player.setPosition(target);
    emit seeked(target);
}

void Backend::seekBy(qint64 offsetMs) { seek(m_player.position() + offsetMs); }

void Backend::setVolume(double volume)
{
    m_audioOutput.setVolume(std::clamp(volume, 0.0, 1.0));
}

void Backend::loadAccent(const QString &artworkUrl)
{
    if (artworkUrl.isEmpty()) return;
    m_pendingArtworkUrl = artworkUrl;
    auto *reply = m_network.get(QNetworkRequest(QUrl(artworkUrl)));
    connect(reply, &QNetworkReply::finished, this, [this, reply, artworkUrl] {
        const auto bytes = reply->readAll();
        reply->deleteLater();
        if (artworkUrl != m_pendingArtworkUrl) return;
        QImage image;
        if (!image.loadFromData(bytes)) return;
        const auto color = paletteColor(image);
        if (color != m_accent) {
            m_accent = color;
            emit accentChanged();
        }
    });
}

QColor Backend::paletteColor(const QImage &source) const
{
    const auto image = source.scaled(48, 48, Qt::KeepAspectRatio, Qt::SmoothTransformation).convertToFormat(QImage::Format_RGB32);
    struct Bucket { double red = 0; double green = 0; double blue = 0; double score = 0; int count = 0; };
    QHash<int, Bucket> buckets;
    for (int y = 0; y < image.height(); ++y) {
        for (int x = 0; x < image.width(); ++x) {
            const QColor color(image.pixel(x, y));
            const double lightness = color.lightnessF();
            const double saturation = color.hsvSaturationF();
            const double edge = std::min({x + 1.0, y + 1.0, image.width() - x + 0.0, image.height() - y + 0.0});
            const double centerWeight = 0.6 + std::min(1.0, edge / 10.0) * 0.4;
            const double lightnessWeight = lightness < 0.06 || lightness > 0.96 ? 0.05 : 1.0;
            const int key = (color.red() >> 4) << 8 | (color.green() >> 4) << 4 | (color.blue() >> 4);
            auto bucket = buckets.value(key);
            bucket.red += color.red();
            bucket.green += color.green();
            bucket.blue += color.blue();
            bucket.count++;
            bucket.score += centerWeight * lightnessWeight * (0.15 + saturation * 2.8);
            buckets.insert(key, bucket);
        }
    }
    QColor best = m_accent;
    double bestScore = -1;
    for (const auto &bucket : buckets) {
        if (bucket.score > bestScore && bucket.count > 0) {
            bestScore = bucket.score;
            best = QColor(qRound(bucket.red / bucket.count), qRound(bucket.green / bucket.count), qRound(bucket.blue / bucket.count));
        }
    }
    if (best.lightnessF() < 0.22) best = best.lighter(165);
    if (best.lightnessF() > 0.78) best = best.darker(125);
    return best;
}

QVariantMap Backend::jsonTrackToVariant(const QJsonObject &track)
{
    QStringList artists;
    for (const auto &artist : track.value(QStringLiteral("artists")).toArray()) artists.append(artist.toString());
    return {
        {QStringLiteral("id"), track.value(QStringLiteral("id")).toString()},
        {QStringLiteral("title"), track.value(QStringLiteral("title")).toString()},
        {QStringLiteral("artists"), artists},
        {QStringLiteral("artistText"), artists.join(QStringLiteral(", "))},
        {QStringLiteral("albumId"), track.value(QStringLiteral("albumId")).toString()},
        {QStringLiteral("albumTitle"), track.value(QStringLiteral("albumTitle")).toString()},
        {QStringLiteral("durationMs"), track.value(QStringLiteral("durationMs")).toInteger()},
        {QStringLiteral("isrc"), track.value(QStringLiteral("isrc")).toString()},
        {QStringLiteral("coverUrl"), track.value(QStringLiteral("coverUrl")).toString()},
    };
}

void Backend::setProviderReady(bool ready) { if (m_providerReady != ready) { m_providerReady = ready; emit providerReadyChanged(); } }
void Backend::setLinked(bool linked) { if (m_linked != linked) { m_linked = linked; emit linkedChanged(); } }
void Backend::setBusy(bool busy) { if (m_busy != busy) { m_busy = busy; emit busyChanged(); } }
void Backend::setStatus(const QString &message) { if (m_statusMessage != message) { m_statusMessage = message; emit statusMessageChanged(); } }
