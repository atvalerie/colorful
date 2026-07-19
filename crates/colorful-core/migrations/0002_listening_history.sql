CREATE TABLE listen_events (
    event_id TEXT PRIMARY KEY CHECK (length(trim(event_id)) > 0),
    device_id TEXT NOT NULL CHECK (length(trim(device_id)) > 0),
    provider TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    started_at_ms INTEGER NOT NULL CHECK (started_at_ms >= 0),
    ended_at_ms INTEGER NOT NULL CHECK (ended_at_ms >= started_at_ms),
    listened_ms INTEGER NOT NULL CHECK (listened_ms > 0),
    track_duration_ms INTEGER CHECK (track_duration_ms IS NULL OR track_duration_ms > 0),
    FOREIGN KEY (provider, provider_id)
        REFERENCES tracks (provider, provider_id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

CREATE INDEX listen_events_by_end_time
    ON listen_events (ended_at_ms DESC);

CREATE INDEX listen_events_by_track
    ON listen_events (provider, provider_id, ended_at_ms DESC);

INSERT INTO schema_migrations (version, applied_at_ms)
VALUES (2, unixepoch('subsec') * 1000);

PRAGMA user_version = 2;
