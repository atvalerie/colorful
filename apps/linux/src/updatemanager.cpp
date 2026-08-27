#include "updatemanager.h"
#include "buildinfo_generated.h"
#include "debuglog.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDesktopServices>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QSaveFile>
#include <QSettings>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>
#include <QRegularExpression>
#include <optional>

namespace {
constexpr qint64 AutomaticCheckIntervalMs = 6 * 60 * 60 * 1000;
constexpr int DownloadAttempts = 3;
constexpr int DownloadInactivityTimeoutMs = 5 * 60 * 1000;
const QUrl LatestReleaseUrl(QStringLiteral(
    "https://api.github.com/repos/atvalerie/colorful/releases/latest"));
const QUrl PreviewReleaseUrl(QStringLiteral(
    "https://api.github.com/repos/atvalerie/colorful/releases/tags/dev-nightly"));

struct ParsedRelease {
    QString channel;
    QString version;
    QString baseVersion;
    qint64 build = -1;
    QString sha;
};

QList<int> versionParts(QString version)
{
    if (version.startsWith(u'v')) version.removeFirst();
    version = version.section(u'-', 0, 0).section(u'+', 0, 0);
    const auto textParts = version.split(u'.');
    if (textParts.size() != 3) return {};
    QList<int> parts;
    for (const auto &part : textParts) {
        bool ok = false;
        const auto value = part.toInt(&ok);
        if (!ok || value < 0) return {};
        parts.append(value);
    }
    return parts;
}

bool isNewerVersion(const QString &candidate, const QString &current)
{
    const auto candidateParts = versionParts(candidate);
    const auto currentParts = versionParts(current);
    if (candidateParts.size() != 3 || currentParts.size() != 3) return false;
    for (qsizetype index = 0; index < 3; ++index) {
        if (candidateParts[index] != currentParts[index])
            return candidateParts[index] > currentParts[index];
    }
    return false;
}

bool isAtLeastVersion(const QString &candidate, const QString &current)
{
    return candidate == current || isNewerVersion(candidate, current);
}

std::optional<ParsedRelease> parseRelease(const QJsonObject &object, const QString &channel)
{
    const auto tag = object.value(QStringLiteral("tag_name")).toString();
    if (channel == QStringLiteral("stable")) {
        static const QRegularExpression stableTag(QStringLiteral("^v([0-9]+\\.[0-9]+\\.[0-9]+)$"));
        const auto match = stableTag.match(tag);
        if (!match.hasMatch() || versionParts(match.captured(1)).size() != 3) return std::nullopt;
        return ParsedRelease{channel, match.captured(1), match.captured(1), -1, {}};
    }
    if (channel != QStringLiteral("preview") || tag != QStringLiteral("dev-nightly"))
        return std::nullopt;
    static const QRegularExpression previewTitle(
        QStringLiteral("^colorful ([0-9]+\\.[0-9]+\\.[0-9]+)-dev\\.([0-9]+)\\+([0-9A-Fa-f]{12})$"));
    const auto match = previewTitle.match(object.value(QStringLiteral("name")).toString());
    if (!match.hasMatch() || versionParts(match.captured(1)).size() != 3) return std::nullopt;
    bool buildOk = false;
    const auto build = match.captured(2).toLongLong(&buildOk);
    if (!buildOk || build < 0) return std::nullopt;
    return ParsedRelease{channel,
                         QStringLiteral("%1-dev.%2+%3")
                             .arg(match.captured(1), match.captured(2), match.captured(3).toLower()),
                         match.captured(1), build, match.captured(3).toLower()};
}

bool candidateAvailable(const ParsedRelease &candidate,
                        const QString &currentChannel,
                        const QString &currentBaseVersion,
                        qint64 currentBuild)
{
    if (candidate.channel == QStringLiteral("stable")) {
        // A preview build returning to stable is explicit even when both
        // builds share the same semantic base version.
        if (currentChannel == QStringLiteral("preview")) return true;
        return isNewerVersion(candidate.baseVersion, currentBaseVersion);
    }
    if (currentChannel == QStringLiteral("stable"))
        return isAtLeastVersion(candidate.baseVersion, currentBaseVersion);
    if (isNewerVersion(candidate.baseVersion, currentBaseVersion)) return true;
    return candidate.baseVersion == currentBaseVersion && candidate.build > currentBuild;
}

std::optional<QJsonObject> selectAsset(const QJsonArray &assets, const QString &channel,
                                       const QString &wantedSuffix)
{
    QString wantedName;
    if (channel == QStringLiteral("preview")) {
        if (wantedSuffix == QStringLiteral("-setup.exe"))
            wantedName = QStringLiteral("colorful-windows-x64-preview-setup.exe");
        else if (wantedSuffix == QStringLiteral(".AppImage"))
            wantedName = QStringLiteral("colorful-linux-x86_64-preview.AppImage");
    }
    for (const auto &value : assets) {
        const auto asset = value.toObject();
        const auto name = asset.value(QStringLiteral("name")).toString();
        const bool matches = channel == QStringLiteral("preview")
            ? !wantedName.isEmpty() && name == wantedName
            : !wantedSuffix.isEmpty() && name.endsWith(wantedSuffix, Qt::CaseInsensitive);
        if (matches) return asset;
    }
    return std::nullopt;
}

QVariantMap parsedReleaseMap(const ParsedRelease &release)
{
    return {
        {QStringLiteral("channel"), release.channel},
        {QStringLiteral("version"), release.version},
        {QStringLiteral("baseVersion"), release.baseVersion},
        {QStringLiteral("build"), release.build},
        {QStringLiteral("sha"), release.sha},
        {QStringLiteral("releaseKey"), release.channel + QLatin1Char(':')
            + (release.channel == QStringLiteral("preview")
                   ? release.baseVersion + QStringLiteral("-dev.") + QString::number(release.build)
                   : release.version)},
    };
}

QString normalizedDigest(QString digest)
{
    if (digest.startsWith(QStringLiteral("sha256:"), Qt::CaseInsensitive))
        digest = digest.sliced(7);
    return digest.trimmed().toLower();
}
}

