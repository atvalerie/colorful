#include "linuxplayback.h"

#include <QMetaObject>
#include <algorithm>

namespace {
qint64 clockTimeToMs(gint64 value)
{
    return value < 0 || static_cast<GstClockTime>(value) == GST_CLOCK_TIME_NONE
        ? 0
        : value / GST_MSECOND;
}
}

LinuxPlayback::LinuxPlayback(QObject *parent)
    : QObject(parent)
{
    gst_init(nullptr, nullptr);
    m_playbin = gst_element_factory_make("playbin3", "colorful-player");
    if (!m_playbin) {
        QMetaObject::invokeMethod(this, [this] {
            emit errorOccurred(QStringLiteral("GStreamer playbin3 is not available"));
        }, Qt::QueuedConnection);
        return;
    }
    m_bus = gst_element_get_bus(m_playbin);
    // Keep playbin's output graph alive while the URI changes. This avoids
    // closing and reopening the PipeWire/Pulse stream between every track.
    g_object_set(m_playbin, "instant-uri", TRUE, nullptr);
    applyVolume();
    g_signal_connect(m_playbin, "about-to-finish", G_CALLBACK(handleAboutToFinish), this);
    m_pollTimer.setInterval(100);
    connect(&m_pollTimer, &QTimer::timeout, this, [this] {
        drainBus();
        updateQueries();
    });
    m_pollTimer.start();
    m_seekTimeout.setSingleShot(true);
    m_seekTimeout.setInterval(4000);
    connect(&m_seekTimeout, &QTimer::timeout, this, [this] {
        if (m_asyncOperation == AsyncOperation::None) return;
        const auto operation = m_asyncOperation;
        const auto target = m_confirmingSeekMs;
        m_asyncOperation = AsyncOperation::None;
        m_confirmingSeekMs = -1;
        m_queuedSeekMs = -1;
        if (operation == AsyncOperation::UserSeek || operation == AsyncOperation::SourceRestoreSeek)
            emit seekFailed(target, QStringLiteral("The pipeline did not confirm the seek"));
        finishLoading();
        applyDesiredState();
    });
}

LinuxPlayback::~LinuxPlayback()
{
    m_pollTimer.stop();
    if (m_playbin) gst_element_set_state(m_playbin, GST_STATE_NULL);
    if (m_bus) gst_object_unref(m_bus);
    if (m_playbin) gst_object_unref(m_playbin);
}

void LinuxPlayback::setSource(const QUrl &source, qint64 startPositionMs, bool autoplay)
{
    if (!m_playbin || !source.isValid() || source.isEmpty()) return;
    m_source = source;
    m_positionMs = 0;
    m_durationMs = 0;
    m_seekable = false;
    m_prerollSeekMs = std::max<qint64>(0, startPositionMs);
    m_confirmingSeekMs = -1;
    m_queuedSeekMs = -1;
    m_seekTimeout.stop();
    m_asyncOperation = AsyncOperation::SourcePreroll;
    m_loading = true;
    m_desiredState = autoplay ? State::Playing : State::Paused;
    setLogicalState(m_desiredState);
    emit positionChanged();
    emit durationChanged();
    emit loadingChanged(true);
    const auto uri = source.toEncoded();
    // With instant-uri enabled playbin3 replaces uridecodebin3 in place;
    // playsink and the selected audio sink remain allocated.
    g_object_set(m_playbin, "uri", uri.constData(), nullptr);
    gst_element_set_state(m_playbin, GST_STATE_PAUSED);
}

void LinuxPlayback::clearSource()
{
    if (!m_playbin) return;
    m_seekTimeout.stop();
    gst_element_set_state(m_playbin, GST_STATE_NULL);
    m_source = QUrl();
    m_positionMs = 0;
    m_durationMs = 0;
    m_seekable = false;
    m_loading = false;
    m_desiredState = State::Stopped;
    m_asyncOperation = AsyncOperation::None;
    m_confirmingSeekMs = -1;
    m_queuedSeekMs = -1;
    setLogicalState(State::Stopped);
    emit positionChanged();
    emit durationChanged();
    emit loadingChanged(false);
}

