# colorful desktop client

The Qt client is the primary desktop alpha and is shared by Linux and Windows.
It uses Qt 6 Quick/QML for the interface, embedded libmpv for playback and
adaptive-stream caching, and the shared Rust/SQLite engine for durable queue,
library, history, settings, and offline-job state. Linux adds QtDBus/MPRIS and
Secret Service; Windows adds SMTC, WASAPI, and per-user DPAPI encryption.

## What works

- TIDAL device linking, cached account country, subscription checks, search,
  collection, playlists, personalized daily/discovery/new-release shelves,
  catalog pages, full-track playback, related tracks/radio, and selectable
  stream quality;
- public YouTube Music song/video/release/artist/channel search, paginated
  uploader pages, catalog navigation, playback, downloads, and real automix,
  plus browser-session access to private libraries and playlists with lazy
  continuation loading and YouTube's server-side playlist shuffle;
- public SoundCloud search, profiles, sets, playback, related stations, and
  optional OAuth-session access to personalized home shelves, liked tracks,
  followed profiles, owned sets, and account recommendations;
- persistent queue/library/position, drag reordering, play-next insertion,
  shuffle, three-state repeat, autoplay, prepared-next playback, and gapless
  transitions;
- seeking, persisted perceptual volume and mute, selectable Linux audio output,
  buffering/error feedback with retry, MPRIS, keyboard and mouse controls, and
  Discord Rich Presence;
- resumable TIDAL, YouTube, and SoundCloud downloads stored as standalone `.mka` files,
  with storage/count summaries, configurable quotas, quota-aware pausing, and
  confirmed cleanup for completed or unfinished jobs;
- ten-band EQ, presets, clipping protection, and optional ReplayGain
  normalization;
- album-derived or fixed contrast-safe accents, plus a no-artwork low-data
  mode;
- action toasts, settings/storage/account views, qualified listening history,
  and the optional owner-only Discord statistics widget.

Encrypted device sync and parties are not implemented yet. Linux packaging
produces an AppImage and portable AppDir archive with a compiled
`colorful-provider`, so installed users do not need Bun or the source tree.

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

The public TIDAL clients are built in. Both the native executable and launcher
discover optional overrides from the repository `.env` and `../mocha/.env`
without printing them. Explicit process environment values take precedence.
Account sessions are read from Secret Service, never from either file. Use the
root `.env.example` as the override reference.

For an immediate relaunch of an already-built binary:

```bash
./scripts/run-linux.sh --no-build
```

### Release packages

Validate the development machine before building:

```bash
./scripts/check-linux-deps.sh build
```

The first package build needs the official linuxdeploy tools and standalone
yt-dlp binary. The provisioner downloads these into the ignored `.cache`
directory and verifies yt-dlp against its published SHA-256 list:

```bash
./scripts/provision-linux-packaging.sh
./scripts/package-linux.sh
```

Artifacts are written to `dist/` as an AppImage and a portable `.tar.gz`
containing the AppDir. The package contains the Qt/libmpv runtime,
checksum-verified static FFmpeg/ffprobe, standalone yt-dlp, the Rust core, and
the compiled provider host. Desktop Secret Service access still uses the
distribution's `secret-tool` and session
D-Bus services. The bundle audit can also enforce a release ceiling, for
example `COLORFUL_MAX_GLIBC=2.35 ./scripts/package-linux.sh` on an Ubuntu 22.04
builder. A package made on a newer host remains suitable for local testing but
will generally not run on distributions with older glibc.

Set `COLORFUL_YT_DLP` to select a different `yt-dlp` executable, or
`COLORFUL_DISABLE_DISCORD_RPC=1` to disable local Rich Presence IPC.
Set `COLORFUL_YT_DLP_ARGS` when the local YouTube session needs additional
extractor arguments such as `--cookies-from-browser firefox`; the value is
parsed as a command-line fragment and is used only for bulk downloads.

### Windows

Install Visual Studio 2022 with the MSVC x64 workload, Rust, Bun, CMake, Ninja,
and Git. From PowerShell at the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\provision-windows-qt.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\run-windows.ps1
```

The provisioner installs a local Qt 6.8.3 MSVC build and libmpv development
bundle. The build output is `build\windows-qt\colorful.exe`; Qt libraries,
libmpv, the Rust core, the DPAPI credential helper, and the compiled provider
host are deployed beside it. yt-dlp, FFmpeg, and ffprobe are bundled as well.
Use `-NoBuild` for an immediate relaunch.

Windows playback is lossless when the source and selected output support it.
Shared WASAPI is the safe default. Exclusive WASAPI can be enabled in Playback
settings when direct device ownership is wanted; EQ and normalization still
alter samples when enabled.

## Desktop controls

The compact player exposes shuffle, repeat-off/queue/track, mute, output volume,
queue, and retry state directly. Queue rows can be dragged to reorder them, and
track context menus include **Play next**. Playback settings contain the libmpv
audio-output selector; **System default** continues to follow PipeWire routing.

Keyboard controls are `Space` for play/pause, `M` for mute, left/right to seek
five seconds, Ctrl+left/right for previous/next, and up/down for perceptual
volume steps. Mouse buttons 4 and 5 retain previous/next behavior. Shortcuts do
not intercept typing in text fields.

The lyrics control beside the queue opens a mutually exclusive side panel.
colorful prefers the provider's own lyrics: timestamped TIDAL lyrics and native
YouTube Music lyrics are used when present, with LRCLIB as a fallback for all
providers. Synced lines follow playback and support a ±250 ms display offset;
successful results are cached in shared local storage for offline reuse.

## Offline files and low-data mode

TIDAL downloads resolve a fresh stable representation and write resumable media
chunks. YouTube downloads deliberately use yt-dlp's native bulk-transfer and
`.part` resume path instead of the latency-oriented playback URL. SoundCloud
prefers AAC 160 HLS by default and can optionally use an uploader-authorized
WAV, FLAC, or other original. All paths are remuxed without re-encoding into
one `.mka` file. A completed track no longer needs its provider manifest or a
network connection. TIDAL ReplayGain values are retained as standard tags when
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
