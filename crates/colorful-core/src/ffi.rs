//! Stable C ABI used by native platform shells.
//!
//! The ABI owns engine handles in a synchronized registry and exchanges
//! versioned UTF-8 JSON. Callers never dereference Rust pointers; the only
//! returned pointer is an owned string released with [`colorful_string_free`].

use crate::download::DownloadJob;
use crate::engine::{Engine, EngineCommand, EngineEvent, PlaybackDirective};
use crate::media::{MediaId, Track};
use crate::playback::RepeatMode;
use crate::queue::QueueEntryId;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Mutex, OnceLock};

pub const ABI_VERSION: u32 = 1;

#[derive(Default)]
struct Registry {
    next_handle: u64,
    engines: HashMap<u64, Engine>,
}

impl Registry {
    fn insert(&mut self, engine: Engine) -> u64 {
        self.next_handle = self
            .next_handle
            .checked_add(1)
            .expect("engine handle space exhausted");
        self.engines.insert(self.next_handle, engine);
        self.next_handle
    }
}

fn registry() -> &'static Mutex<Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(Registry::default()))
}

#[derive(Debug, Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum WireCommand {
    PlayTracks {
        tracks: Vec<Track>,
    },
    Enqueue {
        track: Track,
    },
    PlayNext {
        track: Track,
    },
    Select {
        entry_id: QueueEntryId,
    },
    Remove {
        entry_id: QueueEntryId,
    },
    Move {
        entry_id: QueueEntryId,
        target_index: usize,
    },
    Play,
    Pause,
    Stop,
    SeekTo {
        position_ms: u64,
    },
    SkipNext,
    SkipPrevious,
    SetRepeat {
        repeat: RepeatMode,
    },
    SetShuffle {
        enabled: bool,
        seed: u64,
    },
    CheckpointPosition {
        position_ms: u64,
    },
    AddToLibrary {
        track: Track,
    },
    RemoveFromLibrary {
        id: MediaId,
    },
    SetSetting {
        key: String,
        value_json: String,
    },
    SaveDownload {
        track: Track,
        job: DownloadJob,
    },
    RemoveDownload {
        id: MediaId,
    },
}

impl From<WireCommand> for EngineCommand {
    fn from(value: WireCommand) -> Self {
        match value {
            WireCommand::PlayTracks { tracks } => Self::PlayTracks(tracks),
            WireCommand::Enqueue { track } => Self::Enqueue(track),
            WireCommand::PlayNext { track } => Self::PlayNext(track),
            WireCommand::Select { entry_id } => Self::Select(entry_id),
            WireCommand::Remove { entry_id } => Self::Remove(entry_id),
            WireCommand::Move {
                entry_id,
                target_index,
            } => Self::Move {
                entry: entry_id,
                target_index,
            },
            WireCommand::Play => Self::Play,
            WireCommand::Pause => Self::Pause,
            WireCommand::Stop => Self::Stop,
            WireCommand::SeekTo { position_ms } => Self::SeekTo(position_ms),
            WireCommand::SkipNext => Self::SkipNext,
            WireCommand::SkipPrevious => Self::SkipPrevious,
            WireCommand::SetRepeat { repeat } => Self::SetRepeat(repeat),
            WireCommand::SetShuffle { enabled, seed } => Self::SetShuffle { enabled, seed },
            WireCommand::CheckpointPosition { position_ms } => {
                Self::CheckpointPosition(position_ms)
            }
            WireCommand::AddToLibrary { track } => Self::AddToLibrary(track),
            WireCommand::RemoveFromLibrary { id } => Self::RemoveFromLibrary(id),
            WireCommand::SetSetting { key, value_json } => Self::SetSetting { key, value_json },
            WireCommand::SaveDownload { track, job } => Self::SaveDownload { track, job },
            WireCommand::RemoveDownload { id } => Self::RemoveDownload(id),
        }
    }
}

