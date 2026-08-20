# iOS CI on hosted macOS

**Status:** Implemented for unsigned simulator and device builds.

The repository contains the native project at `apps/ios/Colorful.xcodeproj`.
Because compiling and archiving it requires Xcode,
`.github/workflows/ios-build.yml` runs the iOS build on GitHub's pinned
`macos-14` image.

## Current workflow

For relevant pushes to `dev`, pull requests, and manual runs, CI:

- builds `colorful-core` for the matching Apple simulator target;
- builds and uploads an unsigned simulator `.app`;
- builds `colorful-core` for `aarch64-apple-ios`;
- archives and uploads an unsigned device IPA; and
- updates the `dev-nightly` prerelease IPA after successful `dev` pushes.

The workflow keeps signing disabled and does not require certificates,
provisioning profiles, Apple-account credentials, or other signing secrets.
See [iOS builds](ios-builds.md) for local commands, artifact details, and the
nightly download URL.

## Signing limitation

An unsigned IPA is useful for compile validation, import-based containers, and
as input to a separate local signing step, but it is not directly installable
through SpringBoard. Direct device installation still requires Xcode-managed
signing or an appropriate Apple Developer Program certificate and provisioning
profile. If CI signing is added later, all signing material must remain in
encrypted CI secrets and out of Git.
