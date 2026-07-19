#include "linuxplayback.h"

#include <QMetaObject>
#include <algorithm>
#include <cmath>

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
    g_object_set(m_playbin, "volume", m_volume, nullptr);
    g_signal_connect(m_playbin, "about-to-finish", G_CALLBACK(handleAboutToFinish), this);
    m_pollTimer.setInterval(100);
    connect(&m_pollTimer, &QTimer::timeout, this, [this] {
        drainBus();
        updateQueries();
    });
    m_pollTimer.start();
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
    gst_element_set_state(m_playbin, GST_STATE_NULL);
    m_source = source;
    m_positionMs = 0;
    m_durationMs = 0;
    m_seekable = false;
    m_prerollSeekMs = std::max<qint64>(0, startPositionMs);
    m_confirmingSeekMs = -1;
    m_autoplayAfterPreroll = autoplay;
    m_loading = true;
    emit positionChanged();
    emit durationChanged();
    emit loadingChanged(true);
    const auto uri = source.toEncoded();
    g_object_set(m_playbin, "uri", uri.constData(), nullptr);
    gst_element_set_state(m_playbin, GST_STATE_PAUSED);
}

void LinuxPlayback::clearSource()
{
    if (!m_playbin) return;
    gst_element_set_state(m_playbin, GST_STATE_NULL);
    m_source = QUrl();
    m_positionMs = 0;
    m_durationMs = 0;
    m_seekable = false;
    m_loading = false;
    m_confirmingSeekMs = -1;
    updateState(GST_STATE_NULL);
    emit positionChanged();
    emit durationChanged();
    emit loadingChanged(false);
}

void LinuxPlayback::play()
{
    if (m_playbin && hasSource()) gst_element_set_state(m_playbin, GST_STATE_PLAYING);
}

void LinuxPlayback::pause()
{
    if (m_playbin && hasSource()) gst_element_set_state(m_playbin, GST_STATE_PAUSED);
}

void LinuxPlayback::stop()
{
    if (!m_playbin) return;
    gst_element_set_state(m_playbin, GST_STATE_READY);
    m_positionMs = 0;
    m_confirmingSeekMs = -1;
    updateState(GST_STATE_READY);
    emit positionChanged();
}

bool LinuxPlayback::seek(qint64 positionMs)
{
    if (!m_playbin || !hasSource() || !m_seekable) {
        emit seekFailed(positionMs, QStringLiteral("The current stream is not seekable"));
        return false;
    }
    const auto target = std::max<qint64>(0, positionMs);
    const auto accepted = gst_element_seek_simple(
        m_playbin,
        GST_FORMAT_TIME,
        static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT),
        target * GST_MSECOND);
    if (!accepted) {
        emit seekFailed(target, QStringLiteral("GStreamer rejected the seek"));
        return false;
    }
    m_confirmingSeekMs = target;
    return true;
}

void LinuxPlayback::setVolume(double volume)
{
    const auto next = std::clamp(volume, 0.0, 1.0);
    if (qFuzzyCompare(m_volume, next)) return;
    m_volume = next;
    if (m_playbin) g_object_set(m_playbin, "volume", m_volume, nullptr);
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
            m_loading = false;
            updateState(GST_STATE_NULL);
            emit loadingChanged(false);
            emit errorOccurred(text);
            break;
        }
        case GST_MESSAGE_EOS:
            updateState(GST_STATE_READY);
            emit endOfMedia();
            break;
        case GST_MESSAGE_ASYNC_DONE:
            if (GST_MESSAGE_SRC(message) == GST_OBJECT(m_playbin)) applyPrerollSeek();
            break;
        case GST_MESSAGE_STATE_CHANGED:
            if (GST_MESSAGE_SRC(message) == GST_OBJECT(m_playbin)) {
                GstState oldState;
                GstState newState;
                GstState pending;
                gst_message_parse_state_changed(message, &oldState, &newState, &pending);
                Q_UNUSED(oldState)
                Q_UNUSED(pending)
                updateState(newState);
            }
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

void LinuxPlayback::updateQueries()
{
    if (!m_playbin || !hasSource()) return;
    gint64 position = GST_CLOCK_TIME_NONE;
    if (gst_element_query_position(m_playbin, GST_FORMAT_TIME, &position)) {
        const auto nextPosition = clockTimeToMs(position);
        if (nextPosition != m_positionMs) {
            m_positionMs = nextPosition;
            emit positionChanged();
        }
        if (m_confirmingSeekMs >= 0 && std::abs(m_positionMs - m_confirmingSeekMs) <= 1500) {
            const auto confirmed = m_positionMs;
            m_confirmingSeekMs = -1;
            emit seekCompleted(confirmed);
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

void LinuxPlayback::updateState(GstState state)
{
    const auto next = state == GST_STATE_PLAYING
        ? State::Playing
        : state == GST_STATE_PAUSED ? State::Paused : State::Stopped;
    if (next == m_state) return;
    m_state = next;
    emit stateChanged();
}

void LinuxPlayback::applyPrerollSeek()
{
    updateQueries();
    if (m_prerollSeekMs > 0) {
        const auto target = m_prerollSeekMs;
        m_prerollSeekMs = 0;
        seek(target);
    }
    if (m_loading) {
        m_loading = false;
        emit loadingChanged(false);
    }
    const bool shouldAutoplay = m_autoplayAfterPreroll;
    m_autoplayAfterPreroll = false;
    if (shouldAutoplay) gst_element_set_state(m_playbin, GST_STATE_PLAYING);
}

void LinuxPlayback::handleAboutToFinish(GstElement *, gpointer userData)
{
    auto *self = static_cast<LinuxPlayback *>(userData);
    QMetaObject::invokeMethod(self, [self] { emit self->aboutToFinish(); }, Qt::QueuedConnection);
}
