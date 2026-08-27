#pragma once

#include <QNetworkAccessManager>
#include <QJsonObject>
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
    Q_PROPERTY(QString channel READ channel WRITE setChannel NOTIFY changed)

public:
    explicit UpdateManager(QObject *parent = nullptr);
    ~UpdateManager() override;

    QString state() const { return m_state; }
    QString status() const { return m_status; }
    QVariantMap release() const { return m_release; }
    double progress() const { return m_progress; }
    bool updateAvailable() const { return m_state == QStringLiteral("available"); }
    bool canInstall() const;
    QString channel() const { return m_channel; }

    Q_INVOKABLE void checkForUpdates(bool force = false);
    Q_INVOKABLE void setChannel(const QString &channel);
    Q_INVOKABLE void dismiss();
    Q_INVOKABLE void startUpdate();
    Q_INVOKABLE void openReleasePage();

signals:
    void changed();
    void updateFound();

private:
    friend class UpdateManagerTest;
    // Pure release parsing/comparison seams used by the updater contract
    // tests. They do not perform network or filesystem I/O.
    static QVariantMap parseReleaseForTest(const QJsonObject &object, const QString &channel);
    static bool candidateAvailableForTest(const QVariantMap &candidate,
                                          const QString &currentChannel,
                                          const QString &currentBaseVersion,
                                          qint64 currentBuild);
    static QString selectAssetNameForTest(const QJsonObject &release, const QString &channel,
                                          const QString &wantedSuffix);
    void setState(const QString &state, const QString &status = {});
    void handleReleaseResponse(QNetworkReply *reply, bool force, const QString &channel,
                               quint64 generation);
    void beginDownload(const QUrl &url, const QString &name, const QString &digest,
                       qint64 expectedSize);
    void startDownloadAttempt();
    void failDownloadAttempt(const QString &reason, bool retryable = true);
    void finishDownload(QNetworkReply *reply);
    bool launchInstaller(const QString &path);
    QString downloadDestination(const QString &name) const;
    static QString lastCheckKey(const QString &channel);
    static QString dismissedKey(const QString &channel);

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
    QString m_channel = QStringLiteral("stable");
    bool m_forcedCheckPending = false;
    quint64 m_checkGeneration = 0;
};