#[derive(Serialize)]
#[serde(tag = "directive", rename_all = "snake_case")]
enum WireDirective {
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

impl From<PlaybackDirective> for WireDirective {
    fn from(value: PlaybackDirective) -> Self {
        match value {
            PlaybackDirective::Load {
                track,
                position_ms,
                autoplay,
            } => Self::Load {
                track,
                position_ms,
                autoplay,
            },
            PlaybackDirective::Pause => Self::Pause,
            PlaybackDirective::Stop => Self::Stop,
            PlaybackDirective::Seek { position_ms } => Self::Seek { position_ms },
        }
    }
}

#[derive(Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
enum WireEvent {
    QueueChanged {
        queue: crate::queue::QueueSnapshot,
    },
    PlaybackChanged {
        playback: crate::playback::PlaybackState,
    },
    PlaybackDirective {
        value: WireDirective,
    },
    LibraryChanged,
    SettingChanged {
        key: String,
    },
    DownloadChanged {
        job: DownloadJob,
    },
    DownloadRemoved {
        id: MediaId,
    },
}

impl From<EngineEvent> for WireEvent {
    fn from(value: EngineEvent) -> Self {
        match value {
            EngineEvent::QueueChanged(queue) => Self::QueueChanged { queue },
            EngineEvent::PlaybackChanged(playback) => Self::PlaybackChanged { playback },
            EngineEvent::PlaybackDirective(value) => Self::PlaybackDirective {
                value: value.into(),
            },
            EngineEvent::LibraryChanged => Self::LibraryChanged,
            EngineEvent::SettingChanged(key) => Self::SettingChanged { key },
            EngineEvent::DownloadChanged(job) => Self::DownloadChanged { job },
            EngineEvent::DownloadRemoved(id) => Self::DownloadRemoved { id },
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot<'a> {
    abi_version: u32,
    queue: crate::queue::QueueSnapshot,
    playback: &'a crate::playback::PlaybackState,
    library: Vec<Track>,
    downloads: Vec<DownloadJob>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Response<T: Serialize> {
    abi_version: u32,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    value: Option<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

fn success<T: Serialize>(value: T) -> *mut c_char {
    json_string(&Response {
        abi_version: ABI_VERSION,
        ok: true,
        value: Some(value),
        error: None,
    })
}

fn failure(error: impl Into<String>) -> *mut c_char {
    json_string(&Response::<()> {
        abi_version: ABI_VERSION,
        ok: false,
        value: None,
        error: Some(error.into()),
    })
}

fn json_string(value: &impl Serialize) -> *mut c_char {
    let json = serde_json::to_string(value).unwrap_or_else(|error| {
        format!(
            r#"{{"abiVersion":{ABI_VERSION},"ok":false,"error":"serialization failed: {error}"}}"#
        )
    });
    CString::new(json)
        .expect("JSON never contains NUL bytes")
        .into_raw()
}

fn guarded(function: impl FnOnce() -> Result<*mut c_char, String>) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(function)) {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => failure(error),
        Err(_) => failure("colorful core panicked while handling the request"),
    }
}

unsafe fn required_string(pointer: *const c_char, name: &str) -> Result<String, String> {
    if pointer.is_null() {
        return Err(format!("{name} is null"));
    }
    let value = unsafe { CStr::from_ptr(pointer) };
    value
        .to_str()
        .map(str::to_owned)
        .map_err(|_| format!("{name} is not valid UTF-8"))
}

#[unsafe(no_mangle)]
pub extern "C" fn colorful_core_abi_version() -> u32 {
    ABI_VERSION
}

/// Opens an engine and returns a JSON response containing its numeric handle.
///
/// # Safety
///
/// `database_path` must point to a valid NUL-terminated string for the duration
/// of this call. The returned string must be released with
/// [`colorful_string_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn colorful_engine_open(database_path: *const c_char) -> *mut c_char {
    guarded(|| {
        let path = unsafe { required_string(database_path, "database_path") }?;
        let engine = Engine::open(path).map_err(|error| error.to_string())?;
        let handle = registry()
            .lock()
            .map_err(|_| "engine registry lock is poisoned".to_owned())?
            .insert(engine);
        Ok(success(serde_json::json!({ "handle": handle })))
    })
}

/// Dispatches one JSON command to an open engine.
///
/// # Safety
///
/// `command_json` must point to a valid NUL-terminated string for the duration
/// of this call. The returned string must be released with
/// [`colorful_string_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn colorful_engine_dispatch(
    handle: u64,
    command_json: *const c_char,
) -> *mut c_char {
    guarded(|| {
        let json = unsafe { required_string(command_json, "command_json") }?;
        let command: WireCommand =
            serde_json::from_str(&json).map_err(|error| format!("invalid command: {error}"))?;
        let mut registry = registry()
            .lock()
            .map_err(|_| "engine registry lock is poisoned".to_owned())?;
        let engine = registry
            .engines
            .get_mut(&handle)
            .ok_or_else(|| format!("unknown engine handle {handle}"))?;
        let events = engine
            .dispatch(command.into())
            .map_err(|error| error.to_string())?
            .into_iter()
            .map(WireEvent::from)
            .collect::<Vec<_>>();
        Ok(success(serde_json::json!({ "events": events })))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn colorful_engine_snapshot(handle: u64) -> *mut c_char {
    guarded(|| {
        let registry = registry()
            .lock()
            .map_err(|_| "engine registry lock is poisoned".to_owned())?;
        let engine = registry
            .engines
            .get(&handle)
            .ok_or_else(|| format!("unknown engine handle {handle}"))?;
        let snapshot = Snapshot {
            abi_version: ABI_VERSION,
            queue: engine.queue().snapshot(),
            playback: engine.playback(),
            library: engine.library().map_err(|error| error.to_string())?,
            downloads: engine.downloads().map_err(|error| error.to_string())?,
        };
        Ok(success(snapshot))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn colorful_engine_close(handle: u64) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        registry()
            .lock()
            .is_ok_and(|mut registry| registry.engines.remove(&handle).is_some())
    }))
    .unwrap_or(false)
}

/// Maps a TIDAL JSON:API catalog document into colorful's portable track
/// representation without requiring an engine instance.
///
/// # Safety
///
/// `document_json` must point to a valid NUL-terminated UTF-8 string for the
/// duration of this call. The returned string must be released with
/// [`colorful_string_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn colorful_tidal_map_tracks(document_json: *const c_char) -> *mut c_char {
    guarded(|| {
        let json = unsafe { required_string(document_json, "document_json") }?;
        let document = serde_json::from_str(&json)
            .map_err(|error| format!("invalid TIDAL catalog document: {error}"))?;
        let tracks =
            crate::providers::tidal::map_tracks(&document).map_err(|error| error.to_string())?;
        Ok(success(tracks))
    })
}

/// # Safety
///
/// `value` must be a pointer returned by a colorful C ABI function and must be
/// released exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn colorful_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn response(pointer: *mut c_char) -> serde_json::Value {
        let json = unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .unwrap()
            .to_owned();
        unsafe { colorful_string_free(pointer) };
        serde_json::from_str(&json).unwrap()
    }

