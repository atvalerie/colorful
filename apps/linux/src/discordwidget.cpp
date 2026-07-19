#include "discordwidget.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDesktopServices>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QSettings>
#include <QStandardPaths>
#include <QUrlQuery>
#include <algorithm>
#include <limits>

namespace {
constexpr auto defaultApplicationId = "1528095256820842606";
constexpr auto defaultRedirectUri = "http://127.0.0.1/callback";
constexpr qint64 automaticPublishIntervalMs = 15 * 60 * 1000;
constexpr qint64 manualPublishIntervalMs = 60 * 1000;

QStringList secretAttributes(const QString &applicationId)
{
    return {
        QStringLiteral("application"), QStringLiteral("colorful"),
        QStringLiteral("service"), QStringLiteral("discord-statistics-widget"),
        QStringLiteral("discord-application"), applicationId,
    };
}

QVariantMap firstMap(const QVariantMap &map, const QString &key)
{
    const auto values = map.value(key).toList();
    return values.isEmpty() ? QVariantMap{} : values.constFirst().toMap();
}

QString artistNames(const QVariantList &artists)
{
    QStringList names;
    for (const auto &value : artists) {
        const auto name = value.toMap().value(QStringLiteral("name")).toString().trimmed();
        if (!name.isEmpty()) names.append(name);
    }
    return names.join(QStringLiteral(", "));
}

QString artworkUrl(const QVariantMap &owner)
{
    return owner.value(QStringLiteral("artwork")).toMap().value(QStringLiteral("url")).toString();
}

QString compactDuration(qint64 milliseconds)
{
    const auto minutes = std::max<qint64>(0, milliseconds) / 60'000;
    const auto hours = minutes / 60;
    const auto remainingMinutes = minutes % 60;
    return hours > 0
        ? QStringLiteral("%1h %2m").arg(hours).arg(remainingMinutes)
        : QStringLiteral("%1m").arg(minutes);
}

QJsonObject textField(const QString &name, const QString &value)
{
    return {{QStringLiteral("type"), 1}, {QStringLiteral("name"), name}, {QStringLiteral("value"), value}};
}

QJsonObject numberField(const QString &name, qint64 value)
{
    return {{QStringLiteral("type"), 2}, {QStringLiteral("name"), name}, {QStringLiteral("value"), value}};
}

void appendImage(QJsonArray &fields, const QString &name, const QString &url)
{
    if (!url.startsWith(QStringLiteral("https://"), Qt::CaseInsensitive)) return;
    fields.append(QJsonObject{
        {QStringLiteral("type"), 3},
        {QStringLiteral("name"), name},
        {QStringLiteral("value"), QJsonObject{{QStringLiteral("url"), url}}},
    });
}
}

DiscordWidgetExporter::DiscordWidgetExporter(QObject *parent)
    : QObject(parent)
{
    QSettings settings;
    m_enabled = settings.value(QStringLiteral("discordWidget/enabled"), false).toBool();
    m_applicationId = settings.value(QStringLiteral("discord/applicationId"),
                                     QString::fromLatin1(defaultApplicationId)).toString();
    m_redirectUri = settings.value(QStringLiteral("discord/oauthRedirectUri"),
                                   QString::fromLatin1(defaultRedirectUri)).toString();
    m_detectedUserId = settings.value(QStringLiteral("discordWidget/userId")).toString();
    m_userIdOverride = settings.value(QStringLiteral("discordWidget/userIdOverride")).toString();
    m_userId = m_userIdOverride.isEmpty() ? m_detectedUserId : m_userIdOverride;
    m_publishTimer.setSingleShot(true);
    connect(&m_publishTimer, &QTimer::timeout, this, [this] { publish(m_manualPublish); });
    loadToken();
}

void DiscordWidgetExporter::setRedirectUri(const QString &redirectUri)
{
    const auto trimmed = redirectUri.trimmed();
    const QUrl parsed(trimmed);
    if (!parsed.isValid() || parsed.scheme().isEmpty()) {
        setStatus(QStringLiteral("Enter a valid Discord OAuth2 redirect URI"));
        return;
    }
    if (m_redirectUri == trimmed) return;
    m_redirectUri = trimmed;
    QSettings().setValue(QStringLiteral("discord/oauthRedirectUri"), m_redirectUri);
    setStatus(QStringLiteral("OAuth2 redirect saved; register the exact URI in Discord"));
    emit stateChanged();
}

