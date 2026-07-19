#include "linuxplayback.h"

#include <QMetaObject>
#include <algorithm>
#include <cmath>

namespace {
constexpr quint64 PositionProperty = 1;
constexpr quint64 DurationProperty = 2;
constexpr quint64 SeekableProperty = 3;

QString mpvError(int error)
{
    return QString::fromUtf8(mpv_error_string(error));
}
}

LinuxPlayback::LinuxPlayback(QObject *parent)
    : QObject(parent)
{
    m_mpv = mpv_create();
    if (!m_mpv) {
        QMetaObject::invokeMethod(this, [this] {
            emit errorOccurred(QStringLiteral("Could not create the libmpv playback engine"));
        }, Qt::QueuedConnection);
        return;
    }

    mpv_set_option_string(m_mpv, "terminal", "no");
    mpv_set_option_string(m_mpv, "input-default-bindings", "no");
    mpv_set_option_string(m_mpv, "input-vo-keyboard", "no");
    mpv_set_option_string(m_mpv, "video", "no");
    mpv_set_option_string(m_mpv, "audio-display", "no");
    mpv_set_option_string(m_mpv, "ytdl", "no");
    mpv_set_option_string(m_mpv, "cache", "yes");
    // Keep the audio output and decoder transition inside libmpv. With one
    // upcoming URI in its playlist, libmpv can prefetch network data and
    // switch tracks without colorful replacing the active file at EOF.
    mpv_set_option_string(m_mpv, "gapless-audio", "yes");
    mpv_set_option_string(m_mpv, "prefetch-playlist", "yes");
    const auto initialVolume = QByteArray::number(m_volume * 100.0, 'f', 2);
    mpv_set_option_string(m_mpv, "volume", initialVolume.constData());

    const auto initialized = mpv_initialize(m_mpv);
    if (initialized < 0) {
        const auto message = QStringLiteral("Could not initialize libmpv: %1").arg(mpvError(initialized));
        mpv_terminate_destroy(m_mpv);
        m_mpv = nullptr;
        QMetaObject::invokeMethod(this, [this, message] { emit errorOccurred(message); }, Qt::QueuedConnection);
        return;
    }

    mpv_observe_property(m_mpv, PositionProperty, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, DurationProperty, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, SeekableProperty, "seekable", MPV_FORMAT_FLAG);
    mpv_set_wakeup_callback(m_mpv, handleWakeup, this);
}

LinuxPlayback::~LinuxPlayback()
{
    if (!m_mpv) return;
    mpv_set_wakeup_callback(m_mpv, nullptr, nullptr);
    mpv_terminate_destroy(m_mpv);
}

void LinuxPlayback::setSource(const QUrl &source, qint64 startPositionMs, bool autoplay)
{
    if (!m_mpv || !source.isValid() || source.isEmpty()) return;
    setSeekSilence(false);
    m_source = source;
    m_preparedSource = QUrl();
    m_prepareRequestId = 0;
    m_currentWasPrepared = false;
    m_positionMs = std::max<qint64>(0, startPositionMs);
    m_durationMs = 0;
    m_seekable = false;
    m_confirmingSeekMs = -1;
    m_queuedSeekMs = -1;
    m_desiredState = autoplay ? State::Playing : State::Paused;
    setLogicalState(m_desiredState);
    if (!m_loading) {
        m_loading = true;
        emit loadingChanged(true);
    }
    emit positionChanged();
    emit durationChanged();

    const auto uri = source.toEncoded();
    const auto options = QStringLiteral("pause=yes,start=%1")
        .arg(m_positionMs / 1000.0, 0, 'f', 3).toUtf8();
    const char *arguments[] = {"loadfile", uri.constData(), "replace", "-1", options.constData(), nullptr};
    m_loadRequestId = m_nextRequestId++;
    command(arguments, m_loadRequestId);
}

void LinuxPlayback::prepareNextSource(const QUrl &source)
{
    if (!m_mpv || !hasSource() || !source.isValid() || source.isEmpty()) return;
    if (m_preparedSource == source) return;

    clearPreparedNext();
    m_preparedSource = source;
    const auto uri = source.toEncoded();
    const char *arguments[] = {"loadfile", uri.constData(), "append", nullptr};
    m_prepareRequestId = m_nextRequestId++;
    command(arguments, m_prepareRequestId);
}

void LinuxPlayback::clearPreparedNext()
{
    if (!m_mpv || m_preparedSource.isEmpty()) return;
    m_preparedSource = QUrl();
    m_prepareRequestId = 0;
    const char *arguments[] = {"playlist-clear", nullptr};
    command(arguments);
}

