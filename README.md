<p align="center">
  <img src="assets/branding/colorful.svg" alt="colorful prism logo" width="128" height="128">
</p>

<h1 align="center">colorful</h1>

<p align="center">
  A colorful, local-first personal music player built natively for each platform.
</p>

<p align="center">
  <strong>Linux · Android · Windows · iOS (planned)</strong>
</p>

> [!IMPORTANT]
> **This project is entirely AI-made.** It is a personal project built to meet
> my own music playback needs, and an exception to my usual stance on
> AI-generated code.

> [!CAUTION]
> **colorful is not a piracy project.** It does not provide accounts, shared
> credentials, subscription bypasses, provider tokens, or account sources. You
> must use your own legitimate provider account and configuration.

<p align="center">
  <img src="assets/desktop_early_ver.png" alt="An early colorful Linux build showing TIDAL search results, a live queue, and the compact bottom player" width="100%">
</p>

<p align="center"><sub>Early Linux build. The interface is actively changing.</sub></p>

## About

colorful is a local-first personal streaming and music-library client. TIDAL is
the primary provider; public SoundCloud and public/optionally authenticated
YouTube Music desktop paths are also working.

- Platform-native playback, media sessions, credentials, and interfaces
- A shared Rust core for queues, storage, offline-job state, and listening history
- Device-local data with no required colorful account or central library server

Future parties and device sync may use encrypted relays, but provider
credentials remain device-local.

## Current status

colorful is an early personal alpha, not a packaged consumer release.

| Target | Status | Current implementation |
| --- | --- | --- |
| Linux | Usable alpha | Qt 6/QML, embedded libmpv, MPRIS, Discord Rich Presence and statistics widget, Secret Service, TIDAL, YouTube Music, and SoundCloud, persistent queue/library |
| Android | Working vertical slice | Kotlin/Compose, Media3 `MediaSessionService`, Android Keystore, TIDAL device linking/search/playback, and Rust/SQLite queue persistence |
| Windows | Qt alpha build | The same Qt/QML desktop shell as Linux, embedded libmpv over WASAPI, Windows media controls, DPAPI credentials, and the Rust/SQLite engine |
| iOS | Planned | SwiftUI, AVFoundation/AVAudioEngine, Keychain, system Now Playing integration |
| macOS | Not targeted | No first-party target is planned |

### Working today

- TIDAL device linking and subscription-aware full-track playback
- account-country discovery with a cached fallback
- TIDAL collection, playlists, personalized daily/discovery/new-release shelves,
  catalog pages, and account/subscription details
- public YouTube Music song, video, release, artist, and uploader-channel search;
  paginated channel uploads, catalog pages, native Innertube playback, ranged
  downloads, and continuously paged genuine radio/automix on desktop
- optional locally stored YouTube Music browser session for private library content, playlists, and personalized mixes
- public SoundCloud mixed search, tracks, profiles, sets, related radio, catalog pagination, playback, quality-aware downloads, and optional uploader originals on Linux
- optional locally stored SoundCloud OAuth session for personalized home shelves, liked tracks, sets, owned playlists, followed profiles, and account recommendations
- independent TIDAL, YouTube, and SoundCloud search continuation without resetting the visible result list
- a personalized cross-provider desktop Home assembled from connected-service
  mixes and recommendations, ordered by locally measured provider listening time
- combined desktop search that groups tracks, albums, artists, and channels by
  the same most-listened-provider order without disturbing provider relevance
- bounded desktop catalog-page caching with instant history restoration and
  stale-while-refresh behavior
- lossless/adaptive playback with accurate duration and seeking
- persisted perceptual desktop volume, real mute, and selectable Linux output
- prepared-next, gapless Linux playback with prefetched autoplay
- persistent reorderable and width-adjustable desktop queue, play-next insertion, repeat/shuffle, playback
  position, autoplay, and related tracks
- provider-neutral local playlists with ordered duplicates, create/rename/delete,
  collection-wide adds, and editing from every desktop track surface
- provider-first desktop lyrics with TIDAL synchronization, YouTube Music
  lyrics, LRCLIB fallback, offline caching, and adjustable timing
- Linux MPRIS and Discord Rich Presence
- Android system media session and background playback ownership
- album-art-derived, contrast-safe accent colors
- selectable TIDAL stream quality and album-derived or fixed accent modes
- persistent 10-band Linux equalizer with presets, clipping protection, and ReplayGain normalization
- resumable desktop TIDAL, YouTube, and SoundCloud downloads with durable checkpoints,
  artwork, local-file playback, storage summaries, configurable quotas, and
  confirmed bulk cleanup
- a persistent low-data mode that avoids loading remote artwork and profile images
- qualified local listening history with per-provider usage plus
  top-track/top-artist/top-album statistics
- opt-in Discord profile statistics publishing with Secret Service token storage
- first-launch desktop setup for optional provider connections, playback
  defaults, and offline storage, with a Settings action to rerun it
