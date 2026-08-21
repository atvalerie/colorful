use crate::media::{ArtistCredit, Artwork, MediaId, Provider, Track};
use crate::playback::RepeatMode;
use crate::queue::{PlaybackQueue, QueueEntryId, QueueSnapshot, QueueSnapshotError};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use std::fmt;

/// The on-disk and over-the-wire identifier for a portable travel snapshot.
pub const TRAVEL_SNAPSHOT_FORMAT: &str = "colorful-travel-snapshot";

/// The current travel snapshot schema version.
pub const TRAVEL_SNAPSHOT_VERSION: u32 = 1;

/// Settings whose values are portable across colorful clients. New settings
/// must be added here deliberately after their value shape has been reviewed.
pub const PORTABLE_SETTING_KEYS: &[&str] = &[
    "playback/autoplay",
    "playback/streamQuality",
    "playback/normalization",
    "playback/equalizerBands",
    "playback/equalizerPreset",
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TravelSnapshotError {
    InvalidJson(String),
    Serialization(String),
    UnsupportedFormat(String),
    UnsupportedVersion(u32),
    Invalid(String),
    InvalidQueue(QueueSnapshotError),
}

impl fmt::Display for TravelSnapshotError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidJson(error) => write!(formatter, "invalid travel snapshot JSON: {error}"),
            Self::Serialization(error) => {
                write!(formatter, "could not serialize travel snapshot: {error}")
            }
            Self::UnsupportedFormat(format) => {
                write!(formatter, "unsupported travel snapshot format: {format}")
            }
            Self::UnsupportedVersion(version) => write!(
                formatter,
                "unsupported travel snapshot version {version}; supported version is {TRAVEL_SNAPSHOT_VERSION}"
            ),
            Self::Invalid(error) => write!(formatter, "invalid travel snapshot: {error}"),
            Self::InvalidQueue(error) => {
                write!(formatter, "invalid travel snapshot queue: {error:?}")
            }
        }
    }
}

impl std::error::Error for TravelSnapshotError {}

#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TravelMediaId {
    pub provider: Provider,
    pub provider_id: String,
}

impl From<&MediaId> for TravelMediaId {
    fn from(value: &MediaId) -> Self {
        Self {
            provider: value.provider,
            provider_id: value.provider_id.clone(),
        }
    }
}

impl TravelMediaId {
    fn into_media_id(&self) -> Result<MediaId, TravelSnapshotError> {
        if self.provider == Provider::Local {
            return Err(TravelSnapshotError::Invalid(
                "local-provider media is not portable".into(),
            ));
        }
        MediaId::new(self.provider, self.provider_id.clone()).ok_or_else(|| {
            TravelSnapshotError::Invalid("media IDs must have a non-empty provider ID".into())
        })
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TravelArtist {
    pub id: Option<TravelMediaId>,
    pub name: String,
}

impl From<&ArtistCredit> for TravelArtist {
    fn from(value: &ArtistCredit) -> Self {
        Self {
            id: value.id.as_ref().map(TravelMediaId::from),
            name: value.name.clone(),
        }
    }
}

impl TravelArtist {
    fn into_artist(&self) -> Result<ArtistCredit, TravelSnapshotError> {
        Ok(ArtistCredit {
            id: self
                .id
                .as_ref()
                .map(TravelMediaId::into_media_id)
                .transpose()?,
            name: self.name.clone(),
        })
    }
}

/// Artwork dimensions are useful metadata. URLs and local cache keys are
/// intentionally absent because they may be signed or device-specific.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TravelArtwork {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
}

impl TravelArtwork {
    fn from_artwork(value: &Artwork) -> Option<Self> {
        (value.width.is_some() || value.height.is_some()).then_some(Self {
            width: value.width,
            height: value.height,
        })
    }

