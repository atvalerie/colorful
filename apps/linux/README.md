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
  uploader pages, catalog navigation, typed native Innertube playback, ranged
  downloads, and paged real automix, plus browser-session access to private
  libraries and playlists with lazy continuation loading and YouTube's
  server-side playlist shuffle;
- public SoundCloud search, profiles, sets, playback, related stations, and
  optional OAuth-session access to personalized home shelves, liked tracks,
  followed profiles, owned sets, and account recommendations;
- persistent queue/library/position, drag reordering, play-next insertion,
  shuffle, three-state repeat, autoplay, prepared-next playback, and gapless
  transitions;
- browser-style back/forward navigation and a bounded 128-entry catalog cache;
  fresh pages are reused for 15 minutes, while older cached pages render
  immediately and refresh in the background;
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
`qmllint`, `qdbus6`, and `dbus-run-session`. Normal and age-restricted YouTube
Music playback use typed Innertube requests; the pinned `youtubei.js` player
implementation transforms restricted ciphered formats. No external video
extractor is used or required.

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

The first package build needs the official linuxdeploy tools. The provisioner
downloads these into the ignored `.cache` directory:

```bash
./scripts/provision-linux-packaging.sh
./scripts/package-linux.sh
```

Artifacts are written to `dist/` as an AppImage and a portable `.tar.gz`
containing the AppDir. The package contains the Qt/libmpv runtime,
checksum-verified static FFmpeg/ffprobe, the Rust core, and
the compiled provider host. Desktop Secret Service access still uses the
distribution's `secret-tool` and session
D-Bus services. The bundle audit can also enforce a release ceiling, for
example `COLORFUL_MAX_GLIBC=2.35 ./scripts/package-linux.sh` on an Ubuntu 22.04
builder. A package made on a newer host remains suitable for local testing but
will generally not run on distributions with older glibc.

Set `COLORFUL_DISABLE_DISCORD_RPC=1` to disable local Rich Presence IPC.

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
host are deployed beside it. FFmpeg and ffprobe are bundled as well.
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
volume steps. Mouse buttons 4 and 5, plus Alt+left/right, move backward and
forward through application pages and catalog details. Shortcuts do not
intercept typing in text fields.

The lyrics control beside the queue opens a mutually exclusive side panel.
colorful prefers the provider's own lyrics: timestamped TIDAL lyrics and native
YouTube Music lyrics are used when present, with LRCLIB as a fallback for all
providers. Synced lines follow playback and support a ±250 ms display offset;
successful results are cached in shared local storage for offline reuse.

## Offline files and low-data mode

Every download resolves a fresh provider source rather than persisting its
short-lived signed URL. TIDAL and SoundCloud use resumable FFmpeg media parts.
YouTube writes an exact raw checkpoint with bounded 1 MiB HTTP byte-range
requests, resumes from its current byte offset with a newly signed player URL,
and avoids the real-time pacing that Google can apply to one long continuous
read. FFmpeg then remuxes the completed source without re-encoding into one
`.mka` file. SoundCloud prefers AAC 160 HLS by default and can optionally use
an uploader-authorized WAV, FLAC, or other original. A completed track no
longer needs its provider manifest or a network connection. TIDAL ReplayGain
values are retained as standard tags when available.

**Settings → Appearance → Low data mode** keeps playback unchanged while
suppressing remote artwork/profile requests in QML, album-color extraction,
MPRIS, Discord presence, and artwork for new downloads. Existing cached covers
are not deleted.

## Checks

Run the complete Rust, TypeScript, storage, Linux build, QML, and headless MPRIS
suite from the repository root:

```bash
(cd packages/provider-kit && bun install) # first checkout only
(cd packages/provider-host && bun install --frozen-lockfile)
./scripts/test-linux.sh
```

A shorter manual playback pass should cover all three providers, seeking,
next-track transition, rapid skipping, repeat/shuffle, queue reordering,
mute/volume restoration, output switching, a paused/resumed download, offline
playback, MPRIS controls, and restoration after restarting the app. YouTube
download coverage should include both a short track and a long source so the
ranged path and its restart checkpoint are exercised.

Useful MPRIS checks:

```bash
qdbus6 org.mpris.MediaPlayer2.colorful /org/mpris/MediaPlayer2 \
  org.freedesktop.DBus.Properties.Get org.mpris.MediaPlayer2.Player PlaybackStatus

qdbus6 org.mpris.MediaPlayer2.colorful /org/mpris/MediaPlayer2 \
  org.mpris.MediaPlayer2.Player.PlayPause
```

If playback fails, colorful reports the libmpv error in the UI and writes a
rotating diagnostic log. On Linux it is normally at
`~/.local/share/colorful/colorful/colorful.log`; on Windows it is beneath the
equivalent per-user local application-data directory. The launch terminal also
prints the resolved path. Follow a Linux failure live with:

```bash
tail -f ~/.local/share/colorful/colorful/colorful.log
```

The log records provider requests, catalog cache hits/misses, YouTube
playability and selected format, the CDN hostname, sanitized libmpv warnings,
and each YouTube download range's offset, size, and elapsed time. Signed URLs,
authorization headers, and cookies are redacted. The current log rotates to
`colorful.log.old` at 4 MiB.

A packaged application must ship a compatible libmpv runtime and comply with
the licenses of the exact Qt, libmpv, FFmpeg, and other dependency builds it
distributes.
