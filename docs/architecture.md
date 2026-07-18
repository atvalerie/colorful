# Architecture

## Principle

colorful is local-first. A network connection is needed for provider catalog
and streaming operations, optional metadata sources, and remote parties, but
not for the local library, queue, downloaded playback, or settings.

## Runtime shape

```text
Native UI
  |  typed commands/events
Native playback adapter ---- OS audio + media session
  |
colorful engine (Rust) ------ SQLite, cache, downloads, party state
  |
Provider adapter ------------ TIDAL / SoundCloud / optional YouTube
```

The playback adapter is deliberately native. It must expose prepared-next-item
and transition callbacks so the engine can arrange gapless playback without a
network request or decoder startup on the track boundary.

## Why the previous TypeScript core is not discarded

The code in `../backend` is strongly typed and already contains valuable
provider clients, normalized media models, download adapters, palette scoring,
and tested parsing behavior. It is the behavioral reference and enables a fast
desktop spike through Bun.

Bun and Node APIs are not a dependable application runtime on Android or iOS.
Embedding a JavaScript engine would also require us to implement networking,
crypto, secure storage, cancellation, and background-lifecycle bridges twice.
Therefore:

1. Keep pure provider contracts and fixture tests in TypeScript.
2. Use a Bun provider sidecar only during the first desktop milestone.
3. Port adapters into the Rust engine provider-by-provider.
4. Run the TypeScript and Rust adapters against identical sanitized fixtures
   until their normalized results match.

This is a migration, not a rewrite performed all at once.

## Ownership boundaries

### Portable engine

- normalized media identities and provider references
- queue, repeat, shuffle, autoplay, and transition planning
- SQLite repositories and migrations
- download jobs, resumable cache, quotas, and eviction
- provider orchestration and token refresh state
- party queue operations and synchronized clock model
- artwork palette output and accessible color derivation

### Native shell

- audio decoding/output and device routing
- media session / lock-screen / headset controls
- audio focus, interruptions, calls, and background execution
- secure credential storage
- filesystem pickers and platform permissions
- notifications and download foreground services
- native UI and accessibility

### DSP

EQ, gain, limiter, loudness normalization, and crossfade belong behind a common
DSP contract. The implementation may be shared where platform APIs allow raw
PCM access, but the platform playback adapter controls insertion into its audio
graph. Gapless is not implemented as a crossfade and must work with EQ off.

## Native targets

| Target | UI | Playback integration |
| --- | --- | --- |
| Android | Kotlin + Jetpack Compose | Media3 session with a custom audio/DSP boundary |
| Linux | C++ + Qt Quick/QML | Qt Multimedia/FFmpeg with MPRIS over QtDBus |
| Windows | C# + WinUI | Media Foundation/WASAPI adapter |
| iOS | Swift + SwiftUI | AVAudioEngine/AVFoundation + MPNowPlayingInfoCenter |

The exact playback backend stays replaceable until gapless, lossless formats,
EQ, background behavior, and device switching pass acceptance tests.

## Delivery order

1. Domain contracts, queue state machine, SQLite schema, and provider fixtures.
2. Linux shell plus Bun provider spike and real TIDAL device linking.
3. Rust TIDAL adapter, download manager, and gapless Linux playback.
4. Android shell using the same Rust adapter and local database model.
5. SoundCloud adapter, party sessions, and relay deployment.
6. Windows shell, then iOS shell and cloud build/signing workflow.
