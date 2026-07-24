# colorful for Windows

The active Windows target is the shared Qt Quick/QML desktop client under
`apps/linux` (the directory name is historical). It provides the same catalog,
library, downloads, resizable queue, lyrics, settings, first-launch setup, and
player UI as Linux. The shared Home feed and combined Search prioritize
providers using device-local listening time, while retaining each provider's
own result ordering.

That shared feature set includes TIDAL, public and optionally authenticated
YouTube Music, and SoundCloud. YouTube catalog/radio/playback use typed native
Innertube requests, with the pinned `youtubei.js` player implementation only
for restricted cipher transforms. Offline YouTube transfers use resumable
1 MiB HTTP byte ranges; no external video extractor is required.

Windows-specific integration includes:

- libmpv with WASAPI shared output and an optional exclusive-output mode;
- System Media Transport Controls for media keys, metadata, artwork, and the
  Windows media flyout;
- per-user DPAPI encryption for provider and Discord credentials;
- Discord named-pipe IPC;
- a standalone compiled provider host, so Bun is a build dependency rather
  than a runtime dependency.

## Toolchain

- Visual Studio 2022 with Desktop development with C++ (MSVC x64)
- a current Windows 10/11 SDK
- Rust stable with the `x86_64-pc-windows-msvc` host
- Bun, CMake, Ninja, and Git
- Inno Setup 6 for setup executables (`winget install JRSoftware.InnoSetup`)

## Build and run

From PowerShell at the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\provision-windows-qt.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\run-windows.ps1
```

The provisioner installs Qt, a libmpv development bundle, the official
Khronos/LunarG Vulkan loader and a GPL FFmpeg build under the current
user profile. The build script compiles the Rust core and provider host, builds
the Qt application, then deploys its runtime dependencies to
`build\windows-qt`. Relaunch an existing build with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-windows.ps1 -NoBuild
```

The old C#/WinUI prototype remains in this directory as an archived experiment,
but the standard Windows scripts now target the Qt client.

## Distributable builds

Create a clean Release build and no-install ZIP with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package-windows.ps1
```

The archive contains the application, Qt runtime/plugins, libmpv, the Rust
core, provider and credential helpers, Vulkan loader, FFmpeg, license,
and notices. Add `-Installer` when Inno Setup 6 is available to create a
per-user installer from the identical staging directory. Use `-NoBuild` only
when the existing `build\windows-qt` output has the intended configuration.

These artifacts are currently unsigned, so Windows SmartScreen may warn the
recipient. The ZIP is no-install portable; settings, downloads, and encrypted
sessions intentionally remain in the recipient's local application-data
directory.

## Versions and installer upgrades

`VERSION` at the repository root is the authoritative desktop release version.
It is a numeric `major.minor.patch` value and is embedded in the Qt executable,
shown in Settings diagnostics, and used for every artifact and installer
registry entry. Increment it once for every setup release:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\set-version.ps1 -Version 0.1.1
powershell -ExecutionPolicy Bypass -File .\scripts\package-windows.ps1 -Installer
```

Commit the version change with the release. The installer has a permanent
Inno Setup `AppId`; never regenerate or change it. Running a newer setup over
an installed copy therefore updates the same per-user installation and
Add/Remove Programs entry. It reuses the previous destination, asks to close a
running copy, replaces the private runtime bundle, and preserves the database,
downloads, settings, and encrypted sessions stored outside the install
directory. An older setup refuses to overwrite an executable with a newer
embedded version.

Before sharing a release, test an actual two-version upgrade in a clean VM:

1. Install the previous setup and sign into the intended providers.
2. Play a track, alter a setting, and create or resume a download.
3. Build a setup with a higher `VERSION` and run it without uninstalling.
4. Confirm there is one installed-app entry with the new version.
5. Confirm the executable reports the new version and the prior data survives.
6. Exercise playback, credentials, media controls, Discord, and downloads.

Once the Windows and Linux packages pass their clean-machine checks, create and
push an annotated `vMAJOR.MINOR.PATCH` tag matching `VERSION`. The GitHub
Actions release workflow builds both platforms and creates one GitHub Release
containing all four desktop artifacts. A platform failure prevents publication.

Every non-documentation push to `main` also runs the desktop dev-build workflow.
It produces 14-day Windows and Linux artifacts labelled
`MAJOR.MINOR.PATCH-dev.RUN+COMMIT` inside the application; artifact and
installer filenames carry the same `dev.RUN` marker. A manual workflow run can
build only Windows, only Linux, or both. Dev installers retain the permanent
application identity and numeric base version, so a subsequent higher stable
release upgrades the same installation normally.

The client checks the latest stable GitHub Release periodically and previews
its Markdown changelog in-app. Choosing **Install update** streams the matching
setup executable to a temporary file, verifies the SHA-256 digest published by
GitHub for that release asset, starts the installer, and exits colorful.
Missing or mismatched integrity metadata is never executed and falls back to
the release page.

The engine database and encrypted credential files live beneath the current
user's local application-data directory. Secrets never enter SQLite.
The public TIDAL clients are built in. Both the native executable and launcher
discover optional overrides from a sibling `mocha\.env` and the repository's
`.env`; neither file is copied or printed. Explicit process environment values
take precedence. Provider sessions remain in the per-user DPAPI store and do
not depend on an `.env` file.

FFmpeg and ffprobe are used to probe and assemble completed offline media.
YouTube's network transfer is handled by the Qt client as bounded byte ranges,
then remuxed without re-encoding into the same standalone `.mka` format used
on Linux. Pausing or restarting preserves the raw byte checkpoint and resolves
a fresh signed source before resuming.

## Diagnostics

The application prints its rotating diagnostic-log path at launch. The log is
stored under the current user's local application-data directory and records
sanitized provider, playback, and YouTube range-transfer timing. Signed media
URLs, cookies, and authorization values are redacted and must not be included
in bug reports. Its `display` entry records the active screen resolution,
logical DPI, Qt scale factor, and text renderer.

For display regressions, report the Windows **Settings > System > Display >
Scale** value; "2K" resolution alone does not identify the effective UI scale.
Test 2560x1440 at 100%, 125%, and 150%, then move the running window between
monitors with different scale factors. Text, controls, hit targets, and layout
should remain crisp and retain the same logical size after the move. Also open
the executable's **Properties > Compatibility > Change high DPI settings** and
leave **Override high DPI scaling behavior** unchecked: a `System` override
causes Windows to bitmap-scale the whole application and makes it blurry.
