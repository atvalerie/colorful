#pragma once

#include <QObject>
#include <QUrl>
#include <mpv/client.h>

class LinuxPlayback final : public QObject
{
    Q_OBJECT

public:
    enum class State { Stopped, Paused, Playing };

    explicit LinuxPlayback(QObject *parent = nullptr);
    ~LinuxPlayback() override;

    bool isAvailable() const { return m_mpv != nullptr; }
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
    void drainEvents();
    void handleProperty(quint64 propertyId, const mpv_event_property &property);
    bool performSeek(qint64 positionMs);
    void setPauseProperty(bool paused);
    void setLogicalState(State state);
    void finishLoading();
    void command(const char *arguments[], quint64 requestId = 0);
    static void handleWakeup(void *userData);

    mpv_handle *m_mpv = nullptr;
    QUrl m_source;
    State m_state = State::Stopped;
    State m_desiredState = State::Stopped;
    qint64 m_positionMs = 0;
    qint64 m_durationMs = 0;
    qint64 m_confirmingSeekMs = -1;
    qint64 m_queuedSeekMs = -1;
    bool m_seekable = false;
    bool m_loading = false;
    quint64 m_nextRequestId = 1;
    quint64 m_seekRequestId = 0;
    quint64 m_loadRequestId = 0;
    double m_volume = 0.78;
};