bool LinuxPlayback::playPreparedNext(bool autoplay)
{
    if (!m_mpv || m_preparedSource.isEmpty()) return false;
    m_desiredState = autoplay ? State::Playing : State::Paused;
    setLogicalState(m_desiredState);
    promotePreparedSource(false);
    const char *arguments[] = {"playlist-next", "force", nullptr};
    command(arguments);
    return true;
}

void LinuxPlayback::clearSource()
{
    if (!m_mpv) return;
    setSeekSilence(false);
    const char *arguments[] = {"stop", nullptr};
    command(arguments);
    m_source = QUrl();
    m_preparedSource = QUrl();
    m_prepareRequestId = 0;
    m_currentWasPrepared = false;
    m_positionMs = 0;
    m_durationMs = 0;
    m_seekable = false;
    m_confirmingSeekMs = -1;
    m_queuedSeekMs = -1;
    m_desiredState = State::Stopped;
    setLogicalState(State::Stopped);
    finishLoading();
    emit positionChanged();
    emit durationChanged();
}

void LinuxPlayback::play()
{
    if (!m_mpv || !hasSource()) return;
    m_desiredState = State::Playing;
    setLogicalState(State::Playing);
    setPauseProperty(false);
}

void LinuxPlayback::pause()
{
    if (!m_mpv || !hasSource() || m_desiredState != State::Playing) return;
    m_desiredState = State::Paused;
    setLogicalState(State::Paused);
    setPauseProperty(true);
}

void LinuxPlayback::stop()
{
    if (!m_mpv || !hasSource()) return;
    setSeekSilence(false);
    m_desiredState = State::Stopped;
    setLogicalState(State::Stopped);
    setPauseProperty(true);
    m_confirmingSeekMs = -1;
    m_queuedSeekMs = -1;
    const char *arguments[] = {"seek", "0", "absolute+exact", nullptr};
    command(arguments);
    m_positionMs = 0;
    finishLoading();
    emit positionChanged();
}

bool LinuxPlayback::seek(qint64 positionMs)
{
    if (!m_mpv || !hasSource()) {
        emit seekFailed(positionMs, QStringLiteral("There is no active playback source"));
        return false;
    }
    // The backend already clamps against catalog duration. libmpv's duration
    // and seekable properties can briefly describe a prefetched playlist item
    // instead of the active DASH stream, so they must not veto or truncate a
    // valid user seek here. The asynchronous command reply remains the source
    // of truth for actual seek failures.
    const auto target = std::max<qint64>(0, positionMs);
    if (m_confirmingSeekMs >= 0) {
        m_queuedSeekMs = target;
        return true;
    }
    return performSeek(target);
}

bool LinuxPlayback::performSeek(qint64 target)
{
    // An uncached adaptive-stream seek can temporarily starve and restart the
    // audio output. Keep that single transition continuous with silence; this
    // is deliberately disabled again as soon as playback restarts.
    setSeekSilence(true);
    const auto seconds = QByteArray::number(target / 1000.0, 'f', 3);
    const char *arguments[] = {"seek", seconds.constData(), "absolute+exact", nullptr};
    m_confirmingSeekMs = target;
    m_seekRequestId = m_nextRequestId++;
    command(arguments, m_seekRequestId);
    return true;
}

void LinuxPlayback::setVolume(double volume)
{
    const auto next = std::clamp(volume, 0.0, 1.0);
    if (qFuzzyCompare(m_volume, next)) return;
    m_volume = next;
    if (m_mpv) {
        double mpvVolume = m_volume * 100.0;
        mpv_set_property_async(m_mpv, 0, "volume", MPV_FORMAT_DOUBLE, &mpvVolume);
    }
    emit volumeChanged();
}

