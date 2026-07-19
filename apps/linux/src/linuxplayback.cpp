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
    if (!createPersistentOutput()) {
        QMetaObject::invokeMethod(this, [this] {
            emit errorOccurred(QStringLiteral("Could not create the persistent audio output"));
        }, Qt::QueuedConnection);
    }
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
    m_fadeTimer.setInterval(5);
    connect(&m_fadeTimer, &QTimer::timeout, this, [this] {
        ++m_fadeStep;
        const auto progress = std::min(1.0, m_fadeStep / static_cast<double>(m_fadeSteps));
        m_transitionGain = m_fadeStart + (m_fadeTarget - m_fadeStart) * progress;
        applyVolume();
        if (progress < 1.0) return;
        m_fadeTimer.stop();
        auto completion = std::move(m_fadeCompletion);
        m_fadeCompletion = {};
        if (completion) completion();
    });
    m_seekTimeout.setSingleShot(true);
    m_seekTimeout.setInterval(4000);
    connect(&m_seekTimeout, &QTimer::timeout, this, [this] {
        if (m_confirmingSeekMs < 0) return;
        const auto target = m_confirmingSeekMs;
        m_confirmingSeekMs = -1;
        emit seekFailed(target, QStringLiteral("The pipeline did not confirm the seek"));
        if (m_resumeAfterConfirmedSeek) {
            m_resumeAfterConfirmedSeek = false;
            gst_element_set_state(m_playbin, GST_STATE_PLAYING);
            fadeTo(1, 45);
        }
    });
}

LinuxPlayback::~LinuxPlayback()
{
    m_pollTimer.stop();
    if (m_playbin) gst_element_set_state(m_playbin, GST_STATE_NULL);
    if (m_outputPipeline) gst_element_set_state(m_outputPipeline, GST_STATE_NULL);
    if (m_bus) gst_object_unref(m_bus);
    if (m_playbin) gst_object_unref(m_playbin);
    if (m_outputPipeline) gst_object_unref(m_outputPipeline);
}

void LinuxPlayback::setSource(const QUrl &source, qint64 startPositionMs, bool autoplay)
{
    if (!m_playbin || !source.isValid() || source.isEmpty()) return;
    const auto generation = ++m_sourceGeneration;
    const auto load = [this, generation, source, startPositionMs, autoplay] {
        if (generation != m_sourceGeneration) return;
        m_transitionGain = 0;
        applyVolume();
        m_logicallyStopped = false;
        m_source = source;
        m_positionMs = 0;
        m_durationMs = 0;
        m_seekable = false;
        m_prerollSeekMs = std::max<qint64>(0, startPositionMs);
        m_confirmingSeekMs = -1;
        m_seekTimeout.stop();
        m_autoplayAfterPreroll = autoplay;
        m_resumeAfterConfirmedSeek = false;
        m_loading = true;
        emit positionChanged();
        emit durationChanged();
        emit loadingChanged(true);
        const auto uri = source.toEncoded();
        // With instant-uri enabled playbin3 replaces uridecodebin3 in place;
        // playsink and the selected audio sink remain allocated.
        g_object_set(m_playbin, "uri", uri.constData(), nullptr);
        gst_element_set_state(m_playbin, GST_STATE_PAUSED);
    };
    if (hasSource() && m_state != State::Stopped && m_transitionGain > 0) fadeTo(0, 35, load);
    else load();
}

void LinuxPlayback::clearSource()
{
    if (!m_playbin) return;
    ++m_sourceGeneration;
    m_fadeTimer.stop();
    m_fadeCompletion = {};
    gst_element_set_state(m_playbin, GST_STATE_NULL);
    m_source = QUrl();
    m_positionMs = 0;
    m_durationMs = 0;
    m_seekable = false;
    m_loading = false;
    m_logicallyStopped = true;
    m_confirmingSeekMs = -1;
    m_seekTimeout.stop();
    m_transitionGain = 1;
    applyVolume();
    updateState(GST_STATE_NULL);
    emit positionChanged();
    emit durationChanged();
    emit loadingChanged(false);
}

void LinuxPlayback::play()
{
    if (!m_playbin || !hasSource()) return;
    m_logicallyStopped = false;
    gst_element_set_state(m_playbin, GST_STATE_PLAYING);
    fadeTo(1, 45);
}

void LinuxPlayback::pause()
{
    if (!m_playbin || !hasSource() || m_state != State::Playing) return;
    const auto generation = m_sourceGeneration;
    fadeTo(0, 35, [this, generation] {
        if (generation == m_sourceGeneration) gst_element_set_state(m_playbin, GST_STATE_PAUSED);
    });
}

void LinuxPlayback::stop()
{
    if (!m_playbin) return;
    const auto generation = ++m_sourceGeneration;
    m_confirmingSeekMs = -1;
    m_seekTimeout.stop();
    fadeTo(0, 35, [this, generation] {
        if (generation != m_sourceGeneration) return;
        // A user-visible stop is logical only. Leave the pipeline paused so
        // the platform audio sink is not destroyed and recreated on resume.
        gst_element_set_state(m_playbin, GST_STATE_PAUSED);
        gst_element_seek_simple(
            m_playbin,
            GST_FORMAT_TIME,
            static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT),
            0);
        m_logicallyStopped = true;
        m_positionMs = 0;
        if (m_state != State::Stopped) {
            m_state = State::Stopped;
            emit stateChanged();
        }
        emit positionChanged();
    });
}

