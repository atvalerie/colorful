# iOS music-player platform practices

**Status:** Working implementation checklist, 2026-08-16.

This document turns the expectations of an iPhone music player into concrete
Colorful rules. It complements [the iOS parity matrix](ios-parity.md): Linux is
the behavioral reference, while Apple owns the platform-specific behavior.

## Non-negotiable behavior

### Playback has one owner

- `PlaybackStore` mirrors the Rust queue and playback state; it does not become
  a second durable queue.
- `IOSPlaybackService` owns `AVPlayer`, the audio session, interruptions,
  route changes, Now Playing, and remote controls.
- Playback commands are serialized. UI controls update optimistically, then
  reconcile with the Rust response. A stale snapshot must not undo a newer
  pause/play command.
- The service must remain alive independently of a SwiftUI screen. Going to
  the Home Screen, locking the phone, or opening Control Center must not tear
  down the player.

### Background and system audio

- Use the `.playback` audio-session category and the Audio background mode.
- Activate the audio session when playback is about to begin, rather than
  claiming audio focus merely because the app launched.
- Observe interruption notifications. Do not resume after every interruption;
  resume only when the system indicates that playback should resume and the
  user had been playing before the interruption.
- Observe route changes. Headphones and AirPods should reroute without an
  unnecessary pause; an output becoming unavailable should pause or surface a
  clear recovery state according to the route reason.
- Reconcile the core snapshot and native player on every foreground transition.
  Checkpoint position when leaving the active scene, but do not pause solely
  because the UI became inactive.

### Now Playing and external controls

Publish, whenever available:

- title, artist, album, artwork, duration, elapsed position, and playback rate;
- queue index/count and service identifier when the queue model can provide
  them;
- play, pause, next, previous, and position-change commands only when the
  corresponding operation is supported.

Remote commands must enter the same serialized playback path as the mini-player
and full player. Never maintain a separate “lock-screen playing” flag.

### Queue and seek semantics

- A queue occurrence ID is distinct from a media ID; duplicates must remain
  independently addressable.
- Use Rust's `playOrder`, shuffle, repeat, autoplay, and persisted position
  semantics rather than recreating them in Swift.
- A seek updates the native player immediately and checkpoints the resulting
  position after the command is accepted. Buffering time, paused time, and
  seeks do not count as listening time.
- End-of-track transitions must go through the core so next, repeat-one, and
  repeat-all behave identically on every client.

### Artwork and metadata

- Keep remote artwork optional: show a deterministic Colorful fallback while
  loading, in low-data mode, offline, or after an HTTP failure.
- Cache artwork by a stable provider/media or artwork key. Do not download the
  same cover on every Now Playing update or every row redraw.
- Use the same artwork source for the collection page, mini-player, full
  player, and `MPNowPlayingInfoCenter` where possible.
- Artwork failures must never stop audio or make a track unplayable.

## iOS interaction conventions

- The compact player is a persistent affordance above the tab bar; tapping its
  content expands the player and tapping its transport control only toggles
  playback.
- The full player should expose progress, elapsed/remaining time, previous,
  play/pause, next, queue, output route, and the track's collection context.
- Search results should open collection context when a collection exists;
  playing a track and adding it to the queue remain distinct actions.
- Use sheets, navigation stacks, swipe actions, context menus, and system
  controls where they improve discoverability. Do not make passive branding or
  greeting text look or behave like a button.
- Support Dynamic Type, VoiceOver labels/traits, sufficient hit targets,
  Reduce Motion, and meaningful loading/empty/error states.
- Preserve Linux's small actions and fallbacks, but adapt desktop-only dense
  panels, hover behavior, keyboard shortcuts, and drag targets to touch.

## Data, privacy, and reliability

- Refresh tokens remain in Keychain; provider credentials never enter the Rust
  SQLite database or logs. An explicitly transferred provider credential is
  decrypted only for validation and immediate Keychain import.
- Signed playback URLs are short-lived transport data, not durable credentials.
  Re-resolve them after expiry, a failed stream, or a restored process.
- Use URLSession/background URLSession for catalog and download work. Do not
  assume a suspended app can keep arbitrary tasks alive.
- Every provider request needs loading, cancellation, authentication-expired,
  rate-limit, offline, and retry states. A stale authorization screen must be
  reconciled when the user returns from Safari.
- Keep listening-history writes tied to actual audible playback boundaries,
  not button taps or time spent buffering.

## Current status and next hardening

Implemented in the current iOS slice:

- Rust-backed queue/library snapshot and serialized core access;
- TIDAL device authorization and Keychain refresh-token storage;
- native TIDAL source resolution and `AVPlayer` playback;
- audio background mode, Now Playing text metadata, remote transport commands;
- lifecycle reconciliation, periodic position checkpointing, and remote artwork
  loading for Now Playing;
- native album collection context, mini-player artwork, artwork-derived player
  and album palettes, full-player queue editing, and Play Next;
- native buffering indication, retry feedback, occurrence-aware duplicate queue
  transitions, and reason-aware interruption/route handling foundations.
- qualified audible-time accounting backed by idempotent core history events,
  plus a provider-aware Home rotation derived from core listening statistics.

Next P0 hardening before calling playback reliable:

1. Verify the new buffering, retry, interruption, and headset-removal behavior
   on physical hardware and add source-expiry retry policy.
2. Verify qualified audible-time history on a physical device across buffering,
   pauses, seeks, interruptions, background playback, and queue transitions.
3. Prepare the next item for lower-latency transitions where provider sources
   permit it.
4. Test lock/unlock, Control Center, AirPods connect/disconnect, phone calls,
   Siri, rapid pause/play, rapid next/previous, seek during buffering, and
   process restoration on a physical iPhone.
5. Add the remaining Linux parity details in the iOS UI: autoplay, downloads,
   lyrics, history, action feedback, and provider/account edge states.

ActivityKit Live Activities are a later layer, not a replacement for Now
Playing. They should be introduced only after the native player has a stable
source of truth; the activity reads playback state and routes user actions back
through the same playback owner.

## Apple references

- [Playing audio — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/playing-audio)
- [AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession)
- [Handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
- [Responding to audio route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)
- [MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)
- [MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)
- [ActivityKit](https://developer.apple.com/documentation/activitykit)
