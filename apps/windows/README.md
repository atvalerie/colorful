# colorful for Windows

The active Windows target is the shared Qt Quick/QML desktop client under
`apps/linux` (the directory name is historical). It provides the same catalog,
library, downloads, queue, lyrics, settings, and player UI as Linux.

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
in bug reports.
