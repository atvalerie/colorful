# Android shell

Kotlin/Compose shell backed by the portable Rust engine. Build with:

```bash
./scripts/build-android.sh
```

The build produces arm64 phone and x86_64 emulator libraries under the ignored
`apps/android/build` directory. Press **Write persistence marker**, force-close,
and relaunch; the library count proves Kotlin, JNI, Rust, and SQLite reconnect.

Playback lives in a Media3 `MediaSessionService`, not the activity. The service
owns ExoPlayer, audio focus, noisy-output handling, system media controls, and
the future provider-source boundary.
