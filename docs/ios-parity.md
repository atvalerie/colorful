# iOS parity and implementation matrix

**Status:** Working matrix for the iOS-first milestone, 2026-08-16.

This matrix distinguishes current desktop behavior from the iOS target. It is
not a promise that every desktop feature belongs in the first phone release.

| Area | Current authoritative reference | iOS target | Priority |
| --- | --- | --- | --- |
| Desktop shell | Qt Quick/QML under `apps/linux`; shared by Windows | Native SwiftUI shell | P0 |
| TIDAL authorization | Desktop device link; Android native vertical slice | Device authorization + Keychain | P0 |
| TIDAL search/catalog/playback | Desktop broad implementation | Search, track, album, artist, playlist, and play | P0 |
| Home feed | Cross-provider shelves ordered by local listening time plus provider recommendations | Local rotation and native TIDAL daily/discovery/new-release shelves implemented | P1 |
| Combined search | Provider-prioritized desktop search | Native search with provider grouping/order | P1 |
| Queue | Rust/SQLite queue with duplicates, reorder, shuffle, repeat, autoplay | Same core state with iOS sheet UI | P0 |
| Library/playlists | Rust/SQLite library and Colorful-owned ordered playlists | Same core state and native editing flows | P0 |
| Listening history | Globally identified local events and provider aggregates | Implemented from qualified native audible time; physical-device lifecycle verification remains | P0 |
| Playback | libmpv, prepared-next, gapless, EQ/normalization | AVFoundation native playback foundation; harden buffering, transitions, and physical-device behavior | P0 |
| System media controls | Linux MPRIS; Windows SMTC | Now Playing + Remote Command Center | P0 |
| Offline downloads | Resumable desktop transfers and standalone `.mka` files | Native background HLS packages, durable Rust job state, offline playback, deletion, and tagged M4A export implemented; standalone lossless FLAC finalization and physical-device lifecycle validation remain | P1 |
| Lyrics | Provider-first, synced, cached, LRCLIB fallback | Native TIDAL user/catalog lookup plus synced/plain LRCLIB fallback implemented; caching remains | P1 |
| Appearance | Accent mode, fixed accent, low-data mode, text scale | Dynamic Type plus Colorful accent/low-data policies | P1 |
| Detail behavior | Linux optional actions, fallbacks, metadata, toasts, and edge-case handling | Preserve these details in native presentations; document intentional iOS divergences | P0 |
| EQ/normalization | Desktop contract; Android incomplete | Add after stable playback unless daily use requires it | P2 |
| YouTube Music | Desktop public/private-session catalog and playback | Later native adapter; restricted source resolution is a risk | P2 |
| SoundCloud | Desktop public/account catalog, playback, downloads | Later native adapter | P2 |
| Parties | Linux encrypted party client is current active social slice | Later native participant/host experience | P2 |
| Device sync | Identity/pairing foundation; merge journal and transport planned | Later, using existing sync/security documents | P2 |
| Updates/builds | Desktop packaging and GitHub release workflows | Unsigned simulator/device IPA through macOS CI first | P1 |

## Source-of-truth rules

- For current desktop product behavior, read `apps/linux/qml` and
  `apps/linux/src`; `apps/windows` contains the archived WinUI experiment plus
  documentation of the shared Qt Windows target.
- Treat Linux as the mobile behavioral baseline, including small optional
  actions and fallback states. A mobile-only simplification needs a reason;
  a mobile-only enhancement should fit the same local-first product model.
- Before closing an iOS feature, check the corresponding Linux surface for
  secondary actions, empty/loading/error states, metadata, artwork fallbacks,
  queue semantics, and feedback/toast behavior.
- For portable state, read `crates/colorful-core`, `docs/core-abi.md`, and
  `docs/storage.md` before adding Swift models.
- For provider semantics, read `docs/provider-migration.md` and the provider
  fixtures/tests; do not copy desktop UI assumptions into the provider layer.
- For sync, identity, parties, and permissions, read the dedicated security
  documents before exposing controls in iOS.
- For visual decisions, follow [the iOS UI baseline](ios-ui.md), not the
  disposable React prototype or the current Android engineering screen.