bool LinuxPlayback::seek(qint64 positionMs)
{
    if (!m_playbin || !hasSource() || !m_seekable) {
        emit seekFailed(positionMs, QStringLiteral("The current stream is not seekable"));
        return false;
    }
    const auto target = std::max<qint64>(0, positionMs);
    const bool resume = playing();
    const auto generation = m_sourceGeneration;
    fadeTo(0, 30, [this, generation, target, resume] {
        if (generation == m_sourceGeneration) performSeek(target, resume);
    });
    return true;
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
            m_loading = false;
            updateState(GST_STATE_NULL);
            emit loadingChanged(false);
            emit errorOccurred(text);
            break;
        }
        case GST_MESSAGE_EOS:
            // Keep the old presence and sink alive until Backend either swaps
            // in the next URI or performs an explicit logical stop.
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
        if (m_confirmingSeekMs >= 0 && std::abs(m_positionMs - m_confirmingSeekMs) <= 1500) {
            const auto confirmed = m_positionMs;
            m_confirmingSeekMs = -1;
            m_seekTimeout.stop();
            emit seekCompleted(confirmed);
            if (m_resumeAfterConfirmedSeek) {
                m_resumeAfterConfirmedSeek = false;
                gst_element_set_state(m_playbin, GST_STATE_PLAYING);
                fadeTo(1, 45);
            }
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
    // PAUSED is used internally for URI preroll and flushing seeks. Preserve
    // the user-visible state so MPRIS/Discord never report a fake pause.
    if ((m_loading || m_confirmingSeekMs >= 0) && state != GST_STATE_PLAYING) return;
    const auto next = m_logicallyStopped
        ? State::Stopped
        : state == GST_STATE_PLAYING
        ? State::Playing
        : state == GST_STATE_PAUSED ? State::Paused : State::Stopped;
    if (next == m_state) return;
    m_state = next;
    emit stateChanged();
}

void LinuxPlayback::applyPrerollSeek()
{
    updateQueries(true);
    if (m_prerollSeekMs > 0) {
        const auto target = m_prerollSeekMs;
        m_prerollSeekMs = 0;
        const bool shouldAutoplay = m_autoplayAfterPreroll;
        m_autoplayAfterPreroll = false;
        performSeek(target, shouldAutoplay);
    } else {
        const bool shouldAutoplay = m_autoplayAfterPreroll;
        m_autoplayAfterPreroll = false;
        if (shouldAutoplay) {
            gst_element_set_state(m_playbin, GST_STATE_PLAYING);
            fadeTo(1, 45);
        }
    }
    if (m_loading) {
        m_loading = false;
        emit loadingChanged(false);
    }
}

bool LinuxPlayback::performSeek(qint64 positionMs, bool resumeAfterConfirmation)
{
    const auto accepted = gst_element_seek_simple(
        m_playbin,
        GST_FORMAT_TIME,
        static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT),
        positionMs * GST_MSECOND);
    if (!accepted) {
        emit seekFailed(positionMs, QStringLiteral("GStreamer rejected the seek"));
        if (resumeAfterConfirmation) fadeTo(1, 45);
        return false;
    }
    m_confirmingSeekMs = positionMs;
    m_resumeAfterConfirmedSeek = resumeAfterConfirmation;
    m_seekTimeout.start();
    return true;
}

void LinuxPlayback::fadeTo(double target, int durationMs, std::function<void()> completion)
{
    m_fadeTimer.stop();
    m_fadeStart = m_transitionGain;
    m_fadeTarget = std::clamp(target, 0.0, 1.0);
    m_fadeStep = 0;
    m_fadeSteps = std::max(1, durationMs / m_fadeTimer.interval());
    m_fadeCompletion = std::move(completion);
    if (qFuzzyCompare(m_fadeStart, m_fadeTarget)) {
        auto immediate = std::move(m_fadeCompletion);
        m_fadeCompletion = {};
        if (immediate) immediate();
        return;
    }
    m_fadeTimer.start();
}

void LinuxPlayback::applyVolume()
{
    if (m_playbin) g_object_set(m_playbin, "volume", m_volume * m_transitionGain, nullptr);
}

bool LinuxPlayback::createPersistentOutput()
{
    // playbin may pause or flush while seeking. Route it through an internal
    // channel so the real platform sink belongs to a second pipeline which
    // continuously runs (and supplies silence during an underrun). This keeps
    // PipeWire/Pulse and the physical device awake without advancing playback.
    auto *bridgeSink = gst_element_factory_make("interaudiosink", "colorful-audio-bridge");
    if (!bridgeSink) return false;
    g_object_set(bridgeSink,
                 "channel", "colorful-output",
                 "sync", TRUE,
                 nullptr);
    g_object_set(m_playbin, "audio-sink", bridgeSink, nullptr);
    gst_object_unref(bridgeSink);

    GError *error = nullptr;
    m_outputPipeline = gst_parse_launch(
        "interaudiosrc channel=colorful-output automatic-eos=false "
        "buffer-time=100000000 latency-time=20000000 period-time=10000000 ! "
        "audioconvert ! audioresample ! autoaudiosink",
        &error);
    if (error) {
        g_error_free(error);
        if (m_outputPipeline) {
            gst_object_unref(m_outputPipeline);
            m_outputPipeline = nullptr;
        }
        g_object_set(m_playbin, "audio-sink", nullptr, nullptr);
        return false;
    }
    if (!m_outputPipeline) {
        g_object_set(m_playbin, "audio-sink", nullptr, nullptr);
        return false;
    }
    if (gst_element_set_state(m_outputPipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        gst_object_unref(m_outputPipeline);
        m_outputPipeline = nullptr;
        g_object_set(m_playbin, "audio-sink", nullptr, nullptr);
        return false;
    }
    return true;
}

void LinuxPlayback::handleAboutToFinish(GstElement *, gpointer userData)
{
    auto *self = static_cast<LinuxPlayback *>(userData);
    QMetaObject::invokeMethod(self, [self] { emit self->aboutToFinish(); }, Qt::QueuedConnection);
}