UpdateManager::UpdateManager(QObject *parent)
    : QObject(parent)
{
    QSettings settings;
    m_channel = settings.value(QStringLiteral("updates/channel"), QStringLiteral("stable")).toString();
    if (m_channel != QStringLiteral("stable") && m_channel != QStringLiteral("preview"))
        m_channel = QStringLiteral("stable");
    QTimer::singleShot(8000, this, [this] { checkForUpdates(false); });
}

UpdateManager::~UpdateManager() = default;

QVariantMap UpdateManager::parseReleaseForTest(const QJsonObject &object, const QString &channel)
{
    const auto parsed = parseRelease(object, channel);
    return parsed ? parsedReleaseMap(*parsed) : QVariantMap{};
}

bool UpdateManager::candidateAvailableForTest(const QVariantMap &candidate,
                                              const QString &currentChannel,
                                              const QString &currentBaseVersion,
                                              qint64 currentBuild)
{
    const auto channel = candidate.value(QStringLiteral("channel")).toString();
    const auto base = candidate.value(QStringLiteral("baseVersion")).toString();
    if (channel.isEmpty() || base.isEmpty()) return false;
    ParsedRelease parsed{
        channel,
        candidate.value(QStringLiteral("version")).toString(),
        base,
        candidate.value(QStringLiteral("build"), -1).toLongLong(),
        candidate.value(QStringLiteral("sha")).toString(),
    };
    return candidateAvailable(parsed, currentChannel, currentBaseVersion, currentBuild);
}

