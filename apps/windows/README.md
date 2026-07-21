# Windows shell

**Status:** Native foundation. The WinUI 3 application builds, opens the shared
Rust/SQLite engine through its stable ABI, and owns a Windows `MediaPlayer`
playback boundary with system media-command support.

The current shell is the beginning of the Windows vertical slice, not feature
parity with Linux. Provider authorization, catalog pages, downloads, queue
hydration, Discord integration, and the complete player UI still need their
Windows adapters.

## Toolchain

- Visual Studio 2022 with .NET desktop and Desktop development with C++
- Windows SDK 10.0.26100 or newer
- .NET 9 SDK
- Rust stable with the `x86_64-pc-windows-msvc` host
- CMake and Ninja (the Visual Studio copies are sufficient)
- Git and Bun for the rest of the monorepo

The project currently uses Windows App SDK `1.8.260710003`, the final supported
1.8 servicing release available to the installed .NET 9 / Visual Studio 2022
toolchain. It targets Windows 10 build 19041 and runs unpackaged with a
self-contained Windows App SDK runtime.

## Build and run

From PowerShell at the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\run-windows.ps1
```

`build-windows.ps1` imports the Visual Studio developer environment, builds
`colorful-core.dll`, restores the WinUI NuGet graph, and copies the native core
next to the application executable. `run-windows.ps1` rebuilds by default; use
`-NoBuild` for an immediate relaunch.

The engine database is stored under `%LOCALAPPDATA%\colorful\colorful.sqlite`.
Provider credentials must use Windows Credential Manager and must never enter
that database.
