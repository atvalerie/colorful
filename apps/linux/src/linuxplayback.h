#pragma once

#include <QObject>
#include <QTimer>
#include <QUrl>
#include <gst/gst.h>
#include <functional>

class LinuxPlayback final : public QObject
{
    Q_OBJECT

public:
    enum class State { Stopped, Paused, Playing };

    explicit LinuxPlayback(QObject *parent = nullptr);
    ~LinuxPlayback() override;

    bool isAvailable() const { return m_playbin != nullptr; }
    bool hasSource() const { return !m_source.isEmpty(); }
    bool playing() const { return m_state == State::Playing; }
    State state() const { return m_state; }
    qint64 position() const { return m_positionMs; }
    qint64 duration() const { return m_durationMs; }
    double volume() const { return m_volume; }
    bool seekable() const { return m_seekable; }

    void setSource(const QUrl &source, qint64 startPositionMs, bool autoplay);
    void clearSource();
    void play();
    void pause();
    void stop();
    bool seek(qint64 positionMs);
    void setVolume(double volume);

signals:
    void stateChanged();
    void positionChanged();
    void durationChanged();
    void volumeChanged();
    void loadingChanged(bool loading);
    void seekCompleted(qint64 positionMs);
    void seekFailed(qint64 positionMs, const QString &reason);
    void errorOccurred(const QString &message);
    void endOfMedia();
    void aboutToFinish();

private:
    void drainBus();
    void updateQueries(bool allowWhileLoading = false);
    void updateState(GstState state);
    void applyPrerollSeek();
    bool performSeek(qint64 positionMs, bool resumeAfterConfirmation);
    void fadeTo(double target, int durationMs, std::function<void()> completion = {});
    void applyVolume();
    static void handleAboutToFinish(GstElement *, gpointer userData);

    GstElement *m_playbin = nullptr;
    GstBus *m_bus = nullptr;
    QTimer m_pollTimer;
    QTimer m_fadeTimer;
    QTimer m_seekTimeout;
    QUrl m_source;
    State m_state = State::Stopped;
    qint64 m_positionMs = 0;
    qint64 m_durationMs = 0;
    qint64 m_prerollSeekMs = 0;
    qint64 m_confirmingSeekMs = -1;
    bool m_seekable = false;
    bool m_loading = false;
    bool m_logicallyStopped = true;
    bool m_autoplayAfterPreroll = false;
    bool m_resumeAfterConfirmedSeek = false;
    double m_volume = 0.78;
    double m_transitionGain = 1.0;
    double m_fadeStart = 1.0;
    double m_fadeTarget = 1.0;
    int m_fadeStep = 0;
    int m_fadeSteps = 1;
    quint64 m_sourceGeneration = 0;
    std::function<void()> m_fadeCompletion;
};