    fn into_artwork(&self) -> Artwork {
        Artwork {
            url: None,
            local_key: None,
            width: self.width,
            height: self.height,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TravelTrack {
    pub id: TravelMediaId,
    pub title: String,
    pub version: Option<String>,
    pub artists: Vec<TravelArtist>,
    pub album_id: Option<TravelMediaId>,
    pub album_title: Option<String>,
    pub artwork: Option<TravelArtwork>,
    pub duration_ms: Option<u64>,
    pub isrc: Option<String>,
    pub explicit: Option<bool>,
}

impl TravelTrack {
    fn from_track(value: &Track) -> Result<Self, TravelSnapshotError> {
        let track = Self {
            id: TravelMediaId::from(&value.id),
            title: value.title.clone(),
            version: value.version.clone(),
            artists: value
                .artists
                .iter()
                .map(|artist| TravelArtist {
                    id: artist
                        .id
                        .as_ref()
                        .filter(|id| id.provider != Provider::Local)
                        .map(TravelMediaId::from),
                    name: artist.name.clone(),
                })
                .collect(),
            album_id: value
                .album_id
                .as_ref()
                .filter(|id| id.provider != Provider::Local)
                .map(TravelMediaId::from),
            album_title: value.album_title.clone(),
            artwork: value.artwork.as_ref().and_then(TravelArtwork::from_artwork),
            duration_ms: value.duration_ms,
            isrc: value.isrc.clone(),
            explicit: value.explicit,
        };
        track.validate()?;
        Ok(track)
    }

    fn into_track(&self) -> Result<Track, TravelSnapshotError> {
        Ok(Track {
            id: self.id.into_media_id()?,
            title: self.title.clone(),
            version: self.version.clone(),
            artists: self
                .artists
                .iter()
                .map(TravelArtist::into_artist)
                .collect::<Result<_, _>>()?,
            album_id: self
                .album_id
                .as_ref()
                .map(TravelMediaId::into_media_id)
                .transpose()?,
            album_title: self.album_title.clone(),
            artwork: self.artwork.as_ref().map(TravelArtwork::into_artwork),
            duration_ms: self.duration_ms,
            isrc: self.isrc.clone(),
            explicit: self.explicit,
        })
    }

    fn validate(&self) -> Result<(), TravelSnapshotError> {
        self.id.into_media_id()?;
        if self.title.trim().is_empty() {
            return Err(TravelSnapshotError::Invalid(
                "track titles must not be blank".into(),
            ));
        }
        for artist in &self.artists {
            if artist.name.trim().is_empty() {
                return Err(TravelSnapshotError::Invalid(
                    "artist names must not be blank".into(),
                ));
            }
            if let Some(id) = &artist.id {
                id.into_media_id()?;
            }
        }
        if let Some(album_id) = &self.album_id {
            album_id.into_media_id()?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TravelLibraryEntry {
    pub id: TravelMediaId,
    pub added_at_ms: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TravelPlaylist {
    pub id: String,
    pub name: String,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    pub track_ids: Vec<TravelMediaId>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TravelQueueEntry {
    pub id: QueueEntryId,
    pub media_id: TravelMediaId,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TravelQueue {
    pub entries: Vec<TravelQueueEntry>,
    pub play_order: Vec<QueueEntryId>,
    pub current: Option<QueueEntryId>,
    pub shuffle: bool,
    pub shuffle_seed: u64,
    pub next_entry_id: u64,
}

impl TravelQueue {
    fn from_queue(value: &PlaybackQueue) -> Self {
        let snapshot = value.snapshot();
        Self {
            entries: snapshot
                .entries
                .iter()
                .map(|entry| TravelQueueEntry {
                    id: entry.id,
                    media_id: TravelMediaId::from(&entry.media_id),
                })
                .collect(),
            play_order: snapshot.play_order,
            current: snapshot.current,
            shuffle: snapshot.shuffle,
            shuffle_seed: snapshot.shuffle_seed,
            next_entry_id: snapshot.next_entry_id,
        }
    }

    fn into_queue(&self) -> Result<PlaybackQueue, TravelSnapshotError> {
        let snapshot = QueueSnapshot {
            entries: self
                .entries
                .iter()
                .map(|entry| {
                    Ok(crate::queue::QueueEntry {
                        id: entry.id,
                        media_id: entry.media_id.into_media_id()?,
                    })
                })
                .collect::<Result<_, TravelSnapshotError>>()?,
            play_order: self.play_order.clone(),
            current: self.current,
            shuffle: self.shuffle,
            shuffle_seed: self.shuffle_seed,
            next_entry_id: self.next_entry_id,
        };
        PlaybackQueue::from_snapshot(snapshot).map_err(TravelSnapshotError::InvalidQueue)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TravelPlayback {
    pub queue: TravelQueue,
    pub position_ms: u64,
    pub repeat: RepeatMode,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TravelSetting {
    pub key: String,
    pub value: Value,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TravelSnapshot {
    pub format: String,
    pub version: u32,
    pub tracks: Vec<TravelTrack>,
    pub library: Vec<TravelLibraryEntry>,
    pub playlists: Vec<TravelPlaylist>,
    pub playback: TravelPlayback,
    pub settings: Vec<TravelSetting>,
}

impl TravelSnapshot {
    pub fn from_json(json: &str) -> Result<Self, TravelSnapshotError> {
        let snapshot: Self = serde_json::from_str(json)
            .map_err(|error| TravelSnapshotError::InvalidJson(error.to_string()))?;
        let mut snapshot = snapshot;
        snapshot.canonicalize()?;
        Ok(snapshot)
    }

    pub fn to_json(&self) -> Result<String, TravelSnapshotError> {
        let mut snapshot = self.clone();
        snapshot.canonicalize()?;
        serde_json::to_string(&snapshot)
            .map_err(|error| TravelSnapshotError::Serialization(error.to_string()))
    }

    pub fn validate(&self) -> Result<(), TravelSnapshotError> {
        if self.format != TRAVEL_SNAPSHOT_FORMAT {
            return Err(TravelSnapshotError::UnsupportedFormat(self.format.clone()));
        }
        if self.version != TRAVEL_SNAPSHOT_VERSION {
            return Err(TravelSnapshotError::UnsupportedVersion(self.version));
        }

        let mut track_ids = HashSet::with_capacity(self.tracks.len());
        for track in &self.tracks {
            track.validate()?;
            if !track_ids.insert(track.id.clone()) {
                return Err(TravelSnapshotError::Invalid(format!(
                    "duplicate track {}:{}",
                    track.id.provider, track.id.provider_id
                )));
            }
        }

        let mut library_ids = HashSet::with_capacity(self.library.len());
        for entry in &self.library {
            entry.id.into_media_id()?;
            if !track_ids.contains(&entry.id) {
                return Err(TravelSnapshotError::Invalid(format!(
                    "library references missing track {}:{}",
                    entry.id.provider, entry.id.provider_id
                )));
            }
            if !library_ids.insert(entry.id.clone()) {
                return Err(TravelSnapshotError::Invalid(format!(
                    "duplicate library track {}:{}",
                    entry.id.provider, entry.id.provider_id
                )));
            }
        }

        let mut playlist_ids = HashSet::with_capacity(self.playlists.len());
        for playlist in &self.playlists {
            if playlist.id.trim().is_empty() {
                return Err(TravelSnapshotError::Invalid(
                    "playlist IDs must not be blank".into(),
                ));
            }
            if playlist.name.trim().is_empty() {
                return Err(TravelSnapshotError::Invalid(
                    "playlist names must not be blank".into(),
                ));
            }
            if !playlist_ids.insert(playlist.id.as_str()) {
                return Err(TravelSnapshotError::Invalid(format!(
                    "duplicate playlist ID {}",
                    playlist.id
                )));
            }
            for id in &playlist.track_ids {
                id.into_media_id()?;
                if !track_ids.contains(id) {
                    return Err(TravelSnapshotError::Invalid(format!(
                        "playlist {} references missing track {}:{}",
                        playlist.id, id.provider, id.provider_id
                    )));
                }
            }
        }

        for entry in &self.playback.queue.entries {
            entry.media_id.into_media_id()?;
            if !track_ids.contains(&entry.media_id) {
                return Err(TravelSnapshotError::Invalid(format!(
                    "queue references missing track {}:{}",
                    entry.media_id.provider, entry.media_id.provider_id
                )));
            }
        }
        let queue = self.playback.queue.into_queue()?;
        if self.playback.queue.shuffle_seed > i64::MAX as u64 {
            return Err(TravelSnapshotError::Invalid(
                "shuffle seed does not fit the portable SQLite representation".into(),
            ));
        }
        if self.playback.position_ms > 0 && queue.current_id().is_none() {
            return Err(TravelSnapshotError::Invalid(
                "playback position requires a current queue entry".into(),
            ));
        }

        let mut setting_keys = HashSet::with_capacity(self.settings.len());
        for setting in &self.settings {
            if !validate_setting(&setting.key, &setting.value) {
                return Err(TravelSnapshotError::Invalid(format!(
                    "setting {} is not portable or has an invalid value",
                    setting.key
                )));
            }
            if !setting_keys.insert(setting.key.as_str()) {
                return Err(TravelSnapshotError::Invalid(format!(
                    "duplicate setting {}",
                    setting.key
                )));
            }
        }
        Ok(())
    }

    pub(crate) fn canonicalize(&mut self) -> Result<(), TravelSnapshotError> {
        self.validate()?;
        self.tracks
            .sort_by(|left, right| media_id_key(&left.id).cmp(&media_id_key(&right.id)));
        self.library
            .sort_by(|left, right| media_id_key(&left.id).cmp(&media_id_key(&right.id)));
        self.playlists.sort_by(|left, right| left.id.cmp(&right.id));
        self.settings
            .sort_by(|left, right| left.key.cmp(&right.key));
        Ok(())
    }

    pub(crate) fn from_storage_parts(
        tracks: Vec<Track>,
        library: Vec<TravelLibraryEntry>,
        playlists: Vec<TravelPlaylist>,
        queue: &PlaybackQueue,
        position_ms: u64,
        repeat: RepeatMode,
        settings: Vec<TravelSetting>,
    ) -> Result<Self, TravelSnapshotError> {
        let mut unique_tracks = Vec::with_capacity(tracks.len());
        for track in tracks {
            if !unique_tracks
                .iter()
                .any(|existing: &Track| existing.id == track.id)
            {
                unique_tracks.push(track);
            }
        }
        let snapshot = Self {
            format: TRAVEL_SNAPSHOT_FORMAT.into(),
            version: TRAVEL_SNAPSHOT_VERSION,
            tracks: unique_tracks
                .iter()
                .map(TravelTrack::from_track)
                .collect::<Result<_, _>>()?,
            library,
            playlists,
            playback: TravelPlayback {
                queue: TravelQueue::from_queue(queue),
                position_ms,
                repeat,
            },
            settings,
        };
        let mut snapshot = snapshot;
        snapshot.canonicalize()?;
        Ok(snapshot)
    }

    pub(crate) fn tracks(&self) -> Result<Vec<Track>, TravelSnapshotError> {
        self.tracks.iter().map(TravelTrack::into_track).collect()
    }

    pub(crate) fn queue(&self) -> Result<PlaybackQueue, TravelSnapshotError> {
        self.playback.queue.into_queue()
    }
}

/// Removes local-provider queue entries for export while retaining the queue's
/// stable portable entries and playback order. If the current entry is local,
/// the next portable playback entry is selected, falling back to the first
/// portable entry. The caller resets the position when that happens.
pub(crate) fn filter_local_queue(
    value: &PlaybackQueue,
) -> Result<(PlaybackQueue, bool), TravelSnapshotError> {
    let snapshot = value.snapshot();
    let portable_ids: HashSet<_> = snapshot
        .entries
        .iter()
        .filter(|entry| entry.media_id.provider != Provider::Local)
        .map(|entry| entry.id)
        .collect();
    let entries = snapshot
        .entries
        .iter()
        .filter(|entry| portable_ids.contains(&entry.id))
        .cloned()
        .collect::<Vec<_>>();
    let play_order = snapshot
        .play_order
        .iter()
        .copied()
        .filter(|id| portable_ids.contains(id))
        .collect::<Vec<_>>();
    let current_was_removed = snapshot
        .current
        .is_some_and(|current| !portable_ids.contains(&current));
    let current = if current_was_removed {
        snapshot
            .current
            .and_then(|current| {
                snapshot
                    .play_order
                    .iter()
                    .position(|id| *id == current)
                    .and_then(|position| {
                        snapshot
                            .play_order
                            .iter()
                            .skip(position + 1)
                            .find(|id| portable_ids.contains(id))
                            .copied()
                    })
            })
            .or_else(|| play_order.first().copied())
    } else {
        snapshot.current
    };
    PlaybackQueue::from_snapshot(QueueSnapshot {
        entries,
        play_order,
        current,
        shuffle: snapshot.shuffle,
        shuffle_seed: snapshot.shuffle_seed,
        next_entry_id: snapshot.next_entry_id,
    })
    .map(|queue| (queue, current_was_removed))
    .map_err(TravelSnapshotError::InvalidQueue)
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TravelImportSummary {
    pub track_count: usize,
    pub library_count: usize,
    pub playlist_count: usize,
    pub queue_count: usize,
    pub setting_count: usize,
}

impl TravelImportSummary {
    pub(crate) fn from_snapshot(snapshot: &TravelSnapshot) -> Self {
        Self {
            track_count: snapshot.tracks.len(),
            library_count: snapshot.library.len(),
            playlist_count: snapshot.playlists.len(),
            queue_count: snapshot.playback.queue.entries.len(),
            setting_count: snapshot.settings.len(),
        }
    }
}

pub fn is_portable_setting_key(key: &str) -> bool {
    PORTABLE_SETTING_KEYS.contains(&key)
}

pub fn validate_setting(key: &str, value: &Value) -> bool {
    match key {
        "playback/autoplay" | "playback/normalization" => value.is_boolean(),
        "playback/streamQuality" | "playback/equalizerPreset" => value
            .as_str()
            .is_some_and(|value| !value.trim().is_empty() && value.len() <= 64),
        "playback/equalizerBands" => value.as_array().is_some_and(|values| {
            values.len() == 10
                && values.iter().all(|value| {
                    value
                        .as_f64()
                        .is_some_and(|gain| gain.is_finite() && (-12.0..=12.0).contains(&gain))
                })
        }),
        _ => false,
    }
}

fn media_id_key(id: &TravelMediaId) -> String {
    format!("{}\0{}", id.provider, id.provider_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::Provider;

    fn media(provider: Provider, id: &str) -> MediaId {
        MediaId::new(provider, id).unwrap()
    }

    fn track(id: &str) -> Track {
        Track {
            id: media(Provider::Tidal, id),
            title: format!("Track {id}"),
            version: None,
            artists: vec![ArtistCredit {
                id: None,
                name: "Artist".into(),
            }],
            album_id: None,
            album_title: None,
            artwork: Some(Artwork {
                url: Some("https://signed.example/audio?token=secret".into()),
                local_key: Some("C:/private/cache/cover.jpg".into()),
                width: Some(100),
                height: Some(100),
            }),
            duration_ms: Some(10_000),
            isrc: None,
            explicit: Some(false),
        }
    }

    fn snapshot() -> TravelSnapshot {
        let first = track("first");
        let second = track("second");
        let mut queue = PlaybackQueue::new();
        queue.replace([first.id.clone(), second.id.clone(), first.id.clone()]);
        queue.set_shuffle(true, 42);
        queue.advance(RepeatMode::All);
        TravelSnapshot::from_storage_parts(
            vec![second.clone(), first.clone(), first],
            vec![TravelLibraryEntry {
                id: TravelMediaId::from(&second.id),
                added_at_ms: 7,
            }],
            vec![TravelPlaylist {
                id: "playlist-1".into(),
                name: "Trip".into(),
                created_at_ms: 1,
                updated_at_ms: 2,
                track_ids: vec![
                    TravelMediaId::from(&second.id),
                    TravelMediaId::from(&second.id),
                ],
            }],
            &queue,
            1_234,
            RepeatMode::All,
            vec![TravelSetting {
                key: "playback/autoplay".into(),
                value: Value::Bool(true),
            }],
        )
        .unwrap()
    }

    #[test]
    fn canonical_json_is_deterministic_and_preserves_order() {
        let snapshot = snapshot();
        let first = snapshot.to_json().unwrap();
        let second = snapshot.to_json().unwrap();
        assert_eq!(first, second);
        assert!(first.find("\"tracks\"").unwrap() < first.find("\"playback\"").unwrap());
        assert!(first.contains("\"trackIds\":[{\"provider\":\"tidal\",\"providerId\":\"second\"},{\"provider\":\"tidal\",\"providerId\":\"second\"}]"));
    }

    #[test]
    fn round_trip_rehydrates_without_local_artwork_data() {
        let snapshot = snapshot();
        let json = snapshot.to_json().unwrap();
        let parsed = TravelSnapshot::from_json(&json).unwrap();
        assert_eq!(parsed, snapshot);
        assert!(!json.contains("signed.example"));
        assert!(!json.contains("private/cache"));
        assert!(!json.contains("localKey"));
        assert_eq!(parsed.tracks[0].artwork.as_ref().unwrap().width, Some(100));
    }

    #[test]
    fn rejects_unsupported_versions_and_excluded_fields() {
        let version = snapshot()
            .to_json()
            .unwrap()
            .replace("\"version\":1", "\"version\":2");
        assert_eq!(
            TravelSnapshot::from_json(&version),
            Err(TravelSnapshotError::UnsupportedVersion(2))
        );

        let with_downloads = snapshot()
            .to_json()
            .unwrap()
            .replace('}', ",\"downloads\":[]}");
        assert!(matches!(
            TravelSnapshot::from_json(&with_downloads),
            Err(TravelSnapshotError::InvalidJson(_))
        ));
    }

    #[test]
    fn rejects_duplicate_tracks_and_nonportable_settings() {
        let mut duplicate_tracks = snapshot();
        duplicate_tracks
            .tracks
            .push(duplicate_tracks.tracks[0].clone());
        assert!(matches!(
            duplicate_tracks.validate(),
            Err(TravelSnapshotError::Invalid(message)) if message.contains("duplicate track")
        ));

        let mut nonportable = snapshot();
        nonportable.settings.push(TravelSetting {
            key: "provider/token".into(),
            value: Value::String("secret".into()),
        });
        assert!(matches!(
            nonportable.validate(),
            Err(TravelSnapshotError::Invalid(message)) if message.contains("not portable")
        ));
    }

    #[test]
    fn filters_local_queue_entries_and_recovers_from_a_local_current_entry() {
        let local = media(Provider::Local, "C:/private/local-track");
        let portable = media(Provider::Tidal, "portable");
        let mut queue = PlaybackQueue::new();
        queue.replace([local, portable.clone()]);

        let (filtered, current_was_removed) = filter_local_queue(&queue).unwrap();
        assert!(current_was_removed);
        assert_eq!(filtered.entries().len(), 1);
        assert_eq!(filtered.current().unwrap().media_id, portable);

        let mut local_only = PlaybackQueue::new();
        local_only.replace([media(Provider::Local, "only-local")]);
        let (filtered, current_was_removed) = filter_local_queue(&local_only).unwrap();
        assert!(current_was_removed);
        assert!(filtered.is_empty());
        assert!(filtered.current().is_none());
    }

    #[test]
    fn rejects_shuffle_seeds_that_do_not_fit_sqlite() {
        let mut snapshot = snapshot();
        snapshot.playback.queue.shuffle_seed = u64::MAX;
        assert!(matches!(
            snapshot.validate(),
            Err(TravelSnapshotError::Invalid(message))
                if message.contains("shuffle seed")
        ));
    }
}
