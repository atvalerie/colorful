CREATE TABLE local_playlists (
    playlist_id TEXT PRIMARY KEY CHECK (length(trim(playlist_id)) > 0),
    name TEXT NOT NULL CHECK (length(trim(name)) > 0),
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE local_playlist_items (
    playlist_id TEXT NOT NULL,
    position INTEGER NOT NULL CHECK (position >= 0),
    provider TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    added_at_ms INTEGER NOT NULL,
    PRIMARY KEY (playlist_id, position),
    FOREIGN KEY (playlist_id) REFERENCES local_playlists (playlist_id) ON DELETE CASCADE,
    FOREIGN KEY (provider, provider_id) REFERENCES tracks (provider, provider_id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

CREATE INDEX local_playlist_items_track
    ON local_playlist_items (provider, provider_id);

INSERT INTO schema_migrations (version, applied_at_ms)
VALUES (3, unixepoch('subsec') * 1000);

PRAGMA user_version = 3;