QString UpdateManager::selectAssetNameForTest(const QJsonObject &release, const QString &channel,
                                              const QString &wantedSuffix)
{
    const auto asset = selectAsset(release.value(QStringLiteral("assets")).toArray(), channel,
                                   wantedSuffix);
    return asset ? asset->value(QStringLiteral("name")).toString() : QString();
}

QString UpdateManager::lastCheckKey(const QString &channel)
{
    return QStringLiteral("updates/lastCheck%1Ms").arg(channel == QStringLiteral("preview")
                                                          ? QStringLiteral("Preview")
                                                          : QStringLiteral("Stable"));
}

QString UpdateManager::dismissedKey(const QString &channel)
{
    return QStringLiteral("updates/dismissed%1Version").arg(channel == QStringLiteral("preview")
                                                              ? QStringLiteral("Preview")
                                                              : QStringLiteral("Stable"));
}

void UpdateManager::setChannel(const QString &channel)
{
    if (channel != QStringLiteral("stable") && channel != QStringLiteral("preview")) return;
    if (m_state == QStringLiteral("downloading") || m_state == QStringLiteral("installing")) return;
    if (m_channel == channel) return;
    m_channel = channel;
    ++m_checkGeneration;
    QSettings().setValue(QStringLiteral("updates/channel"), m_channel);
    m_release.clear();
    m_progress = 0;
    m_forcedCheckPending = true;
    setState(QStringLiteral("idle"));
    QTimer::singleShot(0, this, [this] { checkForUpdates(true); });
}

bool UpdateManager::canInstall() const
{
#if defined(Q_OS_WIN)
    return m_release.value(QStringLiteral("assetName")).toString().endsWith(
        QStringLiteral("-setup.exe"), Qt::CaseInsensitive);
#else
    return false;
#endif
}

void UpdateManager::setState(const QString &state, const QString &status)
{
    m_state = state;
    m_status = status;
    emit changed();
}

void UpdateManager::checkForUpdates(bool force)
{
    if (m_reply || m_state == QStringLiteral("downloading")) {
        if (force) m_forcedCheckPending = true;
        return;
    }
    m_forcedCheckPending = false;
    QSettings settings;
    const auto now = QDateTime::currentMSecsSinceEpoch();
    const auto channel = m_channel;
    const auto generation = m_checkGeneration;
    const auto lastCheck = settings.value(lastCheckKey(channel), 0).toLongLong();
    if (!force && now - lastCheck < AutomaticCheckIntervalMs) return;

    setState(QStringLiteral("checking"), QStringLiteral("Checking for updates…"));
    QNetworkRequest request(channel == QStringLiteral("preview") ? PreviewReleaseUrl : LatestReleaseUrl);
    request.setHeader(QNetworkRequest::UserAgentHeader,
                      QStringLiteral("colorful/%1").arg(QString::fromLatin1(COLORFUL_VERSION)));
    request.setRawHeader("Accept", "application/vnd.github+json");
    request.setRawHeader("X-GitHub-Api-Version", "2022-11-28");
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(15000);
    auto *reply = m_network.get(request);
    m_reply = reply;
    connect(reply, &QNetworkReply::finished, this, [this, reply, force, channel, generation] {
        m_reply.clear();
        if (generation == m_checkGeneration)
            handleReleaseResponse(reply, force, channel, generation);
        reply->deleteLater();
        if (m_forcedCheckPending)
            QTimer::singleShot(0, this, [this] { checkForUpdates(true); });
    });
}

