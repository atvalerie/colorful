# Colorful

Colorful is a local-first personal music player for Android, Linux, Windows,
and iOS. Native platform shells own playback and OS integration; a portable
engine owns the queue, library, downloads, cache policy, and party state.

This repository is intentionally at the architecture-foundation stage. The
first supported targets are Linux desktop and Android.

## Repository map

- `crates/colorful-core`: portable Rust domain and state-machine code
- `packages/provider-kit`: strict TypeScript provider contracts and migration
  fixtures derived from the existing backend
- `apps/*`: native application integration notes until each shell is created
- `docs/architecture.md`: component boundaries and delivery order
- `docs/connectivity.md`: LAN, NAT traversal, relay, and party synchronization
- `docs/provider-migration.md`: what to reuse from `backend` and `mocha`
- `docs/macos-ci.md`: practical iOS builds without owning a Mac

## Local checks

```bash
cargo test --workspace
cd packages/provider-kit
bun test
bun run typecheck
```

## Non-goals

- A mandatory Colorful account or central media server
- Sending provider credentials to party peers or relays
- Reimplementing the audio engine in TypeScript
- Treating an HTTP URL as sufficient for gapless playback

