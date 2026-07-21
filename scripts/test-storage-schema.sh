#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
migration_one="$repo_dir/crates/colorful-core/migrations/0001_local_state.sql"
migration_two="$repo_dir/crates/colorful-core/migrations/0002_listening_history.sql"
migration_three="$repo_dir/crates/colorful-core/migrations/0003_local_playlists.sql"
test_db="$(mktemp --suffix=.colorful-storage-test.sqlite)"

cleanup() {
  rm -f -- "$test_db"
}
trap cleanup EXIT

sqlite3 -bail "$test_db" < "$migration_one"
sqlite3 -bail "$test_db" < "$migration_two"
sqlite3 -bail "$test_db" < "$migration_three"

[[ "$(sqlite3 "$test_db" 'PRAGMA user_version;')" == "3" ]]
[[ -z "$(sqlite3 "$test_db" 'PRAGMA foreign_key_check;')" ]]
[[ "$(sqlite3 "$test_db" 'SELECT count(*) FROM schema_migrations WHERE version = 1;')" == "1" ]]
[[ "$(sqlite3 "$test_db" 'SELECT count(*) FROM schema_migrations WHERE version = 2;')" == "1" ]]
[[ "$(sqlite3 "$test_db" 'SELECT count(*) FROM schema_migrations WHERE version = 3;')" == "1" ]]
[[ "$(sqlite3 "$test_db" 'SELECT count(*) FROM playback_state WHERE singleton_id = 1;')" == "1" ]]

sqlite3 -bail "$test_db" <<'SQL'
PRAGMA foreign_keys = ON;

INSERT INTO tracks (
  provider, provider_id, title, duration_ms, metadata_updated_at_ms
) VALUES
  ('tidal', 'track-a', 'First', 180000, 1),
  ('tidal', 'track-b', 'Second', 200000, 1);

INSERT INTO library_tracks (provider, provider_id, added_at_ms)
VALUES ('tidal', 'track-a', 2);

INSERT INTO playback_queue (
  entry_id, provider, provider_id, visible_position, play_position, added_at_ms
) VALUES
  (1, 'tidal', 'track-a', 0, 1, 3),
  (2, 'tidal', 'track-b', 1, 0, 3);

UPDATE playback_state
SET current_entry_id = 1,
    position_ms = 42000,
    repeat_mode = 'all',
    shuffle_enabled = 1,
    shuffle_seed = 99,
    next_entry_id = 3,
    updated_at_ms = 4
WHERE singleton_id = 1;

INSERT INTO settings (key, value_json, updated_at_ms)
VALUES ('audio.quality', '{"stream":"lossless"}', 5);

INSERT INTO listen_events (
  event_id, device_id, provider, provider_id, started_at_ms,
  ended_at_ms, listened_ms, track_duration_ms
) VALUES ('event-a', 'device-a', 'tidal', 'track-a', 10, 100010, 100000, 180000);

INSERT INTO local_playlists (playlist_id, name, created_at_ms, updated_at_ms)
VALUES ('playlist-a', 'Mixed providers', 6, 6);
INSERT INTO local_playlist_items (playlist_id, position, provider, provider_id, added_at_ms)
VALUES ('playlist-a', 0, 'tidal', 'track-a', 7),
       ('playlist-a', 1, 'tidal', 'track-a', 8);
SQL

[[ "$(sqlite3 "$test_db" 'SELECT provider_id FROM playback_queue ORDER BY play_position;')" == $'track-b\ntrack-a' ]]
[[ "$(sqlite3 "$test_db" "SELECT listened_ms FROM listen_events WHERE event_id = 'event-a';")" == "100000" ]]
[[ "$(sqlite3 "$test_db" "SELECT count(*) FROM local_playlist_items WHERE playlist_id = 'playlist-a';")" == "2" ]]

if sqlite3 -bail "$test_db" \
  "PRAGMA foreign_keys = ON; INSERT INTO tracks (provider, provider_id, title, metadata_updated_at_ms) VALUES ('invalid', 'x', 'x', 1);" \
  >/dev/null 2>&1; then
  echo "provider constraint accepted an invalid value" >&2
  exit 1
fi

if sqlite3 -bail "$test_db" \
  "PRAGMA foreign_keys = ON; INSERT INTO library_tracks (provider, provider_id, added_at_ms) VALUES ('tidal', 'missing', 1);" \
  >/dev/null 2>&1; then
  echo "foreign-key constraint accepted a missing track" >&2
  exit 1
fi

echo "colorful storage schema checks passed"
