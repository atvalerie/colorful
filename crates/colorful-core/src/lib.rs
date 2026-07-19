//! Portable state and contracts for colorful.
//!
//! Platform audio, secure storage, and UI deliberately live outside this crate.

pub mod download;
pub mod engine;
pub mod ffi;
pub mod history;
pub mod media;
pub mod party;
pub mod playback;
pub mod providers;
pub mod queue;
pub mod storage;

pub use download::{DownloadJob, DownloadState, DownloadTransitionError};
pub use engine::{
    Engine, EngineCommand, EngineError, EngineEvent, EngineResult, PlaybackDirective,
};
pub use history::{ListenEvent, ListenStats, TopAlbum, TopArtist, TopTrack};
pub use media::{MediaId, Provider, Track};
pub use party::{ConnectivityPolicy, NetworkObservation, Transport};
pub use playback::{
    AudioProcessingSettings, EQUALIZER_FREQUENCIES_HZ, PlaybackCommand, PlaybackState, RepeatMode,
};
pub use queue::{PlaybackQueue, QueueEntry, QueueEntryId, QueueSnapshot, QueueSnapshotError};
pub use storage::{Storage, StorageError, StorageResult, StoredPlayback};
