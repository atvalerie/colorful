# Colorful

Colorful is a local-first personal music player for Android, Linux, Windows,
and iOS. Native platform shells own playback and OS integration; a portable
engine owns the queue, library, downloads, cache policy, and party state.

The first working vertical slice targets Linux desktop. Android follows after
the provider and playback boundaries have been exercised here.

## Try the Linux player

The current client is native Qt 6 Quick/QML with TIDAL device linking, catalog
search, streaming playback, a live queue, album-derived colors, secure refresh
token storage through Linux Secret Service, and MPRIS desktop controls.

```bash
./scripts/run-linux.sh
```

The launcher reuses the TIDAL configuration in the adjacent `mocha/.env`
without copying or displaying it. See `apps/linux/README.md` for the test flow
and troubleshooting.

## Repository map

- `apps/design-lab`: disposable React prototype for collaborative UI iteration
- `crates/colorful-core`: portable Rust domain and state-machine code
- `packages/provider-kit`: strict TypeScript provider contracts and migration
  fixtures derived from the existing backend
- `apps/linux`: native Qt/QML application
- `apps/*`: remaining native application integration plans
- `docs/architecture.md`: component boundaries and delivery order
- `docs/connectivity.md`: LAN, NAT traversal, relay, and party synchronization
- `docs/sync.md`: proposed encrypted multi-device sync and playback handoff
- `docs/storage.md`: device-local SQLite schema and migration rules
- `docs/provider-migration.md`: what to reuse from `backend` and `mocha`
- `docs/macos-ci.md`: practical iOS builds without owning a Mac

## Local checks

```bash
./scripts/test-linux.sh
./scripts/test-storage-schema.sh
```

## Non-goals

- A mandatory Colorful account or central media server
- Sending provider credentials to party peers or relays
- Reimplementing the audio engine in TypeScript
- Treating an HTTP URL as sufficient for gapless playback
