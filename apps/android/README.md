# colorful for Android

The Android client is a working native vertical slice built with Kotlin,
Jetpack Compose, Media3, JNI, and the shared Rust/SQLite engine. Its application
ID is `sh.valerie.colorful`; the minimum supported Android version is API 28.

## What works

- TIDAL device authorization with process-safe polling;
- refresh-token encryption in Android Keystore;
- account-country discovery and caching, with `US` as the fallback;
- TIDAL track search, play-now, and enqueue actions;
- HLS playback through Media3/ExoPlayer;
- a background `MediaSessionService` with notification, lock-screen, headset,
  audio-focus, and noisy-output handling;
- persistent Rust/SQLite queue state and periodic playback-position
  checkpoints; and
- arm64 phone and x86_64 emulator builds.

The Compose activity is intentionally still a compact engineering UI. The
service owns playback and provider source resolution, so closing or recreating
the activity does not own or reset the session.

Android does not yet have the desktop catalog pages, YouTube Music provider,
offline-download manager, EQ/normalization controls, or final visual design.
The desktop Bun provider host is not embedded in the APK. Android provider
work must use native/shared request contracts and platform networking; the
typed desktop YouTube Music implementation is the reference for future
`search`, `browse`, `next`, and `player` support.

## Build

Install Android Studio and the repository-pinned SDK 36, NDK
`30.0.15729638`, and CMake 4.1.2. Install the Rust Android targets:

```bash
rustup target add aarch64-linux-android x86_64-linux-android
```

The public TIDAL client configuration is built in; environment values or the
sibling `../mocha/.env` can override it. Run from the repository root:

```bash
./scripts/build-android.sh
```

The script uses Android Studio's bundled JBR by default and honors
`ANDROID_SDK_ROOT`, `ANDROID_NDK_ROOT`, and `COLORFUL_JAVA_HOME` overrides. The
debug APK is written to `apps/android/app/build/outputs/apk/debug/app-debug.apk`.

## Manual smoke test

1. Install and launch the debug APK.
2. Link TIDAL and return to colorful after the browser reports success.
3. Confirm the displayed country changes to the account country after refresh.
4. Search for a track, play it, enqueue another, and use the system media UI.
5. Force-close the activity and reconnect to the still-owned or restored media
   session; verify that queue and checkpointed position survive recreation.

Provider secrets and signed playback URLs must never be included in bug-report
logs or screenshots.

## Next milestone

Android feature parity is the active cross-platform milestone: product UI,
complete catalog navigation, YouTube Music and SoundCloud, provider-neutral
playlists, downloads and storage controls, lyrics caching, EQ/normalization,
and device/emulator playback restoration tests. iOS follows after these shared
behaviors have been exercised on Android.
