# colorful documentation

This is the documentation hub for colorful. Use the sections below to find platform notes, design decisions, provider setup, and development references.

## Getting started and platforms

- [Project overview](../README.md) — Product overview, downloads, architecture summary, and build entry points.
- [Android client](../apps/android/README.md) — Android client structure, supported functionality, builds, and smoke tests.
- [Design Lab](../apps/design-lab/README.md) — Disposable React prototype used to explore the visual language.
- [Linux desktop client](../apps/linux/README.md) — Shared Qt desktop client requirements, launch instructions, packaging, and platform controls.
- [Windows desktop client](../apps/windows/README.md) — Windows build, packaging, installer, and diagnostics notes.
- [Deep links](deep-links.md) — `colorful://` catalog-link formats and handling.

## Architecture, core, and storage

- [Architecture](architecture.md) — Runtime shape, ownership boundaries, native targets, and delivery structure.
- [Native core ABI](core-abi.md) — C ABI rules, JSON command/event shapes, and native-shell integration.
- [Local storage](storage.md) — SQLite state, credentials, downloaded media, migrations, and retention boundaries.

## Providers and accounts

- [Provider migration map](provider-migration.md) — Provider concepts and implementation boundaries carried into colorful.
- [YouTube Music account setup](youtube-music-login.md) — Browser-based account connection and manual fallback.
- [SoundCloud account setup](soundcloud-login.md) — Browser-based account connection and manual fallback.

## iOS

- [iOS shell](../apps/ios/README.md) — Native SwiftUI client scope, Rust integration, playback, and account features.
- [iOS architecture](ios-architecture.md) — SwiftUI, Rust, playback, provider, offline, and sync ownership.
- [iOS builds](ios-builds.md) — Local Xcode builds and the optional Rust-core integration.
- [iOS CI on hosted macOS](macos-ci.md) — Hosted workflow for unsigned simulator and device builds.
- [iOS parity matrix](ios-parity.md) — Desktop reference behavior, iOS targets, and priorities.
- [iOS platform practices](ios-platform-practices.md) — Playback, audio-session, controls, queue, artwork, and reliability rules.
- [iOS product baseline](ios-product.md) — Product direction, sequencing, and current non-goals for the native client.
- [iOS UI and design system](ios-ui.md) — Visual direction, navigation, interactions, and design tokens.

## Sync, social, and relay

- [Hosted backend boundary](backend.md) — Service roles, privacy boundaries, and invite/party URL handling.
- [Party connectivity](connectivity.md) — Connection ladder, relay use, synchronized state, and security baseline.
- [Identity and device pairing](identity-and-pairing.md) — Local identity material, recovery exports, and pairing confirmation.
- [Listening parties](parties.md) — Party protocol, invitations, participant controls, and synchronization behavior.
- [Identity, devices, sync, and parties](social-model.md) — Product model for identities, devices, pairing, and parties.
- [Multi-device sync](sync.md) — Sync goals, data boundaries, pairing, merges, handoff, and delivery order.
- [Relay backend](../services/colorful-relay/README.md) — Relay service endpoints, local development, and deployment notes.

## Contributing, release, and roadmap

- [Contributing](../CONTRIBUTING.md) — Commit conventions, checks, and release contribution guidance.
- [Third-party notices](../THIRD_PARTY_NOTICES.md) — Third-party components and their licenses.
- [TODO and roadmap](todo.md) — Canonical implementation backlog and upcoming work.
