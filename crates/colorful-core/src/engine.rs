use crate::download::DownloadJob;
use crate::history::{ListenEvent, ListenStats};
use crate::media::{MediaId, Track};
use crate::playback::{PlaybackState, RepeatMode};
use crate::queue::{PlaybackQueue, QueueEntryId, QueueSnapshot};
use crate::storage::{Storage, StorageError};
use std::fmt;
use std::path::Path;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EngineCommand {
    PlayTracks(Vec<Track>),
    PlayTracksInOrder(Vec<Track>),
    Enqueue(Track),
    EnqueueTracks(Vec<Track>),
    PlayNext(Track),
    Select(QueueEntryId),
    Remove(QueueEntryId),
    Move {
        entry: QueueEntryId,
        target_index: usize,
    },
    Play,
    Pause,
    Stop,
    SeekTo(u64),
    SkipNext,
    SkipPrevious,
    SetRepeat(RepeatMode),
    SetShuffle {
        enabled: bool,
        seed: u64,
    },
    CheckpointPosition(u64),
    AddToLibrary(Track),
    RemoveFromLibrary(MediaId),
    SetSetting {
        key: String,
        value_json: String,
    },
    SaveDownload {
        track: Track,
        job: DownloadJob,
    },
    RemoveDownload(MediaId),
    RecordListen {
        track: Track,
        event: ListenEvent,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PlaybackDirective {
    Load {
        track: Box<Track>,
        position_ms: u64,
        autoplay: bool,
    },
    Pause,
    Stop,
    Seek {
        position_ms: u64,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EngineEvent {
    QueueChanged(QueueSnapshot),
    PlaybackChanged(PlaybackState),
    PlaybackDirective(PlaybackDirective),
    LibraryChanged,
    SettingChanged(String),
    DownloadChanged(DownloadJob),
    DownloadRemoved(MediaId),
    HistoryChanged,
}

#[derive(Debug)]
pub enum EngineError {
    Storage(StorageError),
    MissingTrack(MediaId),
    InvalidListen,
}

impl fmt::Display for EngineError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Storage(error) => error.fmt(formatter),
            Self::MissingTrack(id) => write!(
                formatter,
                "missing metadata for {} track {}",
                id.provider, id.provider_id
            ),
            Self::InvalidListen => formatter.write_str("invalid listening-history event"),
        }
    }
}

impl std::error::Error for EngineError {}

impl From<StorageError> for EngineError {
    fn from(value: StorageError) -> Self {
        Self::Storage(value)
    }
}

pub type EngineResult<T> = Result<T, EngineError>;

pub struct Engine {
    storage: Storage,
    queue: PlaybackQueue,
    playback: PlaybackState,
}

impl Engine {
    pub fn open(path: impl AsRef<Path>) -> EngineResult<Self> {
        Self::from_storage(Storage::open(path)?)
    }

    pub fn open_in_memory() -> EngineResult<Self> {
        Self::from_storage(Storage::open_in_memory()?)
    }

    pub fn from_storage(storage: Storage) -> EngineResult<Self> {
        let stored = storage.load_playback()?;
        let playback = PlaybackState {
            current: stored.queue.current().map(|entry| entry.media_id.clone()),
            position_ms: stored.position_ms,
            playing: false,
            repeat: stored.repeat,
            shuffle: stored.queue.shuffle_enabled(),
        };
        Ok(Self {
            storage,
            queue: stored.queue,
            playback,
        })
    }

    pub fn queue(&self) -> &PlaybackQueue {
        &self.queue
    }

    pub fn playback(&self) -> &PlaybackState {
        &self.playback
    }

    pub fn library(&self) -> EngineResult<Vec<Track>> {
        Ok(self.storage.library()?)
    }

    /// Hydrates the visible queue order for native shells. Queue snapshots use
    /// stable entry IDs and media IDs; shells also need the persisted metadata
    /// to render a queue after a process restart.
    pub fn queue_tracks(&self) -> EngineResult<Vec<Track>> {
        self.queue
            .entries()
            .iter()
            .map(|entry| {
                self.storage
                    .track(&entry.media_id)?
                    .ok_or_else(|| EngineError::MissingTrack(entry.media_id.clone()))
            })
            .collect()
    }

    pub fn setting(&self, key: &str) -> EngineResult<Option<String>> {
        Ok(self.storage.setting(key)?)
    }

    pub fn downloads(&self) -> EngineResult<Vec<DownloadJob>> {
        Ok(self.storage.downloads()?)
    }

    /// Hydrates download jobs in the same order returned by [`Self::downloads`].
    /// Native shells need this metadata to render and resume offline jobs after
    /// a restart without querying the provider.
    pub fn download_tracks(&self, downloads: &[DownloadJob]) -> EngineResult<Vec<Track>> {
        downloads
            .iter()
            .map(|job| {
                self.storage
                    .track(&job.media_id)?
                    .ok_or_else(|| EngineError::MissingTrack(job.media_id.clone()))
            })
            .collect()
    }

    pub fn listen_stats(&self) -> EngineResult<ListenStats> {
        Ok(self.storage.listen_stats(None, 5)?)
    }

    pub fn dispatch(&mut self, command: EngineCommand) -> EngineResult<Vec<EngineEvent>> {
        let mut events = Vec::new();
        let mut persist_playback = false;
        match command {
            EngineCommand::PlayTracks(tracks) => {
                for track in &tracks {
                    self.storage.upsert_track(track)?;
                }
                self.queue.replace(tracks.into_iter().map(|track| track.id));
                self.sync_current();
                self.playback.position_ms = 0;
                self.playback.playing = self.playback.current.is_some();
                events.push(EngineEvent::QueueChanged(self.queue.snapshot()));
                events.push(EngineEvent::PlaybackChanged(self.playback.clone()));
                if let Some(directive) = self.load_current_directive(self.playback.playing)? {
                    events.push(EngineEvent::PlaybackDirective(directive));
                }
                persist_playback = true;
            }
            EngineCommand::PlayTracksInOrder(tracks) => {
                for track in &tracks {
                    self.storage.upsert_track(track)?;
                }
                self.queue
                    .replace_in_order(tracks.into_iter().map(|track| track.id));
                self.sync_current();
                self.playback.position_ms = 0;
                self.playback.playing = self.playback.current.is_some();
                events.push(EngineEvent::QueueChanged(self.queue.snapshot()));
                events.push(EngineEvent::PlaybackChanged(self.playback.clone()));
                if let Some(directive) = self.load_current_directive(self.playback.playing)? {
                    events.push(EngineEvent::PlaybackDirective(directive));
                }
                persist_playback = true;
            }
            EngineCommand::Enqueue(track) => {
                self.storage.upsert_track(&track)?;
                self.queue.append(track.id);
                self.sync_current();
                events.push(EngineEvent::QueueChanged(self.queue.snapshot()));
                events.push(EngineEvent::PlaybackChanged(self.playback.clone()));
                persist_playback = true;
            }
            EngineCommand::EnqueueTracks(tracks) => {
                for track in tracks {
                    self.storage.upsert_track(&track)?;
                    self.queue.append(track.id);
                }
                self.sync_current();
                events.push(EngineEvent::QueueChanged(self.queue.snapshot()));
                events.push(EngineEvent::PlaybackChanged(self.playback.clone()));
                persist_playback = true;
            }
            EngineCommand::PlayNext(track) => {
                self.storage.upsert_track(&track)?;
                self.queue.play_next(track.id);
                self.sync_current();
                events.push(EngineEvent::QueueChanged(self.queue.snapshot()));
                events.push(EngineEvent::PlaybackChanged(self.playback.clone()));
                persist_playback = true;
            }
            EngineCommand::Select(entry) => {
                if self.queue.select(entry) {
                    self.sync_current();
                    self.playback.position_ms = 0;
                    self.playback.playing = true;
                    events.push(EngineEvent::PlaybackChanged(self.playback.clone()));
                    if let Some(directive) = self.load_current_directive(true)? {
                        events.push(EngineEvent::PlaybackDirective(directive));
                    }
                    persist_playback = true;
                }
            }
            EngineCommand::Remove(entry) => {
                let removing_current = self.queue.current_id() == Some(entry);
                if self.queue.remove(entry).is_some() {
                    self.sync_current();
                    if self.playback.current.is_none() {
                        self.playback.playing = false;
                        self.playback.position_ms = 0;
                    } else if removing_current {
                        self.playback.position_ms = 0;
                    }
                    events.push(EngineEvent::QueueChanged(self.queue.snapshot()));
                    events.push(EngineEvent::PlaybackChanged(self.playback.clone()));
                    if removing_current {
                        events.push(EngineEvent::PlaybackDirective(
                            self.load_current_directive(self.playback.playing)?
                                .unwrap_or(PlaybackDirective::Stop),
                        ));
                    }
                    persist_playback = true;
                }
            }
            EngineCommand::Move {
                entry,
                target_index,
            } => {
                if self.queue.move_entry(entry, target_index) {
                    events.push(EngineEvent::QueueChanged(self.queue.snapshot()));
                    persist_playback = true;
                }
            }
            EngineCommand::Play => {
                if self.playback.current.is_some() {
                    self.playback.playing = true;
                    events.push(EngineEvent::PlaybackChanged(self.playback.clone()));
                    if let Some(directive) = self.load_current_directive(true)? {
                        events.push(EngineEvent::PlaybackDirective(directive));
                    }
                    persist_playback = true;
                }
            }
            EngineCommand::Pause => {
                self.playback.playing = false;
                events.push(EngineEvent::PlaybackChanged(self.playback.clone()));
                events.push(EngineEvent::PlaybackDirective(PlaybackDirective::Pause));
                persist_playback = true;
            }
            EngineCommand::Stop => {
                self.playback.playing = false;
                self.playback.position_ms = 0;
                events.push(EngineEvent::PlaybackChanged(self.playback.clone()));
                events.push(EngineEvent::PlaybackDirective(PlaybackDirective::Stop));
                persist_playback = true;
            }
            EngineCommand::SeekTo(position_ms) => {
                if self.playback.current.is_some() {
                    self.playback.position_ms = self.clamp_position(position_ms)?;
                    events.push(EngineEvent::PlaybackChanged(self.playback.clone()));
                    events.push(EngineEvent::PlaybackDirective(PlaybackDirective::Seek {
                        position_ms: self.playback.position_ms,
                    }));
                    persist_playback = true;
                }
            }
            EngineCommand::SkipNext => {
                let autoplay = self.playback.playing;
                let next = self.queue.advance(self.playback.repeat).is_some();
                self.sync_current();
                self.playback.position_ms = 0;
                if !next {
                    self.playback.playing = false;
                }
                events.push(EngineEvent::PlaybackChanged(self.playback.clone()));
                events.push(EngineEvent::PlaybackDirective(if next {
                    self.load_current_directive(autoplay)?
                        .expect("advanced queue has a current track")
                } else {
                    PlaybackDirective::Stop
                }));
                persist_playback = true;
            }
            EngineCommand::SkipPrevious => {
                let autoplay = self.playback.playing;
                if self.playback.position_ms > 3000 {
                    self.playback.position_ms = 0;
                    events.push(EngineEvent::PlaybackDirective(PlaybackDirective::Seek {
                        position_ms: 0,
                    }));
                } else if self.queue.retreat(self.playback.repeat).is_some() {
                    self.sync_current();
                    self.playback.position_ms = 0;
                    if let Some(directive) = self.load_current_directive(autoplay)? {
                        events.push(EngineEvent::PlaybackDirective(directive));
                    }
                }
                events.push(EngineEvent::PlaybackChanged(self.playback.clone()));
                persist_playback = true;
            }
            EngineCommand::SetRepeat(repeat) => {
                self.playback.repeat = repeat;
                events.push(EngineEvent::PlaybackChanged(self.playback.clone()));
                persist_playback = true;
            }
            EngineCommand::SetShuffle { enabled, seed } => {
                self.queue.set_shuffle(enabled, seed);
                self.playback.shuffle = enabled;
                events.push(EngineEvent::QueueChanged(self.queue.snapshot()));
                events.push(EngineEvent::PlaybackChanged(self.playback.clone()));
                persist_playback = true;
            }
            EngineCommand::CheckpointPosition(position_ms) => {
                if self.playback.current.is_some() {
                    self.playback.position_ms = self.clamp_position(position_ms)?;
                    persist_playback = true;
                }
            }
            EngineCommand::AddToLibrary(track) => {
                self.storage.add_to_library(&track, unix_time_ms())?;
                events.push(EngineEvent::LibraryChanged);
            }
            EngineCommand::RemoveFromLibrary(id) => {
                if self.storage.remove_from_library(&id)? {
                    events.push(EngineEvent::LibraryChanged);
                }
            }
            EngineCommand::SetSetting { key, value_json } => {
                self.storage
                    .set_setting(&key, &value_json, unix_time_ms())?;
                events.push(EngineEvent::SettingChanged(key));
            }
            EngineCommand::SaveDownload { track, job } => {
                self.storage.save_download(&track, &job)?;
                events.push(EngineEvent::DownloadChanged(job));
            }
            EngineCommand::RemoveDownload(id) => {
                if self.storage.remove_download(&id)? {
                    events.push(EngineEvent::DownloadRemoved(id));
                }
            }
            EngineCommand::RecordListen { track, event } => {
                if !event.is_valid() || event.media_id != track.id {
                    return Err(EngineError::InvalidListen);
                }
                if self.storage.record_listen(&track, &event)? {
                    events.push(EngineEvent::HistoryChanged);
                }
            }
        }
        if persist_playback {
            self.storage.save_playback(
                &self.queue,
                self.playback.position_ms,
                self.playback.repeat,
                unix_time_ms(),
            )?;
        }
        Ok(events)
    }

    fn sync_current(&mut self) {
        self.playback.current = self.queue.current().map(|entry| entry.media_id.clone());
    }

    fn current_track(&self) -> EngineResult<Option<Track>> {
        self.playback
            .current
            .as_ref()
            .map(|id| {
                self.storage
                    .track(id)?
                    .ok_or_else(|| EngineError::MissingTrack(id.clone()))
            })
            .transpose()
    }

    fn load_current_directive(&self, autoplay: bool) -> EngineResult<Option<PlaybackDirective>> {
        Ok(self.current_track()?.map(|track| PlaybackDirective::Load {
            track: Box::new(track),
            position_ms: self.playback.position_ms,
            autoplay,
        }))
    }

    fn clamp_position(&self, position_ms: u64) -> EngineResult<u64> {
        Ok(
            match self.current_track()?.and_then(|track| track.duration_ms) {
                Some(duration) => position_ms.min(duration),
                None => position_ms,
            },
        )
    }
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
    use crate::media::{ArtistCredit, Provider};

    fn track(id: &str) -> Track {
        Track {
            id: MediaId::new(Provider::Tidal, id).unwrap(),
            title: format!("Track {id}"),
            version: None,
            artists: vec![ArtistCredit {
                id: None,
                name: "Artist".into(),
            }],
            album_id: None,
            album_title: None,
            artwork: None,
            duration_ms: Some(120_000),
            isrc: None,
            explicit: None,
        }
    }

    #[test]
    fn play_tracks_emits_native_load_directive_and_persists_state() {
        let mut engine = Engine::open_in_memory().unwrap();
        let events = engine
            .dispatch(EngineCommand::PlayTracks(vec![track("a"), track("b")]))
            .unwrap();

        assert!(events.iter().any(|event| matches!(
            event,
            EngineEvent::PlaybackDirective(PlaybackDirective::Load { track, autoplay: true, .. })
                if track.id.provider_id == "a"
        )));
        assert_eq!(engine.playback.current.as_ref().unwrap().provider_id, "a");
        assert!(engine.playback.playing);
        assert_eq!(
            engine
                .queue_tracks()
                .unwrap()
                .into_iter()
                .map(|track| track.id.provider_id)
                .collect::<Vec<_>>(),
            vec!["a".to_owned(), "b".to_owned()]
        );
    }

    #[test]
    fn enqueue_tracks_appends_a_continuation_in_one_command_and_keeps_duplicates() {
        let mut engine = Engine::open_in_memory().unwrap();
        engine
            .dispatch(EngineCommand::PlayTracks(vec![track("a")]))
            .unwrap();
        let events = engine
            .dispatch(EngineCommand::EnqueueTracks(vec![
                track("b"),
                track("b"),
                track("c"),
            ]))
            .unwrap();
        assert_eq!(
            events
                .iter()
                .filter(|event| matches!(event, EngineEvent::QueueChanged(_)))
                .count(),
            1
        );
        assert_eq!(
            engine
                .queue_tracks()
                .unwrap()
                .into_iter()
                .map(|track| track.id.provider_id)
                .collect::<Vec<_>>(),
            vec![
                "a".to_owned(),
                "b".to_owned(),
                "b".to_owned(),
                "c".to_owned()
            ]
        );
    }

    #[test]
    fn provider_order_bypasses_local_shuffle_without_disabling_it() {
        let mut engine = Engine::open_in_memory().unwrap();
        engine
            .dispatch(EngineCommand::SetShuffle {
                enabled: true,
                seed: 41,
            })
            .unwrap();
        engine
            .dispatch(EngineCommand::PlayTracksInOrder(vec![
                track("a"),
                track("b"),
                track("c"),
            ]))
            .unwrap();
        let snapshot = engine.queue.snapshot();
        assert!(snapshot.shuffle);
        assert_eq!(
            snapshot.play_order,
            snapshot
                .entries
                .iter()
                .map(|entry| entry.id)
                .collect::<Vec<_>>()
        );
        assert_eq!(engine.playback.current.as_ref().unwrap().provider_id, "a");
    }

    #[test]
    fn next_and_previous_follow_queue_rules() {
        let mut engine = Engine::open_in_memory().unwrap();
        engine
            .dispatch(EngineCommand::PlayTracks(vec![track("a"), track("b")]))
            .unwrap();
        engine.dispatch(EngineCommand::SkipNext).unwrap();
        assert_eq!(engine.playback.current.as_ref().unwrap().provider_id, "b");

        engine
            .dispatch(EngineCommand::CheckpointPosition(4000))
            .unwrap();
        let events = engine.dispatch(EngineCommand::SkipPrevious).unwrap();
        assert_eq!(engine.playback.current.as_ref().unwrap().provider_id, "b");
        assert!(
            events.contains(&EngineEvent::PlaybackDirective(PlaybackDirective::Seek {
                position_ms: 0,
            }))
        );

        engine.dispatch(EngineCommand::SkipPrevious).unwrap();
        assert_eq!(engine.playback.current.as_ref().unwrap().provider_id, "a");
    }

    #[test]
    fn library_and_settings_share_the_same_boundary() {
        let mut engine = Engine::open_in_memory().unwrap();
        engine
            .dispatch(EngineCommand::AddToLibrary(track("liked")))
            .unwrap();
        engine
            .dispatch(EngineCommand::SetSetting {
                key: "discord.enabled".into(),
                value_json: "true".into(),
            })
            .unwrap();

        assert_eq!(engine.library().unwrap()[0].id.provider_id, "liked");
        assert_eq!(
            engine.setting("discord.enabled").unwrap().as_deref(),
            Some("true")
        );
    }

    #[test]
    fn download_jobs_share_the_engine_boundary() {
        let mut engine = Engine::open_in_memory().unwrap();
        let track = track("offline");
        let job = DownloadJob::queued(track.id.clone(), 42);
        let events = engine
            .dispatch(EngineCommand::SaveDownload {
                track,
                job: job.clone(),
            })
            .unwrap();
        assert_eq!(events, vec![EngineEvent::DownloadChanged(job.clone())]);
        assert_eq!(engine.downloads().unwrap(), vec![job.clone()]);
        assert_eq!(
            engine.download_tracks(&[job.clone()]).unwrap()[0].id,
            job.media_id.clone()
        );
        assert_eq!(
            engine
                .dispatch(EngineCommand::RemoveDownload(job.media_id.clone()))
                .unwrap(),
            vec![EngineEvent::DownloadRemoved(job.media_id)]
        );
    }

    #[test]
    fn qualified_listens_share_an_idempotent_statistics_boundary() {
        let mut engine = Engine::open_in_memory().unwrap();
        let track = track("history");
        let event = ListenEvent {
            event_id: "device-a:event-1".into(),
            device_id: "device-a".into(),
            media_id: track.id.clone(),
            started_at_ms: 1,
            ended_at_ms: 60_001,
            listened_ms: 60_000,
            track_duration_ms: track.duration_ms,
        };
        assert_eq!(
            engine
                .dispatch(EngineCommand::RecordListen {
                    track: track.clone(),
                    event: event.clone(),
                })
                .unwrap(),
            vec![EngineEvent::HistoryChanged]
        );
        assert!(
            engine
                .dispatch(EngineCommand::RecordListen { track, event })
                .unwrap()
                .is_empty()
        );
        let stats = engine.listen_stats().unwrap();
        assert_eq!(stats.play_count, 1);
        assert_eq!(stats.total_listened_ms, 60_000);
    }

    #[test]
    fn playback_survives_closing_and_reopening_the_database() {
        let unique = format!(
            "colorful-engine-{}-{}.sqlite",
            std::process::id(),
            unix_time_ms()
        );
        let path = std::env::temp_dir().join(unique);
        {
            let mut engine = Engine::open(&path).unwrap();
            engine
                .dispatch(EngineCommand::PlayTracks(vec![track("a"), track("b")]))
                .unwrap();
            engine.dispatch(EngineCommand::SkipNext).unwrap();
            engine
                .dispatch(EngineCommand::CheckpointPosition(12_345))
                .unwrap();
        }
        {
            let engine = Engine::open(&path).unwrap();
            assert_eq!(engine.playback.current.as_ref().unwrap().provider_id, "b");
            assert_eq!(engine.playback.position_ms, 12_345);
            assert!(!engine.playback.playing);
        }
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{}", path.display(), suffix));
        }
    }
}