void UpdateManager::handleReleaseResponse(QNetworkReply *reply, bool force, const QString &channel,
                                          quint64 generation)
{
    if (generation != m_checkGeneration) return;
    const auto statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (reply->error() != QNetworkReply::NoError || statusCode != 200) {
        DebugLog::write(u"updates", QStringLiteral("check failed status=%1 error=%2")
                                        .arg(statusCode)
                                        .arg(reply->errorString()));
        setState(QStringLiteral("error"),
                 force ? QStringLiteral("Could not check for updates") : QString());
        return;
    }
    QSettings().setValue(lastCheckKey(channel), QDateTime::currentMSecsSinceEpoch());
    const auto document = QJsonDocument::fromJson(reply->readAll());
    if (!document.isObject()) {
        setState(QStringLiteral("error"), QStringLiteral("The update response was invalid"));
        return;
    }
    const auto object = document.object();
    const auto parsed = parseRelease(object, channel);
    if (!parsed) {
        setState(QStringLiteral("error"), QStringLiteral("The update response was invalid"));
        return;
    }
    const auto currentChannel = QStringLiteral(COLORFUL_BUILD_CHANNEL) == QStringLiteral("dev")
        ? QStringLiteral("preview") : QStringLiteral("stable");
    const auto currentBaseVersion = QString::fromLatin1(COLORFUL_SEMANTIC_VERSION);
    bool currentBuildOk = false;
    const auto currentBuild = QString::fromLatin1(COLORFUL_BUILD_NUMBER).toLongLong(&currentBuildOk);
    const auto available = candidateAvailable(*parsed, currentChannel, currentBaseVersion,
                                              currentBuildOk ? currentBuild : -1);
    if (!available) {
        m_release.clear();
        const auto currentStatus = channel == QStringLiteral("preview")
            ? QStringLiteral("You’re running the latest preview build")
            : QStringLiteral("You’re running the latest release");
        setState(QStringLiteral("current"), force ? currentStatus : QString());
        return;
    }

    const auto version = parsed->version;
    const auto tag = object.value(QStringLiteral("tag_name")).toString();

    QString wantedSuffix;
#if defined(Q_OS_WIN)
    wantedSuffix = QStringLiteral("-setup.exe");
#elif defined(Q_OS_LINUX)
    wantedSuffix = QStringLiteral(".AppImage");
#endif
    const auto selectedAsset = selectAsset(object.value(QStringLiteral("assets")).toArray(), channel,
                                           wantedSuffix).value_or(QJsonObject{});

    m_release = {
        {QStringLiteral("channel"), parsed->channel},
        {QStringLiteral("version"), version},
        {QStringLiteral("baseVersion"), parsed->baseVersion},
        {QStringLiteral("build"), parsed->build},
        {QStringLiteral("sha"), parsed->sha},
        {QStringLiteral("downgrade"), currentChannel == QStringLiteral("preview")
                                            && parsed->channel == QStringLiteral("stable")},
        {QStringLiteral("releaseKey"), parsedReleaseMap(*parsed).value(QStringLiteral("releaseKey"))},
        {QStringLiteral("name"), object.value(QStringLiteral("name")).toString(tag)},
        {QStringLiteral("notes"), object.value(QStringLiteral("body")).toString()},
        {QStringLiteral("url"), object.value(QStringLiteral("html_url")).toString()},
        {QStringLiteral("publishedAt"), object.value(QStringLiteral("published_at")).toString()},
        {QStringLiteral("assetName"), selectedAsset.value(QStringLiteral("name")).toString()},
        {QStringLiteral("assetUrl"), selectedAsset.value(QStringLiteral("browser_download_url")).toString()},
        {QStringLiteral("assetDigest"), selectedAsset.value(QStringLiteral("digest")).toString()},
        {QStringLiteral("assetSize"), selectedAsset.value(QStringLiteral("size")).toInteger()},
    };
    const auto dismissed = QSettings().value(dismissedKey(channel)).toString();
    DebugLog::write(u"updates", QStringLiteral("available version=%1 asset=%2")
                                    .arg(version, m_release.value(QStringLiteral("assetName")).toString()));
    setState(QStringLiteral("available"), QStringLiteral("colorful %1 is available").arg(version));
    if (force || dismissed != m_release.value(QStringLiteral("releaseKey")).toString()) emit updateFound();
}

