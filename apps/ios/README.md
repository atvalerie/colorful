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
transcodings. Mixed search opens native public profile and set pages, while
large sets hydrate SoundCloud's compact track IDs in bounded batches before
queueing or playback. Account import, personalized shelves, and downloads
remain follow-up slices.
Public YouTube Music song/video search and native playback are available in
the same mixed search surface. Playback now prefers the public native-iOS HLS
response, resolves its AAC-LC audio rendition, validates the VOD playlist, and
hands its HTTPS media segments to AVFoundation's native HLS stack. Safari HLS
is the secondary strategy; Android VR and downgraded TV AAC/MP4 sources remain
last-resort direct-stream fallbacks. YouTube artist, album, account, library,
and authenticated deciphering surfaces remain follow-up work.

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

The current shell uses Swift, SwiftUI, AVFoundation/AVPlayer, AVAudioSession,
Keychain, background audio mode, MPRemoteCommandCenter, and
MPNowPlayingInfoCenter. It reuses the shared engine contracts and uses Android
and desktop behavior as references. The first TIDAL playback slice, public
YouTube Music/SoundCloud search and playback, native queue/library projections,
lyrics, and the first offline download flows are connected. Physical-device
validation, provider account/library expansion, and remaining parity work are
still in progress; Android product parity is not a prerequisite.

To build the shell on macOS, see [`../../docs/ios-builds.md`](../../docs/ios-builds.md).

Read the implementation baseline in:

- [`../../docs/ios-product.md`](../../docs/ios-product.md)
- [`../../docs/ios-ui.md`](../../docs/ios-ui.md)
- [`../../docs/ios-architecture.md`](../../docs/ios-architecture.md)
- [`../../docs/ios-parity.md`](../../docs/ios-parity.md)
- [`../../docs/ios-builds.md`](../../docs/ios-builds.md) for macOS CI and signing
