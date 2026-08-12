#pragma once

#include <QNetworkAccessManager>
#include <QObject>
#include <QPointer>
#include <QUrl>
#include <QVariantMap>
#include <memory>

class QNetworkReply;
class QSaveFile;

class UpdateManager final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString state READ state NOTIFY changed)
    Q_PROPERTY(QString status READ status NOTIFY changed)
    Q_PROPERTY(QVariantMap release READ release NOTIFY changed)
    Q_PROPERTY(double progress READ progress NOTIFY changed)
    Q_PROPERTY(bool updateAvailable READ updateAvailable NOTIFY changed)
    Q_PROPERTY(bool canInstall READ canInstall NOTIFY changed)

public:
    explicit UpdateManager(QObject *parent = nullptr);
    ~UpdateManager() override;

    QString state() const { return m_state; }
    QString status() const { return m_status; }
    QVariantMap release() const { return m_release; }
    double progress() const { return m_progress; }
    bool updateAvailable() const { return m_state == QStringLiteral("available"); }
    bool canInstall() const;

    Q_INVOKABLE void checkForUpdates(bool force = false);
    Q_INVOKABLE void dismiss();
    Q_INVOKABLE void startUpdate();
    Q_INVOKABLE void openReleasePage();

signals:
    void changed();
    void updateFound();

private:
    friend class UpdateManagerTest;
    void setState(const QString &state, const QString &status = {});
    void handleReleaseResponse(QNetworkReply *reply, bool force);
    void beginDownload(const QUrl &url, const QString &name, const QString &digest,
                       qint64 expectedSize);
    void startDownloadAttempt();
    void failDownloadAttempt(const QString &reason, bool retryable = true);
    void finishDownload(QNetworkReply *reply);
    bool launchInstaller(const QString &path);
    QString downloadDestination(const QString &name) const;

    QNetworkAccessManager m_network;
    QPointer<QNetworkReply> m_reply;
    std::unique_ptr<QSaveFile> m_file;
    QString m_state = QStringLiteral("idle");
    QString m_status;
    QVariantMap m_release;
    QString m_downloadPath;
    QUrl m_downloadUrl;
    QString m_downloadName;
    QString m_expectedDigest;
    qint64 m_expectedSize = 0;
    int m_downloadAttempt = 0;
    bool m_allowLaunch = true;
    bool m_openDownloadedLocation = true;
    double m_progress = 0;
};