void UpdateManager::dismiss()
{
    const auto version = m_release.value(QStringLiteral("version")).toString();
    if (!version.isEmpty())
        QSettings().setValue(dismissedKey(m_release.value(QStringLiteral("channel")).toString()),
                            m_release.value(QStringLiteral("releaseKey")).toString());
    setState(QStringLiteral("dismissed"));
}

void UpdateManager::openReleasePage()
{
    const QUrl url(m_release.value(QStringLiteral("url")).toString());
    if (url.isValid()) QDesktopServices::openUrl(url);
}

QString UpdateManager::downloadDestination(const QString &name) const
{
#if defined(Q_OS_WIN)
    return QDir(QStandardPaths::writableLocation(QStandardPaths::TempLocation))
        .filePath(QStringLiteral("colorful-update-%1.exe")
                      .arg(m_release.value(QStringLiteral("version")).toString()));
#else
    auto directory = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
    if (directory.isEmpty())
        directory = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    return QDir(directory).filePath(name);
#endif
}

void UpdateManager::startUpdate()
{
    const QUrl url(m_release.value(QStringLiteral("assetUrl")).toString());
    const auto name = m_release.value(QStringLiteral("assetName")).toString();
    const auto digest = m_release.value(QStringLiteral("assetDigest")).toString();
    if (!url.isValid() || name.isEmpty() || normalizedDigest(digest).size() != 64) {
        openReleasePage();
        return;
    }
    beginDownload(url, name, digest,
                  m_release.value(QStringLiteral("assetSize")).toLongLong());
}

void UpdateManager::beginDownload(const QUrl &url, const QString &name, const QString &digest,
                                  qint64 expectedSize)
{
    m_downloadUrl = url;
    m_downloadName = name;
    m_downloadPath = downloadDestination(name);
    QDir().mkpath(QFileInfo(m_downloadPath).absolutePath());
    m_expectedDigest = normalizedDigest(digest);
    m_expectedSize = expectedSize;
    m_downloadAttempt = 0;
    m_progress = 0;
    startDownloadAttempt();
}

void UpdateManager::startDownloadAttempt()
{
    ++m_downloadAttempt;
    m_file = std::make_unique<QSaveFile>(m_downloadPath);
    if (!m_file->open(QIODevice::WriteOnly)) {
        m_file.reset();
        setState(QStringLiteral("error"), QStringLiteral("Could not create the update file"));
        return;
    }
    m_progress = 0;
    setState(QStringLiteral("downloading"),
             m_downloadAttempt == 1
                 ? QStringLiteral("Downloading update…")
                 : QStringLiteral("Retrying update download (%1/%2)…")
                       .arg(m_downloadAttempt)
                       .arg(DownloadAttempts));

    QNetworkRequest request(m_downloadUrl);
    request.setHeader(QNetworkRequest::UserAgentHeader,
                      QStringLiteral("colorful/%1").arg(QString::fromLatin1(COLORFUL_VERSION)));
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(DownloadInactivityTimeoutMs);
    auto *reply = m_network.get(request);
    m_reply = reply;
    connect(reply, &QIODevice::readyRead, this, [this, reply] {
        if (m_file) m_file->write(reply->readAll());
    });
    connect(reply, &QNetworkReply::downloadProgress, this, [this](qint64 received, qint64 total) {
        m_progress = total > 0 ? static_cast<double>(received) / total : 0;
        emit changed();
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        m_reply.clear();
        finishDownload(reply);
        reply->deleteLater();
    });
}

