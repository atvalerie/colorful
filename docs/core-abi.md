# Native core ABI

`colorful-core` builds as a static library, shared library, or ordinary Rust
library. Native shells include `crates/colorful-core/include/colorful_core.h`
and use an opaque numeric engine handle; no platform ever dereferences a Rust
object pointer.

Every function that returns `char *` returns a versioned UTF-8 JSON response.
The caller must release it exactly once with `colorful_string_free`. Commands
use a tagged shape, for example:

```json
{"command":"seek_to","position_ms":42000}
```

```json
{
  "command":"set_shuffle",
  "enabled":true,
  "seed":12345
}
```

Responses contain `abiVersion`, `ok`, and either `value` or `error`. Dispatch
responses contain typed events. A native playback directive is explicit:

```json
{
  "event":"playback_directive",
  "value":{
    "directive":"load",
    "track":{"id":{"provider":"tidal","providerId":"123"}},
    "position_ms":0,
    "autoplay":true
  }
}
```

Offline transfer workers use the same boundary. The native shell performs the
actual network and filesystem work, while `save_download` persists the portable
job state and emits `download_changed`; engine snapshots include all jobs needed
to restore an interrupted transfer after process death.

Snapshots also expose `queueTracks`, aligned with the visible `queue.entries`
array. Stable entry IDs remain the control identity, while the hydrated tracks
let native shells restore artwork and metadata without maintaining a second
queue database.

Qualified listens enter through `record_listen`. The shell supplies a globally
unique event ID and originating device ID, while the core validates the event,
stores its track metadata transactionally, and ignores duplicate IDs. Snapshots
expose `listenStats` with total audible time, play count, and top tracks,
artists, and albums.
Platform shells decide what counts as audible time; forward seeks, buffering,
and pauses must not inflate the supplied duration.

The ABI registry serializes access to each SQLite-backed engine, catches Rust
panics before they cross the C boundary, validates UTF-8/JSON, and reports stale
handles as errors. `colorful_core_abi_version()` lets a shell reject an
incompatible library before opening its database.
