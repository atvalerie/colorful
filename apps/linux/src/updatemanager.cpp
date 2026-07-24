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

namespace {
constexpr qint64 AutomaticCheckIntervalMs = 6 * 60 * 60 * 1000;
const QUrl LatestReleaseUrl(QStringLiteral(
    "https://api.github.com/repos/atvalerie/colorful/releases/latest"));

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
    QTimer::singleShot(8000, this, [this] { checkForUpdates(false); });
}

UpdateManager::~UpdateManager() = default;

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
    if (m_reply || m_state == QStringLiteral("downloading")) return;
    QSettings settings;
    const auto now = QDateTime::currentMSecsSinceEpoch();
    const auto lastCheck = settings.value(QStringLiteral("updates/lastCheckMs"), 0).toLongLong();
    if (!force && now - lastCheck < AutomaticCheckIntervalMs) return;

    setState(QStringLiteral("checking"), QStringLiteral("Checking for updates…"));
    QNetworkRequest request(LatestReleaseUrl);
    request.setHeader(QNetworkRequest::UserAgentHeader,
                      QStringLiteral("colorful/%1").arg(QString::fromLatin1(COLORFUL_VERSION)));
    request.setRawHeader("Accept", "application/vnd.github+json");
    request.setRawHeader("X-GitHub-Api-Version", "2022-11-28");
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(15000);
    auto *reply = m_network.get(request);
    m_reply = reply;
    connect(reply, &QNetworkReply::finished, this, [this, reply, force] {
        m_reply.clear();
        handleReleaseResponse(reply, force);
        reply->deleteLater();
    });
}

void UpdateManager::handleReleaseResponse(QNetworkReply *reply, bool force)
{
    const auto statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (reply->error() != QNetworkReply::NoError || statusCode != 200) {
        DebugLog::write(u"updates", QStringLiteral("check failed status=%1 error=%2")
                                        .arg(statusCode)
                                        .arg(reply->errorString()));
        setState(QStringLiteral("error"),
                 force ? QStringLiteral("Could not check for updates") : QString());
        return;
    }
    QSettings().setValue(QStringLiteral("updates/lastCheckMs"), QDateTime::currentMSecsSinceEpoch());
    const auto document = QJsonDocument::fromJson(reply->readAll());
    if (!document.isObject()) {
        setState(QStringLiteral("error"), QStringLiteral("The update response was invalid"));
        return;
    }
    const auto object = document.object();
    const auto tag = object.value(QStringLiteral("tag_name")).toString();
    const auto version = tag.startsWith(u'v') ? tag.sliced(1) : tag;
    if (!isNewerVersion(version, QString::fromLatin1(COLORFUL_VERSION))) {
        setState(QStringLiteral("current"),
                 force ? QStringLiteral("You’re running the latest release") : QString());
        return;
    }

    QString wantedSuffix;
#if defined(Q_OS_WIN)
    wantedSuffix = QStringLiteral("-setup.exe");
#elif defined(Q_OS_LINUX)
    wantedSuffix = QStringLiteral(".AppImage");
#endif
    QJsonObject selectedAsset;
    for (const auto &value : object.value(QStringLiteral("assets")).toArray()) {
        const auto asset = value.toObject();
        if (!wantedSuffix.isEmpty()
            && asset.value(QStringLiteral("name")).toString().endsWith(
                wantedSuffix, Qt::CaseInsensitive)) {
            selectedAsset = asset;
            break;
        }
    }

    m_release = {
        {QStringLiteral("version"), version},
        {QStringLiteral("name"), object.value(QStringLiteral("name")).toString(tag)},
        {QStringLiteral("notes"), object.value(QStringLiteral("body")).toString()},
        {QStringLiteral("url"), object.value(QStringLiteral("html_url")).toString()},
        {QStringLiteral("publishedAt"), object.value(QStringLiteral("published_at")).toString()},
        {QStringLiteral("assetName"), selectedAsset.value(QStringLiteral("name")).toString()},
        {QStringLiteral("assetUrl"), selectedAsset.value(QStringLiteral("browser_download_url")).toString()},
        {QStringLiteral("assetDigest"), selectedAsset.value(QStringLiteral("digest")).toString()},
    };
    const auto dismissed = QSettings().value(QStringLiteral("updates/dismissedVersion")).toString();
    DebugLog::write(u"updates", QStringLiteral("available version=%1 asset=%2")
                                    .arg(version, m_release.value(QStringLiteral("assetName")).toString()));
    setState(QStringLiteral("available"), QStringLiteral("colorful %1 is available").arg(version));
    if (force || dismissed != version) emit updateFound();
}

void UpdateManager::dismiss()
{
    const auto version = m_release.value(QStringLiteral("version")).toString();
    if (!version.isEmpty())
        QSettings().setValue(QStringLiteral("updates/dismissedVersion"), version);
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
    beginDownload(url, name, digest);
}

void UpdateManager::beginDownload(const QUrl &url, const QString &name, const QString &digest)
{
    m_downloadPath = downloadDestination(name);
    QDir().mkpath(QFileInfo(m_downloadPath).absolutePath());
    m_file = std::make_unique<QSaveFile>(m_downloadPath);
    if (!m_file->open(QIODevice::WriteOnly)) {
        m_file.reset();
        setState(QStringLiteral("error"), QStringLiteral("Could not create the update file"));
        return;
    }
    m_expectedDigest = normalizedDigest(digest);
    m_progress = 0;
    setState(QStringLiteral("downloading"), QStringLiteral("Downloading update…"));

    QNetworkRequest request(url);
    request.setHeader(QNetworkRequest::UserAgentHeader,
                      QStringLiteral("colorful/%1").arg(QString::fromLatin1(COLORFUL_VERSION)));
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(30000);
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

void UpdateManager::finishDownload(QNetworkReply *reply)
{
    if (m_file) m_file->write(reply->readAll());
    if (!m_file || reply->error() != QNetworkReply::NoError) {
        if (m_file) m_file->cancelWriting();
        m_file.reset();
        setState(QStringLiteral("error"), QStringLiteral("The update download failed"));
        return;
    }
    if (!m_file->commit()) {
        m_file.reset();
        setState(QStringLiteral("error"), QStringLiteral("Could not save the update"));
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
        setState(QStringLiteral("error"), QStringLiteral("Update verification failed"));
        return;
    }
    downloaded.close();
    DebugLog::write(u"updates", QStringLiteral("verified version=%1 file=%2")
                                    .arg(m_release.value(QStringLiteral("version")).toString(),
                                         QFileInfo(m_downloadPath).fileName()));

#if defined(Q_OS_WIN)
    if (launchInstaller(m_downloadPath)) return;
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
    QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(m_downloadPath).absolutePath()));
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