void UpdateManager::failDownloadAttempt(const QString &reason, bool retryable)
{
    if (m_file) m_file->cancelWriting();
    m_file.reset();
    QFile::remove(m_downloadPath);
    DebugLog::write(u"updates", QStringLiteral("download attempt=%1 failed: %2")
                                    .arg(m_downloadAttempt)
                                    .arg(reason));
    if (retryable && m_downloadAttempt < DownloadAttempts) {
        const auto delayMs = 1000 * (1 << (m_downloadAttempt - 1));
        setState(QStringLiteral("downloading"),
                 QStringLiteral("Download interrupted: %1. Retrying…").arg(reason));
        QTimer::singleShot(delayMs, this, &UpdateManager::startDownloadAttempt);
        return;
    }
    setState(QStringLiteral("error"),
             QStringLiteral("Update download failed: %1. Use View on GitHub to download it in your browser.")
                 .arg(reason));
}

void UpdateManager::finishDownload(QNetworkReply *reply)
{
    if (m_file) m_file->write(reply->readAll());
    if (!m_file || reply->error() != QNetworkReply::NoError) {
        failDownloadAttempt(reply->errorString());
        return;
    }
    if (m_expectedSize > 0 && m_file->size() != m_expectedSize) {
        failDownloadAttempt(QStringLiteral("received %1 of %2 bytes")
                                .arg(m_file->size())
                                .arg(m_expectedSize));
        return;
    }
    if (!m_file->commit()) {
        failDownloadAttempt(QStringLiteral("could not save the downloaded file"), false);
        return;
    }
    m_file.reset();

    QFile downloaded(m_downloadPath);
    if (!downloaded.open(QIODevice::ReadOnly)) {
        setState(QStringLiteral("error"), QStringLiteral("Could not verify the update"));
        return;
    }
    QCryptographicHash hash(QCryptographicHash::Sha256);
    hash.addData(&downloaded);
    const auto actual = QString::fromLatin1(hash.result().toHex());
    if (actual != m_expectedDigest) {
        downloaded.close();
        QFile::remove(m_downloadPath);
        DebugLog::write(u"updates", QStringLiteral("digest mismatch expected=%1 actual=%2")
                                        .arg(m_expectedDigest, actual));
        failDownloadAttempt(QStringLiteral("SHA-256 verification failed"));
        return;
    }
    downloaded.close();
    DebugLog::write(u"updates", QStringLiteral("verified version=%1 file=%2")
                                    .arg(m_release.value(QStringLiteral("version")).toString(),
                                         QFileInfo(m_downloadPath).fileName()));

#if defined(Q_OS_WIN)
    if (m_allowLaunch && launchInstaller(m_downloadPath)) return;
#elif defined(Q_OS_LINUX)
    if (m_downloadPath.endsWith(QStringLiteral(".AppImage"), Qt::CaseInsensitive)) {
        QFile::setPermissions(m_downloadPath,
                              QFileDevice::ReadOwner | QFileDevice::WriteOwner
                                  | QFileDevice::ExeOwner | QFileDevice::ReadGroup
                                  | QFileDevice::ExeGroup | QFileDevice::ReadOther
                                  | QFileDevice::ExeOther);
    }
#endif
    setState(QStringLiteral("ready"), QStringLiteral("Update downloaded to %1").arg(m_downloadPath));
    if (m_openDownloadedLocation)
        QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(m_downloadPath).absolutePath()));
    if (m_forcedCheckPending)
        QTimer::singleShot(0, this, [this] { checkForUpdates(true); });
}

bool UpdateManager::launchInstaller(const QString &path)
{
#if defined(Q_OS_WIN)
    const QStringList arguments = {
        QStringLiteral("/SILENT"),
        QStringLiteral("/CLOSEAPPLICATIONS"),
        QStringLiteral("/RESTARTAPPLICATIONS"),
    };
    if (!QProcess::startDetached(path, arguments)) {
        setState(QStringLiteral("error"), QStringLiteral("Could not start the updater"));
        return false;
    }
    setState(QStringLiteral("installing"), QStringLiteral("Installing update…"));
    QTimer::singleShot(250, QCoreApplication::instance(), &QCoreApplication::quit);
    return true;
#else
    Q_UNUSED(path)
    return false;
#endif
}
