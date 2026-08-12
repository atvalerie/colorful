//! Stateful JSON C ABI for native party clients.

use crate::party_session::{
    GuestCommand, JoinRequest, PartyChannel, PartyEvent, PartyEventBody, PartyFrame, PartyHost,
    PartyInvite, PartyReplica, PartyTrack, PartyUser,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Mutex, OnceLock};

#[derive(Default)]
struct PartyRegistry {
    next_handle: u64,
    sessions: HashMap<u64, PartyController>,
}

impl PartyRegistry {
    fn insert(&mut self) -> u64 {
        self.next_handle = self
            .next_handle
            .checked_add(1)
            .expect("party handle space exhausted");
        self.sessions
            .insert(self.next_handle, PartyController::Empty);
        self.next_handle
    }
}

fn registry() -> &'static Mutex<PartyRegistry> {
    static REGISTRY: OnceLock<Mutex<PartyRegistry>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(PartyRegistry::default()))
}

enum PartyController {
    Empty,
    Host {
        host: PartyHost,
        channel: PartyChannel,
        relay_guest_capability: String,
    },
    Guest {
        user: PartyUser,
        channel: PartyChannel,
        replica: PartyReplica,
    },
}

#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum PartyCommand {
    Create {
        display_name: String,
        expires_at_ms: i64,
        relay_session_id: String,
        relay_host_capability: String,
        relay_guest_capability: String,
    },
    Join {
        display_name: String,
        relay_session_id: String,
        fragment: String,
        now_ms: i64,
    },
    Receive {
        frame: PartyFrame,
        #[serde(default)]
        received_at_ms: Option<i64>,
    },
    Playback {
        entry_id: Option<String>,
        playing: bool,
        position_ms: u64,
        host_time_ms: i64,
        generation: u64,
    },
    HostTrack {
        track: PartyTrack,
    },
    HostQueue {
        tracks: Vec<PartyTrack>,
    },
    HostSnapshot,
    Suggest {
        track: PartyTrack,
    },
    Enqueue {
        track: PartyTrack,
    },
    Resync,
    Leave,
    ClockPing {
        nonce: u64,
        client_send_ms: i64,
    },
    SetJoinEnabled {
        enabled: bool,
    },
    Kick {
        participant_id: String,
    },
    SetRole {
        participant_id: String,
        role: crate::party_session::PartyRole,
    },
}

#[derive(Deserialize, Serialize)]
#[serde(tag = "message", rename_all = "snake_case")]
enum PartyMessage {
    Join(JoinRequest),
    Command(GuestCommand),
    Event(PartyEvent),
}

