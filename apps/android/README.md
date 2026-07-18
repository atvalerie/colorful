# Android shell

Kotlin/Compose shell backed by the portable Rust engine. Build with:

```bash
./scripts/build-android.sh
```

The build produces arm64 phone and x86_64 emulator libraries under the ignored
`apps/android/build` directory. Press **Write persistence marker**, force-close,
and relaunch; the library count proves Kotlin, JNI, Rust, and SQLite reconnect.
