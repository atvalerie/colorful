//! Portable state and contracts for colorful.
//!
//! Platform audio, secure storage, and UI deliberately live outside this crate.

pub mod download;
pub mod engine;
pub mod ffi;
pub mod history;
pub mod identity;
pub mod media;
pub mod pairing;
pub mod party;
mod party_ffi;
pub mod party_session;
pub mod playback;
pub mod playlist;
pub mod providers;
pub mod queue;
pub mod storage;
pub mod travel_snapshot;

pub use download::{DownloadJob, DownloadState, DownloadTransitionError};
pub use engine::{
    Engine, EngineCommand, EngineError, EngineEvent, EngineResult, PlaybackDirective,
};
pub use history::{ListenEvent, ListenStats, ProviderListenStats, TopAlbum, TopArtist, TopTrack};
pub use identity::{
    DeviceCertificate, IdentityError, IdentityProfile, LocalIdentity, ProtectedIdentityExport,
};
pub use media::{MediaId, Provider, Track};
pub use pairing::{
    ConfirmedPairing, PairingConfirmation, PairingEnvelope, PairingError, PairingInvite,
    PairingInviter, PairingJoiner, PairingResponse, PairingRole, PairingSession,
    PairingVerification,
};
pub use party::{ConnectivityPolicy, NetworkObservation, Transport};
pub use party_session::{
    ApplyPartyEvent, GuestCommand, JoinRequest, PartyChannel, PartyError, PartyEvent,
    PartyEventBody, PartyFrame, PartyHost, PartyInvite, PartyParticipant, PartyReplica, PartyRole,
    PartyTrack, PartyUser,
};
pub use playback::{
    AudioProcessingSettings, EQUALIZER_FREQUENCIES_HZ, PlaybackCommand, PlaybackState, RepeatMode,
};
pub use providers::account::{
    DeviceAuthorizationChallenge, ProviderAccountState, ProviderCredentialHandle,
};
pub use queue::{PlaybackQueue, QueueEntry, QueueEntryId, QueueSnapshot, QueueSnapshotError};
pub use storage::{Storage, StorageError, StorageResult, StoredPlayback};
pub use travel_snapshot::{
    PORTABLE_SETTING_KEYS, TRAVEL_SNAPSHOT_FORMAT, TRAVEL_SNAPSHOT_VERSION, TravelArtist,
    TravelArtwork, TravelImportSummary, TravelLibraryEntry, TravelMediaId, TravelPlayback,
    TravelPlaylist, TravelQueue, TravelQueueEntry, TravelSetting, TravelSnapshot,
    TravelSnapshotError, TravelTrack,
};
