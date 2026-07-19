# colorful for Linux

The first native client uses Qt 6 Quick/QML for a deeply customizable interface,
libmpv for playback, adaptive-stream caching, and Linux audio output, Linux
Secret Service for the TIDAL refresh token, and QtDBus for MPRIS controls.

From the repository root:

```bash
./scripts/run-linux.sh
```

The launcher builds the app when necessary and loads the existing TIDAL client
configuration from `../mocha/.env`. It does not copy or print those credentials.
You can instead provide the same `TIDAL_*` variables in your environment.

Offline downloads require the `ffmpeg` executable. colorful resolves a fresh
TIDAL DASH source for the transfer, remuxes the selected audio without
re-encoding, and stores the standalone `.mka` file plus artwork under its
private application-data directory. Completed playback does not use a manifest
or require the provider host to be online.

When a Discord-compatible desktop client is running, colorful publishes the
current track through local Rich Presence IPC. Set
`COLORFUL_DISABLE_DISCORD_RPC=1` before launching to disable it.

## Test flow

1. Click **Connect**, then **Open TIDAL to approve**.
2. Finish linking in the browser. The dialog closes when approval completes.
3. Search for an artist or track.
4. Double-click a result to play immediately, or click **+** to queue it.
5. Use the bottom controls, headset keys, desktop media controls, or MPRIS.

Useful MPRIS checks:

```bash
qdbus6 org.mpris.MediaPlayer2.colorful /org/mpris/MediaPlayer2 \
  org.freedesktop.DBus.Properties.Get org.mpris.MediaPlayer2.Player PlaybackStatus

qdbus6 org.mpris.MediaPlayer2.colorful /org/mpris/MediaPlayer2 \
  org.mpris.MediaPlayer2.Player.PlayPause
```

If playback fails, the bottom status line reports the libmpv error. Building
requires the libmpv development package; the packaged application must ship a
compatible libmpv runtime.
