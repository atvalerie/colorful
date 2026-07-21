using Windows.Media.Core;
using Windows.Media.Playback;

namespace Colorful.Windows.Playback;

internal sealed class WindowsPlaybackService : IDisposable
{
    private readonly MediaPlayer _player = new();
    private readonly MediaPlaybackList _playlist = new();

    public MediaPlaybackSession Session => _player.PlaybackSession;
    public bool IsPlaying => Session.PlaybackState == MediaPlaybackState.Playing;

    public WindowsPlaybackService()
    {
        _player.AudioCategory = MediaPlayerAudioCategory.Media;
        _player.AutoPlay = false;
        _player.CommandManager.IsEnabled = true;
        _playlist.MaxPlayedItemsToKeepOpen = 3;
        _player.Source = _playlist;
    }

    public void ReplaceQueue(IEnumerable<WindowsPlaybackItem> items, bool autoplay)
    {
        _player.Pause();
        _playlist.Items.Clear();
        foreach (var item in items)
        {
            _playlist.Items.Add(CreateItem(item));
        }

        if (autoplay && _playlist.Items.Count > 0)
        {
            _player.Play();
        }
    }

    public void Play() => _player.Play();
    public void Pause() => _player.Pause();

    public void Toggle()
    {
        if (IsPlaying)
        {
            Pause();
        }
        else
        {
            Play();
        }
    }

    public void Seek(TimeSpan position)
    {
        if (Session.CanSeek)
        {
            Session.Position = position;
        }
    }

    public void SetVolume(double perceptualVolume)
    {
        var clamped = Math.Clamp(perceptualVolume, 0.0, 1.0);
        _player.Volume = Math.Pow(clamped, 2.0);
    }

    public void Dispose()
    {
        _player.Dispose();
    }

    private static MediaPlaybackItem CreateItem(WindowsPlaybackItem item)
    {
        var playbackItem = new MediaPlaybackItem(MediaSource.CreateFromUri(item.Source));
        var display = playbackItem.GetDisplayProperties();
        display.Type = global::Windows.Media.MediaPlaybackType.Music;
        display.MusicProperties.Title = item.Title;
        display.MusicProperties.Artist = item.Artist;
        if (item.Artwork is not null)
        {
            display.Thumbnail = global::Windows.Storage.Streams.RandomAccessStreamReference
                .CreateFromUri(item.Artwork);
        }
        playbackItem.ApplyDisplayProperties(display);
        return playbackItem;
    }
}

internal sealed record WindowsPlaybackItem(
    Uri Source,
    string Title,
    string Artist,
    Uri? Artwork = null);