void LinuxPlayback::play()
{
    if (!m_playbin || !hasSource()) return;
    m_desiredState = State::Playing;
    setLogicalState(State::Playing);
    if (m_asyncOperation == AsyncOperation::None) applyDesiredState();
}

void LinuxPlayback::pause()
{
    if (!m_playbin || !hasSource() || m_desiredState != State::Playing) return;
    m_desiredState = State::Paused;
    setLogicalState(State::Paused);
    gst_element_set_state(m_playbin, GST_STATE_PAUSED);
}

void LinuxPlayback::stop()
{
    if (!m_playbin) return;
    m_desiredState = State::Stopped;
    setLogicalState(State::Stopped);
    m_confirmingSeekMs = -1;
    m_queuedSeekMs = -1;
    m_seekTimeout.stop();
    finishLoading();
    // A user-visible stop is logical only. Leave the pipeline paused so a
    // later play does not need to reconstruct the entire output graph.
    gst_element_set_state(m_playbin, GST_STATE_PAUSED);
    if (!performSeek(0, AsyncOperation::StopSeek)) {
        m_asyncOperation = AsyncOperation::None;
        m_positionMs = 0;
        emit positionChanged();
    }
}

bool LinuxPlayback::seek(qint64 positionMs)
{
    if (!m_playbin || !hasSource() || !m_seekable) {
        emit seekFailed(positionMs, QStringLiteral("The current stream is not seekable"));
        return false;
    }
    const auto target = std::max<qint64>(0, positionMs);
    if (m_asyncOperation != AsyncOperation::None) {
        m_queuedSeekMs = target;
        return true;
    }
    return performSeek(target, AsyncOperation::UserSeek);
}

void LinuxPlayback::setVolume(double volume)
{
    const auto next = std::clamp(volume, 0.0, 1.0);
    if (qFuzzyCompare(m_volume, next)) return;
    m_volume = next;
    applyVolume();
    emit volumeChanged();
}

void LinuxPlayback::drainBus()
{
    if (!m_bus) return;
    while (auto *message = gst_bus_pop(m_bus)) {
        switch (GST_MESSAGE_TYPE(message)) {
        case GST_MESSAGE_ERROR: {
            GError *error = nullptr;
            gchar *debug = nullptr;
            gst_message_parse_error(message, &error, &debug);
            const auto text = error ? QString::fromUtf8(error->message) : QStringLiteral("Unknown GStreamer error");
            if (error) g_error_free(error);
            if (debug) g_free(debug);
            m_seekTimeout.stop();
            m_asyncOperation = AsyncOperation::None;
            m_desiredState = State::Stopped;
            setLogicalState(State::Stopped);
            finishLoading();
            emit errorOccurred(text);
            break;
        }
        case GST_MESSAGE_EOS:
            // Keep the old presence and sink alive until Backend either swaps
            // in the next URI or performs an explicit logical stop.
            emit endOfMedia();
            break;
        case GST_MESSAGE_ASYNC_DONE:
            if (GST_MESSAGE_SRC(message) == GST_OBJECT(m_playbin)) handleAsyncDone();
            break;
        // PAUSED is also used internally for preroll and flushing seeks, so
        // state-changed messages deliberately do not alter user-visible state.
        case GST_MESSAGE_STATE_CHANGED:
            break;
        case GST_MESSAGE_DURATION_CHANGED:
            updateQueries();
            break;
        default:
            break;
        }
        gst_message_unref(message);
    }
}

