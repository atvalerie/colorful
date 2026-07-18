# Local storage

Colorful's durable state lives in one device-local SQLite database. Provider
credentials remain in the operating system's secret store and media files remain
on disk; the database holds only credential handles and file paths.

The first migration is
`crates/colorful-core/migrations/0001_local_state.sql`. It defines:

- normalized track metadata and ordered artist credits;
- the user's local library;
- stable queue entry IDs, visible order, shuffled play order, and playback state;
- offline download jobs and cache eviction metadata;
- JSON settings with database-level validation.

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

Schema migrations are append-only. A released migration is never edited; a new
numbered migration advances both `schema_migrations` and `PRAGMA user_version`.
The app must enable SQLite foreign keys on every connection.

Run the migration and constraint smoke test with:

```bash
./scripts/test-storage-schema.sh
```
