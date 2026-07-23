use crate::download::{DownloadJob, DownloadState};
use crate::history::{
    ListenEvent, ListenStats, ProviderListenStats, TopAlbum, TopArtist, TopTrack,
};
use crate::media::{ArtistCredit, Artwork, MediaId, Provider, Track};
use crate::playback::RepeatMode;
use crate::playlist::LocalPlaylist;
use crate::queue::{PlaybackQueue, QueueEntry, QueueEntryId, QueueSnapshot, QueueSnapshotError};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use std::fmt;
use std::path::Path;
use std::time::Duration;

const CURRENT_SCHEMA_VERSION: i64 = 3;
const INITIAL_MIGRATION: &str = include_str!("../migrations/0001_local_state.sql");
const LISTENING_HISTORY_MIGRATION: &str = include_str!("../migrations/0002_listening_history.sql");
const LOCAL_PLAYLISTS_MIGRATION: &str = include_str!("../migrations/0003_local_playlists.sql");

#[derive(Debug)]
pub enum StorageError {
    Database(rusqlite::Error),
    Io(std::io::Error),
    UnsupportedSchema(i64),
    InvalidProvider(String),
    InvalidMediaId,
    InvalidQueue(QueueSnapshotError),
    InvalidDownloadState(String),
    IntegerOutOfRange(&'static str),
}

impl fmt::Display for StorageError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Database(error) => write!(formatter, "SQLite error: {error}"),
            Self::Io(error) => write!(formatter, "storage I/O error: {error}"),
            Self::UnsupportedSchema(version) => {
                write!(
                    formatter,
                    "database schema {version} is newer than supported schema {CURRENT_SCHEMA_VERSION}"
                )
            }
            Self::InvalidProvider(provider) => {
                write!(formatter, "unknown provider in database: {provider}")
            }
            Self::InvalidMediaId => formatter.write_str("database contains an invalid media ID"),
            Self::InvalidQueue(error) => {
                write!(formatter, "database contains an invalid queue: {error:?}")
            }
            Self::InvalidDownloadState(state) => {
                write!(formatter, "unknown download state in database: {state}")
            }
            Self::IntegerOutOfRange(field) => write!(
                formatter,
                "{field} does not fit SQLite's signed integer range"
            ),
        }
    }
}

impl std::error::Error for StorageError {}

impl From<rusqlite::Error> for StorageError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Database(value)
    }
}

impl From<std::io::Error> for StorageError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<QueueSnapshotError> for StorageError {
    fn from(value: QueueSnapshotError) -> Self {
        Self::InvalidQueue(value)
    }
}

pub type StorageResult<T> = Result<T, StorageError>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredPlayback {
    pub queue: PlaybackQueue,
    pub position_ms: u64,
    pub repeat: RepeatMode,
}

pub struct Storage {
    connection: Connection,
}