void DiscordWidgetExporter::setStats(const QVariantMap &stats)
{
    if (m_stats == stats) return;
    m_stats = stats;
    schedulePublish();
}

void DiscordWidgetExporter::setEnabled(bool enabled)
{
    if (m_enabled == enabled) return;
    m_enabled = enabled;
    QSettings().setValue(QStringLiteral("discordWidget/enabled"), enabled);
    if (!enabled) {
        m_publishTimer.stop();
        setStatus(configured() ? QStringLiteral("Discord widget updates are off")
                               : QStringLiteral("Discord widget is not configured"));
    } else if (!configured()) {
        setStatus(QStringLiteral("Store the widget bot token to enable updates"));
    } else if (m_userId.isEmpty()) {
        setStatus(QStringLiteral("Open Discord once so colorful can identify the widget owner"));
    } else {
        schedulePublish();
    }
    emit stateChanged();
}

void DiscordWidgetExporter::setApplicationId(const QString &applicationId)
{
    const auto trimmed = applicationId.trimmed();
    if (trimmed.size() < 15 || trimmed.size() > 22
        || std::any_of(trimmed.cbegin(), trimmed.cend(), [](QChar character) { return !character.isDigit(); })) {
        setStatus(QStringLiteral("Discord Application ID must be a numeric snowflake"));
        return;
    }
    if (m_applicationId == trimmed) return;
    m_applicationId = trimmed;
    m_token.fill('\0');
    m_token.clear();
    m_publishTimer.stop();
    QSettings settings;
    settings.setValue(QStringLiteral("discord/applicationId"), m_applicationId);
    settings.remove(QStringLiteral("discordWidget/lastPayloadHash"));
    settings.remove(QStringLiteral("discordWidget/lastPublishedAtMs"));
    setStatus(QStringLiteral("Discord application changed; loading its credential…"));
    emit stateChanged();
    loadToken();
}

void DiscordWidgetExporter::setUserId(const QString &userId)
{
    const auto trimmed = userId.trimmed();
    if (trimmed.size() < 15 || trimmed.size() > 22
        || std::any_of(trimmed.cbegin(), trimmed.cend(), [](QChar character) { return !character.isDigit(); })) {
        setStatus(QStringLiteral("Discord User ID must be a numeric snowflake"));
        return;
    }
    if (m_detectedUserId == trimmed) return;
    m_detectedUserId = trimmed;
    QSettings settings;
    settings.setValue(QStringLiteral("discordWidget/userId"), m_detectedUserId);
    if (!m_userIdOverride.isEmpty()) return;
    m_userId = m_detectedUserId;
    settings.remove(QStringLiteral("discordWidget/lastPayloadHash"));
    settings.remove(QStringLiteral("discordWidget/lastPublishedAtMs"));
    setStatus(QStringLiteral("Discord widget owner detected through IPC"));
    emit stateChanged();
    schedulePublish();
}

void DiscordWidgetExporter::setUserIdOverride(const QString &userId)
{
    const auto trimmed = userId.trimmed();
    if (!trimmed.isEmpty()
        && (trimmed.size() < 15 || trimmed.size() > 22
            || std::any_of(trimmed.cbegin(), trimmed.cend(), [](QChar character) { return !character.isDigit(); }))) {
        setStatus(QStringLiteral("Discord User ID must be a numeric snowflake"));
        return;
    }
    if (m_userIdOverride == trimmed) return;
    m_userIdOverride = trimmed;
    m_userId = m_userIdOverride.isEmpty() ? m_detectedUserId : m_userIdOverride;
    QSettings settings;
    if (m_userIdOverride.isEmpty()) settings.remove(QStringLiteral("discordWidget/userIdOverride"));
    else settings.setValue(QStringLiteral("discordWidget/userIdOverride"), m_userIdOverride);
    settings.remove(QStringLiteral("discordWidget/lastPayloadHash"));
    settings.remove(QStringLiteral("discordWidget/lastPublishedAtMs"));
    setStatus(m_userIdOverride.isEmpty()
        ? QStringLiteral("Using the Discord owner detected through IPC")
        : QStringLiteral("Using the manually selected Discord widget owner"));
    emit stateChanged();
    schedulePublish();
}

