<p align="center">
  <img src="assets/branding/colorful.svg" alt="colorful prism logo" width="128" height="128">
</p>

<h1 align="center">colorful</h1>

<p align="center">
  A colorful, local-first personal music player built natively for each platform.
</p>

<p align="center">
  <strong>Linux · Android · Windows (planned) · iOS (planned)</strong>
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
the primary provider; an early public YouTube Music desktop path is also working.

- Platform-native playback, media sessions, credentials, and interfaces
- A shared Rust core for queues, storage, offline-job state, and listening history
- Device-local data with no required colorful account or central library server

Future parties and device sync may use encrypted relays, but provider
credentials remain device-local.

## Current status

colorful is an early personal alpha, not a packaged consumer release.

| Target | Status | Current implementation |
| --- | --- | --- |
| Linux | Usable alpha | Qt 6/QML, embedded libmpv, MPRIS, Discord Rich Presence and statistics widget, Secret Service, TIDAL and public YouTube playback, persistent queue/library |
| Android | Working vertical slice | Kotlin/Compose, Media3 `MediaSessionService`, Android Keystore, TIDAL device linking/search/playback, and Rust/SQLite queue persistence |
| Windows | Planned | WinUI, Media Foundation/WASAPI, System Media Transport Controls |
| iOS | Planned | SwiftUI, AVFoundation/AVAudioEngine, Keychain, system Now Playing integration |
| macOS | Not targeted | No first-party target is planned |

### Working today

- TIDAL device linking and subscription-aware full-track playback
- account-country discovery with a cached fallback
- TIDAL collection, playlists, mixes, catalog pages, and account/subscription details
- public YouTube Music song, video, release, artist, and uploader-channel search; paginated channel uploads, catalog pages, playback, downloads, and genuine radio/automix on Linux
- lossless/adaptive playback with accurate duration and seeking
- prepared-next, gapless Linux playback with prefetched autoplay
- persistent queue, library, playback position, autoplay, and related tracks
- Linux MPRIS and Discord Rich Presence
- Android system media session and background playback ownership
- album-art-derived, contrast-safe accent colors
- selectable TIDAL stream quality and album-derived or fixed accent modes
- persistent 10-band Linux equalizer with presets, clipping protection, and ReplayGain normalization
- resumable desktop TIDAL and YouTube downloads with durable checkpoints, artwork, and local-file playback
- a persistent low-data mode that avoids loading remote artwork and profile images
- qualified local listening history and top-track/top-artist/top-album statistics
- opt-in Discord profile statistics publishing with Secret Service token storage
- desktop settings for accounts, stream quality, autoplay, EQ/normalization, Discord integrations, appearance, low-data behavior, storage, and build information
- sync-ready, idempotent history event identities

### On the roadmap

- broader TIDAL home/recommendation surfaces
- Android EQ and normalization using the shared audio-processing contract
- Android offline downloads and YouTube Music support
- SoundCloud public accounts, catalog, and playback
- encrypted multi-device library sync and playback handoff
- parties over LAN, ICE/STUN, and an encrypted relay fallback
- Windows and iOS native shells

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

Linux provider host (transitional Bun process)
  └── TIDAL + public YouTube Music catalog/source adapters
```

Playback is intentionally platform-owned. The portable engine does not decode
audio or attempt to replace Media3, libmpv, AVFoundation, or Windows media APIs.

## Repository layout

| Path | Purpose |
| --- | --- |
| `crates/colorful-core` | Portable Rust domain engine, SQLite repositories, migrations, and stable native ABI |
| `packages/provider-kit` | Typed provider contracts and shared migration fixtures |
| `packages/provider-host` | Transitional Bun-based Linux provider adapter |
| `apps/linux` | Native Qt Quick/QML desktop client with libmpv and MPRIS |
| `apps/android` | Native Kotlin/Compose client with Media3 and JNI bindings |
| `apps/design-lab` | Disposable React UI prototype; not a production client |
| `apps/windows` | Windows target plan |
| `apps/ios` | iOS target plan |
| `docs` | Architecture, storage, connectivity, sync, provider, CI, and integration notes |
| `scripts` | Reproducible build, run, and test entry points |

## Provider and account requirements

colorful does not bundle provider accounts or private provider configuration.
Supply your own TIDAL account and permitted client configuration in a local
environment file:

```bash
cp .env.example .env
set -a
source .env
set +a
```

Never commit `.env` or post credentials. Linux stores refresh tokens through
Secret Service; Android uses Android Keystore.

colorful is not affiliated with, endorsed by, or sponsored by TIDAL, Discord,
SoundCloud, YouTube, or their respective owners. Product names belong to their
owners.

## Running the Linux client

Required development tools currently include Rust, Bun, CMake 3.25+, Ninja,
Qt 6.8+ (`Core`, `Gui`, `Quick`, `QuickControls2`, `Network`, and `DBus`),
`pkg-config`, libmpv development files, SQLite's CLI for schema tests,
`secret-tool` for secure login persistence, `yt-dlp` for YouTube playback,
radio, and downloads, and `ffmpeg` for offline download assembly. Public
YouTube Music browsing/search itself does not require `yt-dlp`.

With the provider environment exported:

```bash
./scripts/run-linux.sh
```

For an instant relaunch of the existing binary without checking for source
changes, use `./scripts/run-linux.sh --no-build`.

See [the Linux client guide](apps/linux/README.md) for the manual test flow,
MPRIS checks, and troubleshooting.

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

On a fresh checkout, install the provider-kit TypeScript development
dependencies once:

```bash
(cd packages/provider-kit && bun install)
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

Linux Rich Presence publishes the active local track through Discord's local
IPC connection. The separate owner-only profile widget publishes aggregate
all-time listening statistics and can eventually include mobile listens
received through encrypted sync. Its Application ID is editable so each user
can connect an application and widget configuration they own. Bot tokens stay
in Secret Service and are kept separate per application.

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
