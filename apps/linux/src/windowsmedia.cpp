#include "windowsmedia.h"

#include "backend.h"

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/base.h>

#include <QMetaObject>
#include <QTimer>
#include <QUrl>
#include <QVariantMap>
#include <QWindow>

using winrt::Windows::Foundation::TimeSpan;
using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;
using winrt::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs;
using winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties;
using winrt::Windows::Storage::Streams::RandomAccessStreamReference;

namespace {
TimeSpan milliseconds(qint64 value)
{
    return TimeSpan{std::max<qint64>(0, value) * 10'000};
}

winrt::hstring hstring(const QString &value)
{
    return winrt::hstring(reinterpret_cast<const wchar_t *>(value.utf16()), value.size());
}
}

class WindowsMediaSession::Impl
{
public:
    Impl(Backend *backend, QWindow *window)
        : m_backend(backend)
    {
        try {
            winrt::init_apartment(winrt::apartment_type::single_threaded);
        } catch (const winrt::hresult_error &error) {
            if (error.code() != RPC_E_CHANGED_MODE) throw;
        }

        auto interop = winrt::get_activation_factory<
            SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
        winrt::check_hresult(interop->GetForWindow(
            reinterpret_cast<HWND>(window->winId()),
            winrt::guid_of<winrt::Windows::Media::ISystemMediaTransportControls>(),
            winrt::put_abi(m_controls)));

        m_buttonToken = m_controls.ButtonPressed(
            [this](const SystemMediaTransportControls &,
                   const SystemMediaTransportControlsButtonPressedEventArgs &event) {
                const auto button = event.Button();
                QMetaObject::invokeMethod(m_backend, [backend = m_backend, button] {
                    switch (button) {
                    case SystemMediaTransportControlsButton::Play: backend->play(); break;
                    case SystemMediaTransportControlsButton::Pause: backend->pause(); break;
                    case SystemMediaTransportControlsButton::Next: backend->next(); break;
                    case SystemMediaTransportControlsButton::Previous: backend->previous(); break;
                    case SystemMediaTransportControlsButton::Stop: backend->stop(); break;
                    default: break;
                    }
                }, Qt::QueuedConnection);
            });

        QObject::connect(m_backend, &Backend::currentTrackChanged, m_backend, [this] {
            updateMetadata();
            updateCapabilities();
            updateTimeline();
        });
        QObject::connect(m_backend, &Backend::playbackChanged, m_backend, [this] {
            updatePlaybackStatus();
        });
        QObject::connect(m_backend, &Backend::durationChanged, m_backend, [this] {
            updateTimeline();
        });
        QObject::connect(m_backend, &Backend::queueChanged, m_backend, [this] {
            updateCapabilities();
        });
        QObject::connect(m_backend, &Backend::seeked, m_backend, [this] {
            updateTimeline();
        });

        m_timelineTimer.setInterval(1000);
        QObject::connect(&m_timelineTimer, &QTimer::timeout, m_backend, [this] {
            if (m_backend->playing()) updateTimeline();
        });
        m_timelineTimer.start();

        updateMetadata();
        updateCapabilities();
        updatePlaybackStatus();
        updateTimeline();
    }

    ~Impl()
    {
        if (m_controls && m_buttonToken.value) m_controls.ButtonPressed(m_buttonToken);
    }

private:
    void updateMetadata()
    {
        if (!m_controls) return;
        const auto track = m_backend->currentTrack();
        m_controls.IsEnabled(!track.isEmpty());
        auto updater = m_controls.DisplayUpdater();
        updater.ClearAll();
        if (track.isEmpty()) {
            updater.Update();
            return;
        }

        updater.Type(MediaPlaybackType::Music);
        const auto properties = updater.MusicProperties();
        properties.Title(hstring(track.value(QStringLiteral("title")).toString()));
        properties.Artist(hstring(track.value(QStringLiteral("artistText")).toString()));
        properties.AlbumTitle(hstring(track.value(QStringLiteral("albumTitle")).toString()));

        if (!m_backend->lowDataMode()) {
            const auto artwork = QUrl(track.value(QStringLiteral("coverUrl")).toString());
            if (artwork.isValid() && !artwork.isEmpty()) {
                try {
                    updater.Thumbnail(RandomAccessStreamReference::CreateFromUri(
                        winrt::Windows::Foundation::Uri(hstring(artwork.toString(QUrl::FullyEncoded)))));
                } catch (const winrt::hresult_error &) {
                    // Metadata remains useful when Windows rejects an artwork URL.
                }
            }
        }
        updater.Update();
    }

    void updatePlaybackStatus()
    {
        if (!m_controls) return;
        if (m_backend->currentTrack().isEmpty()) {
            m_controls.PlaybackStatus(MediaPlaybackStatus::Closed);
        } else if (m_backend->playing()) {
            m_controls.PlaybackStatus(MediaPlaybackStatus::Playing);
        } else {
            m_controls.PlaybackStatus(MediaPlaybackStatus::Paused);
        }
    }

    void updateCapabilities()
    {
        if (!m_controls) return;
        const auto hasTrack = !m_backend->currentTrack().isEmpty();
        m_controls.IsPlayEnabled(hasTrack);
        m_controls.IsPauseEnabled(hasTrack);
        m_controls.IsStopEnabled(hasTrack);
        m_controls.IsNextEnabled(m_backend->canGoNext());
        m_controls.IsPreviousEnabled(m_backend->canGoPrevious());
    }

    void updateTimeline()
    {
        if (!m_controls || m_backend->currentTrack().isEmpty()) return;
        const auto duration = m_backend->duration();
        const auto position = std::clamp<qint64>(m_backend->position(), 0, std::max<qint64>(0, duration));
        SystemMediaTransportControlsTimelineProperties timeline;
        timeline.StartTime(milliseconds(0));
        timeline.MinSeekTime(milliseconds(0));
        timeline.Position(milliseconds(position));
        timeline.MaxSeekTime(milliseconds(duration));
        timeline.EndTime(milliseconds(duration));
        m_controls.UpdateTimelineProperties(timeline);
        m_controls.PlaybackRate(1.0);
    }

    Backend *m_backend;
    SystemMediaTransportControls m_controls{nullptr};
    winrt::event_token m_buttonToken{};
    QTimer m_timelineTimer;
};

WindowsMediaSession::WindowsMediaSession(Backend *backend, QWindow *window, QObject *parent)
    : QObject(parent)
{
    try {
        m_impl = std::make_unique<Impl>(backend, window);
    } catch (const winrt::hresult_error &error) {
        qWarning("Windows media controls unavailable: 0x%08lx", static_cast<unsigned long>(error.code().value));
    }
}

WindowsMediaSession::~WindowsMediaSession() = default;
