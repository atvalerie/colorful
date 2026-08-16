# iOS builds

The repository now contains the first native SwiftUI shell at
`apps/ios/Colorful.xcodeproj`. It is intentionally split into two build
layers:

- The default Xcode build compiles the shell without requiring a Rust artifact.
  This keeps UI work easy to preview on a Mac and keeps generated libraries out
  of Git.
- The opt-in build compiles `colorful-core` for the active Apple target and
  links it through the existing C ABI. The Swift shell verifies ABI v1, opens
  `Library/Application Support/Colorful/colorful.sqlite3`, and closes the
  handle on teardown.

## Local macOS build

From the repository root on macOS:

```sh
bash scripts/build-ios-core.sh aarch64-apple-ios-sim
xcodebuild \
  -project apps/ios/Colorful.xcodeproj \
  -scheme Colorful \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  COLORFUL_CORE_SWIFT_CONDITION=COLORFUL_CORE_ENABLED \
  COLORFUL_CORE_LIBRARY_SEARCH_PATH="$PWD/target/aarch64-apple-ios-sim/release" \
  COLORFUL_CORE_LDFLAGS="-lcolorful_core -framework Security" \
  build
```

For a physical iPhone IPA container, use the device Rust target and package the
unsigned archive:

```sh
bash scripts/build-ios-core.sh aarch64-apple-ios
xcodebuild archive \
  -project apps/ios/Colorful.xcodeproj \
  -scheme Colorful \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  -archivePath build/Colorful.xcarchive \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  COLORFUL_CORE_SWIFT_CONDITION=COLORFUL_CORE_ENABLED \
  COLORFUL_CORE_LIBRARY_SEARCH_PATH="$PWD/target/aarch64-apple-ios/release" \
  COLORFUL_CORE_LDFLAGS="-lcolorful_core -framework Security" \
  SKIP_INSTALL=NO
mkdir -p build/Payload
cp -R build/Colorful.xcarchive/Products/Applications/Colorful.app build/Payload/Colorful.app
cd build
zip -qry colorful-ios-unsigned.ipa Payload
```

The GitHub workflow performs this device archive automatically and uploads
`colorful-ios-unsigned.ipa`. This is a real device IPA container, but it is not
signed for SpringBoard installation. It is useful for testing import-based
containers such as LiveContainer or as the input to a local signing step.

For a directly installable iPhone IPA, select a connected device in Xcode and
let Xcode sign the app with the Apple account available on that Mac. The
repository does not commit signing certificates, provisioning profiles, or
generated `.a` files.

## GitHub Actions

`.github/workflows/ios-build.yml` uses a hosted macOS runner, builds both the
matching simulator app and an `aarch64-apple-ios` device archive, and uploads
both the unsigned simulator `.app` and `colorful-ios-unsigned.ipa`.

Pushes to `dev` also update the `colorful nightly` GitHub prerelease. The IPA
has a stable direct URL for import-based testing:

`https://github.com/atvalerie/colorful/releases/download/dev-nightly/colorful-ios-unsigned.ipa`

Pull requests build the IPA but do not publish or modify the nightly release.

An installable device IPA still needs signing. With a free Personal Team, the
usual Apple seven-day provisioning window remains a platform constraint. A
GitHub workflow can sign only when you provide your own signing material as
secrets, and it cannot turn a free account into a year-long distribution
certificate. For daily sideloading, keep signing/refreshing separate from this
reproducible build workflow.
