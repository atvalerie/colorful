# colorful for Windows

The active Windows target is the shared Qt Quick/QML desktop client under
`apps/linux` (the directory name is historical). It provides the same catalog,
library, downloads, queue, lyrics, settings, and player UI as Linux.

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
Khronos/LunarG Vulkan loader, yt-dlp, and a GPL FFmpeg build under the current
user profile. The build script compiles the Rust core and provider host, builds
the Qt application, then deploys its runtime dependencies to
`build\windows-qt`. Relaunch an existing build with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-windows.ps1 -NoBuild
```

The old C#/WinUI prototype remains in this directory as an archived experiment,
but the standard Windows scripts now target the Qt client.

The engine database and encrypted credential files live beneath the current
user's local application-data directory. Secrets never enter SQLite.
The public TIDAL clients are built in. Both the native executable and launcher
discover optional overrides from a sibling `mocha\.env` and the repository's
`.env`; neither file is copied or printed. Explicit process environment values
take precedence. Provider sessions remain in the per-user DPAPI store and do
not depend on an `.env` file.
