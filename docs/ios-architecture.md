# iOS native architecture

**Status:** Active implementation contract. The SwiftUI shell, Rust state,
TIDAL account/catalog/playback, public YouTube Music and SoundCloud playback,
system media controls, qualified listening history, lyrics, and initial offline
flows are connected. Physical-device hardening, prepared-next playback, and
provider-account expansion remain.

The iOS target is a native SwiftUI shell around the existing portable Rust
engine. The shell owns Apple platform behavior; it must not create a second
queue, library, or credential database.

## Runtime layers

```text
SwiftUI views and feature models
        │
        ├── navigation, accessibility, sheets, and presentation
        ├── native playback/session owner
        ├── provider authorization and source adapters
        ├── Keychain, filesystem, permissions, and notifications
        └── background audio/download lifecycle
                         │
                 ColorfulCoreBridge
                         │
                colorful-core Rust ABI
                         │
       SQLite · queue · library · playlists
       history · settings · offline-job state
```

## Ownership rules

The Rust engine owns normalized media identities, queue state, repeat/shuffle,
library membership, Colorful playlists, history, portable settings, and
durable offline-job records. The iOS shell owns:

- AVFoundation/AVPlayer output, route selection, interruptions, and audio
  session policy;
- `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` integration;
- Keychain credentials and provider authorization UI;
- network source resolution until a provider adapter has a portable home;
- background URL sessions, local files, permissions, and notifications;
- SwiftUI presentation and accessibility.

The shell sends commands to the engine and consumes snapshots/events. It may
cache view state for rendering, but it must not maintain a competing durable
queue or playlist model.

## Core bridge

The bridge must follow [the native core ABI](core-abi.md):

- load the core with an opaque engine handle;
- check `colorful_core_abi_version()` before opening storage;
- send versioned JSON commands;
- decode `abiVersion`, `ok`, `value`, and `error` responses;
- consume typed playback, queue, download, and state events;
- release every returned Rust string exactly once;
- serialize access to the engine on one dedicated actor/queue.

Swift models should be projections of engine snapshots and events. Playback
directives are explicit: the shell resolves the requested track, loads the
native player, and reports progress, transitions, pauses, and listen events
back to the engine.

## Playback

The playback owner is an iOS-native service that remains independent of the
SwiftUI view lifecycle. It must cover:

- audio-session configuration for music playback;
- provider-source resolution off the main thread;
- local-file playback for completed downloads;
- prepared-next playback where the provider/source permits it;
- seeking, pause/resume, interruption recovery, route changes, and failures;
- audible-time accounting that excludes buffering, pauses, and seeks;
- Now Playing metadata and remote transport commands.

Do not make a view or `ViewModel` the owner of the audio session. The Android
`MediaSessionService` ownership pattern and the desktop prepared-next contract
are the references, while the actual implementation remains Apple-native.

## Providers

Implement TIDAL first using the device-authorization and refresh semantics
already exercised by Android and documented in [provider migration](provider-migration.md).
Store the refresh token in Keychain and keep provider credentials out of Rust
SQLite.

The desktop Bun provider host is a behavioral/reference implementation, not an
iOS runtime dependency. YouTube Music and SoundCloud should be added behind
the same normalized contracts after the TIDAL slice is reliable. Their
authentication, restricted playback, browser-session, and source-resolution
constraints must be treated as explicit platform risks rather than hidden in
the UI layer.

For public YouTube Music playback, iOS prefers the native iOS client's HLS
master, selects and validates an audio-only AAC rendition, and lets
`AVURLAsset` fetch the HTTPS media segments. Do not route binary HLS segments
through `AVAssetResourceLoaderDelegate` or stage the complete adaptive file
before playback. Direct adaptive AAC is a fallback only when public HLS
identities fail.

## Offline and background work

Offline jobs remain durable in the core. The shell performs TIDAL HLS transfers
with `AVAssetDownloadURLSession`, restores its background session after relaunch,
and owns that session in an application-lifetime service created by the app
delegate rather than a SwiftUI view. Delegate events and durable writes drain
before UIKit's background-session completion handler is called. Completed
packages are validated with `AVAssetCache.isPlayableOffline`; managed `.movpkg`
contents stay under AVFoundation's ownership. Signed provider URLs must not be
persisted as durable credentials; resumed jobs re-resolve fresh sources. See
[the iOS offline download rules](ios-offline.md) for container portability,
LiveContainer behavior, force-quit limits, and device validation.

Background execution is capability-specific. Background audio is part of the
music-player contract. General sync, catalog refresh, and download completion
must use the appropriate iOS background tasks, notifications, or background
URL sessions rather than assuming a permanently running process.

## Sync and parties

The first iOS slice should not invent sync semantics. Use the existing identity,
pairing, party, and future merge documents as the source of truth:

- [identity and pairing](identity-and-pairing.md);
- [multi-device sync](sync.md);
- [social model](social-model.md);
- [parties](parties.md).

When sync work begins, iOS should expose the same trust, revocation, recovery,
and conflict decisions as other native clients. Provider credentials remain in
Keychain, but the user may explicitly import a compatible provider-scoped
credential from a mutually confirmed device over the end-to-end encrypted
pairing channel. Downloads and local output settings remain device-local.
