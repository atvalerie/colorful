use crate::media::{ArtistCredit, Artwork, MediaId, Provider, Track};
use crate::playback::RepeatMode;
use crate::queue::{PlaybackQueue, QueueEntry, QueueEntryId, QueueSnapshot, QueueSnapshotError};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use std::fmt;
use std::path::Path;
use std::time::Duration;

const CURRENT_SCHEMA_VERSION: i64 = 1;
const INITIAL_MIGRATION: &str = include_str!("../migrations/0001_local_state.sql");

#[derive(Debug)]
pub enum StorageError {
    Database(rusqlite::Error),
    Io(std::io::Error),
    UnsupportedSchema(i64),
    InvalidProvider(String),
    InvalidMediaId,
    InvalidQueue(QueueSnapshotError),
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
        match version {
            0 => {
                if let Err(error) = connection
                    .execute_batch(&format!("BEGIN IMMEDIATE;\n{INITIAL_MIGRATION}\nCOMMIT;"))
                {
                    let _ = connection.execute_batch("ROLLBACK;");
                    return Err(error.into());
                }
            }
            CURRENT_SCHEMA_VERSION => {}
            other => return Err(StorageError::UnsupportedSchema(other)),
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
            artwork_local_key = excluded.artwork_local_key,
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
}