void LinuxPlayback::drainEvents()
{
    if (!m_mpv) return;
    for (;;) {
        auto *event = mpv_wait_event(m_mpv, 0);
        if (!event || event->event_id == MPV_EVENT_NONE) break;
        switch (event->event_id) {
        case MPV_EVENT_PROPERTY_CHANGE:
            if (event->data)
                handleProperty(event->reply_userdata, *static_cast<mpv_event_property *>(event->data));
            break;
        case MPV_EVENT_FILE_LOADED:
            setPauseProperty(m_desiredState != State::Playing);
            finishLoading();
            break;
        case MPV_EVENT_PLAYBACK_RESTART:
            if (m_confirmingSeekMs >= 0) {
                if (m_queuedSeekMs >= 0) {
                    const auto target = m_queuedSeekMs;
                    m_queuedSeekMs = -1;
                    m_confirmingSeekMs = -1;
                    performSeek(target);
                    break;
                }
                const auto confirmed = m_confirmingSeekMs;
                m_confirmingSeekMs = -1;
                setSeekSilence(false);
                emit seekCompleted(confirmed);
            }
            finishLoading();
            break;
        case MPV_EVENT_COMMAND_REPLY:
            if (event->error >= 0) break;
            if (event->reply_userdata == m_seekRequestId && m_confirmingSeekMs >= 0) {
                const auto target = m_confirmingSeekMs;
                m_confirmingSeekMs = -1;
                setSeekSilence(false);
                emit seekFailed(target, mpvError(event->error));
                if (m_queuedSeekMs >= 0) {
                    const auto queued = m_queuedSeekMs;
                    m_queuedSeekMs = -1;
                    performSeek(queued);
                }
            } else if (event->reply_userdata == m_loadRequestId) {
                finishLoading();
                emit errorOccurred(QStringLiteral("libmpv could not load the stream: %1").arg(mpvError(event->error)));
            } else if (event->reply_userdata == m_prepareRequestId) {
                m_preparedSource = QUrl();
                m_prepareRequestId = 0;
                emit preparedNextFailed(mpvError(event->error));
            }
            break;
        case MPV_EVENT_END_FILE: {
            setSeekSilence(false);
            const auto *end = static_cast<mpv_event_end_file *>(event->data);
            if (end && end->reason == MPV_END_FILE_REASON_EOF) {
                if (!m_preparedSource.isEmpty()) promotePreparedSource(true);
                else emit endOfMedia();
            }
            else if (end && end->reason == MPV_END_FILE_REASON_ERROR) {
                finishLoading();
                const auto message = mpvError(end->error);
                if (m_currentWasPrepared) {
                    m_currentWasPrepared = false;
                    emit preparedPlaybackFailed(message);
                } else {
                    emit errorOccurred(QStringLiteral("libmpv playback failed: %1").arg(message));
                }
            }
            break;
        }
        default:
            break;
        }
    }
}

void LinuxPlayback::handleProperty(quint64 propertyId, const mpv_event_property &property)
{
    if (!property.data) return;
    if (propertyId == PositionProperty && property.format == MPV_FORMAT_DOUBLE) {
        const auto next = qRound64(*static_cast<double *>(property.data) * 1000.0);
        if (next != m_positionMs) {
            m_positionMs = std::max<qint64>(0, next);
            emit positionChanged();
        }
    } else if (propertyId == DurationProperty && property.format == MPV_FORMAT_DOUBLE) {
        const auto next = qRound64(*static_cast<double *>(property.data) * 1000.0);
        if (next > 0 && next != m_durationMs) {
            m_durationMs = next;
            emit durationChanged();
        }
    } else if (propertyId == SeekableProperty && property.format == MPV_FORMAT_FLAG) {
        m_seekable = *static_cast<int *>(property.data) != 0;
    }
}

void LinuxPlayback::setSeekSilence(bool enabled)
{
    if (!m_mpv || m_seekSilenceActive == enabled) return;
    m_seekSilenceActive = enabled;
    int value = enabled ? 1 : 0;
    mpv_set_property_async(m_mpv, 0, "audio-stream-silence", MPV_FORMAT_FLAG, &value);
}

void LinuxPlayback::setPauseProperty(bool paused)
{
    if (!m_mpv) return;
    int value = paused ? 1 : 0;
    mpv_set_property_async(m_mpv, 0, "pause", MPV_FORMAT_FLAG, &value);
}

void LinuxPlayback::setLogicalState(State state)
{
    if (m_state == state) return;
    m_state = state;
    emit stateChanged();
}

void LinuxPlayback::promotePreparedSource(bool notifyOwner)
{
    if (m_preparedSource.isEmpty()) return;
    m_source = m_preparedSource;
    m_preparedSource = QUrl();
    m_prepareRequestId = 0;
    m_currentWasPrepared = true;
    m_positionMs = 0;
    m_durationMs = 0;
    m_seekable = false;
    m_confirmingSeekMs = -1;
    m_queuedSeekMs = -1;
    if (!m_loading) {
        m_loading = true;
        emit loadingChanged(true);
    }
    emit positionChanged();
    emit durationChanged();
    if (notifyOwner) emit preparedNextStarted();
}

void LinuxPlayback::finishLoading()
{
    if (!m_loading) return;
    m_loading = false;
    emit loadingChanged(false);
}

void LinuxPlayback::command(const char *arguments[], quint64 requestId)
{
    if (!m_mpv) return;
    const auto result = mpv_command_async(m_mpv, requestId, arguments);
    if (result < 0) emit errorOccurred(QStringLiteral("libmpv command failed: %1").arg(mpvError(result)));
}

void LinuxPlayback::handleWakeup(void *userData)
{
    auto *self = static_cast<LinuxPlayback *>(userData);
    QMetaObject::invokeMethod(self, [self] { self->drainEvents(); }, Qt::QueuedConnection);
}
