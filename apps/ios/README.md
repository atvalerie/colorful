# iOS shell

**Status:** The SwiftUI shell, Rust-backed snapshot, queue/library projection,
TIDAL device authorization, Keychain refresh-token storage, and TIDAL search
projection are connected. Device authorization persists across the Safari
handoff, pauses safely in the background, and resumes when the app is active.
Native audio output and Now Playing integration are the next slice; search
results can be queued, but they are not audible yet.

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
