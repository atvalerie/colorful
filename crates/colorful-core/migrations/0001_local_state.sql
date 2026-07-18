PRAGMA foreign_keys = ON;

CREATE TABLE schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at_ms INTEGER NOT NULL
) STRICT;

INSERT INTO schema_migrations (version, applied_at_ms)
VALUES (1, unixepoch('subsec') * 1000);

CREATE TABLE tracks (
    provider TEXT NOT NULL CHECK (provider IN ('tidal', 'soundcloud', 'youtube', 'local')),
    provider_id TEXT NOT NULL CHECK (length(trim(provider_id)) > 0),
    title TEXT NOT NULL,
    album_provider TEXT CHECK (album_provider IN ('tidal', 'soundcloud', 'youtube', 'local')),
    album_provider_id TEXT,
    album_title TEXT,
    artwork_url TEXT,
    artwork_local_key TEXT,
    duration_ms INTEGER CHECK (duration_ms IS NULL OR duration_ms >= 0),
    isrc TEXT,
    explicit INTEGER CHECK (explicit IS NULL OR explicit IN (0, 1)),
    metadata_updated_at_ms INTEGER NOT NULL,
    PRIMARY KEY (provider, provider_id),
    CHECK ((album_provider IS NULL) = (album_provider_id IS NULL))
) STRICT, WITHOUT ROWID;

CREATE TABLE track_artists (
    track_provider TEXT NOT NULL,
    track_provider_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    artist_provider TEXT CHECK (artist_provider IN ('tidal', 'soundcloud', 'youtube', 'local')),
    artist_provider_id TEXT,
    name TEXT NOT NULL,
    PRIMARY KEY (track_provider, track_provider_id, ordinal),
    FOREIGN KEY (track_provider, track_provider_id)
        REFERENCES tracks (provider, provider_id) ON DELETE CASCADE,
    CHECK ((artist_provider IS NULL) = (artist_provider_id IS NULL))
) STRICT, WITHOUT ROWID;

CREATE TABLE library_tracks (
    provider TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    added_at_ms INTEGER NOT NULL,
    source TEXT NOT NULL DEFAULT 'user' CHECK (source IN ('user', 'provider', 'import', 'sync')),
    PRIMARY KEY (provider, provider_id),
    FOREIGN KEY (provider, provider_id)
        REFERENCES tracks (provider, provider_id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

CREATE TABLE playback_queue (
    entry_id INTEGER PRIMARY KEY CHECK (entry_id > 0),
    provider TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    visible_position INTEGER NOT NULL UNIQUE CHECK (visible_position >= 0),
    play_position INTEGER NOT NULL UNIQUE CHECK (play_position >= 0),
    added_at_ms INTEGER NOT NULL,
    FOREIGN KEY (provider, provider_id)
        REFERENCES tracks (provider, provider_id) ON DELETE CASCADE
) STRICT;

CREATE TABLE playback_state (
    singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
    current_entry_id INTEGER,
    position_ms INTEGER NOT NULL DEFAULT 0 CHECK (position_ms >= 0),
    repeat_mode TEXT NOT NULL DEFAULT 'off' CHECK (repeat_mode IN ('off', 'all', 'one')),
    shuffle_enabled INTEGER NOT NULL DEFAULT 0 CHECK (shuffle_enabled IN (0, 1)),
    shuffle_seed INTEGER NOT NULL DEFAULT 0,
    next_entry_id INTEGER NOT NULL DEFAULT 1 CHECK (next_entry_id > 0),
    updated_at_ms INTEGER NOT NULL,
    FOREIGN KEY (current_entry_id) REFERENCES playback_queue (entry_id) ON DELETE SET NULL
) STRICT;

INSERT INTO playback_state (singleton_id, updated_at_ms)
VALUES (1, unixepoch('subsec') * 1000);

CREATE TABLE downloads (
    provider TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('queued', 'resolving', 'downloading', 'complete', 'failed', 'paused')),
    local_path TEXT,
    bytes_downloaded INTEGER NOT NULL DEFAULT 0 CHECK (bytes_downloaded >= 0),
    bytes_total INTEGER CHECK (bytes_total IS NULL OR bytes_total >= 0),
    source_expires_at_ms INTEGER,
    error_code TEXT,
    updated_at_ms INTEGER NOT NULL,
    PRIMARY KEY (provider, provider_id),
    FOREIGN KEY (provider, provider_id)
        REFERENCES tracks (provider, provider_id) ON DELETE CASCADE,
    CHECK ((state = 'complete') = (local_path IS NOT NULL))
) STRICT, WITHOUT ROWID;

CREATE TABLE cache_entries (
    cache_key TEXT PRIMARY KEY CHECK (length(trim(cache_key)) > 0),
    kind TEXT NOT NULL CHECK (kind IN ('artwork', 'audio', 'manifest', 'lyrics', 'other')),
    local_path TEXT NOT NULL,
    size_bytes INTEGER NOT NULL CHECK (size_bytes >= 0),
    last_accessed_at_ms INTEGER NOT NULL,
    pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0, 1))
) STRICT, WITHOUT ROWID;

CREATE INDEX cache_entries_eviction_order
    ON cache_entries (pinned, last_accessed_at_ms);

CREATE TABLE settings (
    key TEXT PRIMARY KEY CHECK (length(trim(key)) > 0),
    value_json TEXT NOT NULL CHECK (json_valid(value_json)),
    updated_at_ms INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

PRAGMA user_version = 1;