impl PartyController {
    fn dispatch(&mut self, command: PartyCommand) -> Result<Value, String> {
        match command {
            PartyCommand::Create {
                display_name,
                expires_at_ms,
                relay_session_id,
                relay_host_capability,
                relay_guest_capability,
            } => {
                if !matches!(self, Self::Empty) {
                    return Err("party handle is already active".into());
                }
                let (host, _) = PartyHost::create(display_name, expires_at_ms).map_err(error)?;
                let fragment = host
                    .invite_fragment(&relay_guest_capability)
                    .map_err(error)?;
                let party_id = host.party_id().to_owned();
                let channel = host.channel();
                *self = Self::Host {
                    host,
                    channel,
                    relay_guest_capability,
                };
                Ok(json!({
                    "role": "host",
                    "partyId": party_id,
                    "relaySessionId": relay_session_id,
                    "relayCapability": relay_host_capability,
                    "fragment": fragment,
                    "outbound": [],
                    "state": state(self),
                }))
            }
            PartyCommand::Join {
                display_name,
                relay_session_id,
                fragment,
                now_ms,
            } => {
                if !matches!(self, Self::Empty) {
                    return Err("party handle is already active".into());
                }
                let invite = PartyInvite::from_fragment(&fragment, now_ms).map_err(error)?;
                let user = PartyUser::temporary(display_name).map_err(error)?;
                let request = user.join_request(&invite).map_err(error)?;
                let party_id = invite.party_id().to_owned();
                let expires_at_ms = invite.expires_at_ms();
                let relay_capability = invite.relay_guest_capability().to_owned();
                let channel = invite.channel();
                let frame = channel.seal(&PartyMessage::Join(request)).map_err(error)?;
                let replica = PartyReplica::from_invite(&invite);
                *self = Self::Guest {
                    user,
                    channel,
                    replica,
                };
                Ok(json!({
                    "role": "guest",
                    "partyId": party_id,
                    "relaySessionId": relay_session_id,
                    "relayCapability": relay_capability,
                    "expiresAtMs": expires_at_ms,
                    "outbound": [frame],
                    "state": state(self),
                }))
            }
            PartyCommand::Receive {
                frame,
                received_at_ms,
            } => match self {
                Self::Host { host, channel, .. } => {
                    let message: PartyMessage = channel.open(&frame).map_err(error)?;
                    let events = match message {
                        PartyMessage::Join(request) => {
                            host.admit(&request).map_err(error)?;
                            vec![host.snapshot().map_err(error)?]
                        }
                        PartyMessage::Command(command) => {
                            let received = received_at_ms.unwrap_or_default();
                            vec![
                                host.accept_command_at(&command, received, received)
                                    .map_err(error)?,
                            ]
                        }
                        PartyMessage::Event(_) => {
                            return Err("guests cannot send authoritative events".into());
                        }
                    };
                    let outbound = seal_events(channel, events)?;
                    Ok(json!({ "outbound": outbound, "state": state(self) }))
                }
                Self::Guest {
                    user,
                    channel,
                    replica,
                } => {
                    let message: PartyMessage = channel.open(&frame).map_err(error)?;
                    let PartyMessage::Event(event) = message else {
                        return Err("host sent a non-event party message".into());
                    };
                    replica.apply(&event).map_err(error)?;
                    if let PartyEventBody::KeyRotated { epoch, envelopes } = &event.body {
                        let Some(key) = user
                            .open_rotated_key(replica.party_id(), *epoch, envelopes)
                            .map_err(error)?
                        else {
                            return Ok(
                                json!({ "outbound": [], "event": event, "revoked": true, "state": state(self) }),
                            );
                        };
                        channel.set_key(key, *epoch);
                    }
                    Ok(json!({ "outbound": [], "event": event, "state": state(self) }))
                }
                Self::Empty => Err("party handle is not active".into()),
            },
            PartyCommand::Playback {
                entry_id,
                playing,
                position_ms,
                host_time_ms,
                generation,
            } => {
                let Self::Host { host, channel, .. } = self else {
                    return Err("only the host controls playback".into());
                };
                let event = host
                    .set_playback(entry_id, playing, position_ms, host_time_ms, generation)
                    .map_err(error)?;
                let outbound = seal_events(channel, vec![event])?;
                Ok(json!({ "outbound": outbound, "state": state(self) }))
            }
            PartyCommand::HostTrack { track } => {
                let Self::Host { host, channel, .. } = self else {
                    return Err("only the host publishes tracks".into());
                };
                let event = host.queue_track(track).map_err(error)?;
                let entry_id = match &event.body {
                    PartyEventBody::TrackQueued { entry_id, .. } => entry_id.clone(),
                    _ => unreachable!(),
                };
                let outbound = seal_events(channel, vec![event])?;
                Ok(json!({ "entryId": entry_id, "outbound": outbound, "state": state(self) }))
            }
            PartyCommand::HostQueue { tracks } => {
                let Self::Host { host, channel, .. } = self else {
                    return Err("only the host publishes the queue".into());
                };
                let event = host.replace_queue(tracks).map_err(error)?;
                let entries = match &event.body {
                    PartyEventBody::QueueReplaced { entries } => entries.clone(),
                    _ => unreachable!(),
                };
                let outbound = seal_events(channel, vec![event])?;
                Ok(json!({ "entries": entries, "outbound": outbound, "state": state(self) }))
            }
            PartyCommand::HostSnapshot => {
                let Self::Host { host, channel, .. } = self else {
                    return Err("only the host publishes authoritative snapshots".into());
                };
                let event = host.snapshot().map_err(error)?;
                let outbound = seal_events(channel, vec![event])?;
                Ok(json!({ "outbound": outbound, "state": state(self) }))
            }
            PartyCommand::Suggest { track } => {
                let Self::Guest {
                    user,
                    channel,
                    replica,
                } = self
                else {
                    return Err("only a guest sends suggestions".into());
                };
                let command = user
                    .suggest_track(replica.party_id(), track)
                    .map_err(error)?;
                let frame = channel
                    .seal(&PartyMessage::Command(command))
                    .map_err(error)?;
                Ok(json!({ "outbound": [frame], "state": state(self) }))
            }
            PartyCommand::Enqueue { track } => {
                let Self::Guest {
                    user,
                    channel,
                    replica,
                } = self
                else {
                    return Err("only a participant sends co-host queue commands".into());
                };
                let command = user
                    .enqueue_track(replica.party_id(), track)
                    .map_err(error)?;
                let frame = channel
                    .seal(&PartyMessage::Command(command))
                    .map_err(error)?;
                Ok(json!({ "outbound": [frame], "state": state(self) }))
            }
            PartyCommand::Resync => {
                let Self::Guest {
                    user,
                    channel,
                    replica,
                } = self
                else {
                    return Err("only a participant requests party resynchronization".into());
                };
                let command = user.sync_request(replica.party_id()).map_err(error)?;
                let frame = channel
                    .seal(&PartyMessage::Command(command))
                    .map_err(error)?;
                Ok(json!({ "outbound": [frame], "state": state(self) }))
            }
            PartyCommand::Leave => {
                let Self::Guest {
                    user,
                    channel,
                    replica,
                } = self
                else {
                    return Err("only a participant sends a leave command".into());
                };
                let command = user.leave(replica.party_id()).map_err(error)?;
                let frame = channel
                    .seal(&PartyMessage::Command(command))
                    .map_err(error)?;
                Ok(json!({ "outbound": [frame], "state": state(self) }))
            }
            PartyCommand::ClockPing {
                nonce,
                client_send_ms,
            } => {
                let Self::Guest {
                    user,
                    channel,
                    replica,
                } = self
                else {
                    return Err("only a guest samples the host clock".into());
                };
                let command = user
                    .clock_ping(replica.party_id(), nonce, client_send_ms)
                    .map_err(error)?;
                let frame = channel
                    .seal(&PartyMessage::Command(command))
                    .map_err(error)?;
                Ok(json!({ "outbound": [frame], "state": state(self) }))
            }
            PartyCommand::SetJoinEnabled { enabled } => {
                let Self::Host { host, channel, .. } = self else {
                    return Err("only the host controls joining".into());
                };
                let event = host.set_join_enabled(enabled).map_err(error)?;
                let outbound = seal_events(channel, vec![event])?;
                Ok(json!({ "outbound": outbound, "state": state(self) }))
            }
            PartyCommand::Kick { participant_id } => {
                let Self::Host {
                    host,
                    channel,
                    relay_guest_capability,
                } = self
                else {
                    return Err("only the host can kick".into());
                };
                let removed = host.kick(&participant_id).map_err(error)?;
                let (rotation, epoch, key) = host.rotate_key().map_err(error)?;
                let outbound = seal_events(channel, vec![removed, rotation])?;
                channel.set_key(key, epoch);
                let fragment = host
                    .invite_fragment(relay_guest_capability)
                    .map_err(error)?;
                Ok(
                    json!({ "outbound": outbound, "fragment": fragment, "keyEpoch": epoch, "state": state(self) }),
                )
            }
            PartyCommand::SetRole {
                participant_id,
                role,
            } => {
                let Self::Host { host, channel, .. } = self else {
                    return Err("only the host assigns party roles".into());
                };
                let event = host.set_role(&participant_id, role).map_err(error)?;
                let outbound = seal_events(channel, vec![event])?;
                Ok(json!({ "outbound": outbound, "state": state(self) }))
            }
        }
    }
}

