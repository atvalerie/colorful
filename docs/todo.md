# colorful TODO

This is the canonical implementation backlog. Keep completed work out of this
file unless it provides necessary context for the next milestone.

## Next milestone: Android feature parity

- replace the compact engineering UI with the colorful product design;
- add first-launch provider/playback/storage setup and a personalized
  cross-provider Home ordered by device-local provider listening time;
- apply the same provider priority to combined search while retaining each
  service's own relevance order;
- add complete TIDAL catalog, account, library, playlist, mix, album, artist,
  and track pages;
- add YouTube Music account, catalog, radio, queue, and playback support;
- add SoundCloud account, catalog, radio, queue, and playback support;
- add resumable offline downloads, quotas, cleanup, and storage management;
- add synchronized and plain lyrics with offline caching;
- add provider-neutral local playlist creation and editing;
- implement the shared EQ, ReplayGain, and normalization contract;
- bring account, playback, appearance, and storage settings to useful parity;
- test queue restoration, background ownership, seeking, rapid skipping,
  prepared-next playback, and gapless transitions on devices and emulators.

## iOS native client

- create the SwiftUI/Xcode project and bind the shared Rust core;
- implement playback with AVFoundation/AVAudioEngine;
- implement background audio, MPRemoteCommandCenter, and Now Playing metadata;
- store credentials in Keychain;
- implement the provider adapters, catalog UI, queue, downloads, lyrics, and
  local library behavior exercised by Android;
- establish macOS CI, signing, and sideloadable IPA builds.

The iOS client should follow the Android parity milestone so shared behavior is
already exercised before each remote macOS build cycle.

## Multi-device sync

- define versioned operations and persist the append-only local journal;
- add deterministic two-device export/import and merge tests;
- implement device identity keys, QR pairing, trust management, and revocation;
- implement authenticated LAN discovery and encrypted direct transport;
- add ICE/STUN connectivity plus relay or encrypted-mailbox fallback;
- synchronize library state, playlists, history, preferences, and optional
  queue snapshots;
- implement explicit playback handoff;
- publish expiring active-device presence so desktop Discord RPC can represent
  playback occurring on a paired phone.

The detailed security and merge model lives in [sync.md](sync.md).

## Desktop and release follow-up

- test Linux and Windows packages on clean machines rather than development
  hosts;
- build public Linux artifacts on an older supported glibc base;
- add a polished Windows installer and decide whether releases will be signed;
- continue fixing playback, provider, layout, and packaging bugs found by
  real-world testing;
- migrate provider behavior away from the transitional Bun sidecar where a
  shared or native implementation is practical.

## Later

- listening parties over LAN, peer-to-peer connectivity, and relay fallback;
- customizable Discord statistics widgets and profile-board layouts;
- deeper appearance and accent customization;
- optional encrypted local-file transfer between trusted devices;
- provider write actions only if they become an explicit product requirement.
