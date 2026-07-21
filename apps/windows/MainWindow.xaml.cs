using Colorful.Windows.Core;
using Colorful.Windows.Playback;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using WinRT.Interop;

namespace Colorful.Windows;

public sealed partial class MainWindow : Window
{
    private readonly CoreBridge _core;
    private readonly WindowsPlaybackService _playback = new();

    public MainWindow()
    {
        InitializeComponent();
        ConfigureWindow();

        try
        {
            _core = new CoreBridge();
            using var snapshot = _core.Snapshot();
            var queueCount = snapshot.RootElement
                .GetProperty("value")
                .GetProperty("queue")
                .GetProperty("entries")
                .GetArrayLength();
            CoreStatusText.Text = $"Ready · ABI {_core.AbiVersion}";
            CoreDetailsText.Text = $"{queueCount} queued · {_core.DatabasePath}";
        }
        catch (Exception error)
        {
            CoreStatusText.Text = "Core unavailable";
            CoreDetailsText.Text = error.Message;
            throw;
        }

        _playback.SetVolume(VolumeSlider.Value);
        _playback.Session.PlaybackStateChanged += (_, _) =>
        {
            DispatcherQueue.TryEnqueue(UpdatePlaybackState);
        };
        Closed += (_, _) =>
        {
            _playback.Dispose();
            _core.Dispose();
        };
    }

    private void ConfigureWindow()
    {
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarDragRegion);

        var windowHandle = WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(windowHandle);
        var appWindow = AppWindow.GetFromWindowId(windowId);
        appWindow.Resize(new Windows.Graphics.SizeInt32(1180, 760));

        if (AppWindowTitleBar.IsCustomizationSupported())
        {
            var titleBar = appWindow.TitleBar;
            titleBar.ExtendsContentIntoTitleBar = true;
            titleBar.BackgroundColor = Colors.Transparent;
            titleBar.InactiveBackgroundColor = Colors.Transparent;
            titleBar.ButtonBackgroundColor = Colors.Transparent;
            titleBar.ButtonInactiveBackgroundColor = Colors.Transparent;
            titleBar.ButtonHoverBackgroundColor = Windows.UI.Color.FromArgb(255, 44, 36, 54);
            titleBar.ButtonPressedBackgroundColor = Windows.UI.Color.FromArgb(255, 160, 108, 255);
            titleBar.ButtonForegroundColor = Colors.White;
            titleBar.ButtonInactiveForegroundColor = Windows.UI.Color.FromArgb(255, 125, 121, 132);
        }
    }

    private void PlayPauseButton_Click(object sender, RoutedEventArgs e)
    {
        _playback.Toggle();
        UpdatePlaybackState();
    }

    private void VolumeSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        _playback.SetVolume(e.NewValue);
    }

    private void UpdatePlaybackState()
    {
        PlayPauseIcon.Symbol = _playback.IsPlaying ? Symbol.Pause : Symbol.Play;
    }
}
