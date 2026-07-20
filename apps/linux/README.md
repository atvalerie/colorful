# colorful for Linux

The Linux client is the primary usable alpha. It uses Qt 6 Quick/QML for the
interface, embedded libmpv for playback and adaptive-stream caching, QtDBus for
MPRIS, Linux Secret Service for credentials, and the shared Rust/SQLite engine
for durable queue, library, history, settings, and offline-job state.

## What works

- TIDAL device linking, cached account country, subscription checks, search,
  collection, playlists, mixes, catalog pages, full-track playback, related
  tracks/radio, and selectable stream quality;
- public YouTube Music song/video/release/artist/channel search, paginated
  uploader pages, catalog navigation, playback, downloads, and real automix;
- persistent queue/library/position, drag reordering, play-next insertion,
  shuffle, three-state repeat, autoplay, prepared-next playback, and gapless
  transitions;
- seeking, persisted perceptual volume and mute, selectable Linux audio output,
  buffering/error feedback with retry, MPRIS, keyboard and mouse controls, and
  Discord Rich Presence;
- resumable TIDAL and YouTube downloads stored as standalone `.mka` files,
  with storage/count summaries and confirmed bulk cleanup;
- ten-band EQ, presets, clipping protection, and optional ReplayGain
  normalization;
- album-derived or fixed contrast-safe accents, plus a no-artwork low-data
  mode;
- action toasts, settings/storage/account views, qualified listening history,
  and the optional owner-only Discord statistics widget.

SoundCloud, encrypted device sync, parties, and packaged releases are not
implemented yet.

## Requirements and launch

Install Rust, Bun, CMake 3.25+, Ninja, Qt 6.8+ (`Core`, `Gui`, `Quick`,
`QuickControls2`, `Network`, and `DBus`), `pkg-config`, libmpv development
files, `secret-tool`, and `ffmpeg`. The full test script also uses `sqlite3`,
`qmllint`, `qdbus6`, and `dbus-run-session`. `yt-dlp` is required only for
YouTube media resolution, radio fallback, and downloads; public YouTube Music
catalog search uses the provider host directly.

From the repository root:

```bash
./scripts/run-linux.sh
```

The launcher imports provider configuration from `../mocha/.env` when present.
It does not copy or print those credentials; the same `TIDAL_*` values can be
exported directly. Use the root `.env.example` as the field reference.

For an immediate relaunch of an already-built binary:

```bash
./scripts/run-linux.sh --no-build
```

Set `COLORFUL_YT_DLP` to select a different `yt-dlp` executable, or
`COLORFUL_DISABLE_DISCORD_RPC=1` to disable local Rich Presence IPC.

## Desktop controls

The compact player exposes shuffle, repeat-off/queue/track, mute, output volume,
queue, and retry state directly. Queue rows can be dragged to reorder them, and
track context menus include **Play next**. Playback settings contain the libmpv
audio-output selector; **System default** continues to follow PipeWire routing.

Keyboard controls are `Space` for play/pause, `M` for mute, left/right to seek
five seconds, Ctrl+left/right for previous/next, and up/down for perceptual
volume steps. Mouse buttons 4 and 5 retain previous/next behavior. Shortcuts do
not intercept typing in text fields.

## Offline files and low-data mode

The download worker resolves a fresh provider source, writes independently
resumable media chunks, and remuxes them without re-encoding into one `.mka`
file. A completed track no longer needs its provider manifest or a network
connection. TIDAL ReplayGain values are retained as standard tags when
available.

**Settings → Appearance → Low data mode** keeps playback unchanged while
suppressing remote artwork/profile requests in QML, album-color extraction,
MPRIS, Discord presence, and artwork for new downloads. Existing cached covers
are not deleted.

## Checks

Run the complete Rust, TypeScript, storage, Linux build, QML, and headless MPRIS
suite from the repository root:

```bash
(cd packages/provider-kit && bun install) # first checkout only
./scripts/test-linux.sh
```

A shorter manual playback pass should cover both providers, seeking, next-track
transition, repeat/shuffle, queue reordering, mute/volume restoration, output
switching, a paused/resumed download, offline playback, MPRIS controls, and
restoration after restarting the app.

Useful MPRIS checks:

```bash
qdbus6 org.mpris.MediaPlayer2.colorful /org/mpris/MediaPlayer2 \
  org.freedesktop.DBus.Properties.Get org.mpris.MediaPlayer2.Player PlaybackStatus

qdbus6 org.mpris.MediaPlayer2.colorful /org/mpris/MediaPlayer2 \
  org.mpris.MediaPlayer2.Player.PlayPause
```

If playback fails, colorful reports the libmpv error in the UI. A packaged
application must ship a compatible libmpv runtime and comply with the licenses
of the exact Qt, libmpv, FFmpeg, and other dependency builds it distributes.
