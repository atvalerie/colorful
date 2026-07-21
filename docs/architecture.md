# Architecture

## Principle

colorful is local-first. A network connection is needed for provider catalog
and streaming operations, optional metadata sources, and remote parties, but
not for the local library, queue, downloaded playback, or settings.

## Runtime shape

```text
Native UI
  ├── native playback adapter ─── OS audio + media session
  ├── secure credential store
  ├── provider/source adapter
  └── versioned C/JSON commands and events
                         │
                  colorful-core (Rust)
                         │
        SQLite · queue · library · settings
        download records · listening history
```

Today Linux obtains TIDAL, public SoundCloud, and public YouTube Music data through the
transitional Bun provider host, then plays through libmpv. Android implements
its TIDAL authorization, account, search, and source resolution natively and
plays through Media3. Neither shell sends provider credentials into the Rust
database.

Provider account state uses a common shell-facing contract, while each native
shell owns credential persistence. TIDAL uses device authorization and stores
its refresh token in the platform credential service. Linux YouTube Music
instead imports a logged-in browser session into Secret Service because Google
currently rejects custom-client OAuth tokens on its private Music endpoints.
Linux SoundCloud may import the OAuth header from the user's own logged-in API
request; only that token is retained in Secret Service.
An Android implementation will store equivalent provider credentials in
Keystore while reusing the provider request semantics.

The playback adapter is deliberately native. It must expose prepared-next-item
and transition callbacks so each shell can arrange gapless playback without a
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
2. Keep the Bun provider sidecar for the Linux alpha while native adapters are
   brought to parity.
3. Port adapters into the Rust engine provider-by-provider.
4. Run the TypeScript and Rust adapters against identical sanitized fixtures
   until their normalized results match.

This is a migration, not a rewrite performed all at once.

## Ownership boundaries

### Portable engine

- normalized media identities and provider references
- queue, repeat, shuffle, current selection, and playback directives
- SQLite repositories and migrations
- durable offline-job records and downloaded-file paths
- idempotent listening events and aggregate statistics
- provider-neutral settings

The sync journal, party transport, cache quotas/eviction, and portable provider
orchestration remain planned. Linux currently owns the resumable transfer
worker; the engine persists its provider-neutral job state.

### Native shell

- audio decoding/output and device routing
- media session / lock-screen / headset controls
- audio focus, interruptions, calls, and background execution
- secure credential storage
- filesystem pickers and platform permissions
- notifications and download foreground services
- provider authorization, token refresh, and source resolution until each
  adapter has a suitable portable home
- native UI and accessibility

On Android the `MediaSessionService` is the long-lived native playback owner.
It holds the portable engine handle, resolves provider sources off the main
thread, maps Rust queue operations to a Media3 playlist, and checkpoints player
position. Compose Activities are controllers of that service rather than
owners of playback or provider sessions.

### DSP

EQ, gain, limiter, loudness normalization, and crossfade belong behind a common
DSP contract. The implementation may be shared where platform APIs allow raw
PCM access, but the platform playback adapter controls insertion into its audio
graph. Gapless is not implemented as a crossfade and must work with EQ off.

The portable contract fixes ten bands at 31 Hz through 16 kHz, bounds each to
±12 dB, and carries the normalization preference. Linux implements the bands
with libmpv's FFmpeg audio-filter graph, adds a limiter only while EQ is active,
and uses TIDAL's per-track manifest ReplayGain and peak values for streamed
normalization. Those values are written as standard ReplayGain tags in offline
Matroska files; other local files use their existing embedded tags. Other native
adapters map the same contract onto their platform audio graphs.

## Native targets

| Target | UI | Playback integration |
| --- | --- | --- |
| Android | Kotlin + Jetpack Compose | Media3 session with a custom audio/DSP boundary |
| Linux | C++ + Qt Quick/QML | embedded libmpv with MPRIS over QtDBus |
| Windows | C# + WinUI | Media Foundation/WASAPI adapter |
| iOS | Swift + SwiftUI | AVAudioEngine/AVFoundation + MPNowPlayingInfoCenter |

Linux's libmpv backend already covers lossless playback, seeking, prepared-next
gapless transitions, EQ, and normalization. Android's Media3 service covers
background playback and system media controls; its DSP and offline features
remain incomplete.

## Current delivery state

- Complete: domain contracts, queue state machine, SQLite schema, stable ABI,
  provider fixtures, Linux TIDAL/public-YouTube alpha, Linux downloads/gapless
  playback/DSP, and the Android TIDAL playback vertical slice.
- Next: add Android feature parity,
  and migrate more provider behavior away from the Bun host.
- Later: SoundCloud, encrypted device sync and active-device presence, parties,
  Windows, then iOS and its cloud build/signing workflow.
