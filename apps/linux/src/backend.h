#pragma once

#include <QAudioOutput>
#include <QColor>
#include <QHash>
#include <QJsonObject>
#include <QMediaPlayer>
#include <QNetworkAccessManager>
#include <QObject>
#include <QProcess>
#include <QVariantList>
#include <functional>

class Backend final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool providerReady READ providerReady NOTIFY providerReadyChanged)
    Q_PROPERTY(bool linked READ linked NOTIFY linkedChanged)
    Q_PROPERTY(bool authPending READ authPending NOTIFY authPendingChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QString userCode READ userCode NOTIFY authDetailsChanged)
    Q_PROPERTY(QString verificationUrl READ verificationUrl NOTIFY authDetailsChanged)
    Q_PROPERTY(QString statusMessage READ statusMessage NOTIFY statusMessageChanged)
    Q_PROPERTY(QVariantList searchResults READ searchResults NOTIFY searchResultsChanged)
    Q_PROPERTY(QVariantList queue READ queue NOTIFY queueChanged)
    Q_PROPERTY(int currentQueueIndex READ currentQueueIndex NOTIFY currentTrackChanged)
    Q_PROPERTY(QVariantMap currentTrack READ currentTrack NOTIFY currentTrackChanged)
    Q_PROPERTY(bool playing READ playing NOTIFY playbackChanged)
    Q_PROPERTY(qint64 position READ position NOTIFY positionChanged)
    Q_PROPERTY(qint64 duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(QColor accent READ accent NOTIFY accentChanged)

public:
    explicit Backend(QObject *parent = nullptr);
    ~Backend() override;

    bool providerReady() const { return m_providerReady; }
    bool linked() const { return m_linked; }
    bool authPending() const { return m_authPending; }
    bool busy() const { return m_busy; }
    QString userCode() const { return m_userCode; }
    QString verificationUrl() const { return m_verificationUrl; }
    QString statusMessage() const { return m_statusMessage; }
    QVariantList searchResults() const { return m_searchResults; }
    QVariantList queue() const { return m_queue; }
    int currentQueueIndex() const { return m_currentIndex; }
    QVariantMap currentTrack() const;
    bool playing() const;
    qint64 position() const { return m_player.position(); }
    qint64 duration() const { return m_player.duration(); }
    double volume() const { return m_audioOutput.volume(); }
    QColor accent() const { return m_accent; }

    QString playbackStatus() const;
    QVariantMap mprisMetadata() const;
    bool canGoNext() const;
    bool canGoPrevious() const;

    Q_INVOKABLE void startLogin();
    Q_INVOKABLE void openVerificationUrl();
    Q_INVOKABLE void unlink();
    Q_INVOKABLE void search(const QString &query);
    Q_INVOKABLE void enqueueSearchResult(int index);
    Q_INVOKABLE void playSearchResult(int index);
    Q_INVOKABLE void playQueueIndex(int index);
    Q_INVOKABLE void removeQueueIndex(int index);
    Q_INVOKABLE void togglePlay();
    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void next();
    Q_INVOKABLE void previous();
    Q_INVOKABLE void seek(qint64 positionMs);
    Q_INVOKABLE void seekBy(qint64 offsetMs);
    Q_INVOKABLE void setVolume(double volume);

signals:
    void providerReadyChanged();
    void linkedChanged();
    void authPendingChanged();
    void busyChanged();
    void authDetailsChanged();
    void statusMessageChanged();
    void searchResultsChanged();
    void queueChanged();
    void currentTrackChanged();
    void playbackChanged();
    void positionChanged();
    void durationChanged();
    void volumeChanged();
    void accentChanged();
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
    void playTrackAt(int index);
    void resolveCurrentSource();
    void loadAccent(const QString &artworkUrl);
    QColor paletteColor(const QImage &image) const;
    static QVariantMap jsonTrackToVariant(const QJsonObject &track);

    QProcess m_provider;
    QByteArray m_providerBuffer;
    QHash<int, ReplyHandler> m_replies;
    int m_nextRequestId = 1;

    QMediaPlayer m_player;
    QAudioOutput m_audioOutput;
    QNetworkAccessManager m_network;
    QVariantList m_searchResults;
    QVariantList m_queue;
    int m_currentIndex = -1;
    bool m_providerReady = false;
    bool m_linked = false;
    bool m_authPending = false;
    bool m_busy = false;
    QString m_userCode;
    QString m_verificationUrl;
    QString m_statusMessage = QStringLiteral("Starting Colorful…");
    QColor m_accent = QColor(QStringLiteral("#ff4f91"));
    QString m_pendingArtworkUrl;
};