fn seal_events(channel: &PartyChannel, events: Vec<PartyEvent>) -> Result<Vec<PartyFrame>, String> {
    events
        .into_iter()
        .map(|event| channel.seal(&PartyMessage::Event(event)).map_err(error))
        .collect()
}

fn state(controller: &PartyController) -> Value {
    match controller {
        PartyController::Empty => json!({ "active": false }),
        PartyController::Host { host, .. } => {
            let participants = host.participants().cloned().collect::<Vec<_>>();
            let mut queue = Vec::new();
            for event in host.events() {
                match &event.body {
                    PartyEventBody::StateSnapshot { entries, .. } => {
                        queue = entries.iter().map(|entry| json!(entry)).collect();
                    }
                    PartyEventBody::QueueReplaced { entries } => {
                        queue = entries.iter().map(|entry| json!(entry)).collect();
                    }
                    PartyEventBody::TrackQueued {
                        entry_id,
                        track,
                        suggested_by,
                    } => queue.push(
                        json!({ "entryId": entry_id, "track": track, "suggestedBy": suggested_by }),
                    ),
                    _ => {}
                }
            }
            json!({ "active": true, "role": "host", "partyId": host.party_id(), "participants": participants, "queue": queue, "joinEnabled": host.join_enabled() })
        }
        PartyController::Guest { user, replica, .. } => json!({
            "active": true,
            "role": replica.participants.get(user.participant_id()).map(|participant| participant.role).unwrap_or(crate::party_session::PartyRole::Guest),
            "partyId": replica.party_id(),
            "participantId": user.participant_id(),
            "participants": replica.participants.values().collect::<Vec<_>>(),
            "queue": replica.queue.iter().map(|(entry_id, track, suggested_by)| json!({ "entryId": entry_id, "track": track, "suggestedBy": suggested_by })).collect::<Vec<_>>(),
            "playback": replica.playback,
            "joinEnabled": replica.join_enabled,
            "ended": replica.ended,
        }),
    }
}

fn error(value: impl std::fmt::Display) -> String {
    value.to_string()
}

#[unsafe(no_mangle)]
pub extern "C" fn colorful_party_open() -> *mut c_char {
    guarded(|| {
        let handle = registry()
            .lock()
            .map_err(|_| "party registry lock is poisoned".to_owned())?
            .insert();
        Ok(success(json!({ "handle": handle })))
    })
}