void DiscordWidgetExporter::authorize()
{
    QUrl url(QStringLiteral("https://discord.com/oauth2/authorize"));
    QUrlQuery query;
    query.addQueryItem(QStringLiteral("client_id"), m_applicationId);
    query.addQueryItem(QStringLiteral("response_type"), QStringLiteral("token"));
    query.addQueryItem(QStringLiteral("scope"), QStringLiteral("openid sdk.social_layer"));
    query.addQueryItem(QStringLiteral("prompt"), QStringLiteral("consent"));
    query.addQueryItem(QStringLiteral("redirect_uri"), m_redirectUri);
    url.setQuery(query);
    if (QDesktopServices::openUrl(url)) {
        setStatus(QStringLiteral("Authorize colorful in Discord, then publish again"));
    } else {
        setStatus(QStringLiteral("Could not open the Discord authorization page"));
    }
}

void DiscordWidgetExporter::storeToken(const QString &token)
{
    const auto trimmed = token.trimmed().toUtf8();
    if (trimmed.isEmpty()) {
        setStatus(QStringLiteral("Enter a bot token first"));
        return;
    }
    const auto executable = QStandardPaths::findExecutable(QStringLiteral("secret-tool"));
    if (executable.isEmpty()) {
        setStatus(QStringLiteral("secret-tool is required to store the Discord token"));
        return;
    }

    setBusy(true);
    setStatus(QStringLiteral("Saving Discord token to Secret Service…"));
    const auto requestedApplicationId = m_applicationId;
    auto *process = new QProcess(this);
    auto arguments = QStringList{QStringLiteral("store"), QStringLiteral("--label=colorful Discord statistics widget")};
    arguments.append(secretAttributes(m_applicationId));
    connect(process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
            [this, process, trimmed, requestedApplicationId](int exitCode, QProcess::ExitStatus status) {
        process->deleteLater();
        setBusy(false);
        if (requestedApplicationId != m_applicationId) return;
        if (status != QProcess::NormalExit || exitCode != 0) {
            setStatus(QStringLiteral("Secret Service refused the Discord token"));
            return;
        }
        m_token = trimmed;
        m_enabled = true;
        QSettings().setValue(QStringLiteral("discordWidget/enabled"), true);
        setStatus(m_userId.isEmpty()
            ? QStringLiteral("Open Discord once so colorful can identify the widget owner")
            : QStringLiteral("Discord widget is ready to publish"));
        emit stateChanged();
        schedulePublish(true);
    });
    process->start(executable, arguments);
    if (!process->waitForStarted(1500)) {
        process->deleteLater();
        setBusy(false);
        setStatus(QStringLiteral("Could not open Secret Service"));
        return;
    }
    process->write(trimmed);
    process->write("\n");
    process->closeWriteChannel();
}

void DiscordWidgetExporter::forgetToken()
{
    m_token.fill('\0');
    m_token.clear();
    m_enabled = false;
    m_publishTimer.stop();
    QSettings().setValue(QStringLiteral("discordWidget/enabled"), false);
    emit stateChanged();

    const auto executable = QStandardPaths::findExecutable(QStringLiteral("secret-tool"));
    if (executable.isEmpty()) {
        setStatus(QStringLiteral("Discord token removed from colorful's memory"));
        return;
    }
    const auto requestedApplicationId = m_applicationId;
    auto *process = new QProcess(this);
    auto arguments = QStringList{QStringLiteral("clear")};
    arguments.append(secretAttributes(m_applicationId));
    connect(process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
            [this, process, requestedApplicationId](int, QProcess::ExitStatus) {
        process->deleteLater();
        if (requestedApplicationId != m_applicationId) return;
        setStatus(QStringLiteral("Discord widget token removed"));
    });
    process->start(executable, arguments);
}

void DiscordWidgetExporter::publishNow()
{
    schedulePublish(true);
}

void DiscordWidgetExporter::loadToken()
{
    const auto executable = QStandardPaths::findExecutable(QStringLiteral("secret-tool"));
    if (executable.isEmpty()) {
        setStatus(QStringLiteral("secret-tool is required for Discord widget updates"));
        return;
    }
    const auto requestedApplicationId = m_applicationId;
    auto *process = new QProcess(this);
    auto arguments = QStringList{QStringLiteral("lookup")};
    arguments.append(secretAttributes(m_applicationId));
    connect(process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
            [this, process, requestedApplicationId](int exitCode, QProcess::ExitStatus status) {
        const auto token = process->readAllStandardOutput().trimmed();
        process->deleteLater();
        if (requestedApplicationId != m_applicationId) return;
        if (status == QProcess::NormalExit && exitCode == 0 && !token.isEmpty()) {
            m_token = token;
            setStatus(m_enabled
                ? m_userId.isEmpty()
                    ? QStringLiteral("Open Discord once so colorful can identify the widget owner")
                    : QStringLiteral("Discord widget is ready")
                : QStringLiteral("Discord widget updates are off"));
            emit stateChanged();
            schedulePublish();
        } else {
            setStatus(QStringLiteral("Discord widget is not configured"));
        }
    });
    process->start(executable, arguments);
}