- desktop settings for accounts, stream quality, autoplay, EQ/normalization, Discord integrations, appearance, low-data behavior, storage, and build information
- sync-ready, idempotent history event identities

### On the roadmap

- Android EQ and normalization using the shared audio-processing contract
- Android offline downloads and YouTube Music support
- encrypted multi-device library sync and playback handoff
- parties over LAN, ICE/STUN, and an encrypted relay fallback
- Windows interactive-runtime polish; iOS native shell

The maintained, milestone-oriented backlog is in [docs/todo.md](docs/todo.md).

## Architecture

```text
Native UI
  │
  ├── native playback + media session + credential store
  ├── platform/provider source resolution
  └── versioned C/JSON commands and events
                    │
             colorful-core (Rust)
                    │
       SQLite · queue · library · history
       settings · offline-job records

Desktop provider host (transitional TypeScript process; bundled on Windows)
  └── TIDAL + public SoundCloud + typed public/authenticated YouTube Music adapters
```

Playback is intentionally platform-owned. The portable engine does not decode
audio or attempt to replace Media3, libmpv, AVFoundation, or Windows media APIs.

## Repository layout

| Path | Purpose |
| --- | --- |
| `crates/colorful-core` | Portable Rust domain engine, SQLite repositories, migrations, and stable native ABI |
| `packages/provider-kit` | Typed provider contracts and shared migration fixtures |
| `packages/provider-host` | Transitional Bun-based desktop provider adapter; compiled to a standalone executable on Windows |
| `apps/linux` | Shared Qt Quick/QML desktop client (historical path), with libmpv, MPRIS on Linux, and SMTC/WASAPI on Windows |
| `apps/android` | Native Kotlin/Compose client with Media3 and JNI bindings |
| `apps/design-lab` | Disposable React UI prototype; not a production client |
| `apps/windows` | Archived WinUI prototype; the active Windows target uses the shared Qt desktop shell |
| `apps/ios` | iOS target plan |
| `docs` | Architecture, storage, connectivity, sync, provider, CI, and integration notes |
| `scripts` | Reproducible build, run, and test entry points |

## Provider and account requirements

colorful bundles the public TIDAL web/device client configuration required to
reach the service. It does not bundle provider accounts, user tokens, imported
browser sessions, or private configuration. Environment values are optional
development overrides:

```bash
cp .env.example .env
set -a
source .env
set +a
```

Never commit a populated `.env` or post account credentials. Linux stores provider secrets through
Secret Service, Windows encrypts them per user with DPAPI, and Android uses
Android Keystore.

Authenticated YouTube Music uses a browser session captured from your own
account. See the [YouTube Music account setup guide](docs/youtube-music-login.md).
SoundCloud can likewise import only the OAuth header from one of your own
logged-in API requests; see the [SoundCloud account setup guide](docs/soundcloud-login.md).

colorful is not affiliated with, endorsed by, or sponsored by TIDAL, Discord,
SoundCloud, YouTube, or their respective owners. Product names belong to their
owners.

## Running the Linux client

Required development tools currently include Rust, Bun, CMake 3.25+, Ninja,
Qt 6.8+ (`Core`, `Gui`, `Quick`, `QuickControls2`, `Network`, and `DBus`),
`pkg-config`, libmpv development files, SQLite's CLI for schema tests,
`secret-tool` for secure login persistence, and `ffmpeg` for offline download
assembly. YouTube Music playback uses typed Innertube `search`, `browse`,
`next`, and `player` requests directly. Restricted ciphered formats are
transformed through the pinned `youtubei.js` player implementation; no
external video extractor is used or required.

No provider environment is required for a normal launch:

```bash
./scripts/run-linux.sh
```

For an instant relaunch of the existing binary without checking for source
changes, use `./scripts/run-linux.sh --no-build`.

See [the Linux client guide](apps/linux/README.md) for the manual test flow,
MPRIS checks, and troubleshooting.

Create distributable Linux artifacts in the Ubuntu 22.04 release container:

```bash
./scripts/package-linux-docker.sh
```

The image pins Qt, Rust, Bun, and CMake, builds as the invoking user, keeps
download and compiler caches under `.cache/container`, and writes an AppImage
and portable AppDir archive beneath `dist/`. The package bundles Qt, libmpv,
and checksum-verified static FFmpeg/ffprobe, then enforces a glibc 2.35 ceiling.
Docker is only the release build environment; finished packages still need
testing in a normal desktop session.

A native host build remains available for packaging development:

```bash
./scripts/check-linux-deps.sh build
./scripts/provision-linux-packaging.sh
./scripts/package-linux.sh
```

## Building Windows

The active Windows client is the same Qt/QML desktop shell. Install Visual
Studio 2022 with MSVC x64, Rust, Bun, CMake, Ninja, and Git, then provision Qt
and libmpv and launch from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\provision-windows-qt.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\run-windows.ps1
```

The build uses libmpv's WASAPI output, supports shared and exclusive modes,
publishes Windows system media controls, protects provider credentials with
DPAPI, and bundles the provider host so Bun is not required at runtime. The
Windows bundle also includes GPL FFmpeg/ffprobe for final offline-media
assembly and probing. YouTube transfers themselves use resumable bounded HTTP
byte ranges. See [the Windows guide](apps/windows/README.md).

Create a no-install archive from a clean Release build with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package-windows.ps1
```

