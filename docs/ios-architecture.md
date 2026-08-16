# iOS native architecture

**Status:** Initial implementation contract, 2026-08-16.

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

- AVFoundation/AVAudioEngine output, route selection, interruptions, and audio
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

The first playback owner should be an iOS-native service/actor that remains
independent of the SwiftUI view lifecycle. It must cover:

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

## Offline and background work

Offline jobs remain durable in the core. The shell performs transfers with
iOS-appropriate background networking and writes progress through the same
download state/event boundary. Signed provider URLs must not be persisted as
durable credentials; resumed jobs re-resolve fresh sources.

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
and conflict decisions as other native clients. Provider credentials,
downloads, and local output settings remain device-local.
