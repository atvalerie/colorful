# iOS shell

**Status:** Planned. There is no Xcode project or buildable iOS target in the
repository yet.

Planned stack: Swift, SwiftUI, AVFoundation/AVAudioEngine, Keychain, background
audio mode, MPRemoteCommandCenter, and MPNowPlayingInfoCenter.

The iOS target follows Android so shared engine behavior is already exercised
before each cloud-mac build cycle. The active prerequisite is Android feature
parity across catalog navigation, providers, queue behavior, downloads,
lyrics, local playlists, and audio processing; iOS should reuse those shared
contracts instead of cloning desktop-side assumptions.

See [`../../docs/macos-ci.md`](../../docs/macos-ci.md) for the proposed
Linux-to-macOS CI and signing workflow.
