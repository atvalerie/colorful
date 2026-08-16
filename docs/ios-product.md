# iOS product baseline

**Status:** iOS-first planning baseline, 2026-08-16.

colorful is a personal music player made primarily for the owner's daily iPhone
workflow and for a small group of friends. iOS is therefore the next product
client, not a downstream port that must wait for Android feature parity.

## Product decision

- Start the native iOS client before completing Android's product UI.
- Treat the physical iPhone as the eventual source of truth for playback,
  permissions, background audio, media controls, credentials, and device sync.
- Use the Linux/Qt client as the behavioral reference for mobile parity: carry
  over its small interaction details, optional controls, fallbacks, and useful
  quirks unless iOS constraints require a change. Android and desktop behavior
  remain implementation references and contract tests, not a release gate for
  iOS.
- Keep the client local-first: provider credentials stay on each device and the
  shared engine remains useful without a colorful account or mandatory server.

## First useful iOS slice

The first device-testable milestone should be a small but real music player:

1. SwiftUI application shell with Colorful's iOS navigation and visual system.
2. Shared Rust core bound through the versioned C/JSON ABI.
3. TIDAL device authorization with refresh-token storage in iOS Keychain.
4. Search, basic catalog navigation, track play, enqueue, next, previous,
   pause, seek, and queue restoration.
5. AVFoundation/AVAudioEngine playback owned by a native playback service.
6. Background audio, lock-screen/Control Center metadata, remote commands,
   interruptions, route changes, and headset controls.
7. Device-local library, playlists, listening history, settings, and accent
   colors from the shared engine.

This slice should be usable on the daily-driver phone before adding every
provider and every desktop feature.

## Follow-up order

After the first slice is stable, add:

- album, artist, playlist, home-feed, and combined-search depth;
- resumable offline downloads and storage management;
- lyrics with the existing provider-first and cached fallback behavior;
- appearance, low-data, and audio-processing settings;
- YouTube Music and SoundCloud native adapters where their authentication and
  source-resolution constraints permit;
- encrypted device pairing, sync, playback handoff, and active-device presence;
- parties and other social playback features.

## Explicit non-goals for the first slice

- Embedding the Bun provider host in iOS.
- Blocking iOS work on Android's unfinished product UI.
- Recreating the desktop sidebar, resizable queue panel, or keyboard-first
  layout on a phone.
- Assuming a sideloading container provides the same guarantees as a native
  installed app. LiveContainer can support iteration, but native device tests
  remain required for push, extensions, and system integrations.

## Current references

The active desktop behavior is documented in [the Linux client README](../apps/linux/README.md).
When a mobile feature is marked complete, compare it with the Linux QML/backend
behavior and preserve the detail-level behavior, not only the feature name.
Windows uses that same Qt/QML client; its separate WinUI files are an archived
experiment, as described in [the Windows README](../apps/windows/README.md).
Portable ownership boundaries are in [architecture](architecture.md), the ABI
contract is in [core-abi](core-abi.md), and storage behavior is in
[storage](storage.md).
