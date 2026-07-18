//! Portable state and contracts for Colorful.
//!
//! Platform audio, secure storage, and UI deliberately live outside this crate.

pub mod media;
pub mod party;
pub mod playback;
pub mod queue;

pub use media::{MediaId, Provider, Track};
pub use party::{ConnectivityPolicy, NetworkObservation, Transport};
pub use playback::{PlaybackCommand, PlaybackState, RepeatMode};
pub use queue::{PlaybackQueue, QueueEntry, QueueEntryId};
