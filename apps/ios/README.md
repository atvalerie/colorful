# iOS shell

**Status:** The SwiftUI shell, Rust-backed snapshot, queue/library projection,
TIDAL device authorization, Keychain refresh-token storage, grouped search,
album/artist/playlist pages, personalized recommendation shelves, qualified
listening history, in-player synced/plain TIDAL lyrics with Rust-backed
successful-result caching and offline-download prefetch, and native TIDAL
playback are connected. Device
authorization persists across the Safari handoff, pauses safely in the
background, and resumes when the app is active. Native audio output, Now
Playing metadata, remote controls, lifecycle reconciliation, and artwork
loading are present. The full player now includes adaptive layout, output
routing, honest buffering/error feedback, artwork-derived color, nested queue
editing, repeat/shuffle, and occurrence-safe duplicate handling. Physical-device
hardening is still in progress. Credited artists are navigable from the full
player, including an artist chooser for collaborations and native TIDAL artist
pages with top tracks and album shelves. The Library now exposes the Rust-backed
saved-track collection and Colorful playlists, with native create, rename,
delete, reorder, removal, and track-action flows.
TIDAL search is grouped into relevance-ordered track, album, and artist
sections, and collection results navigate into the native album and artist
surfaces.
Public SoundCloud track search and native playback are also connected through
a Swift actor that discovers the current public web client, prefers AAC 160
HLS, refreshes rejected bootstrap credentials, and falls back across available
transcodings. SoundCloud set/profile pages, account import, and downloads remain
follow-up slices.

The first offline slice uses Apple's background asset-download session for
TIDAL HLS, persists every job through the Rust download state machine, prefers
completed local packages during playback, and exposes pause/resume, deletion,
storage totals, album batching, and one-action export/share. When AVFoundation
can expose the downloaded audio, lossless assets export through AudioToolbox as
standalone FLAC files and AAC assets export as tagged M4A files. The UI never
exposes Apple's internal HLS package as though it were a song file. Media paths are stored relative to
the application container and legacy absolute paths are rebased at lookup so
sideloading-container UUID changes do not orphan otherwise valid downloads.
LiveContainer also retains Apple's managed background package directly.
Copying a completed `.movpkg` out of that location can leave AVFoundation
unable to resolve its audio tracks, so export failure never invalidates a
playable offline download. Standalone export from LiveContainer remains a
separate compatibility limitation.

Planned stack: Swift, SwiftUI, AVFoundation/AVAudioEngine, Keychain, background
audio mode, MPRemoteCommandCenter, and MPNowPlayingInfoCenter.

The iOS target reuses the shared engine contracts and uses Android and desktop
behavior as references. The first milestone is a real TIDAL playback slice on
the daily-driver iPhone: SwiftUI, Keychain, AVFoundation/AVAudioEngine,
background audio, Now Playing controls, queue restoration, and native device
testing. Android product parity is not a prerequisite.

To build the shell on macOS, see [`../../docs/ios-builds.md`](../../docs/ios-builds.md).

Read the implementation baseline in:

- [`../../docs/ios-product.md`](../../docs/ios-product.md)
- [`../../docs/ios-ui.md`](../../docs/ios-ui.md)
- [`../../docs/ios-architecture.md`](../../docs/ios-architecture.md)
- [`../../docs/ios-parity.md`](../../docs/ios-parity.md)
- [`../../docs/ios-builds.md`](../../docs/ios-builds.md) for macOS CI and signing
