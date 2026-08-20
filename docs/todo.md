# colorful TODO

This is the canonical implementation backlog. Keep completed work out of this
file unless it provides necessary context for the next milestone.

## Next milestone: desktop distribution

- continue testing Linux AppImage and portable archive releases on clean
  machines rather than development hosts;
- keep validating the published Linux artifacts from the containerized Ubuntu
  22.04 builder with its glibc 2.35 ceiling;
- test the Windows portable ZIP and a two-version in-place installer upgrade
  in a clean Windows VM;
- verify bundled playback dependencies, codecs, credential storage, downloads,
  and provider helpers on both platforms;
- continue fixing playback, provider, layout, and packaging bugs found by
  real-world testing.

## Local music library

- add configurable library folders, recursive scanning, file watching, and a
  persistent local-media index;
- play local files through the shared desktop playback, queue, history,
  ReplayGain, artwork, lyrics, and Discord RPC paths;
- browse local music by artist, album, album artist, genre, year, folder,
  recently added, and recently played;
- allow provider-neutral playlists and queues to mix local and streaming
  tracks;
- add safe single-track and batch tag editing for title, artist, album artist,
  album, track and disc numbers, year, genre, lyrics, and cover artwork;
- preserve unknown metadata where possible and use atomic writes, backups,
  rescanning, and undo for destructive tag changes;
- add smart playlists, duplicate detection, and missing-file cleanup after the
  core library and tag workflows are reliable;
- consider transcoding, format conversion, CD support, and deeper
  Strawberry-style library tools later.

## Deferred: Android product parity

Android remains an engineering vertical slice and will continue to receive
shared-contract and playback fixes, but its unfinished product UI is not an
iOS prerequisite. iOS is the next native product client because it is the
owner's daily-driver platform.

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

## iOS native client — next product milestone

- harden AVPlayer ownership, buffering, interruption recovery, route changes,
  rapid transport commands, and restored queues on physical iPhones;
- complete the remaining TIDAL account, catalog, library, playlist, and action
  surfaces using the shared contracts and the iOS documents;
- expand YouTube Music and SoundCloud account/library support beyond the
  current public search, catalog, and playback slices;
- finish provider-neutral local playlists, autoplay, settings, action
  feedback, and provider/account edge states in the order defined by
  `docs/ios-parity.md`;
- harden offline downloads and exported-file metadata, including explicit
  LiveContainer compatibility and storage-cleanup behavior;
- validate the existing unsigned simulator and device-IPA CI artifacts, then
  add signed distribution or TestFlight only when signing material and an
  Apple Developer Program workflow are available.

The iOS client should continue to be tested on the daily-driver phone as its
native playback and provider slices mature. Android remains a later
product-parity track and must not gate iOS work.

## Multi-device sync

Persistent sync work is paused after the reusable identity/pairing foundation
while the party vertical slice is the active priority.

- require explicit local identity creation before enabling persistent sync;
- expose the implemented encrypted identity recovery and numeric-code pairing
  core through platform secure storage and UI;
- define versioned operations and persist the append-only local journal;
- add deterministic two-device export/import and merge tests;
- persist trusted-device enrollment, add optional QR invite transport, and
  implement permission management and revocation;
- implement authenticated LAN discovery and encrypted direct transport;
- add ICE/STUN connectivity plus relay or encrypted-mailbox fallback;
- synchronize library state, playlists, history, preferences, and optional
  queue snapshots;
- add explicit provider-credential handoff between confirmed devices, with
  provider copy/move policy, destination secure-store import, and no sync-journal
  persistence;
- implement explicit playback handoff;
- publish expiring active-device presence so desktop Discord RPC can represent
  playback occurring on a paired phone.

The detailed security and merge model lives in [sync.md](sync.md).

Product decisions for identity, device permissions, parties, ownership
transfer, and Discord are in [social-model.md](social-model.md).

## Later

- migrate provider behavior away from the transitional Bun sidecar where a
  shared or native implementation is practical;
- connect the implemented party protocol to two desktop clients through the
  opaque relay, then add LAN, peer-to-peer connectivity, and relay fallback;
- deeper appearance and accent customization;
- optional encrypted local-file transfer between trusted devices;
- provider write actions only if they become an explicit product requirement.