void DiscordWidgetExporter::schedulePublish(bool manual)
{
    if (!m_enabled || !configured() || m_userId.isEmpty()
        || m_stats.value(QStringLiteral("playCount")).toLongLong() <= 0) return;
    m_pendingPayload = payload();
    if (m_pendingPayload.isEmpty()) return;

    QSettings settings;
    const auto hash = QCryptographicHash::hash(m_pendingPayload, QCryptographicHash::Sha256).toHex();
    if (!manual && settings.value(QStringLiteral("discordWidget/lastPayloadHash")).toByteArray() == hash) return;

    const auto lastPublished = settings.value(QStringLiteral("discordWidget/lastPublishedAtMs"), 0).toLongLong();
    const auto interval = manual ? manualPublishIntervalMs : automaticPublishIntervalMs;
    const auto elapsed = QDateTime::currentMSecsSinceEpoch() - lastPublished;
    const auto delay = std::max<qint64>(manual ? 0 : 2000, interval - elapsed);
    m_manualPublish = m_manualPublish || manual;
    if (!m_publishTimer.isActive() || delay < m_publishTimer.remainingTime()) {
        m_publishTimer.start(static_cast<int>(std::min<qint64>(delay, std::numeric_limits<int>::max())));
    }
    setStatus(delay > 2000
        ? QStringLiteral("Discord widget update queued")
        : QStringLiteral("Publishing Discord widget…"));
}

void DiscordWidgetExporter::publish(bool manual)
{
    Q_UNUSED(manual)
    m_manualPublish = false;
    if (!m_enabled || !configured() || m_userId.isEmpty() || m_pendingPayload.isEmpty() || m_busy) return;

    const auto url = QUrl(QStringLiteral("https://discord.com/api/v9/applications/%1/users/%2/identities/0/profile")
                              .arg(m_applicationId, m_userId));
    QNetworkRequest request(url);
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    request.setRawHeader("Authorization", QByteArray("Bot ") + m_token);
    request.setRawHeader("User-Agent", "DiscordBot (https://github.com/atvalerie/colorful, 0.1.0)");

    setBusy(true);
    const auto publishedPayload = m_pendingPayload;
    const auto publishedApplicationId = m_applicationId;
    auto *reply = m_network.sendCustomRequest(request, QByteArrayLiteral("PATCH"), publishedPayload);
    connect(reply, &QNetworkReply::finished, this, [this, reply, publishedPayload, publishedApplicationId] {
        const auto status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const auto response = QJsonDocument::fromJson(reply->readAll()).object();
        const auto discordCode = response.value(QStringLiteral("code")).toInteger();
        reply->deleteLater();
        setBusy(false);
        if (publishedApplicationId != m_applicationId) return;
        if (status >= 200 && status < 300) {
            QSettings settings;
            settings.setValue(QStringLiteral("discordWidget/lastPublishedAtMs"), QDateTime::currentMSecsSinceEpoch());
            settings.setValue(
                QStringLiteral("discordWidget/lastPayloadHash"),
                QCryptographicHash::hash(publishedPayload, QCryptographicHash::Sha256).toHex());
            setStatus(QStringLiteral("Discord widget updated"));
            if (m_pendingPayload != publishedPayload) schedulePublish();
        } else if (status == 401 || discordCode == 50014) {
            setStatus(QStringLiteral("Discord rejected the bot token (HTTP %1, code %2)")
                          .arg(status).arg(discordCode));
        } else if (discordCode == 50025) {
            setStatus(QStringLiteral("Reauthorize the widget owner in OAuth2 (Discord code 50025)"));
        } else if (discordCode == 50026) {
            setStatus(QStringLiteral("Reauthorize with openid and sdk.social_layer (Discord code 50026)"));
        } else if (status == 403) {
            setStatus(QStringLiteral("Discord denied widget authorization (HTTP 403, code %1)")
                          .arg(discordCode));
        } else if (status == 429) {
            setStatus(QStringLiteral("Discord rate-limited the widget; retrying later"));
            m_publishTimer.start(static_cast<int>(automaticPublishIntervalMs));
        } else {
            setStatus(status > 0
                ? QStringLiteral("Discord widget update failed (HTTP %1, code %2)")
                      .arg(status).arg(discordCode)
                : QStringLiteral("Could not reach Discord for widget update"));
        }
    });
}