impl Storage {
    pub fn open(path: impl AsRef<Path>) -> StorageResult<Self> {
        let path = path.as_ref();
        if let Some(parent) = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            std::fs::create_dir_all(parent)?;
        }
        Self::from_connection(Connection::open(path)?)
    }

    pub fn open_in_memory() -> StorageResult<Self> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(connection: Connection) -> StorageResult<Self> {
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute_batch(
            "PRAGMA foreign_keys = ON;
             PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;",
        )?;
        let version: i64 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
        let migrations = match version {
            0 => Some(format!(
                "{INITIAL_MIGRATION}\n{LISTENING_HISTORY_MIGRATION}\n{LOCAL_PLAYLISTS_MIGRATION}"
            )),
            1 => Some(format!(
                "{LISTENING_HISTORY_MIGRATION}\n{LOCAL_PLAYLISTS_MIGRATION}"
            )),
            2 => Some(LOCAL_PLAYLISTS_MIGRATION.to_owned()),
            CURRENT_SCHEMA_VERSION => None,
            other => return Err(StorageError::UnsupportedSchema(other)),
        };
        if let Some(migrations) = migrations {
            if let Err(error) =
                connection.execute_batch(&format!("BEGIN IMMEDIATE;\n{migrations}\nCOMMIT;"))
            {
                let _ = connection.execute_batch("ROLLBACK;");
                return Err(error.into());
            }
        }
        let foreign_keys: i64 =
            connection.pragma_query_value(None, "foreign_keys", |row| row.get(0))?;
        if foreign_keys != 1 {
            return Err(StorageError::Database(rusqlite::Error::InvalidQuery));
        }
        Ok(Self { connection })
    }

    pub fn schema_version(&self) -> StorageResult<i64> {
        Ok(self
            .connection
            .pragma_query_value(None, "user_version", |row| row.get(0))?)
    }

    pub fn upsert_track(&mut self, track: &Track) -> StorageResult<()> {
        let transaction = self.connection.transaction()?;
        upsert_track(&transaction, track)?;
        transaction.commit()?;
        Ok(())
    }

    pub fn track(&self, id: &MediaId) -> StorageResult<Option<Track>> {
        load_track(&self.connection, id)
    }

    pub fn add_to_library(&mut self, track: &Track, added_at_ms: i64) -> StorageResult<()> {
        let transaction = self.connection.transaction()?;
        upsert_track(&transaction, track)?;
        transaction.execute(
            "INSERT INTO library_tracks (provider, provider_id, added_at_ms, source)
             VALUES (?1, ?2, ?3, 'user')
             ON CONFLICT (provider, provider_id) DO UPDATE SET added_at_ms = excluded.added_at_ms",
            params![
                track.id.provider.to_string(),
                track.id.provider_id,
                added_at_ms
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn remove_from_library(&mut self, id: &MediaId) -> StorageResult<bool> {
        Ok(self.connection.execute(
            "DELETE FROM library_tracks WHERE provider = ?1 AND provider_id = ?2",
            params![id.provider.to_string(), id.provider_id],
        )? > 0)
    }

    pub fn library(&self) -> StorageResult<Vec<Track>> {
        let mut statement = self.connection.prepare(
            "SELECT provider, provider_id FROM library_tracks ORDER BY added_at_ms DESC",
        )?;
        let ids = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        ids.into_iter()
            .map(|(provider, provider_id)| {
                let id = media_id(&provider, provider_id)?;
                load_track(&self.connection, &id)?.ok_or(StorageError::InvalidMediaId)
            })
            .collect()
    }

    pub fn create_playlist(&mut self, name: &str, created_at_ms: i64) -> StorageResult<String> {
        let name = name.trim();
        let id = self.connection.query_row(
            "INSERT INTO local_playlists (playlist_id, name, created_at_ms, updated_at_ms)
             VALUES (lower(hex(randomblob(16))), ?1, ?2, ?2) RETURNING playlist_id",
            params![name, created_at_ms],
            |row| row.get(0),
        )?;
        Ok(id)
    }

    pub fn rename_playlist(
        &mut self,
        id: &str,
        name: &str,
        updated_at_ms: i64,
    ) -> StorageResult<bool> {
        Ok(self.connection.execute(
            "UPDATE local_playlists SET name = ?2, updated_at_ms = ?3 WHERE playlist_id = ?1",
            params![id, name.trim(), updated_at_ms],
        )? > 0)
    }

    pub fn delete_playlist(&mut self, id: &str) -> StorageResult<bool> {
        Ok(self
            .connection
            .execute("DELETE FROM local_playlists WHERE playlist_id = ?1", [id])?
            > 0)
    }

    pub fn add_playlist_track(
        &mut self,
        id: &str,
        track: &Track,
        added_at_ms: i64,
    ) -> StorageResult<bool> {
        self.add_playlist_tracks(id, std::slice::from_ref(track), added_at_ms)
    }

    pub fn add_playlist_tracks(
        &mut self,
        id: &str,
        tracks: &[Track],
        added_at_ms: i64,
    ) -> StorageResult<bool> {
        let transaction = self.connection.transaction()?;
        let exists: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM local_playlists WHERE playlist_id = ?1)",
            [id],
            |row| row.get(0),
        )?;
        if !exists {
            return Ok(false);
        }
        let mut position: i64 = transaction.query_row(
            "SELECT COUNT(*) FROM local_playlist_items WHERE playlist_id = ?1",
            [id],
            |row| row.get(0),
        )?;
        for track in tracks {
            upsert_track(&transaction, track)?;
            transaction.execute(
                "INSERT INTO local_playlist_items (playlist_id, position, provider, provider_id, added_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![id, position, track.id.provider.to_string(), track.id.provider_id, added_at_ms],
            )?;
            position += 1;
        }
        transaction.execute(
            "UPDATE local_playlists SET updated_at_ms = ?2 WHERE playlist_id = ?1",
            params![id, added_at_ms],
        )?;
        transaction.commit()?;
        Ok(!tracks.is_empty())
    }

    pub fn remove_playlist_item(
        &mut self,
        id: &str,
        position: usize,
        updated_at_ms: i64,
    ) -> StorageResult<bool> {
        self.rewrite_playlist_items(id, Some(position), None, updated_at_ms)
    }

    pub fn move_playlist_item(
        &mut self,
        id: &str,
        position: usize,
        target: usize,
        updated_at_ms: i64,
    ) -> StorageResult<bool> {
        self.rewrite_playlist_items(id, Some(position), Some(target), updated_at_ms)
    }

    fn rewrite_playlist_items(
        &mut self,
        id: &str,
        position: Option<usize>,
        target: Option<usize>,
        updated_at_ms: i64,
    ) -> StorageResult<bool> {
        let transaction = self.connection.transaction()?;
        let mut items = {
            let mut statement = transaction.prepare(
                "SELECT provider, provider_id, added_at_ms FROM local_playlist_items
                 WHERE playlist_id = ?1 ORDER BY position",
            )?;
            statement
                .query_map([id], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        let Some(position) = position.filter(|value| *value < items.len()) else {
            return Ok(false);
        };
        let item = items.remove(position);
        if let Some(target) = target {
            items.insert(target.min(items.len()), item);
        }
        transaction.execute(
            "DELETE FROM local_playlist_items WHERE playlist_id = ?1",
            [id],
        )?;
        for (index, (provider, provider_id, added_at_ms)) in items.iter().enumerate() {
            transaction.execute(
                "INSERT INTO local_playlist_items (playlist_id, position, provider, provider_id, added_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![id, sqlite_usize(index, "playlist position")?, provider, provider_id, added_at_ms],
            )?;
        }
        transaction.execute(
            "UPDATE local_playlists SET updated_at_ms = ?2 WHERE playlist_id = ?1",
            params![id, updated_at_ms],
        )?;
        transaction.commit()?;
        Ok(true)
    }

    pub fn playlists(&self) -> StorageResult<Vec<LocalPlaylist>> {
        let rows = {
            let mut statement = self.connection.prepare(
                "SELECT playlist_id, name, created_at_ms, updated_at_ms
                 FROM local_playlists ORDER BY updated_at_ms DESC, name COLLATE NOCASE",
            )?;
            statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        rows.into_iter().map(|(id, name, created_at_ms, updated_at_ms)| {
            let ids = {
                let mut statement = self.connection.prepare(
                    "SELECT provider, provider_id FROM local_playlist_items WHERE playlist_id = ?1 ORDER BY position",
                )?;
                statement.query_map([&id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
                    .collect::<Result<Vec<_>, _>>()?
            };
            let tracks = ids.into_iter().map(|(provider, provider_id)| {
                let media_id = media_id(&provider, provider_id)?;
                load_track(&self.connection, &media_id)?.ok_or(StorageError::InvalidMediaId)
            }).collect::<StorageResult<Vec<_>>>()?;
            Ok(LocalPlaylist { id, name, created_at_ms, updated_at_ms, tracks })
        }).collect()
    }

    /// Inserts a globally identified listen once. Replayed sync operations are
    /// harmless because the event ID is the primary key.
    pub fn record_listen(&mut self, track: &Track, event: &ListenEvent) -> StorageResult<bool> {
        let transaction = self.connection.transaction()?;
        upsert_track(&transaction, track)?;
        let inserted = transaction.execute(
            "INSERT OR IGNORE INTO listen_events (
                event_id, device_id, provider, provider_id, started_at_ms,
                ended_at_ms, listened_ms, track_duration_ms
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                event.event_id,
                event.device_id,
                event.media_id.provider.to_string(),
                event.media_id.provider_id,
                event.started_at_ms,
                event.ended_at_ms,
                sqlite_u64(event.listened_ms, "listened milliseconds")?,
                event
                    .track_duration_ms
                    .map(|value| sqlite_u64(value, "track duration"))
                    .transpose()?,
            ],
        )? > 0;
        transaction.commit()?;
        Ok(inserted)
    }

    pub fn listen_stats(&self, since_ms: Option<i64>, limit: usize) -> StorageResult<ListenStats> {
        let since = since_ms.unwrap_or(0).max(0);
        let (total_listened_ms, play_count): (i64, i64) = self.connection.query_row(
            "SELECT COALESCE(SUM(listened_ms), 0), COUNT(*)
             FROM listen_events WHERE ended_at_ms >= ?1",
            [since],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;

        let provider_stats = {
            let mut statement = self.connection.prepare(
                "SELECT provider, SUM(listened_ms), COUNT(*)
                 FROM listen_events WHERE ended_at_ms >= ?1
                 GROUP BY provider
                 ORDER BY SUM(listened_ms) DESC, COUNT(*) DESC, provider",
            )?;
            statement
                .query_map([since], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                })?
                .map(|row| {
                    let (provider, listened_ms, plays) = row?;
                    Ok(ProviderListenStats {
                        provider: Provider::from_wire_name(&provider)
                            .ok_or_else(|| StorageError::InvalidProvider(provider.clone()))?,
                        listened_ms: listened_ms
                            .try_into()
                            .map_err(|_| StorageError::InvalidMediaId)?,
                        play_count: plays.try_into().map_err(|_| StorageError::InvalidMediaId)?,
                    })
                })
                .collect::<StorageResult<Vec<_>>>()?
        };

        let track_rows = {
            let mut statement = self.connection.prepare(
                "SELECT provider, provider_id, SUM(listened_ms), COUNT(*)
                 FROM listen_events WHERE ended_at_ms >= ?1
                 GROUP BY provider, provider_id
                 ORDER BY SUM(listened_ms) DESC, COUNT(*) DESC, provider, provider_id
                 LIMIT ?2",
            )?;
            statement
                .query_map(
                    params![since, sqlite_usize(limit, "statistics limit")?],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, i64>(2)?,
                            row.get::<_, i64>(3)?,
                        ))
                    },
                )?
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut top_tracks = Vec::with_capacity(track_rows.len());
        for (provider, provider_id, listened_ms, plays) in track_rows {
            let id = media_id(&provider, provider_id)?;
            let track = load_track(&self.connection, &id)?.ok_or(StorageError::InvalidMediaId)?;
            top_tracks.push(TopTrack {
                track,
                listened_ms: listened_ms
                    .try_into()
                    .map_err(|_| StorageError::InvalidMediaId)?,
                play_count: plays.try_into().map_err(|_| StorageError::InvalidMediaId)?,
            });
        }

        let artist_rows = {
            let mut statement = self.connection.prepare(
                "SELECT a.artist_provider, a.artist_provider_id, a.name,
                        SUM(e.listened_ms), COUNT(*)
                 FROM listen_events e
                 JOIN track_artists a
                   ON a.track_provider = e.provider AND a.track_provider_id = e.provider_id
                 WHERE e.ended_at_ms >= ?1
                 GROUP BY a.artist_provider, a.artist_provider_id, a.name
                 ORDER BY SUM(e.listened_ms) DESC, COUNT(*) DESC, a.name
                 LIMIT ?2",
            )?;
            statement
                .query_map(
                    params![since, sqlite_usize(limit, "statistics limit")?],
                    |row| {
                        Ok((
                            row.get::<_, Option<String>>(0)?,
                            row.get::<_, Option<String>>(1)?,
                            row.get::<_, String>(2)?,
                            row.get::<_, i64>(3)?,
                            row.get::<_, i64>(4)?,
                        ))
                    },
                )?
                .collect::<Result<Vec<_>, _>>()?
        };
        let top_artists = artist_rows
            .into_iter()
            .map(|(provider, provider_id, name, listened_ms, plays)| {
                let id = match (provider, provider_id) {
                    (Some(provider), Some(provider_id)) => Some(media_id(&provider, provider_id)?),
                    (None, None) => None,
                    _ => return Err(StorageError::InvalidMediaId),
                };
                Ok(TopArtist {
                    id,
                    name,
                    listened_ms: listened_ms
                        .try_into()
                        .map_err(|_| StorageError::InvalidMediaId)?,
                    play_count: plays.try_into().map_err(|_| StorageError::InvalidMediaId)?,
                })
            })
            .collect::<StorageResult<Vec<_>>>()?;

        let album_rows = {
            let mut statement = self.connection.prepare(
                "SELECT t.album_provider, t.album_provider_id, t.album_title,
                        SUM(e.listened_ms), COUNT(*)
                 FROM listen_events e
                 JOIN tracks t
                   ON t.provider = e.provider AND t.provider_id = e.provider_id
                 WHERE e.ended_at_ms >= ?1
                   AND t.album_provider IS NOT NULL
                   AND t.album_provider_id IS NOT NULL
                   AND t.album_title IS NOT NULL
                 GROUP BY t.album_provider, t.album_provider_id, t.album_title
                 ORDER BY SUM(e.listened_ms) DESC, COUNT(*) DESC,
                          t.album_provider, t.album_provider_id
                 LIMIT ?2",
            )?;
            statement
                .query_map(
                    params![since, sqlite_usize(limit, "statistics limit")?],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                            row.get::<_, i64>(3)?,
                            row.get::<_, i64>(4)?,
                        ))
                    },
                )?
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut top_albums = Vec::with_capacity(album_rows.len());
        for (provider, provider_id, title, listened_ms, plays) in album_rows {
            let id = media_id(&provider, provider_id)?;
            let (track_provider, track_provider_id) = self.connection.query_row(
                "SELECT e.provider, e.provider_id
                 FROM listen_events e
                 JOIN tracks t
                   ON t.provider = e.provider AND t.provider_id = e.provider_id
                 WHERE e.ended_at_ms >= ?1
                   AND t.album_provider = ?2 AND t.album_provider_id = ?3
                 GROUP BY e.provider, e.provider_id
                 ORDER BY SUM(e.listened_ms) DESC, COUNT(*) DESC,
                          e.provider, e.provider_id
                 LIMIT 1",
                params![since, id.provider.to_string(), id.provider_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )?;
            let representative = load_track(
                &self.connection,
                &media_id(&track_provider, track_provider_id)?,
            )?
            .ok_or(StorageError::InvalidMediaId)?;
            top_albums.push(TopAlbum {
                id,
                title,
                artists: representative.artists,
                artwork: representative.artwork,
                listened_ms: listened_ms
                    .try_into()
                    .map_err(|_| StorageError::InvalidMediaId)?,
                play_count: plays.try_into().map_err(|_| StorageError::InvalidMediaId)?,
            });
        }

        Ok(ListenStats {
            total_listened_ms: total_listened_ms
                .try_into()
                .map_err(|_| StorageError::InvalidMediaId)?,
            play_count: play_count
                .try_into()
                .map_err(|_| StorageError::InvalidMediaId)?,
            provider_stats,
            top_tracks,
            top_artists,
            top_albums,
        })
    }

    pub fn save_playback(
        &mut self,
        queue: &PlaybackQueue,
        position_ms: u64,
        repeat: RepeatMode,
        updated_at_ms: i64,
    ) -> StorageResult<()> {
        let snapshot = queue.snapshot();
        let transaction = self.connection.transaction()?;
        transaction.execute("DELETE FROM playback_queue", [])?;

        let play_positions = snapshot
            .play_order
            .iter()
            .enumerate()
            .map(|(position, id)| (*id, position))
            .collect::<std::collections::HashMap<_, _>>();
        for (visible_position, entry) in snapshot.entries.iter().enumerate() {
            transaction.execute(
                "INSERT INTO playback_queue
                 (entry_id, provider, provider_id, visible_position, play_position, added_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    sqlite_u64(entry.id.get(), "queue entry ID")?,
                    entry.media_id.provider.to_string(),
                    entry.media_id.provider_id,
                    sqlite_usize(visible_position, "visible queue position")?,
                    sqlite_usize(play_positions[&entry.id], "play queue position")?,
                    updated_at_ms,
                ],
            )?;
        }

        let current = snapshot
            .current
            .map(|id| sqlite_u64(id.get(), "current queue entry ID"))
            .transpose()?;
        transaction.execute(
            "UPDATE playback_state SET
                current_entry_id = ?1,
                position_ms = ?2,
                repeat_mode = ?3,
                shuffle_enabled = ?4,
                shuffle_seed = ?5,
                next_entry_id = ?6,
                updated_at_ms = ?7
             WHERE singleton_id = 1",
            params![
                current,
                sqlite_u64(position_ms, "playback position")?,
                repeat_wire_name(repeat),
                snapshot.shuffle,
                snapshot.shuffle_seed as i64,
                sqlite_u64(snapshot.next_entry_id, "next queue entry ID")?,
                updated_at_ms,
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn load_playback(&self) -> StorageResult<StoredPlayback> {
        let mut statement = self.connection.prepare(
            "SELECT entry_id, provider, provider_id, play_position
             FROM playback_queue ORDER BY visible_position",
        )?;
        let stored_entries = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        let mut entries = Vec::with_capacity(stored_entries.len());
        let mut order = Vec::with_capacity(stored_entries.len());
        for (entry_id, provider, provider_id, play_position) in stored_entries {
            let id = QueueEntryId::from_raw(
                entry_id
                    .try_into()
                    .map_err(|_| StorageError::InvalidMediaId)?,
            )
            .ok_or(StorageError::InvalidMediaId)?;
            entries.push(QueueEntry {
                id,
                media_id: media_id(&provider, provider_id)?,
            });
            order.push((play_position, id));
        }
        order.sort_by_key(|(position, _)| *position);

        let state = self.connection.query_row(
            "SELECT current_entry_id, position_ms, repeat_mode, shuffle_enabled,
                    shuffle_seed, next_entry_id
             FROM playback_state WHERE singleton_id = 1",
            [],
            |row| {
                Ok((
                    row.get::<_, Option<i64>>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, bool>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, i64>(5)?,
                ))
            },
        )?;
        let current = state
            .0
            .map(|value| {
                let raw = value.try_into().map_err(|_| StorageError::InvalidMediaId)?;
                QueueEntryId::from_raw(raw).ok_or(StorageError::InvalidMediaId)
            })
            .transpose()?;
        let snapshot = QueueSnapshot {
            entries,
            play_order: order.into_iter().map(|(_, id)| id).collect(),
            current,
            shuffle: state.3,
            shuffle_seed: state.4 as u64,
            next_entry_id: state
                .5
                .try_into()
                .map_err(|_| StorageError::InvalidMediaId)?,
        };
        Ok(StoredPlayback {
            queue: PlaybackQueue::from_snapshot(snapshot)?,
            position_ms: state
                .1
                .try_into()
                .map_err(|_| StorageError::InvalidMediaId)?,
            repeat: repeat_from_wire_name(&state.2)?,
        })
    }

    pub fn set_setting(
        &mut self,
        key: &str,
        value_json: &str,
        updated_at_ms: i64,
    ) -> StorageResult<()> {
        self.connection.execute(
            "INSERT INTO settings (key, value_json, updated_at_ms) VALUES (?1, ?2, ?3)
             ON CONFLICT (key) DO UPDATE SET
                value_json = excluded.value_json,
                updated_at_ms = excluded.updated_at_ms",
            params![key, value_json, updated_at_ms],
        )?;
        Ok(())
    }

    pub fn setting(&self, key: &str) -> StorageResult<Option<String>> {
        Ok(self
            .connection
            .query_row(
                "SELECT value_json FROM settings WHERE key = ?1",
                [key],
                |row| row.get(0),
            )
            .optional()?)
    }

    pub fn save_download(&mut self, track: &Track, job: &DownloadJob) -> StorageResult<()> {
        if track.id != job.media_id {
            return Err(StorageError::InvalidMediaId);
        }
        let transaction = self.connection.transaction()?;
        upsert_track(&transaction, track)?;
        transaction.execute(
            "INSERT INTO downloads (
                provider, provider_id, state, local_path, bytes_downloaded,
                bytes_total, source_expires_at_ms, error_code, updated_at_ms
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
             ON CONFLICT (provider, provider_id) DO UPDATE SET
                state = excluded.state,
                local_path = excluded.local_path,
                bytes_downloaded = excluded.bytes_downloaded,
                bytes_total = excluded.bytes_total,
                source_expires_at_ms = excluded.source_expires_at_ms,
                error_code = excluded.error_code,
                updated_at_ms = excluded.updated_at_ms",
            params![
                job.media_id.provider.to_string(),
                job.media_id.provider_id,
                job.state.wire_name(),
                job.local_path,
                sqlite_u64(job.bytes_downloaded, "downloaded byte count")?,
                job.bytes_total
                    .map(|value| sqlite_u64(value, "download total byte count"))
                    .transpose()?,
                job.source_expires_at_ms,
                job.error_code,
                job.updated_at_ms,
            ],
        )?;
        transaction.commit()?;
        Ok(())
    }

    pub fn download(&self, id: &MediaId) -> StorageResult<Option<DownloadJob>> {
        self.connection
            .query_row(
                "SELECT state, local_path, bytes_downloaded, bytes_total,
                        source_expires_at_ms, error_code, updated_at_ms
                 FROM downloads WHERE provider = ?1 AND provider_id = ?2",
                params![id.provider.to_string(), id.provider_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, Option<i64>>(3)?,
                        row.get::<_, Option<i64>>(4)?,
                        row.get::<_, Option<String>>(5)?,
                        row.get::<_, i64>(6)?,
                    ))
                },
            )
            .optional()?
            .map(|row| {
                Ok(DownloadJob {
                    media_id: id.clone(),
                    state: DownloadState::from_wire_name(&row.0)
                        .ok_or(StorageError::InvalidDownloadState(row.0))?,
                    local_path: row.1,
                    bytes_downloaded: row.2.try_into().map_err(|_| StorageError::InvalidMediaId)?,
                    bytes_total: row
                        .3
                        .map(|value| value.try_into().map_err(|_| StorageError::InvalidMediaId))
                        .transpose()?,
                    source_expires_at_ms: row.4,
                    error_code: row.5,
                    updated_at_ms: row.6,
                })
            })
            .transpose()
    }

    pub fn downloads(&self) -> StorageResult<Vec<DownloadJob>> {
        let mut statement = self.connection.prepare(
            "SELECT provider, provider_id FROM downloads
             ORDER BY CASE state WHEN 'downloading' THEN 0 WHEN 'resolving' THEN 1
                       WHEN 'queued' THEN 2 WHEN 'paused' THEN 3 WHEN 'failed' THEN 4 ELSE 5 END,
                      updated_at_ms DESC",
        )?;
        let stored_ids = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        stored_ids
            .into_iter()
            .map(|(provider, provider_id)| {
                let id = media_id(&provider, provider_id)?;
                self.download(&id)?.ok_or(StorageError::InvalidMediaId)
            })
            .collect()
    }

    pub fn remove_download(&mut self, id: &MediaId) -> StorageResult<bool> {
        Ok(self.connection.execute(
            "DELETE FROM downloads WHERE provider = ?1 AND provider_id = ?2",
            params![id.provider.to_string(), id.provider_id],
        )? > 0)
    }
}

fn upsert_track(transaction: &Transaction<'_>, track: &Track) -> StorageResult<()> {
    let (album_provider, album_provider_id) = track
        .album_id
        .as_ref()
        .map(|id| (Some(id.provider.to_string()), Some(id.provider_id.as_str())))
        .unwrap_or((None, None));
    transaction.execute(
        "INSERT INTO tracks (
            provider, provider_id, title, version, album_provider, album_provider_id,
            album_title, artwork_url, artwork_local_key, artwork_width, artwork_height,
            duration_ms, isrc, explicit, metadata_updated_at_ms
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
         ON CONFLICT (provider, provider_id) DO UPDATE SET
            title = excluded.title,
            version = excluded.version,
            album_provider = excluded.album_provider,
            album_provider_id = excluded.album_provider_id,
            album_title = excluded.album_title,
            artwork_url = excluded.artwork_url,
            artwork_local_key = COALESCE(excluded.artwork_local_key, tracks.artwork_local_key),
            artwork_width = excluded.artwork_width,
            artwork_height = excluded.artwork_height,
            duration_ms = excluded.duration_ms,
            isrc = excluded.isrc,
            explicit = excluded.explicit,
            metadata_updated_at_ms = excluded.metadata_updated_at_ms",
        params![
            track.id.provider.to_string(),
            track.id.provider_id,
            track.title,
            track.version,
            album_provider,
            album_provider_id,
            track.album_title,
            track
                .artwork
                .as_ref()
                .and_then(|artwork| artwork.url.as_deref()),
            track
                .artwork
                .as_ref()
                .and_then(|artwork| artwork.local_key.as_deref()),
            track.artwork.as_ref().and_then(|artwork| artwork.width),
            track.artwork.as_ref().and_then(|artwork| artwork.height),
            track
                .duration_ms
                .map(|value| sqlite_u64(value, "track duration"))
                .transpose()?,
            track.isrc,
            track.explicit,
            unix_time_ms(),
        ],
    )?;
    transaction.execute(
        "DELETE FROM track_artists WHERE track_provider = ?1 AND track_provider_id = ?2",
        params![track.id.provider.to_string(), track.id.provider_id],
    )?;
    for (ordinal, artist) in track.artists.iter().enumerate() {
        let (provider, provider_id) = artist
            .id
            .as_ref()
            .map(|id| (Some(id.provider.to_string()), Some(id.provider_id.as_str())))
            .unwrap_or((None, None));
        transaction.execute(
            "INSERT INTO track_artists
             (track_provider, track_provider_id, ordinal, artist_provider, artist_provider_id, name)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                track.id.provider.to_string(),
                track.id.provider_id,
                sqlite_usize(ordinal, "artist ordinal")?,
                provider,
                provider_id,
                artist.name,
            ],
        )?;
    }
    Ok(())
}

fn load_track(connection: &Connection, id: &MediaId) -> StorageResult<Option<Track>> {
    type TrackRow = (
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<u32>,
        Option<u32>,
        Option<i64>,
        Option<String>,
        Option<bool>,
    );
    let row: Option<TrackRow> = connection
        .query_row(
            "SELECT title, version, album_provider, album_provider_id, album_title,
                    artwork_url, artwork_local_key, artwork_width, artwork_height,
                    duration_ms, isrc, explicit
             FROM tracks WHERE provider = ?1 AND provider_id = ?2",
            params![id.provider.to_string(), id.provider_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                    row.get(9)?,
                    row.get(10)?,
                    row.get(11)?,
                ))
            },
        )
        .optional()?;
    let Some(row) = row else { return Ok(None) };

    let album_id = match (row.2, row.3) {
        (Some(provider), Some(provider_id)) => Some(media_id(&provider, provider_id)?),
        (None, None) => None,
        _ => return Err(StorageError::InvalidMediaId),
    };
    let artwork = (row.5.is_some() || row.6.is_some() || row.7.is_some() || row.8.is_some())
        .then_some(Artwork {
            url: row.5,
            local_key: row.6,
            width: row.7,
            height: row.8,
        });
    let mut artist_statement = connection.prepare(
        "SELECT artist_provider, artist_provider_id, name
         FROM track_artists WHERE track_provider = ?1 AND track_provider_id = ?2
         ORDER BY ordinal",
    )?;
    let stored_artists = artist_statement
        .query_map(params![id.provider.to_string(), id.provider_id], |row| {
            Ok((
                row.get::<_, Option<String>>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let artists = stored_artists
        .into_iter()
        .map(|(provider, provider_id, name)| {
            let id = match (provider, provider_id) {
                (Some(provider), Some(provider_id)) => Some(media_id(&provider, provider_id)?),
                (None, None) => None,
                _ => return Err(StorageError::InvalidMediaId),
            };
            Ok(ArtistCredit { id, name })
        })
        .collect::<StorageResult<Vec<_>>>()?;

    Ok(Some(Track {
        id: id.clone(),
        title: row.0,
        version: row.1,
        artists,
        album_id,
        album_title: row.4,
        artwork,
        duration_ms: row
            .9
            .map(|value| value.try_into().map_err(|_| StorageError::InvalidMediaId))
            .transpose()?,
        isrc: row.10,
        explicit: row.11,
    }))
}

fn media_id(provider: &str, provider_id: String) -> StorageResult<MediaId> {
    let provider = Provider::from_wire_name(provider)
        .ok_or_else(|| StorageError::InvalidProvider(provider.to_owned()))?;
    MediaId::new(provider, provider_id).ok_or(StorageError::InvalidMediaId)
}

fn repeat_wire_name(repeat: RepeatMode) -> &'static str {
    match repeat {
        RepeatMode::Off => "off",
        RepeatMode::All => "all",
        RepeatMode::One => "one",
    }
}

fn repeat_from_wire_name(value: &str) -> StorageResult<RepeatMode> {
    match value {
        "off" => Ok(RepeatMode::Off),
        "all" => Ok(RepeatMode::All),
        "one" => Ok(RepeatMode::One),
        _ => Err(StorageError::Database(rusqlite::Error::InvalidQuery)),
    }
}

fn sqlite_u64(value: u64, field: &'static str) -> StorageResult<i64> {
    value
        .try_into()
        .map_err(|_| StorageError::IntegerOutOfRange(field))
}

fn sqlite_usize(value: usize, field: &'static str) -> StorageResult<i64> {
    value
        .try_into()
        .map_err(|_| StorageError::IntegerOutOfRange(field))
}

fn unix_time_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn listen_event(track: &Track, event_id: &str, listened_ms: u64) -> ListenEvent {
        ListenEvent {
            event_id: event_id.into(),
            device_id: "device-a".into(),
            media_id: track.id.clone(),
            started_at_ms: 1_000,
            ended_at_ms: 1_000 + listened_ms as i64,
            listened_ms,
            track_duration_ms: track.duration_ms,
        }
    }

    fn track(id: &str) -> Track {
        Track {
            id: MediaId::new(Provider::Tidal, id).unwrap(),
            title: "Color".into(),
            version: Some("Live".into()),
            artists: vec![ArtistCredit {
                id: MediaId::new(Provider::Tidal, "artist-1"),
                name: "Someone".into(),
            }],
            album_id: MediaId::new(Provider::Tidal, "album-1"),
            album_title: Some("Bright".into()),
            artwork: Some(Artwork {
                url: Some("https://example.test/cover.jpg".into()),
                local_key: None,
                width: Some(1280),
                height: Some(1280),
            }),
            duration_ms: Some(192_000),
            isrc: Some("TEST123".into()),
            explicit: Some(false),
        }
    }

    #[test]
    fn opens_and_migrates_a_new_database() {
        let storage = Storage::open_in_memory().unwrap();
        assert_eq!(storage.schema_version().unwrap(), CURRENT_SCHEMA_VERSION);
    }

    #[test]
    fn upgrades_a_version_one_database_without_losing_state() {
        let connection = Connection::open_in_memory().unwrap();
        connection.execute_batch(INITIAL_MIGRATION).unwrap();
        connection
            .execute(
                "INSERT INTO settings (key, value_json, updated_at_ms)
                 VALUES ('kept', 'true', 1)",
                [],
            )
            .unwrap();

        let storage = Storage::from_connection(connection).unwrap();
        assert_eq!(storage.schema_version().unwrap(), CURRENT_SCHEMA_VERSION);
        assert_eq!(storage.setting("kept").unwrap().as_deref(), Some("true"));
        assert_eq!(
            storage.listen_stats(None, 5).unwrap(),
            ListenStats::default()
        );
    }

    #[test]
    fn upgrades_a_version_two_database_with_local_playlists() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(&format!(
                "{INITIAL_MIGRATION}\n{LISTENING_HISTORY_MIGRATION}"
            ))
            .unwrap();
        let mut storage = Storage::from_connection(connection).unwrap();
        assert_eq!(storage.schema_version().unwrap(), CURRENT_SCHEMA_VERSION);
        let id = storage.create_playlist("Migrated", 1).unwrap();
        storage.add_playlist_track(&id, &track("kept"), 2).unwrap();
        assert_eq!(
            storage.playlists().unwrap()[0].tracks[0].id.provider_id,
            "kept"
        );
    }

    #[test]
    fn listening_history_is_idempotent_and_aggregates_tracks_artists_and_albums() {
        let mut storage = Storage::open_in_memory().unwrap();
        let first = track("first");
        let second = track("second");
        let first_event = listen_event(&first, "event-1", 100_000);
        let second_event = listen_event(&second, "event-2", 40_000);

        assert!(storage.record_listen(&first, &first_event).unwrap());
        assert!(!storage.record_listen(&first, &first_event).unwrap());
        assert!(storage.record_listen(&second, &second_event).unwrap());

        let stats = storage.listen_stats(None, 5).unwrap();
        assert_eq!(stats.total_listened_ms, 140_000);
        assert_eq!(stats.play_count, 2);
        assert_eq!(stats.provider_stats.len(), 1);
        assert_eq!(stats.provider_stats[0].provider, Provider::Tidal);
        assert_eq!(stats.provider_stats[0].listened_ms, 140_000);
        assert_eq!(stats.provider_stats[0].play_count, 2);
        assert_eq!(stats.top_tracks[0].track.id, first.id);
        assert_eq!(stats.top_tracks[0].listened_ms, 100_000);
        assert_eq!(stats.top_artists[0].name, "Someone");
        assert_eq!(stats.top_artists[0].listened_ms, 140_000);
        assert_eq!(stats.top_artists[0].play_count, 2);
        assert_eq!(stats.top_albums[0].title, "Bright");
        assert_eq!(stats.top_albums[0].listened_ms, 140_000);
        assert_eq!(stats.top_albums[0].play_count, 2);
        assert_eq!(stats.top_albums[0].artists[0].name, "Someone");
    }

    #[test]
    fn listening_history_ranks_provider_usage_by_listened_time() {
        let mut storage = Storage::open_in_memory().unwrap();
        let tidal = track("tidal-track");
        let mut youtube = track("youtube-track");
        youtube.id = MediaId::new(Provider::YouTube, "youtube-track").unwrap();
        youtube.artists[0].id = MediaId::new(Provider::YouTube, "youtube-artist");
        youtube.album_id = MediaId::new(Provider::YouTube, "youtube-album");

        storage
            .record_listen(&tidal, &listen_event(&tidal, "tidal-event", 30_000))
            .unwrap();
        storage
            .record_listen(&youtube, &listen_event(&youtube, "youtube-event", 90_000))
            .unwrap();

        let stats = storage.listen_stats(None, 5).unwrap();
        assert_eq!(stats.provider_stats.len(), 2);
        assert_eq!(stats.provider_stats[0].provider, Provider::YouTube);
        assert_eq!(stats.provider_stats[0].listened_ms, 90_000);
        assert_eq!(stats.provider_stats[1].provider, Provider::Tidal);
        assert_eq!(stats.provider_stats[1].listened_ms, 30_000);
    }

    #[test]
    fn round_trips_tracks_and_library_membership() {
        let mut storage = Storage::open_in_memory().unwrap();
        let original = track("track-1");
        storage.add_to_library(&original, 42).unwrap();

        let loaded = storage.track(&original.id).unwrap().unwrap();
        assert_eq!(loaded.title, original.title);
        assert_eq!(loaded.version, original.version);
        assert_eq!(loaded.artists, original.artists);
        assert_eq!(storage.library().unwrap(), vec![loaded]);
        assert!(storage.remove_from_library(&original.id).unwrap());
        assert!(storage.library().unwrap().is_empty());
    }

    #[test]
    fn local_playlists_preserve_order_duplicates_and_edits() {
        let mut storage = Storage::open_in_memory().unwrap();
        let id = storage.create_playlist("Night drive", 10).unwrap();
        storage.add_playlist_track(&id, &track("a"), 11).unwrap();
        storage.add_playlist_track(&id, &track("b"), 12).unwrap();
        storage.add_playlist_track(&id, &track("a"), 13).unwrap();

        let playlist = &storage.playlists().unwrap()[0];
        assert_eq!(playlist.name, "Night drive");
        assert_eq!(
            playlist
                .tracks
                .iter()
                .map(|track| track.id.provider_id.as_str())
                .collect::<Vec<_>>(),
            vec!["a", "b", "a"]
        );

        assert!(storage.move_playlist_item(&id, 2, 0, 14).unwrap());
        assert!(storage.remove_playlist_item(&id, 1, 15).unwrap());
        assert!(storage.rename_playlist(&id, "After dark", 16).unwrap());
        let playlist = &storage.playlists().unwrap()[0];
        assert_eq!(playlist.name, "After dark");
        assert_eq!(
            playlist
                .tracks
                .iter()
                .map(|track| track.id.provider_id.as_str())
                .collect::<Vec<_>>(),
            vec!["a", "b"]
        );
        assert!(storage.delete_playlist(&id).unwrap());
        assert!(storage.playlists().unwrap().is_empty());
    }

    #[test]
    fn round_trips_playback_queue_and_shuffle_state() {
        let mut storage = Storage::open_in_memory().unwrap();
        let first = track("a");
        let second = track("b");
        storage.upsert_track(&first).unwrap();
        storage.upsert_track(&second).unwrap();

        let mut queue = PlaybackQueue::new();
        queue.replace([first.id.clone(), first.id.clone(), second.id.clone()]);
        queue.set_shuffle(true, u64::MAX - 4);
        queue.advance(RepeatMode::Off);
        storage
            .save_playback(&queue, 31_337, RepeatMode::All, 99)
            .unwrap();

        let loaded = storage.load_playback().unwrap();
        assert_eq!(loaded.queue.snapshot(), queue.snapshot());
        assert_eq!(loaded.position_ms, 31_337);
        assert_eq!(loaded.repeat, RepeatMode::All);
    }

    #[test]
    fn lets_sqlite_reject_invalid_json_settings() {
        let mut storage = Storage::open_in_memory().unwrap();
        storage.set_setting("discord.enabled", "true", 1).unwrap();
        assert_eq!(
            storage.setting("discord.enabled").unwrap().as_deref(),
            Some("true")
        );
        assert!(
            storage
                .set_setting("discord.enabled", "not-json", 2)
                .is_err()
        );
    }

    #[test]
    fn round_trips_resumable_and_complete_downloads() {
        let mut storage = Storage::open_in_memory().unwrap();
        let mut track = track("offline");
        let mut job = DownloadJob::queued(track.id.clone(), 1);
        job.begin_transfer(Some(200), Some(5000), 2).unwrap();
        job.report_progress(80, 3).unwrap();
        storage.save_download(&track, &job).unwrap();
        assert_eq!(storage.download(&track.id).unwrap(), Some(job.clone()));

        job.begin_transfer(Some(200), Some(6000), 4).unwrap();
        job.complete("music/offline.flac", 200, 5).unwrap();
        track.artwork.as_mut().unwrap().local_key = Some("music/offline.cover".into());
        storage.save_download(&track, &job).unwrap();
        assert_eq!(storage.download(&track.id).unwrap(), Some(job));

        let mut refreshed_metadata = track.clone();
        refreshed_metadata.artwork.as_mut().unwrap().local_key = None;
        storage.upsert_track(&refreshed_metadata).unwrap();
        assert_eq!(
            storage
                .track(&track.id)
                .unwrap()
                .unwrap()
                .artwork
                .unwrap()
                .local_key
                .as_deref(),
            Some("music/offline.cover")
        );
        assert!(storage.remove_download(&track.id).unwrap());
    }
}
