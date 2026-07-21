# Local storage

colorful's portable durable state lives in one device-local SQLite database.
Provider credentials remain in the operating system's secret store, UI-only
preferences may use the platform settings service, and downloaded media remains
on disk. The database contains music metadata and local file paths, never raw
provider credentials or signed playback URLs.

The initial migration is
`crates/colorful-core/migrations/0001_local_state.sql`. It defines:

- normalized track metadata and ordered artist credits;
- the user's local library;
- stable queue entry IDs, visible order, shuffled play order, and playback state;
- offline download jobs and cache eviction metadata;
- JSON settings with database-level validation.

`0002_listening_history.sql` adds provider-neutral, globally identified listen
events. Each event records its originating device, track reference, wall-clock
interval, and actual audible milliseconds. The event ID is the primary key, so
replaying an event received through multi-device sync cannot increment
statistics twice. Aggregates are derived locally; no listening profile needs to
be uploaded to a colorful service.

`0003_local_playlists.sql` adds colorful-owned playlists and ordered playlist
items. A playlist may contain tracks from different providers and may contain
the same track more than once. Renaming, deletion, item removal, and reordering
change only local colorful state; provider libraries and playlists remain
read-only. Stable playlist IDs and explicit positions are designed to become
sync operations later without changing the desktop data model.

Queue rows distinguish `visible_position` from `play_position`. This keeps manual
reordering predictable while shuffle is active and allows the portable queue
state machine to reconstruct the exact sequence after a restart.

`colorful_core::Storage` owns migration and repository behavior. It enables
foreign keys, WAL mode, normal synchronous durability, and a five-second busy
timeout on every connection. `colorful_core::Engine` is the platform boundary:
native shells send typed commands and receive state events plus explicit
`Load`, `Pause`, `Stop`, and `Seek` playback directives. Playback itself remains
native and provider credentials never enter this database.

Offline jobs use a monotonic portable state machine: queued, resolving,
downloading, paused/failed, then complete. Downloaded byte counts never move
backward, known totals cannot be exceeded, and completion requires a non-empty
local path. Source URLs are deliberately absent from durable storage; only their
expiry is recorded, so a resumed job re-resolves short-lived provider manifests
instead of replaying stale credentials.

The Linux client currently downloads TIDAL, YouTube, or SoundCloud audio into
independently checkpointed Matroska chunks, then asks ffmpeg to concatenate/remux them without
re-encoding into one standalone `.mka` file. Pausing or restarting preserves
completed chunks, re-resolves a fresh provider source, validates existing part
durations, and resumes near the first missing point. Final assembly is written
to a separate path and atomically promoted only after success. The player
always prefers the completed local file. Artwork is stored beside it unless
low-data mode is active, and TIDAL ReplayGain metadata is retained when the
manifest supplies it.

SoundCloud prefers its current AAC 160 HLS rendition rather than the legacy
progressive MP3. A local opt-in may instead request an original file when the
uploader enabled downloads; originals can be substantially larger and fall
back to the preferred transcoding if permission or quota changes.

Schema migrations are append-only. A released migration is never edited; a new
numbered migration advances both `schema_migrations` and `PRAGMA user_version`.
The app must enable SQLite foreign keys on every connection.

Run the migration and constraint smoke test with:

```bash
./scripts/test-storage-schema.sh
```
