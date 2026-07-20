#include "mpris.h"
#include "backend.h"

#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QUrl>

MprisRootAdaptor::MprisRootAdaptor(Backend *backend)
    : QDBusAbstractAdaptor(backend), m_backend(backend) {}

void MprisRootAdaptor::Raise() { emit m_backend->raiseRequested(); }
void MprisRootAdaptor::Quit() { emit m_backend->quitRequested(); }

MprisPlayerAdaptor::MprisPlayerAdaptor(Backend *backend)
    : QDBusAbstractAdaptor(backend), m_backend(backend)
{
    m_lastTrackPath = metadata().value(QStringLiteral("mpris:trackid")).value<QDBusObjectPath>().path();
    connect(backend, &Backend::seeked, this, [this](qint64 positionMs) { emit Seeked(positionMs * 1000); });
    connect(backend, &Backend::currentTrackChanged, this, [this] {
        const auto trackPath = metadata().value(QStringLiteral("mpris:trackid")).value<QDBusObjectPath>().path();
        if (trackPath == m_lastTrackPath) return;
        m_lastTrackPath = trackPath;
        emit Seeked(m_backend->position() * 1000);
    });
}

QString MprisPlayerAdaptor::playbackStatus() const { return m_backend->playbackStatus(); }
QVariantMap MprisPlayerAdaptor::metadata() const { return m_backend->mprisMetadata(); }
double MprisPlayerAdaptor::volume() const { return m_backend->volume(); }
void MprisPlayerAdaptor::setVolume(double value) { m_backend->setVolume(value); }
QString MprisPlayerAdaptor::loopStatus() const
{
    if (m_backend->repeatMode() == QStringLiteral("one")) return QStringLiteral("Track");
    if (m_backend->repeatMode() == QStringLiteral("all")) return QStringLiteral("Playlist");
    return QStringLiteral("None");
}
void MprisPlayerAdaptor::setLoopStatus(const QString &value)
{
    m_backend->setRepeatMode(value == QStringLiteral("Track") ? QStringLiteral("one")
                             : value == QStringLiteral("Playlist") ? QStringLiteral("all")
                                                                    : QStringLiteral("off"));
}
bool MprisPlayerAdaptor::shuffle() const { return m_backend->shuffleEnabled(); }
void MprisPlayerAdaptor::setShuffle(bool value) { m_backend->setShuffleEnabled(value); }
qlonglong MprisPlayerAdaptor::position() const { return m_backend->position() * 1000; }
bool MprisPlayerAdaptor::canGoNext() const { return m_backend->canGoNext(); }
bool MprisPlayerAdaptor::canGoPrevious() const { return m_backend->canGoPrevious(); }
void MprisPlayerAdaptor::Next() { m_backend->next(); }
void MprisPlayerAdaptor::Previous() { m_backend->previous(); }
void MprisPlayerAdaptor::Pause() { m_backend->pause(); }
void MprisPlayerAdaptor::PlayPause() { m_backend->togglePlay(); }
void MprisPlayerAdaptor::Stop() { m_backend->stop(); }
void MprisPlayerAdaptor::Play() { m_backend->play(); }
void MprisPlayerAdaptor::Seek(qlonglong offset) { m_backend->seekBy(offset / 1000); }
void MprisPlayerAdaptor::SetPosition(const QDBusObjectPath &, qlonglong position) { m_backend->seek(position / 1000); }
void MprisPlayerAdaptor::OpenUri(const QString &) {}

MprisService::MprisService(Backend *backend, QObject *parent)
    : QObject(parent), m_backend(backend)
{
    new MprisRootAdaptor(backend);
    new MprisPlayerAdaptor(backend);
    auto connection = QDBusConnection::sessionBus();
    m_registered = connection.registerService(QStringLiteral("org.mpris.MediaPlayer2.colorful"))
        && connection.registerObject(QStringLiteral("/org/mpris/MediaPlayer2"), backend, QDBusConnection::ExportAdaptors);

    connect(backend, &Backend::playbackChanged, this, [this] {
        propertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"), {{QStringLiteral("PlaybackStatus"), m_backend->playbackStatus()}});
    });
    connect(backend, &Backend::currentTrackChanged, this, [this] {
        propertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"), {
            {QStringLiteral("Metadata"), m_backend->mprisMetadata()},
            {QStringLiteral("CanGoNext"), m_backend->canGoNext()},
            {QStringLiteral("CanGoPrevious"), m_backend->canGoPrevious()},
        });
    });
    connect(backend, &Backend::queueChanged, this, [this] {
        propertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"), {
            {QStringLiteral("CanGoNext"), m_backend->canGoNext()},
            {QStringLiteral("CanGoPrevious"), m_backend->canGoPrevious()},
        });
    });
    connect(backend, &Backend::volumeChanged, this, [this] {
        propertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"), {{QStringLiteral("Volume"), m_backend->volume()}});
    });
    connect(backend, &Backend::playbackOptionsChanged, this, [this] {
        const auto loop = m_backend->repeatMode() == QStringLiteral("one") ? QStringLiteral("Track")
            : m_backend->repeatMode() == QStringLiteral("all") ? QStringLiteral("Playlist")
                                                                : QStringLiteral("None");
        propertiesChanged(QStringLiteral("org.mpris.MediaPlayer2.Player"), {
            {QStringLiteral("LoopStatus"), loop},
            {QStringLiteral("Shuffle"), m_backend->shuffleEnabled()},
        });
    });
}

void MprisService::propertiesChanged(const QString &interface, const QVariantMap &changed)
{
    if (!m_registered) return;
    auto message = QDBusMessage::createSignal(
        QStringLiteral("/org/mpris/MediaPlayer2"),
        QStringLiteral("org.freedesktop.DBus.Properties"),
        QStringLiteral("PropertiesChanged"));
    message << interface << changed << QStringList{};
    QDBusConnection::sessionBus().send(message);
}