void LinuxPlayback::updateQueries(bool allowWhileLoading)
{
    // During an in-place URI swap playbin can briefly still answer queries
    // from the outgoing decoder. Never leak that old timeline into the UI.
    if (!m_playbin || !hasSource() || (m_loading && !allowWhileLoading)) return;
    gint64 position = GST_CLOCK_TIME_NONE;
    if (gst_element_query_position(m_playbin, GST_FORMAT_TIME, &position)) {
        const auto nextPosition = clockTimeToMs(position);
        if (nextPosition != m_positionMs) {
            m_positionMs = nextPosition;
            emit positionChanged();
        }
    }
    gint64 duration = GST_CLOCK_TIME_NONE;
    if (gst_element_query_duration(m_playbin, GST_FORMAT_TIME, &duration)) {
        const auto nextDuration = clockTimeToMs(duration);
        if (nextDuration > 0 && nextDuration != m_durationMs) {
            m_durationMs = nextDuration;
            emit durationChanged();
        }
    }
    GstQuery *query = gst_query_new_seeking(GST_FORMAT_TIME);
    if (gst_element_query(m_playbin, query)) {
        GstFormat format;
        gboolean seekable;
        gint64 start;
        gint64 end;
        gst_query_parse_seeking(query, &format, &seekable, &start, &end);
        Q_UNUSED(format)
        Q_UNUSED(start)
        Q_UNUSED(end)
        m_seekable = seekable;
    }
    gst_query_unref(query);
}

void LinuxPlayback::setLogicalState(State state)
{
    if (state == m_state) return;
    m_state = state;
    emit stateChanged();
}

void LinuxPlayback::handleAsyncDone()
{
    if (m_asyncOperation == AsyncOperation::None) return;
    const auto completedOperation = m_asyncOperation;
    const auto completedTarget = m_confirmingSeekMs;
    m_asyncOperation = AsyncOperation::None;
    m_confirmingSeekMs = -1;
    m_seekTimeout.stop();
    updateQueries(true);

    if (completedOperation == AsyncOperation::SourcePreroll && m_prerollSeekMs > 0) {
        const auto target = m_prerollSeekMs;
        m_prerollSeekMs = 0;
        performSeek(target, AsyncOperation::SourceRestoreSeek);
        return;
    }

    if (completedOperation == AsyncOperation::StopSeek) {
        m_positionMs = 0;
        emit positionChanged();
    }

    if (m_queuedSeekMs >= 0 && m_desiredState != State::Stopped) {
        const auto target = m_queuedSeekMs;
        m_queuedSeekMs = -1;
        performSeek(target, AsyncOperation::UserSeek);
        return;
    }

    if (completedOperation == AsyncOperation::UserSeek
        || completedOperation == AsyncOperation::SourceRestoreSeek) {
        const auto confirmed = m_positionMs >= 0 ? m_positionMs : completedTarget;
        emit seekCompleted(confirmed);
    }

    finishLoading();
    applyDesiredState();
}

bool LinuxPlayback::performSeek(qint64 positionMs, AsyncOperation operation)
{
    const auto accepted = gst_element_seek_simple(
        m_playbin,
        GST_FORMAT_TIME,
        static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT),
        positionMs * GST_MSECOND);
    if (!accepted) {
        if (operation == AsyncOperation::UserSeek || operation == AsyncOperation::SourceRestoreSeek)
            emit seekFailed(positionMs, QStringLiteral("GStreamer rejected the seek"));
        finishLoading();
        applyDesiredState();
        return false;
    }
    m_asyncOperation = operation;
    m_confirmingSeekMs = positionMs;
    m_seekTimeout.start();
    return true;
}

void LinuxPlayback::applyDesiredState()
{
    if (!m_playbin || !hasSource()) return;
    gst_element_set_state(m_playbin,
                          m_desiredState == State::Playing ? GST_STATE_PLAYING : GST_STATE_PAUSED);
}

void LinuxPlayback::finishLoading()
{
    if (!m_loading) return;
    m_loading = false;
    emit loadingChanged(false);
}

void LinuxPlayback::applyVolume()
{
    if (m_playbin) g_object_set(m_playbin, "volume", m_volume, nullptr);
}

void LinuxPlayback::handleAboutToFinish(GstElement *, gpointer userData)
{
    auto *self = static_cast<LinuxPlayback *>(userData);
    QMetaObject::invokeMethod(self, [self] { emit self->aboutToFinish(); }, Qt::QueuedConnection);
}