/// # Safety
/// `command_json` must be valid NUL-terminated UTF-8 for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn colorful_party_dispatch(
    handle: u64,
    command_json: *const c_char,
) -> *mut c_char {
    guarded(|| {
        if command_json.is_null() {
            return Err("command_json is null".into());
        }
        let json = unsafe { CStr::from_ptr(command_json) }
            .to_str()
            .map_err(|_| "command_json is not UTF-8".to_owned())?;
        let command = serde_json::from_str(json)
            .map_err(|error| format!("invalid party command: {error}"))?;
        let mut registry = registry()
            .lock()
            .map_err(|_| "party registry lock is poisoned".to_owned())?;
        let controller = registry
            .sessions
            .get_mut(&handle)
            .ok_or_else(|| format!("unknown party handle {handle}"))?;
        Ok(success(controller.dispatch(command)?))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn colorful_party_close(handle: u64) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        registry()
            .lock()
            .is_ok_and(|mut registry| registry.sessions.remove(&handle).is_some())
    }))
    .unwrap_or(false)
}

fn success(value: Value) -> String {
    json!({ "ok": true, "value": value }).to_string()
}
fn failure(error: String) -> String {
    json!({ "ok": false, "error": error }).to_string()
}
fn guarded(operation: impl FnOnce() -> Result<String, String>) -> *mut c_char {
    let response = catch_unwind(AssertUnwindSafe(operation)).map_or_else(
        |_| failure("colorful core panicked".into()),
        |result| result.unwrap_or_else(failure),
    );
    CString::new(response)
        .expect("JSON contains no NUL")
        .into_raw()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(handle: u64, command: Value) -> Value {
        let command = CString::new(command.to_string()).unwrap();
        let pointer = unsafe { colorful_party_dispatch(handle, command.as_ptr()) };
        let result: Value =
            serde_json::from_str(unsafe { CStr::from_ptr(pointer) }.to_str().unwrap()).unwrap();
        unsafe { crate::ffi::colorful_string_free(pointer) };
        result
    }

    #[test]
    fn party_abi_connects_two_isolated_handles() {
        let mut registry = registry().lock().unwrap();
        let host_handle = registry.insert();
        let guest_handle = registry.insert();
        drop(registry);
        let host = call(
            host_handle,
            json!({ "command": "create", "display_name": "Host", "expires_at_ms": 100000, "relay_session_id": "relay", "relay_host_capability": "host-cap", "relay_guest_capability": "guest-cap" }),
        );
        let fragment = host["value"]["fragment"].as_str().unwrap();
        let tracks = (0..34)
            .map(|index| {
                json!({
                    "mediaId": { "provider": "tidal", "providerId": index.to_string() },
                    "title": format!("Track {index}"),
                    "artist": "Artist",
                    "durationMs": 180000,
                    "artworkUrl": format!("https://images.example/{index}.jpg"),
                })
            })
            .collect::<Vec<_>>();
        assert_eq!(
            call(
                host_handle,
                json!({ "command": "host_queue", "tracks": tracks })
            )["ok"],
            true
        );
        let guest = call(
            guest_handle,
            json!({ "command": "join", "display_name": "Guest", "relay_session_id": "relay", "fragment": fragment, "now_ms": 0 }),
        );
        let join_frame = guest["value"]["outbound"][0].clone();
        let admitted = call(
            host_handle,
            json!({ "command": "receive", "frame": join_frame }),
        );
        assert_eq!(admitted["value"]["outbound"].as_array().unwrap().len(), 1);
        let mut guest_state = Value::Null;
        for frame in admitted["value"]["outbound"].as_array().unwrap() {
            let received = call(
                guest_handle,
                json!({ "command": "receive", "frame": frame }),
            );
            assert!(received["ok"].as_bool().unwrap());
            guest_state = received["value"]["state"].clone();
        }
        assert_eq!(guest_state["queue"].as_array().unwrap().len(), 34);
        assert_eq!(
            guest_state["queue"][0]["track"]["artworkUrl"],
            "https://images.example/0.jpg"
        );
        assert_eq!(
            call(
                guest_handle,
                json!({ "command": "suggest", "track": { "mediaId": { "provider": "tidal", "providerId": "1" }, "title": "One", "artist": "A", "durationMs": 1000 } })
            )["ok"],
            true
        );
        let leave = call(guest_handle, json!({ "command": "leave" }));
        assert_eq!(leave["ok"], true);
        let left = call(
            host_handle,
            json!({ "command": "receive", "frame": leave["value"]["outbound"][0] }),
        );
        assert_eq!(left["ok"], true);
        assert_eq!(left["value"]["state"]["participants"].as_array().unwrap().len(), 1);
        assert!(colorful_party_close(host_handle));
        assert!(colorful_party_close(guest_handle));
    }
}
