#pragma once

#include <QDBusAbstractAdaptor>
#include <QDBusObjectPath>
#include <QObject>
#include <QStringList>
#include <QVariantMap>

class Backend;

class MprisRootAdaptor final : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2")
    Q_PROPERTY(bool CanQuit READ canQuit CONSTANT)
    Q_PROPERTY(bool CanRaise READ canRaise CONSTANT)
    Q_PROPERTY(bool HasTrackList READ hasTrackList CONSTANT)
    Q_PROPERTY(QString Identity READ identity CONSTANT)
    Q_PROPERTY(QString DesktopEntry READ desktopEntry CONSTANT)
    Q_PROPERTY(QStringList SupportedUriSchemes READ supportedUriSchemes CONSTANT)
    Q_PROPERTY(QStringList SupportedMimeTypes READ supportedMimeTypes CONSTANT)
public:
    explicit MprisRootAdaptor(Backend *backend);
    bool canQuit() const { return true; }
    bool canRaise() const { return true; }
    bool hasTrackList() const { return false; }
    QString identity() const { return QStringLiteral("colorful"); }
    QString desktopEntry() const { return QStringLiteral("colorful"); }
    QStringList supportedUriSchemes() const { return {QStringLiteral("http"), QStringLiteral("https")}; }
    QStringList supportedMimeTypes() const { return {QStringLiteral("audio/flac"), QStringLiteral("audio/aac"), QStringLiteral("application/vnd.apple.mpegurl")}; }
public slots:
    void Raise();
    void Quit();
private:
    Backend *m_backend;
};

class MprisPlayerAdaptor final : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2.Player")
    Q_PROPERTY(QString PlaybackStatus READ playbackStatus)
    Q_PROPERTY(double Rate READ rate CONSTANT)
    Q_PROPERTY(QVariantMap Metadata READ metadata)
    Q_PROPERTY(double Volume READ volume WRITE setVolume)
    Q_PROPERTY(QString LoopStatus READ loopStatus WRITE setLoopStatus)
    Q_PROPERTY(bool Shuffle READ shuffle WRITE setShuffle)
    Q_PROPERTY(qlonglong Position READ position)
    Q_PROPERTY(double MinimumRate READ minimumRate CONSTANT)
    Q_PROPERTY(double MaximumRate READ maximumRate CONSTANT)
    Q_PROPERTY(bool CanGoNext READ canGoNext)
    Q_PROPERTY(bool CanGoPrevious READ canGoPrevious)
    Q_PROPERTY(bool CanPlay READ canPlay CONSTANT)
    Q_PROPERTY(bool CanPause READ canPause CONSTANT)
    Q_PROPERTY(bool CanSeek READ canSeek CONSTANT)
    Q_PROPERTY(bool CanControl READ canControl CONSTANT)
public:
    explicit MprisPlayerAdaptor(Backend *backend);
    QString playbackStatus() const;
    double rate() const { return 1.0; }
    QVariantMap metadata() const;
    double volume() const;
    void setVolume(double value);
    QString loopStatus() const;
    void setLoopStatus(const QString &value);
    bool shuffle() const;
    void setShuffle(bool value);
    qlonglong position() const;
    double minimumRate() const { return 1.0; }
    double maximumRate() const { return 1.0; }
    bool canGoNext() const;
    bool canGoPrevious() const;
    bool canPlay() const { return true; }
    bool canPause() const { return true; }
    bool canSeek() const { return true; }
    bool canControl() const { return true; }
public slots:
    void Next();
    void Previous();
    void Pause();
    void PlayPause();
    void Stop();
    void Play();
    void Seek(qlonglong offset);
    void SetPosition(const QDBusObjectPath &trackId, qlonglong position);
    void OpenUri(const QString &uri);
signals:
    void Seeked(qlonglong position);
private:
    Backend *m_backend;
    QString m_lastTrackPath;
};

class MprisService final : public QObject
{
    Q_OBJECT
public:
    explicit MprisService(Backend *backend, QObject *parent = nullptr);
    bool registered() const { return m_registered; }
private:
    void propertiesChanged(const QString &interface, const QVariantMap &changed);
    Backend *m_backend;
    bool m_registered = false;
};
