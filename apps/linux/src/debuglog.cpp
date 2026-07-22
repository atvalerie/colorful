#include "debuglog.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMutex>
#include <QMutexLocker>
#include <QRegularExpression>
#include <QStandardPaths>

namespace {
constexpr qint64 MaximumLogBytes = 4 * 1024 * 1024;

QMutex &logMutex()
{
    static QMutex mutex;
    return mutex;
}

QString sanitized(QString message)
{
    static const QRegularExpression url(
        QStringLiteral(R"(https?://[^\s"'<>]+)"), QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression secret(
        QStringLiteral(R"((authorization|cookie|set-cookie)\s*[:=]\s*[^\s,;]+)"),
        QRegularExpression::CaseInsensitiveOption);
    message.replace(url, QStringLiteral("<redacted-url>"));
    message.replace(secret, QStringLiteral("\\1=<redacted>"));
    message.replace(u'\r', u' ');
    if (message.size() > 4000) message = message.left(4000) + QStringLiteral("…");
    return message.trimmed();
}
}

QString DebugLog::filePath()
{
    return QDir(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation))
        .filePath(QStringLiteral("colorful.log"));
}

void DebugLog::write(QStringView component, QStringView message)
{
    QMutexLocker lock(&logMutex());
    const auto path = filePath();
    QDir().mkpath(QFileInfo(path).absolutePath());
    if (QFileInfo(path).size() >= MaximumLogBytes) {
        const auto previous = path + QStringLiteral(".old");
        QFile::remove(previous);
        QFile::rename(path, previous);
    }
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) return;
    const auto line = QStringLiteral("%1 [%2] %3\n")
                          .arg(QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs),
                               component.toString(), sanitized(message.toString()))
                          .toUtf8();
    file.write(line);
    file.close();
    QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
}