Pass `-Installer` when Inno Setup 6 is installed to produce a per-user setup
executable from the same staged files. Artifacts are written beneath `dist`.
The portable ZIP does not install files, but account sessions and settings
remain per-user in Windows application data rather than beside the executable.

Desktop release versions come from the repository-root `VERSION` file. Before
giving someone a newer installer, increment it and commit that change:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\set-version.ps1 -Version 0.1.1
powershell -ExecutionPolicy Bypass -File .\scripts\package-windows.ps1 -Installer
```

The Windows executable, Settings diagnostics, ZIP, setup filename, and
Add/Remove Programs entry all receive that version. Setup releases retain one
permanent application identity, reuse the existing install directory, close a
running copy before replacement, and update the existing installation in
place. Do not change the installer `AppId`. Portable ZIPs remain portable and
are not an upgrade mechanism.

Linux uses the identical version in its runtime diagnostics, AppImage, and
portable archive names. After both desktop packages have been tested, push a
matching annotated tag to build and publish a GitHub Release:

```bash
./scripts/set-version.sh 0.1.1
# commit and test the 0.1.1 release
git tag -a v0.1.1 -m "colorful 0.1.1"
git push origin v0.1.1
```

The release workflow rejects a tag that does not exactly match `v$(cat
VERSION)`. It builds Linux inside the pinned container, builds Windows on a
Windows runner, and publishes the AppImage, Linux archive, Windows ZIP, and
upgradeable setup executable together. The release is published only after
both platform jobs succeed.

Non-documentation pushes to `main` create 14-day development artifacts for
both desktop platforms without publishing a release. These builds are visibly
labelled `VERSION-dev.RUN+COMMIT` in Settings and can also be requested
manually for only Windows or Linux from the **Desktop dev builds** workflow.

New commits follow the Conventional Commits format described in
[CONTRIBUTING.md](CONTRIBUTING.md). An annotated release tag's message is
prepended to the categorized changelog generated from those subjects, allowing
each release to have a hand-written introduction without maintaining a
changelog file.

Desktop clients check the latest stable GitHub Release at most once every six
hours and show its Markdown changelog in-app. The Windows action downloads the
setup executable, verifies GitHub's published SHA-256 asset digest, starts the
installer, and exits the running client. Linux downloads and verifies the
AppImage into the user's Downloads directory; portable Linux replacement
remains explicit rather than modifying a running bundle.

## Building Android

Install Android Studio with SDK 36, NDK `30.0.15729638`, CMake 4.1.2, an
arm64/x86_64 Rust Android toolchain, and the provider environment described
above. Then run:

```bash
./scripts/build-android.sh
```

If needed, install the Rust targets first:

```bash
rustup target add aarch64-linux-android x86_64-linux-android
```

The Android application ID is `sh.valerie.colorful`. See
[the Android client guide](apps/android/README.md) for its current scope.

## Checks

On a fresh checkout, install the provider TypeScript dependencies once:

```bash
(cd packages/provider-kit && bun install)
(cd packages/provider-host && bun install --frozen-lockfile)
```

Run the complete Linux-oriented suite:

```bash
./scripts/test-linux.sh
```

Run only the raw SQLite migration/constraint checks:

```bash
./scripts/test-storage-schema.sh
```

## Privacy and security model

- Provider and Discord credentials stay in the operating system credential
  store and are excluded from portable sync.
- Playback manifests and signed media URLs are never persisted as durable
  credentials.
- Listening history and library data remain local unless encrypted sync is
  explicitly enabled in a future build.
- Planned party peers exchange provider references and commands, not account
  tokens.
- Relays must not receive plaintext libraries, queues, credentials, or audio.

Read [the sync design](docs/sync.md), [party connectivity model](docs/connectivity.md),
and [local storage contract](docs/storage.md) for the longer version.

## Discord integrations

Desktop Rich Presence publishes the active local track through Discord's local
IPC connection. The separate owner-only profile widget publishes aggregate
all-time listening statistics and can eventually include mobile listens
received through encrypted sync. Its Application ID is editable so each user
can connect an application and widget configuration they own. Bot tokens stay
in the platform credential store and are kept separate per application.

Setup and the published field contract are documented in the
[Discord statistics widget guide](docs/discord-widget.md).

## Contributing and AI-generated code

Bug reports should include the platform, reproduction steps, and non-secret
logs. Never post tokens, credentials, signed media URLs, or downloaded media.

## Licensing

colorful is free software licensed under the GNU General Public License,
version 3 or (at your option) any later version (`GPL-3.0-or-later`). See
the [LICENSE](LICENSE) file.

Dependencies and bundled assets retain their own licenses. Binary distributors
must also comply with the licenses of the exact Qt, libmpv, and other dependency
builds they ship.
