#include "credentialstore.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QSaveFile>
#include <QStandardPaths>

#if defined(Q_OS_WIN)
#include <windows.h>
#include <dpapi.h>
#endif

namespace {
QString credentialPath(const QString &name)
{
    const auto digest = QCryptographicHash::hash(name.toUtf8(), QCryptographicHash::Sha256).toHex();
    QDir directory(QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation));
    directory.mkpath(QStringLiteral("credentials"));
    return directory.filePath(QStringLiteral("credentials/%1.bin").arg(QString::fromLatin1(digest)));
}

void setError(QString *error, const QString &message)
{
    if (error) *error = message;
}
}

QByteArray loadCredential(const QString &name, QString *error)
{
    QFile file(credentialPath(name));
    if (!file.exists()) return {};
    if (!file.open(QIODevice::ReadOnly)) {
        setError(error, file.errorString());
        return {};
    }
    const auto protectedValue = file.readAll();
#if defined(Q_OS_WIN)
    DATA_BLOB input{static_cast<DWORD>(protectedValue.size()),
                    reinterpret_cast<BYTE *>(const_cast<char *>(protectedValue.constData()))};
    DATA_BLOB output{};
    if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output)) {
        setError(error, QStringLiteral("Windows Data Protection could not decrypt the credential (%1)").arg(GetLastError()));
        return {};
    }
    QByteArray value(reinterpret_cast<const char *>(output.pbData), static_cast<qsizetype>(output.cbData));
    SecureZeroMemory(output.pbData, output.cbData);
    LocalFree(output.pbData);
    return value;
#else
    Q_UNUSED(error);
    return protectedValue;
#endif
}

bool saveCredential(const QString &name, const QByteArray &value, QString *error)
{
    QByteArray protectedValue;
#if defined(Q_OS_WIN)
    DATA_BLOB input{static_cast<DWORD>(value.size()),
                    reinterpret_cast<BYTE *>(const_cast<char *>(value.constData()))};
    DATA_BLOB output{};
    if (!CryptProtectData(&input, L"colorful credential", nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &output)) {
        setError(error, QStringLiteral("Windows Data Protection could not encrypt the credential (%1)").arg(GetLastError()));
        return false;
    }
    protectedValue = QByteArray(reinterpret_cast<const char *>(output.pbData), static_cast<qsizetype>(output.cbData));
    SecureZeroMemory(output.pbData, output.cbData);
    LocalFree(output.pbData);
#else
    protectedValue = value;
#endif
    QSaveFile file(credentialPath(name));
    if (!file.open(QIODevice::WriteOnly) || file.write(protectedValue) != protectedValue.size() || !file.commit()) {
        setError(error, file.errorString());
        return false;
    }
    QFile::setPermissions(file.fileName(), QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    return true;
}

bool deleteCredential(const QString &name, QString *error)
{
    QFile file(credentialPath(name));
    if (!file.exists() || file.remove()) return true;
    setError(error, file.errorString());
    return false;
}