    #[test]
    fn c_abi_opens_dispatches_snapshots_and_closes_without_rust_pointers() {
        let path = CString::new(":memory:").unwrap();
        let opened = response(unsafe { colorful_engine_open(path.as_ptr()) });
        let handle = opened["value"]["handle"].as_u64().unwrap();
        let command = CString::new(
            r#"{"command":"set_setting","key":"discord.enabled","value_json":"true"}"#,
        )
        .unwrap();
        let dispatched = response(unsafe { colorful_engine_dispatch(handle, command.as_ptr()) });
        assert!(dispatched["ok"].as_bool().unwrap());
        assert_eq!(dispatched["value"]["events"][0]["event"], "setting_changed");

        let snapshot = response(colorful_engine_snapshot(handle));
        assert_eq!(snapshot["value"]["abiVersion"], ABI_VERSION);
        assert!(colorful_engine_close(handle));
        assert!(!colorful_engine_close(handle));
    }

    #[test]
    fn c_abi_returns_errors_for_invalid_utf8_json_and_handles() {
        let command = CString::new("not-json").unwrap();
        let response = response(unsafe { colorful_engine_dispatch(999_999, command.as_ptr()) });
        assert!(!response["ok"].as_bool().unwrap());
        assert!(
            response["error"]
                .as_str()
                .unwrap()
                .contains("invalid command")
        );
    }

    #[test]
    fn c_abi_maps_tidal_catalog_documents_without_an_engine() {
        let fixture =
            CString::new(include_str!("../../../fixtures/tidal/search-tracks.json")).unwrap();
        let mapped = response(unsafe { colorful_tidal_map_tracks(fixture.as_ptr()) });
        assert!(mapped["ok"].as_bool().unwrap());
        assert_eq!(mapped["value"][0]["title"], "Brutal (Instrumental)");
    }
}
