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

Provider continuations append queue pages transactionally with
`{"command":"enqueue_tracks","tracks":[...]}`. One batch produces one queue
snapshot while retaining duplicate playlist entries and their distinct stable
entry IDs.

An already shuffled provider sequence starts with
`{"command":"play_tracks_in_order","tracks":[...]}`. This preserves the
provider's authoritative order while leaving the queue's shuffle state enabled;
continuation pages can then append to that same order without a second local
shuffle.

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
artists, and albums. Its `providerStats` array contains listened time and play
count grouped by provider in descending usage order; native shells use that
local aggregate for presentation such as Home and combined-search priority.
Platform shells decide what counts as audible time; forward seeks, buffering,
and pauses must not inflate the supplied duration.

The ABI registry serializes access to each SQLite-backed engine, catches Rust
panics before they cross the C boundary, validates UTF-8/JSON, and reports stale
handles as errors. `colorful_core_abi_version()` lets a shell reject an
incompatible library before opening its database.

## Travel snapshots

The additive `colorful_engine_export_travel_snapshot(handle)` function returns
the regular ABI response envelope. Its `value` is deterministic JSON with
`format: "colorful-travel-snapshot"` and `version: 1`.

```c
char *colorful_engine_export_travel_snapshot(uint64_t handle);
char *colorful_engine_import_travel_snapshot(uint64_t handle, const char *snapshot_json);
```

The import function accepts the raw snapshot document from the export
response's `value`. It replaces library membership, Colorful playlists and
their order, queue entries and playback position, repeat/shuffle state, and a
small allow-list of portable playback settings. The operation validates every
reference before making one SQLite transaction. Repeating the same import is
safe and produces the same portable state.

Downloads, cache entries, local paths, provider credentials, signed URLs,
listening history, lyrics/cache settings, and platform-specific settings are
not part of the format and remain on the destination device. Track artwork in
the travel document contains dimensions only; artwork URLs and local cache
keys are deliberately omitted.

Local-provider tracks are omitted during export. Playlists remain present with
their portable items in the original order; local items are left out. If the
current queue entry is local, export selects the next portable playback entry,
falls back to the first portable entry when needed, and resets the position to
zero. If no portable queue entry remains, the exported queue has no current
entry.

On import, destination local-library membership is retained. Destination
playlists containing local tracks are retained as well. For a matching
playlist ID, imported portable items are written first and the existing local
items are appended. A destination local-only playlist is kept unchanged.
Local references are never imported from the snapshot.
