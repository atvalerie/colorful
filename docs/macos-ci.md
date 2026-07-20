# iOS builds without a local Mac

**Status:** Planning note. The repository has no Xcode project and no macOS CI
workflow yet.

The repository can be edited on Linux, but the final iOS compile, codesign, and
device archive requires Xcode on macOS.

## Recommended initial setup

Use GitHub Actions with a hosted `macos-latest` runner for the first unsigned
simulator builds and compile checks. GitHub currently maps standard
`macos-latest` to arm64; pin a specific image label once the project depends on
a particular Xcode/SDK combination. Once signing credentials and provisioning
are available, the same workflow can archive a signed IPA. Keep certificates,
profiles, and passwords in encrypted CI secrets and never in Git.

Codemagic and Bitrise are good alternatives when managed mobile signing and
artifact handling are more useful than a generic CI workflow. Cirrus CI also
offers Apple Silicon macOS VMs. Xcode Cloud is attractive later, but its setup
requires Apple Developer Program enrollment, an App Store Connect app record,
a remotely hosted Git repository, and initial workflow configuration through
Xcode.

## Important limitation

Cloud macOS solves compilation; it does not remove Apple's signing and device
provisioning rules. A free Personal Team is awkward to automate because its
short-lived profiles are normally managed interactively by Xcode. For weekly
sideloading, expect either occasional access to a real/remote Mac plus a
sideloading tool, or use paid Developer Program signing/TestFlight when the app
is mature enough to justify it.

Do not build a signing workflow until the iOS target exists. The first CI file
should be an unsigned simulator build so it cannot leak signing material.

## References

- [GitHub-hosted macOS runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [Codemagic signed native iOS builds](https://docs.codemagic.io/yaml-quick-start/first-signed-build/)
- [Bitrise iOS deployment](https://docs.bitrise.io/en/bitrise-ci/deploying/ios-deployment/deploying-an-ios-app-to-bitrise-io.html)
- [Cirrus CI macOS VMs](https://cirrus-ci.org/guide/macOS/)
- [Xcode Cloud setup requirements](https://developer.apple.com/documentation/xcode/setting-up-your-project-to-use-xcode-cloud)