void DiscordWidgetExporter::setBusy(bool busy)
{
    if (m_busy == busy) return;
    m_busy = busy;
    emit stateChanged();
}

void DiscordWidgetExporter::setStatus(const QString &status)
{
    if (m_status == status) return;
    m_status = status;
    emit stateChanged();
}

QByteArray DiscordWidgetExporter::payload() const
{
    const auto topTrackEntry = firstMap(m_stats, QStringLiteral("topTracks"));
    const auto topTrack = topTrackEntry.value(QStringLiteral("track")).toMap();
    const auto topArtist = firstMap(m_stats, QStringLiteral("topArtists"));
    const auto topAlbum = firstMap(m_stats, QStringLiteral("topAlbums"));
    if (topTrack.isEmpty()) return {};

    const auto totalListened = m_stats.value(QStringLiteral("totalListenedMs")).toLongLong();
    const auto roundedListened = totalListened > std::numeric_limits<qint64>::max() - 500
        ? totalListened - totalListened % 1000
        : ((totalListened + 500) / 1000) * 1000;
    const auto playCount = m_stats.value(QStringLiteral("playCount")).toLongLong();
    const auto trackTitle = topTrack.value(QStringLiteral("title")).toString();
    const auto trackArtist = artistNames(topTrack.value(QStringLiteral("artists")).toList());
    const auto albumTitle = topAlbum.value(QStringLiteral("title")).toString();
    const auto albumArtist = artistNames(topAlbum.value(QStringLiteral("artists")).toList());
    const auto useAlbum = !albumTitle.isEmpty();

    QJsonArray dynamic;
    appendImage(dynamic, QStringLiteral("top_artwork"),
                useAlbum ? artworkUrl(topAlbum) : artworkUrl(topTrack));
    dynamic.append(textField(QStringLiteral("top_title"),
                             useAlbum ? QStringLiteral("Most Played Album")
                                      : QStringLiteral("Most Played Track")));
    dynamic.append(textField(
        QStringLiteral("top_subtitle_1"),
        useAlbum
            ? albumTitle + (albumArtist.isEmpty() ? QString{} : QStringLiteral(" - ") + albumArtist)
            : trackTitle + (trackArtist.isEmpty() ? QString{} : QStringLiteral(" - ") + trackArtist)));
    dynamic.append(textField(
        QStringLiteral("top_subtitle_2"),
        QString::number(useAlbum ? topAlbum.value(QStringLiteral("playCount")).toLongLong()
                                 : topTrackEntry.value(QStringLiteral("playCount")).toLongLong())));
    dynamic.append(numberField(QStringLiteral("total_listened"), roundedListened));
    dynamic.append(numberField(QStringLiteral("play_count"), playCount));
    dynamic.append(textField(QStringLiteral("top_artist_name"),
                             topArtist.value(QStringLiteral("name")).toString()));
    dynamic.append(numberField(QStringLiteral("top_artist_plays"),
                               topArtist.value(QStringLiteral("playCount")).toLongLong()));
    dynamic.append(textField(QStringLiteral("top_track_name"), trackTitle));
    dynamic.append(numberField(QStringLiteral("top_track_plays"),
                               topTrackEntry.value(QStringLiteral("playCount")).toLongLong()));
    dynamic.append(textField(QStringLiteral("mini_label"), QStringLiteral("Most Played Track")));
    dynamic.append(textField(
        QStringLiteral("mini_text"),
        trackTitle + (trackArtist.isEmpty() ? QString{} : QStringLiteral(" - ") + trackArtist)));
    appendImage(dynamic, QStringLiteral("mini_artwork"), artworkUrl(topTrack));
    dynamic.append(textField(
        QStringLiteral("activity_summary"),
        QStringLiteral("%1 qualified plays · %2 listened")
            .arg(playCount)
            .arg(compactDuration(roundedListened))));

    return QJsonDocument(QJsonObject{
        {QStringLiteral("username"), QStringLiteral("colorful")},
        {QStringLiteral("data"), QJsonObject{{QStringLiteral("dynamic"), dynamic}}},
    }).toJson(QJsonDocument::Compact);
}
