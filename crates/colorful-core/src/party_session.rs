//! Host-authoritative, transport-independent listening-party protocol.

use crate::media::MediaId;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use hkdf::Hkdf;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt;
use x25519_dalek::{PublicKey as AgreementPublicKey, StaticSecret};
use zeroize::Zeroizing;

const VERSION: u8 = 2;
const KEY_BYTES: usize = 32;
const NONCE_BYTES: usize = 24;
const SIGNATURE_BYTES: usize = 64;
const MAX_NAME_BYTES: usize = 64;
const MAX_WIRE_BYTES: usize = 128 * 1024;
const MAX_SESSION_OPERATIONS: usize = 65_536;
const MAX_RECEIVED_NONCES: usize = 65_536;
const MAX_RELAY_SESSION_ID_BYTES: usize = 256;
const MAX_TICKET_BYTES: usize = KEY_BYTES;
const MAX_TICKET_COMPONENT_TEXT_BYTES: usize = 43;
const MAX_TICKET_TEXT_BYTES: usize =
    3 + MAX_TICKET_COMPONENT_TEXT_BYTES + 1 + MAX_TICKET_COMPONENT_TEXT_BYTES;
const MAX_BOOTSTRAP_CIPHERTEXT_BYTES: usize = 24 + 4096 + 16;
const EVENT_DOMAIN: &[u8] = b"colorful.party.event.v2";
const JOIN_DOMAIN: &[u8] = b"colorful.party.join.v2";
const COMMAND_DOMAIN: &[u8] = b"colorful.party.command.v2";
const FRAME_DOMAIN: &[u8] = b"colorful.party.frame.v2";
const REKEY_DOMAIN: &[u8] = b"colorful.party.rekey.v2";
const DISCORD_TICKET_DOMAIN: &[u8] = b"colorful.discord.ticket.v1";

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PartyRole {
    Host,
    CoHost,
    Guest,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PartyParticipant {
    pub participant_id: String,
    pub display_name: String,
    pub role: PartyRole,
    pub signing_public_key: [u8; KEY_BYTES],
    pub agreement_public_key: [u8; KEY_BYTES],
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PartyKeyEnvelope {
    pub participant_id: String,
    pub ephemeral_public_key: [u8; KEY_BYTES],
    pub nonce: [u8; NONCE_BYTES],
    pub ciphertext: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PartyTrack {
    pub media_id: MediaId,
    pub title: String,
    pub artist: String,
    pub duration_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artwork_url: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PartyQueueEntry {
    pub entry_id: String,
    pub track: PartyTrack,
    pub suggested_by: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PartyPlaybackState {
    pub entry_id: Option<String>,
    pub playing: bool,
    pub position_ms: u64,
    pub host_time_ms: i64,
    pub generation: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PartyEventBody {
    ParticipantJoined {
        participant: PartyParticipant,
    },
    ParticipantRemoved {
        participant_id: String,
    },
    RoleChanged {
        participant_id: String,
        role: PartyRole,
    },
    JoinPolicyChanged {
        enabled: bool,
    },
    JoinApprovalPolicyChanged {
        required: bool,
    },
    JoinRequestRejected {
        participant_id: String,
        reason: String,
    },
    TrackQueued {
        entry_id: String,
        track: PartyTrack,
        suggested_by: String,
    },
    QueueReplaced {
        entries: Vec<PartyQueueEntry>,
    },
    StateSnapshot {
        participants: Vec<PartyParticipant>,
        join_enabled: bool,
        #[serde(default)]
        approval_required: bool,
        entries: Vec<PartyQueueEntry>,
        playback: Option<PartyPlaybackState>,
    },
    KeyRotated {
        epoch: u64,
        envelopes: Vec<PartyKeyEnvelope>,
    },
    PlaybackChanged {
        entry_id: Option<String>,
        playing: bool,
        position_ms: u64,
        host_time_ms: i64,
        generation: u64,
    },
    ClockPong {
        participant_id: String,
        nonce: u64,
        client_send_ms: i64,
        host_receive_ms: i64,
        host_send_ms: i64,
    },
    PartyEnded,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PartyEvent {
    pub version: u8,
    pub party_id: String,
    pub sequence: u64,
    pub body: PartyEventBody,
    pub host_signature: Vec<u8>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JoinRequest {
    pub version: u8,
    pub party_id: String,
    pub participant_id: String,
    pub display_name: String,
    pub signing_public_key: [u8; KEY_BYTES],
    pub agreement_public_key: [u8; KEY_BYTES],
    pub signature: Vec<u8>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GuestCommandBody {
    SuggestTrack { track: PartyTrack },
    EnqueueTrack { track: PartyTrack },
    ClockPing { nonce: u64, client_send_ms: i64 },
    SyncRequest,
    Leave,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GuestCommand {
    pub version: u8,
    pub party_id: String,
    pub operation_id: String,
    pub participant_id: String,
    pub body: GuestCommandBody,
    pub signature: Vec<u8>,
}

/// Temporary party identity, independent from persistent device-sync identity.
pub struct PartyUser {
    participant_id: String,
    display_name: String,
    signing_key: SigningKey,
    agreement_key: StaticSecret,
}

impl PartyUser {
    fn command(&self, party_id: &str, body: GuestCommandBody) -> Result<GuestCommand, PartyError> {
        let mut command = GuestCommand {
            version: VERSION,
            party_id: party_id.to_owned(),
            operation_id: random_id("pco_")?,
            participant_id: self.participant_id.clone(),
            body,
            signature: Vec::new(),
        };
        command.signature = self
            .signing_key
            .sign(&command_bytes(&command)?)
            .to_bytes()
            .to_vec();
        Ok(command)
    }

    pub fn temporary(display_name: impl Into<String>) -> Result<Self, PartyError> {
        let display_name = display_name.into();
        validate_name(&display_name)?;
        let signing_key = SigningKey::from_bytes(&random_array()?);
        let agreement_key = StaticSecret::from(random_array()?);
        let participant_id = fingerprint(&signing_key.verifying_key().to_bytes());
        Ok(Self {
            participant_id,
            display_name,
            signing_key,
            agreement_key,
        })
    }

    pub fn participant_id(&self) -> &str {
        &self.participant_id
    }

    pub fn join_request(&self, invite: &PartyInvite) -> Result<JoinRequest, PartyError> {
        let mut request = JoinRequest {
            version: VERSION,
            party_id: invite.party_id.clone(),
            participant_id: self.participant_id.clone(),
            display_name: self.display_name.clone(),
            signing_public_key: self.signing_key.verifying_key().to_bytes(),
            agreement_public_key: AgreementPublicKey::from(&self.agreement_key).to_bytes(),
            signature: Vec::new(),
        };
        request.signature = self
            .signing_key
            .sign(&join_bytes(&request)?)
            .to_bytes()
            .to_vec();
        Ok(request)
    }

    pub fn suggest_track(
        &self,
        party_id: &str,
        track: PartyTrack,
    ) -> Result<GuestCommand, PartyError> {
        self.command(party_id, GuestCommandBody::SuggestTrack { track })
    }

    pub fn enqueue_track(
        &self,
        party_id: &str,
        track: PartyTrack,
    ) -> Result<GuestCommand, PartyError> {
        self.command(party_id, GuestCommandBody::EnqueueTrack { track })
    }

    pub fn sync_request(&self, party_id: &str) -> Result<GuestCommand, PartyError> {
        self.command(party_id, GuestCommandBody::SyncRequest)
    }

    pub fn leave(&self, party_id: &str) -> Result<GuestCommand, PartyError> {
        self.command(party_id, GuestCommandBody::Leave)
    }

    pub fn clock_ping(
        &self,
        party_id: &str,
        nonce: u64,
        client_send_ms: i64,
    ) -> Result<GuestCommand, PartyError> {
        self.command(
            party_id,
            GuestCommandBody::ClockPing {
                nonce,
                client_send_ms,
            },
        )
    }

    pub fn open_rotated_key(
        &self,
        party_id: &str,
        epoch: u64,
        envelopes: &[PartyKeyEnvelope],
    ) -> Result<Option<[u8; KEY_BYTES]>, PartyError> {
        let Some(envelope) = envelopes
            .iter()
            .find(|value| value.participant_id == self.participant_id)
        else {
            return Ok(None);
        };
        let ephemeral = AgreementPublicKey::from(envelope.ephemeral_public_key);
        let shared = self.agreement_key.diffie_hellman(&ephemeral);
        let key = rekey_wrapping_key(shared.as_bytes(), party_id, epoch, &self.participant_id)?;
        let ciphertext = URL_SAFE_NO_PAD
            .decode(&envelope.ciphertext)
            .map_err(|_| PartyError::InvalidFrame)?;
        let plaintext = XChaCha20Poly1305::new(Key::from_slice(&key))
            .decrypt(
                XNonce::from_slice(&envelope.nonce),
                Payload {
                    msg: &ciphertext,
                    aad: &rekey_aad(party_id, epoch, &self.participant_id),
                },
            )
            .map_err(|_| PartyError::DecryptionFailed)?;
        plaintext
            .try_into()
            .map(Some)
            .map_err(|_| PartyError::InvalidFrame)
    }
}

/// Secret carried in a URL fragment. The relay sees its own guest capability
/// during WebSocket authentication but never receives the separate party key.
pub struct PartyInvite {
    party_id: String,
    relay_guest_capability: String,
    expires_at_ms: i64,
    host_signing_public_key: [u8; KEY_BYTES],
    party_key: Zeroizing<[u8; KEY_BYTES]>,
    key_epoch: u64,
    approval_required: bool,
}

/// An ephemeral relay ticket and the encrypted invite bootstrap sent with it.
///
/// `ticket` is `v1.<lookup>.<bootstrapKey>`. Only `ticket_lookup` is sent to
/// the relay; callers must not persist or log the combined ticket or bootstrap
/// key. The relay session binds key derivation and authenticated encryption to
/// the session that created it.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PartyTicketBootstrap {
    pub ticket: String,
    pub ticket_lookup: String,
    pub bootstrap_ciphertext: String,
}

/// Wrap an existing party invite fragment for a relay session.
pub fn wrap_party_invite_fragment(
    fragment: &str,
    relay_session_id: &str,
) -> Result<PartyTicketBootstrap, PartyError> {
    validate_ticket_session_id(relay_session_id)?;
    let fragment_bytes = validate_ticket_fragment(fragment)?;
    let ticket_lookup = random_array::<MAX_TICKET_BYTES>()?;
    let bootstrap_key = random_array::<MAX_TICKET_BYTES>()?;
    let ticket_lookup = URL_SAFE_NO_PAD.encode(ticket_lookup);
    let bootstrap_key_text = URL_SAFE_NO_PAD.encode(bootstrap_key);
    let ticket = format!("v1.{ticket_lookup}.{bootstrap_key_text}");
    let key = ticket_key(&bootstrap_key, relay_session_id)?;
    let nonce = random_array::<NONCE_BYTES>()?;
    let cipher = XChaCha20Poly1305::new(Key::from_slice(&key));
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: &fragment_bytes,
                aad: &ticket_aad(relay_session_id),
            },
        )
        .map_err(|_| PartyError::InvalidTicket)?;
    let mut envelope = Vec::with_capacity(NONCE_BYTES + ciphertext.len());
    envelope.extend_from_slice(&nonce);
    envelope.extend_from_slice(&ciphertext);
    Ok(PartyTicketBootstrap {
        ticket,
        ticket_lookup,
        bootstrap_ciphertext: URL_SAFE_NO_PAD.encode(envelope),
    })
}

/// Unwrap an invite fragment from a relay ticket bootstrap.
///
/// All malformed, cross-session, wrong-ticket, and tampered inputs collapse to
/// `PartyError::InvalidTicket` so callers cannot use this as an oracle.
pub fn unwrap_party_invite_fragment(
    ticket: &str,
    bootstrap_ciphertext: &str,
    relay_session_id: &str,
) -> Result<String, PartyError> {
    validate_ticket_session_id(relay_session_id)?;
    let parsed_ticket = decode_ticket(ticket)?;
    if bootstrap_ciphertext.is_empty()
        || bootstrap_ciphertext.len() > encoded_len(MAX_BOOTSTRAP_CIPHERTEXT_BYTES)
    {
        return Err(PartyError::InvalidTicket);
    }
    let envelope = URL_SAFE_NO_PAD
        .decode(bootstrap_ciphertext)
        .map_err(|_| PartyError::InvalidTicket)?;
    if envelope.len() < NONCE_BYTES + 16 || envelope.len() > MAX_BOOTSTRAP_CIPHERTEXT_BYTES {
        return Err(PartyError::InvalidTicket);
    }
    if URL_SAFE_NO_PAD.encode(&envelope) != bootstrap_ciphertext {
        return Err(PartyError::InvalidTicket);
    }
    let (nonce, ciphertext) = envelope.split_at(NONCE_BYTES);
    // The relay lookup is intentionally not part of the key or AAD. It is a
    // routing hint only; the combined ticket's bootstrap key authenticates
    // this payload when supplied by the guest.
    let key = ticket_key(&parsed_ticket.bootstrap_key, relay_session_id)?;
    let cipher = XChaCha20Poly1305::new(Key::from_slice(&key));
    let plaintext = cipher
        .decrypt(
            XNonce::from_slice(nonce),
            Payload {
                msg: ciphertext,
                aad: &ticket_aad(relay_session_id),
            },
        )
        .map_err(|_| PartyError::InvalidTicket)?;
    if plaintext.is_empty() || plaintext.len() > 4096 {
        return Err(PartyError::InvalidTicket);
    }
    let fragment = String::from_utf8(plaintext).map_err(|_| PartyError::InvalidTicket)?;
    validate_ticket_fragment(&fragment)?;
    Ok(fragment)
}

fn validate_ticket_session_id(relay_session_id: &str) -> Result<(), PartyError> {
    if relay_session_id.is_empty()
        || relay_session_id.len() > MAX_RELAY_SESSION_ID_BYTES
        || relay_session_id.chars().any(char::is_control)
    {
        return Err(PartyError::InvalidTicket);
    }
    Ok(())
}

fn validate_ticket_fragment(fragment: &str) -> Result<Vec<u8>, PartyError> {
    if fragment.is_empty() || fragment.len() > 4096 || !fragment.is_ascii() {
        return Err(PartyError::InvalidTicket);
    }
    let decoded = URL_SAFE_NO_PAD
        .decode(fragment)
        .map_err(|_| PartyError::InvalidTicket)?;
    if decoded.is_empty() || URL_SAFE_NO_PAD.encode(&decoded) != fragment {
        return Err(PartyError::InvalidTicket);
    }
    Ok(fragment.as_bytes().to_vec())
}

struct ParsedTicket {
    _ticket_lookup: [u8; MAX_TICKET_BYTES],
    bootstrap_key: [u8; MAX_TICKET_BYTES],
}

fn decode_ticket(ticket: &str) -> Result<ParsedTicket, PartyError> {
    if ticket.len() != MAX_TICKET_TEXT_BYTES || !ticket.is_ascii() {
        return Err(PartyError::InvalidTicket);
    }
    let mut parts = ticket.split('.');
    if parts.next() != Some("v1") {
        return Err(PartyError::InvalidTicket);
    }
    let lookup = decode_ticket_component(parts.next().ok_or(PartyError::InvalidTicket)?)?;
    let bootstrap_key = decode_ticket_component(parts.next().ok_or(PartyError::InvalidTicket)?)?;
    if parts.next().is_some() {
        return Err(PartyError::InvalidTicket);
    }
    Ok(ParsedTicket {
        _ticket_lookup: lookup,
        bootstrap_key,
    })
}

fn decode_ticket_component(component: &str) -> Result<[u8; MAX_TICKET_BYTES], PartyError> {
    if component.len() != MAX_TICKET_COMPONENT_TEXT_BYTES || !component.is_ascii() {
        return Err(PartyError::InvalidTicket);
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(component)
        .map_err(|_| PartyError::InvalidTicket)?;
    if URL_SAFE_NO_PAD.encode(&bytes) != component {
        return Err(PartyError::InvalidTicket);
    }
    bytes.try_into().map_err(|_| PartyError::InvalidTicket)
}

fn ticket_key(
    ticket: &[u8; MAX_TICKET_BYTES],
    relay_session_id: &str,
) -> Result<[u8; KEY_BYTES], PartyError> {
    let mut info = Vec::with_capacity(DISCORD_TICKET_DOMAIN.len() + relay_session_id.len() + 2);
    info.extend_from_slice(DISCORD_TICKET_DOMAIN);
    info.push(0);
    info.extend_from_slice(relay_session_id.as_bytes());
    let mut key = [0; KEY_BYTES];
    Hkdf::<Sha256>::new(None, ticket)
        .expand(&info, &mut key)
        .map_err(|_| PartyError::InvalidTicket)?;
    Ok(key)
}

fn ticket_aad(relay_session_id: &str) -> Vec<u8> {
    let mut aad = Vec::with_capacity(DISCORD_TICKET_DOMAIN.len() + relay_session_id.len() + 1);
    aad.extend_from_slice(DISCORD_TICKET_DOMAIN);
    aad.push(0);
    aad.extend_from_slice(relay_session_id.as_bytes());
    aad
}

fn encoded_len(bytes: usize) -> usize {
    (bytes / 3) * 4
        + match bytes % 3 {
            0 => 0,
            1 => 2,
            _ => 3,
        }
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct InviteWire {
    version: u8,
    party_id: String,
    relay_guest_capability: String,
    expires_at_ms: i64,
    host_signing_public_key: [u8; KEY_BYTES],
    party_key: [u8; KEY_BYTES],
    key_epoch: u64,
    #[serde(default)]
    approval_required: bool,
}

impl PartyInvite {
    pub fn party_id(&self) -> &str {
        &self.party_id
    }
    pub fn relay_guest_capability(&self) -> &str {
        &self.relay_guest_capability
    }
    pub fn expires_at_ms(&self) -> i64 {
        self.expires_at_ms
    }

    pub fn from_fragment(fragment: &str, now_ms: i64) -> Result<Self, PartyError> {
        if fragment.len() > 4096 {
            return Err(PartyError::InvalidInvite);
        }
        let encoded = Zeroizing::new(
            URL_SAFE_NO_PAD
                .decode(fragment)
                .map_err(|_| PartyError::InvalidInvite)?,
        );
        let mut wire: InviteWire =
            serde_json::from_slice(&encoded).map_err(|_| PartyError::InvalidInvite)?;
        if wire.version != VERSION
            || wire.party_id.is_empty()
            || wire.relay_guest_capability.is_empty()
        {
            wire.party_key.fill(0);
            return Err(PartyError::InvalidInvite);
        }
        if now_ms > wire.expires_at_ms {
            wire.party_key.fill(0);
            return Err(PartyError::InviteExpired);
        }
        let invite = Self {
            party_id: wire.party_id,
            relay_guest_capability: wire.relay_guest_capability,
            expires_at_ms: wire.expires_at_ms,
            host_signing_public_key: wire.host_signing_public_key,
            party_key: Zeroizing::new(wire.party_key),
            key_epoch: wire.key_epoch,
            approval_required: wire.approval_required,
        };
        wire.party_key.fill(0);
        Ok(invite)
    }

    pub fn channel(&self) -> PartyChannel {
        PartyChannel::new(self.party_id.clone(), *self.party_key, self.key_epoch)
    }

    pub fn approval_required(&self) -> bool {
        self.approval_required
    }
}

#[derive(Clone)]
pub struct PartyHost {
    party_id: String,
    expires_at_ms: i64,
    signing_key: SigningKey,
    party_key: Zeroizing<[u8; KEY_BYTES]>,
    key_epoch: u64,
    sequence: u64,
    join_enabled: bool,
    approval_required: bool,
    participants: HashMap<String, PartyParticipant>,
    seen_operations: HashSet<String>,
    events: Vec<PartyEvent>,
}

impl PartyHost {
    pub fn create(
        display_name: impl Into<String>,
        expires_at_ms: i64,
    ) -> Result<(Self, PartyEvent), PartyError> {
        let display_name = display_name.into();
        validate_name(&display_name)?;
        let signing_key = SigningKey::from_bytes(&random_array()?);
        let public = signing_key.verifying_key().to_bytes();
        let host = PartyParticipant {
            participant_id: fingerprint(&public),
            display_name,
            role: PartyRole::Host,
            signing_public_key: public,
            agreement_public_key: AgreementPublicKey::from(&StaticSecret::from(random_array()?))
                .to_bytes(),
        };
        let mut participants = HashMap::new();
        participants.insert(host.participant_id.clone(), host.clone());
        let mut party = Self {
            party_id: random_id("cparty_")?,
            expires_at_ms,
            signing_key,
            party_key: Zeroizing::new(random_array()?),
            key_epoch: 0,
            sequence: 0,
            join_enabled: true,
            approval_required: false,
            participants,
            seen_operations: HashSet::new(),
            events: Vec::new(),
        };
        let bootstrap =
            party.sign_event(PartyEventBody::ParticipantJoined { participant: host })?;
        Ok((party, bootstrap))
    }

    pub fn party_id(&self) -> &str {
        &self.party_id
    }

    pub fn invite_fragment(&self, relay_guest_capability: &str) -> Result<String, PartyError> {
        if relay_guest_capability.is_empty() {
            return Err(PartyError::InvalidInvite);
        }
        let mut wire = InviteWire {
            version: VERSION,
            party_id: self.party_id.clone(),
            relay_guest_capability: relay_guest_capability.to_owned(),
            expires_at_ms: self.expires_at_ms,
            host_signing_public_key: self.signing_key.verifying_key().to_bytes(),
            party_key: *self.party_key,
            key_epoch: self.key_epoch,
            approval_required: self.approval_required,
        };
        let bytes = Zeroizing::new(serde_json::to_vec(&wire).map_err(PartyError::Json)?);
        wire.party_key.fill(0);
        Ok(URL_SAFE_NO_PAD.encode(bytes.as_slice()))
    }

    pub fn channel(&self) -> PartyChannel {
        PartyChannel::new(self.party_id.clone(), *self.party_key, self.key_epoch)
    }

    pub fn events(&self) -> &[PartyEvent] {
        &self.events
    }

    pub fn participants(&self) -> impl Iterator<Item = &PartyParticipant> {
        self.participants.values()
    }

    pub fn host_participant_id(&self) -> &str {
        self.participants
            .values()
            .find(|participant| participant.role == PartyRole::Host)
            .map(|participant| participant.participant_id.as_str())
            .expect("party host exists")
    }

    pub fn join_enabled(&self) -> bool {
        self.join_enabled
    }

    pub fn approval_required(&self) -> bool {
        self.approval_required
    }

    pub fn set_approval_required(&mut self, required: bool) -> Result<PartyEvent, PartyError> {
        self.approval_required = required;
        self.sign_event(PartyEventBody::JoinApprovalPolicyChanged { required })
    }

    pub fn queue_track(&mut self, track: PartyTrack) -> Result<PartyEvent, PartyError> {
        self.sign_event(PartyEventBody::TrackQueued {
            entry_id: random_id("pqe_")?,
            track,
            suggested_by: self.host_participant_id().to_owned(),
        })
    }

    pub fn replace_queue(&mut self, tracks: Vec<PartyTrack>) -> Result<PartyEvent, PartyError> {
        let suggested_by = self.host_participant_id().to_owned();
        let entries = tracks
            .into_iter()
            .map(|track| {
                Ok(PartyQueueEntry {
                    entry_id: random_id("pqe_")?,
                    track,
                    suggested_by: suggested_by.clone(),
                })
            })
            .collect::<Result<Vec<_>, PartyError>>()?;
        self.sign_event(PartyEventBody::QueueReplaced { entries })
    }

    pub fn admit(&mut self, request: &JoinRequest) -> Result<PartyEvent, PartyError> {
        if !self.join_enabled {
            return Err(PartyError::JoiningDisabled);
        }
        verify_join(request, &self.party_id)?;
        if let Some(existing) = self.participants.get(&request.participant_id) {
            if existing.display_name == request.display_name
                && existing.signing_public_key == request.signing_public_key
                && existing.agreement_public_key == request.agreement_public_key
            {
                return self.snapshot();
            }
            return Err(PartyError::AlreadyJoined);
        }
        let participant = PartyParticipant {
            participant_id: request.participant_id.clone(),
            display_name: request.display_name.clone(),
            role: PartyRole::Guest,
            signing_public_key: request.signing_public_key,
            agreement_public_key: request.agreement_public_key,
        };
        self.participants
            .insert(participant.participant_id.clone(), participant.clone());
        self.sign_event(PartyEventBody::ParticipantJoined { participant })
    }

    pub fn validate_join_request(&self, request: &JoinRequest) -> Result<(), PartyError> {
        if !self.join_enabled {
            return Err(PartyError::JoiningDisabled);
        }
        verify_join(request, &self.party_id)
    }

    pub fn reject_join(
        &mut self,
        participant_id: &str,
        reason: String,
    ) -> Result<PartyEvent, PartyError> {
        self.sign_event(PartyEventBody::JoinRequestRejected {
            participant_id: participant_id.to_owned(),
            reason,
        })
    }

    pub fn snapshot(&mut self) -> Result<PartyEvent, PartyError> {
        let mut entries = Vec::new();
        let mut playback = None;
        for event in &self.events {
            match &event.body {
                PartyEventBody::StateSnapshot {
                    entries: snapshot_entries,
                    playback: snapshot_playback,
                    ..
                } => {
                    entries = snapshot_entries.clone();
                    playback = snapshot_playback.clone();
                }
                PartyEventBody::QueueReplaced {
                    entries: replacement,
                } => entries = replacement.clone(),
                PartyEventBody::TrackQueued {
                    entry_id,
                    track,
                    suggested_by,
                } => entries.push(PartyQueueEntry {
                    entry_id: entry_id.clone(),
                    track: track.clone(),
                    suggested_by: suggested_by.clone(),
                }),
                PartyEventBody::PlaybackChanged {
                    entry_id,
                    playing,
                    position_ms,
                    host_time_ms,
                    generation,
                } => {
                    playback = Some(PartyPlaybackState {
                        entry_id: entry_id.clone(),
                        playing: *playing,
                        position_ms: *position_ms,
                        host_time_ms: *host_time_ms,
                        generation: *generation,
                    })
                }
                _ => {}
            }
        }
        let participants = self.participants.values().cloned().collect();
        let snapshot = self.sign_event(PartyEventBody::StateSnapshot {
            participants,
            join_enabled: self.join_enabled,
            approval_required: self.approval_required,
            entries,
            playback,
        })?;
        self.events.clear();
        self.events.push(snapshot.clone());
        Ok(snapshot)
    }

    pub fn accept_command(&mut self, command: &GuestCommand) -> Result<PartyEvent, PartyError> {
        self.accept_command_at(command, 0, 0)
    }

    pub fn accept_command_at(
        &mut self,
        command: &GuestCommand,
        host_receive_ms: i64,
        host_send_ms: i64,
    ) -> Result<PartyEvent, PartyError> {
        if command.version != VERSION || command.party_id != self.party_id {
            return Err(PartyError::WrongParty);
        }
        if self.seen_operations.contains(&command.operation_id) {
            return Err(PartyError::ReplayedOperation);
        }
        if self.seen_operations.len() >= MAX_SESSION_OPERATIONS {
            return Err(PartyError::SessionLimit);
        }
        let participant = self
            .participants
            .get(&command.participant_id)
            .ok_or(PartyError::UnknownParticipant)?;
        verify_signature(
            &participant.signing_public_key,
            &command_bytes(command)?,
            &command.signature,
        )?;
        self.seen_operations.insert(command.operation_id.clone());
        match &command.body {
            GuestCommandBody::SuggestTrack { track } => {
                self.sign_event(PartyEventBody::TrackQueued {
                    entry_id: random_id("pqe_")?,
                    track: track.clone(),
                    suggested_by: command.participant_id.clone(),
                })
            }
            GuestCommandBody::EnqueueTrack { track } => {
                if participant.role != PartyRole::CoHost {
                    return Err(PartyError::InvalidRole);
                }
                self.sign_event(PartyEventBody::TrackQueued {
                    entry_id: random_id("pqe_")?,
                    track: track.clone(),
                    suggested_by: command.participant_id.clone(),
                })
            }
            GuestCommandBody::ClockPing {
                nonce,
                client_send_ms,
            } => self.sign_event(PartyEventBody::ClockPong {
                participant_id: command.participant_id.clone(),
                nonce: *nonce,
                client_send_ms: *client_send_ms,
                host_receive_ms,
                host_send_ms,
            }),
            GuestCommandBody::SyncRequest => self.snapshot(),
            GuestCommandBody::Leave => {
                if participant.role == PartyRole::Host {
                    return Err(PartyError::InvalidRole);
                }
                self.participants.remove(&command.participant_id);
                self.sign_event(PartyEventBody::ParticipantRemoved {
                    participant_id: command.participant_id.clone(),
                })
            }
        }
    }

    pub fn set_playback(
        &mut self,
        entry_id: Option<String>,
        playing: bool,
        position_ms: u64,
        host_time_ms: i64,
        generation: u64,
    ) -> Result<PartyEvent, PartyError> {
        self.sign_event(PartyEventBody::PlaybackChanged {
            entry_id,
            playing,
            position_ms,
            host_time_ms,
            generation,
        })
    }

    pub fn set_join_enabled(&mut self, enabled: bool) -> Result<PartyEvent, PartyError> {
        self.join_enabled = enabled;
        self.sign_event(PartyEventBody::JoinPolicyChanged { enabled })
    }

    pub fn set_role(
        &mut self,
        participant_id: &str,
        role: PartyRole,
    ) -> Result<PartyEvent, PartyError> {
        if role == PartyRole::Host {
            return Err(PartyError::InvalidRole);
        }
        if participant_id == self.host_participant_id() {
            return Err(PartyError::InvalidRole);
        }
        self.participants
            .get_mut(participant_id)
            .ok_or(PartyError::UnknownParticipant)?
            .role = role;
        self.sign_event(PartyEventBody::RoleChanged {
            participant_id: participant_id.to_owned(),
            role,
        })
    }

    pub fn kick(&mut self, participant_id: &str) -> Result<PartyEvent, PartyError> {
        let participant = self
            .participants
            .get(participant_id)
            .ok_or(PartyError::UnknownParticipant)?;
        if participant.role == PartyRole::Host {
            return Err(PartyError::InvalidRole);
        }
        self.participants.remove(participant_id);
        self.sign_event(PartyEventBody::ParticipantRemoved {
            participant_id: participant_id.to_owned(),
        })
    }

    pub fn rotate_key(&mut self) -> Result<(PartyEvent, u64, [u8; KEY_BYTES]), PartyError> {
        let epoch = self
            .key_epoch
            .checked_add(1)
            .ok_or(PartyError::SequenceOverflow)?;
        let next_key = random_array()?;
        let mut envelopes = Vec::new();
        for participant in self
            .participants
            .values()
            .filter(|value| value.role != PartyRole::Host)
        {
            let secret = StaticSecret::from(random_array()?);
            let ephemeral_public_key = AgreementPublicKey::from(&secret).to_bytes();
            let recipient = AgreementPublicKey::from(participant.agreement_public_key);
            let shared = secret.diffie_hellman(&recipient);
            let wrapping_key = rekey_wrapping_key(
                shared.as_bytes(),
                &self.party_id,
                epoch,
                &participant.participant_id,
            )?;
            let nonce = random_array()?;
            let ciphertext = XChaCha20Poly1305::new(Key::from_slice(&wrapping_key))
                .encrypt(
                    XNonce::from_slice(&nonce),
                    Payload {
                        msg: &next_key,
                        aad: &rekey_aad(&self.party_id, epoch, &participant.participant_id),
                    },
                )
                .map_err(|_| PartyError::EncryptionFailed)?;
            envelopes.push(PartyKeyEnvelope {
                participant_id: participant.participant_id.clone(),
                ephemeral_public_key,
                nonce,
                ciphertext: URL_SAFE_NO_PAD.encode(ciphertext),
            });
        }
        let event = self.sign_event(PartyEventBody::KeyRotated { epoch, envelopes })?;
        self.party_key = Zeroizing::new(next_key);
        self.key_epoch = epoch;
        Ok((event, epoch, next_key))
    }

    fn sign_event(&mut self, body: PartyEventBody) -> Result<PartyEvent, PartyError> {
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or(PartyError::SequenceOverflow)?;
        let mut event = PartyEvent {
            version: VERSION,
            party_id: self.party_id.clone(),
            sequence: self.sequence,
            body,
            host_signature: Vec::new(),
        };
        event.host_signature = self
            .signing_key
            .sign(&event_bytes(&event)?)
            .to_bytes()
            .to_vec();
        self.events.push(event.clone());
        Ok(event)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ApplyPartyEvent {
    Applied,
    IgnoredReplay,
}

pub struct PartyReplica {
    party_id: String,
    host_public_key: [u8; KEY_BYTES],
    sequence: u64,
    pub join_enabled: bool,
    pub approval_required: bool,
    pub ended: bool,
    pub participants: HashMap<String, PartyParticipant>,
    pub queue: Vec<(String, PartyTrack, String)>,
    pub playback: Option<(Option<String>, bool, u64, i64, u64)>,
}

impl PartyReplica {
    pub fn from_invite(invite: &PartyInvite) -> Self {
        Self {
            party_id: invite.party_id.clone(),
            host_public_key: invite.host_signing_public_key,
            sequence: 0,
            join_enabled: true,
            approval_required: invite.approval_required,
            ended: false,
            participants: HashMap::new(),
            queue: Vec::new(),
            playback: None,
        }
    }

    pub fn apply(&mut self, event: &PartyEvent) -> Result<ApplyPartyEvent, PartyError> {
        if event.version != VERSION || event.party_id != self.party_id {
            return Err(PartyError::WrongParty);
        }
        verify_signature(
            &self.host_public_key,
            &event_bytes(event)?,
            &event.host_signature,
        )?;
        if event.sequence <= self.sequence {
            return Ok(ApplyPartyEvent::IgnoredReplay);
        }
        let is_snapshot = matches!(event.body, PartyEventBody::StateSnapshot { .. });
        if !is_snapshot && event.sequence != self.sequence + 1 {
            return Err(PartyError::SequenceGap);
        }
        match &event.body {
            PartyEventBody::ParticipantJoined { participant } => {
                self.participants
                    .insert(participant.participant_id.clone(), participant.clone());
            }
            PartyEventBody::ParticipantRemoved { participant_id } => {
                self.participants.remove(participant_id);
            }
            PartyEventBody::RoleChanged {
                participant_id,
                role,
            } => {
                self.participants
                    .get_mut(participant_id)
                    .ok_or(PartyError::UnknownParticipant)?
                    .role = *role
            }
            PartyEventBody::JoinPolicyChanged { enabled } => self.join_enabled = *enabled,
            PartyEventBody::JoinApprovalPolicyChanged { required } => {
                self.approval_required = *required
            }
            PartyEventBody::JoinRequestRejected { .. } => {}
            PartyEventBody::TrackQueued {
                entry_id,
                track,
                suggested_by,
            } => self
                .queue
                .push((entry_id.clone(), track.clone(), suggested_by.clone())),
            PartyEventBody::QueueReplaced { entries } => {
                self.queue = entries
                    .iter()
                    .map(|entry| {
                        (
                            entry.entry_id.clone(),
                            entry.track.clone(),
                            entry.suggested_by.clone(),
                        )
                    })
                    .collect()
            }
            PartyEventBody::StateSnapshot {
                participants,
                join_enabled,
                approval_required,
                entries,
                playback,
            } => {
                self.participants = participants
                    .iter()
                    .map(|participant| (participant.participant_id.clone(), participant.clone()))
                    .collect();
                self.join_enabled = *join_enabled;
                self.approval_required = *approval_required;
                self.queue = entries
                    .iter()
                    .map(|entry| {
                        (
                            entry.entry_id.clone(),
                            entry.track.clone(),
                            entry.suggested_by.clone(),
                        )
                    })
                    .collect();
                self.playback = playback.as_ref().map(|state| {
                    (
                        state.entry_id.clone(),
                        state.playing,
                        state.position_ms,
                        state.host_time_ms,
                        state.generation,
                    )
                });
                self.ended = false;
            }
            PartyEventBody::KeyRotated { .. } => {}
            PartyEventBody::PlaybackChanged {
                entry_id,
                playing,
                position_ms,
                host_time_ms,
                generation,
            } => {
                self.playback = Some((
                    entry_id.clone(),
                    *playing,
                    *position_ms,
                    *host_time_ms,
                    *generation,
                ))
            }
            PartyEventBody::ClockPong { .. } => {}
            PartyEventBody::PartyEnded => self.ended = true,
        }
        self.sequence = event.sequence;
        Ok(ApplyPartyEvent::Applied)
    }

    pub fn sequence(&self) -> u64 {
        self.sequence
    }
    pub(crate) fn party_id(&self) -> &str {
        &self.party_id
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PartyFrame {
    pub version: u8,
    pub party_id: String,
    pub key_epoch: u64,
    pub nonce: [u8; NONCE_BYTES],
    pub ciphertext: String,
}

pub struct PartyChannel {
    party_id: String,
    key: Zeroizing<[u8; KEY_BYTES]>,
    key_epoch: u64,
    received_nonces: HashSet<[u8; NONCE_BYTES]>,
    received_nonce_order: VecDeque<[u8; NONCE_BYTES]>,
}

impl PartyChannel {
    fn new(party_id: String, key: [u8; KEY_BYTES], key_epoch: u64) -> Self {
        Self {
            party_id,
            key: Zeroizing::new(key),
            key_epoch,
            received_nonces: HashSet::new(),
            received_nonce_order: VecDeque::new(),
        }
    }

    pub fn set_key(&mut self, key: [u8; KEY_BYTES], key_epoch: u64) {
        self.key = Zeroizing::new(key);
        self.key_epoch = key_epoch;
        self.received_nonces.clear();
        self.received_nonce_order.clear();
    }

    pub fn seal<T: Serialize>(&self, value: &T) -> Result<PartyFrame, PartyError> {
        let plaintext = Zeroizing::new(serde_json::to_vec(value).map_err(PartyError::Json)?);
        if plaintext.len() > MAX_WIRE_BYTES {
            return Err(PartyError::MessageTooLarge);
        }
        let nonce = random_array()?;
        let cipher = XChaCha20Poly1305::new(Key::from_slice(self.key.as_ref()));
        let ciphertext = cipher
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: &plaintext,
                    aad: &frame_aad(&self.party_id, self.key_epoch),
                },
            )
            .map_err(|_| PartyError::EncryptionFailed)?;
        Ok(PartyFrame {
            version: VERSION,
            party_id: self.party_id.clone(),
            key_epoch: self.key_epoch,
            nonce,
            ciphertext: URL_SAFE_NO_PAD.encode(ciphertext),
        })
    }

    pub fn open<T: DeserializeOwned>(&mut self, frame: &PartyFrame) -> Result<T, PartyError> {
        if frame.version != VERSION
            || frame.party_id != self.party_id
            || frame.key_epoch != self.key_epoch
        {
            return Err(PartyError::WrongParty);
        }
        if self.received_nonces.contains(&frame.nonce) {
            return Err(PartyError::ReplayedFrame);
        }
        if frame.ciphertext.len() > MAX_WIRE_BYTES * 2 {
            return Err(PartyError::MessageTooLarge);
        }
        let ciphertext = URL_SAFE_NO_PAD
            .decode(&frame.ciphertext)
            .map_err(|_| PartyError::InvalidFrame)?;
        let cipher = XChaCha20Poly1305::new(Key::from_slice(self.key.as_ref()));
        let plaintext = Zeroizing::new(
            cipher
                .decrypt(
                    XNonce::from_slice(&frame.nonce),
                    Payload {
                        msg: &ciphertext,
                        aad: &frame_aad(&self.party_id, self.key_epoch),
                    },
                )
                .map_err(|_| PartyError::DecryptionFailed)?,
        );
        let value = serde_json::from_slice(&plaintext).map_err(PartyError::Json)?;
        self.received_nonces.insert(frame.nonce);
        self.received_nonce_order.push_back(frame.nonce);
        if self.received_nonce_order.len() > MAX_RECEIVED_NONCES {
            if let Some(expired) = self.received_nonce_order.pop_front() {
                self.received_nonces.remove(&expired);
            }
        }
        Ok(value)
    }
}

#[derive(Debug)]
pub enum PartyError {
    Random(getrandom::Error),
    Json(serde_json::Error),
    InvalidName,
    InvalidInvite,
    InviteExpired,
    WrongParty,
    InvalidSignature,
    JoiningDisabled,
    AlreadyJoined,
    UnknownParticipant,
    InvalidRole,
    ReplayedOperation,
    ReplayedFrame,
    SequenceGap,
    SequenceOverflow,
    SessionLimit,
    MessageTooLarge,
    InvalidFrame,
    InvalidTicket,
    EncryptionFailed,
    DecryptionFailed,
}

impl fmt::Display for PartyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "party protocol error: {self:?}")
    }
}
impl std::error::Error for PartyError {}

fn verify_join(request: &JoinRequest, party_id: &str) -> Result<(), PartyError> {
    if request.version != VERSION || request.party_id != party_id {
        return Err(PartyError::WrongParty);
    }
    validate_name(&request.display_name)?;
    if request.participant_id != fingerprint(&request.signing_public_key) {
        return Err(PartyError::InvalidSignature);
    }
    verify_signature(
        &request.signing_public_key,
        &join_bytes(request)?,
        &request.signature,
    )
}

fn verify_signature(
    public: &[u8; KEY_BYTES],
    bytes: &[u8],
    signature: &[u8],
) -> Result<(), PartyError> {
    let signature: [u8; SIGNATURE_BYTES] = signature
        .try_into()
        .map_err(|_| PartyError::InvalidSignature)?;
    VerifyingKey::from_bytes(public)
        .map_err(|_| PartyError::InvalidSignature)?
        .verify(bytes, &Signature::from_bytes(&signature))
        .map_err(|_| PartyError::InvalidSignature)
}

fn event_bytes(event: &PartyEvent) -> Result<Vec<u8>, PartyError> {
    signing_bytes(
        EVENT_DOMAIN,
        &(event.version, &event.party_id, event.sequence, &event.body),
    )
}
fn join_bytes(request: &JoinRequest) -> Result<Vec<u8>, PartyError> {
    signing_bytes(
        JOIN_DOMAIN,
        &(
            request.version,
            &request.party_id,
            &request.participant_id,
            &request.display_name,
            request.signing_public_key,
            request.agreement_public_key,
        ),
    )
}
fn command_bytes(command: &GuestCommand) -> Result<Vec<u8>, PartyError> {
    signing_bytes(
        COMMAND_DOMAIN,
        &(
            command.version,
            &command.party_id,
            &command.operation_id,
            &command.participant_id,
            &command.body,
        ),
    )
}
fn signing_bytes<T: Serialize>(domain: &[u8], value: &T) -> Result<Vec<u8>, PartyError> {
    let mut bytes = domain.to_vec();
    bytes.extend_from_slice(&serde_json::to_vec(value).map_err(PartyError::Json)?);
    Ok(bytes)
}
fn frame_aad(party_id: &str, key_epoch: u64) -> Vec<u8> {
    let mut aad = FRAME_DOMAIN.to_vec();
    aad.extend_from_slice(party_id.as_bytes());
    aad.extend_from_slice(&key_epoch.to_le_bytes());
    aad
}

fn rekey_aad(party_id: &str, epoch: u64, participant_id: &str) -> Vec<u8> {
    let mut aad = REKEY_DOMAIN.to_vec();
    aad.extend_from_slice(party_id.as_bytes());
    aad.extend_from_slice(&epoch.to_le_bytes());
    aad.extend_from_slice(participant_id.as_bytes());
    aad
}
fn rekey_wrapping_key(
    shared: &[u8; KEY_BYTES],
    party_id: &str,
    epoch: u64,
    participant_id: &str,
) -> Result<[u8; KEY_BYTES], PartyError> {
    let mut info = REKEY_DOMAIN.to_vec();
    info.extend_from_slice(party_id.as_bytes());
    info.extend_from_slice(&epoch.to_le_bytes());
    info.extend_from_slice(participant_id.as_bytes());
    let mut key = [0; KEY_BYTES];
    Hkdf::<Sha256>::new(None, shared)
        .expand(&info, &mut key)
        .map_err(|_| PartyError::InvalidFrame)?;
    Ok(key)
}
fn validate_name(name: &str) -> Result<(), PartyError> {
    if name.trim().is_empty() || name.len() > MAX_NAME_BYTES || name.chars().any(char::is_control) {
        Err(PartyError::InvalidName)
    } else {
        Ok(())
    }
}
fn random_array<const N: usize>() -> Result<[u8; N], PartyError> {
    let mut bytes = [0; N];
    getrandom::fill(&mut bytes).map_err(PartyError::Random)?;
    Ok(bytes)
}
fn random_id(prefix: &str) -> Result<String, PartyError> {
    Ok(format!(
        "{prefix}{}",
        URL_SAFE_NO_PAD.encode(random_array::<16>()?)
    ))
}
fn fingerprint(public: &[u8; KEY_BYTES]) -> String {
    let digest = Sha256::digest(public);
    format!("cfp_{}", URL_SAFE_NO_PAD.encode(&digest[..16]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::Provider;

    fn track(id: &str) -> PartyTrack {
        PartyTrack {
            media_id: MediaId::new(Provider::Tidal, id).unwrap(),
            title: format!("Track {id}"),
            artist: "Artist".into(),
            duration_ms: Some(180_000),
            artwork_url: None,
        }
    }

    #[test]
    fn two_desktops_join_suggest_and_follow_host_playback() {
        let (mut host, bootstrap) = PartyHost::create("Desktop host", 100_000).unwrap();
        let invite =
            PartyInvite::from_fragment(&host.invite_fragment("relay-guest-cap").unwrap(), 1_000)
                .unwrap();
        let guest = PartyUser::temporary("Desktop guest").unwrap();
        let joined = host.admit(&guest.join_request(&invite).unwrap()).unwrap();
        let command = guest.suggest_track(host.party_id(), track("123")).unwrap();
        let queued = host.accept_command(&command).unwrap();
        let entry = match &queued.body {
            PartyEventBody::TrackQueued { entry_id, .. } => entry_id.clone(),
            _ => unreachable!(),
        };
        let playback = host
            .set_playback(Some(entry), true, 5_000, 20_000, 1)
            .unwrap();
        let mut replica = PartyReplica::from_invite(&invite);
        for event in [&bootstrap, &joined, &queued, &playback] {
            assert_eq!(replica.apply(event).unwrap(), ApplyPartyEvent::Applied);
        }
        assert_eq!(replica.participants.len(), 2);
        assert_eq!(replica.queue[0].2, guest.participant_id());
        assert!(replica.playback.as_ref().unwrap().1);
        assert!(matches!(
            host.accept_command(&command),
            Err(PartyError::ReplayedOperation)
        ));
    }

    #[test]
    fn repeated_join_is_idempotent_and_signed_leave_removes_the_participant() {
        let (mut host, _) = PartyHost::create("Host", 100_000).unwrap();
        let invite = PartyInvite::from_fragment(&host.invite_fragment("cap").unwrap(), 0).unwrap();
        let guest = PartyUser::temporary("Listener").unwrap();
        let request = guest.join_request(&invite).unwrap();

        host.admit(&request).unwrap();
        let repeated = host.admit(&request).unwrap();
        assert!(matches!(
            repeated.body,
            PartyEventBody::StateSnapshot { .. }
        ));
        assert_eq!(host.participants().count(), 2);

        let left = host
            .accept_command(&guest.leave(host.party_id()).unwrap())
            .unwrap();
        assert!(matches!(
            left.body,
            PartyEventBody::ParticipantRemoved { ref participant_id }
                if participant_id == guest.participant_id()
        ));
        assert_eq!(host.participants().count(), 1);
    }

    #[test]
    fn host_queue_snapshots_replace_order_and_remove_stale_tracks_atomically() {
        let (mut host, bootstrap) = PartyHost::create("Host", 100_000).unwrap();
        let invite = PartyInvite::from_fragment(&host.invite_fragment("cap").unwrap(), 0).unwrap();
        let first = host
            .replace_queue(vec![track("one"), track("two"), track("one")])
            .unwrap();
        let second = host
            .replace_queue(vec![track("two"), track("three")])
            .unwrap();
        let mut replica = PartyReplica::from_invite(&invite);

        replica.apply(&bootstrap).unwrap();
        replica.apply(&first).unwrap();
        assert_eq!(replica.queue.len(), 3);
        assert_eq!(replica.queue[0].1.media_id.provider_id, "one");
        assert_eq!(replica.queue[1].1.media_id.provider_id, "two");
        assert_eq!(replica.queue[2].1.media_id.provider_id, "one");
        assert_ne!(replica.queue[0].0, replica.queue[2].0);

        replica.apply(&second).unwrap();
        assert_eq!(replica.queue.len(), 2);
        assert_eq!(replica.queue[0].1.media_id.provider_id, "two");
        assert_eq!(replica.queue[1].1.media_id.provider_id, "three");
    }

    #[test]
    fn localized_duplicate_titles_keep_distinct_queue_identity_across_playback() {
        let (mut host, bootstrap) = PartyHost::create("Host", 100_000).unwrap();
        let invite = PartyInvite::from_fragment(&host.invite_fragment("cap").unwrap(), 0).unwrap();
        let mut first = track("cn-one");
        first.title = "同一首歌".into();
        let mut second = track("cn-two");
        second.title = "同一首歌".into();
        let replacement = host.replace_queue(vec![first, second]).unwrap();
        let entries = match &replacement.body {
            PartyEventBody::QueueReplaced { entries } => entries,
            _ => unreachable!(),
        };
        assert_ne!(entries[0].entry_id, entries[1].entry_id);

        // Playback references the queue entry, never a title/provider-id
        // lookup.  This is the invariant the desktop guest relies on when
        // consecutive tracks have the same localized title.
        let playback = host
            .set_playback(Some(entries[1].entry_id.clone()), true, 0, 10_000, 2)
            .unwrap();
        let mut replica = PartyReplica::from_invite(&invite);
        replica.apply(&bootstrap).unwrap();
        replica.apply(&replacement).unwrap();
        replica.apply(&playback).unwrap();
        assert_eq!(
            replica.playback.as_ref().unwrap().0,
            Some(entries[1].entry_id.clone())
        );
        assert_eq!(replica.queue[1].1.title, "同一首歌");
        assert_ne!(replica.queue[0].0, replica.queue[1].0);
    }

    #[test]
    fn signed_state_snapshot_bootstraps_a_late_guest_without_replaying_history() {
        let (mut host, bootstrap) = PartyHost::create("Host", 100_000).unwrap();
        let invite = PartyInvite::from_fragment(&host.invite_fragment("cap").unwrap(), 0).unwrap();
        let queue = host
            .replace_queue(vec![track("one"), track("two")])
            .unwrap();
        let entry_id = match &queue.body {
            PartyEventBody::QueueReplaced { entries } => entries[1].entry_id.clone(),
            _ => unreachable!(),
        };
        host.set_playback(Some(entry_id.clone()), true, 4_000, 20_000, 7)
            .unwrap();
        let guest = PartyUser::temporary("Late guest").unwrap();
        host.admit(&guest.join_request(&invite).unwrap()).unwrap();
        let snapshot = host.snapshot().unwrap();

        let mut late_replica = PartyReplica::from_invite(&invite);
        late_replica.apply(&snapshot).unwrap();
        assert_eq!(late_replica.participants.len(), 2);
        assert_eq!(late_replica.queue.len(), 2);
        assert_eq!(late_replica.playback.as_ref().unwrap().0, Some(entry_id));
        assert_eq!(late_replica.sequence(), snapshot.sequence);

        let mut existing_replica = PartyReplica::from_invite(&invite);
        existing_replica.apply(&bootstrap).unwrap();
        existing_replica.apply(&queue).unwrap();
        existing_replica.apply(&snapshot).unwrap();
        assert_eq!(existing_replica.participants.len(), 2);
        assert_eq!(existing_replica.sequence(), snapshot.sequence);
    }

    #[test]
    fn relay_frames_are_opaque_authenticated_and_replay_safe() {
        let (host, event) = PartyHost::create("Host", 100_000).unwrap();
        let invite = PartyInvite::from_fragment(&host.invite_fragment("cap").unwrap(), 0).unwrap();
        let sender = host.channel();
        let mut receiver = invite.channel();
        let frame = sender.seal(&event).unwrap();
        assert_eq!(receiver.open::<PartyEvent>(&frame).unwrap(), event);
        assert!(matches!(
            receiver.open::<PartyEvent>(&frame),
            Err(PartyError::ReplayedFrame)
        ));
        let mut tampered = sender.seal(&event).unwrap();
        let replacement = if tampered.ciphertext.starts_with('A') {
            "B"
        } else {
            "A"
        };
        tampered.ciphertext.replace_range(..1, replacement);
        assert!(matches!(
            receiver.open::<PartyEvent>(&tampered),
            Err(PartyError::DecryptionFailed)
        ));
    }

    #[test]
    fn clock_samples_are_guest_signed_and_host_authoritative() {
        let (mut host, _) = PartyHost::create("Host", 100_000).unwrap();
        let invite = PartyInvite::from_fragment(&host.invite_fragment("cap").unwrap(), 0).unwrap();
        let guest = PartyUser::temporary("Guest").unwrap();
        host.admit(&guest.join_request(&invite).unwrap()).unwrap();
        let ping = guest.clock_ping(host.party_id(), 42, 10_000).unwrap();
        let pong = host.accept_command_at(&ping, 10_080, 10_081).unwrap();
        assert!(matches!(
            pong.body,
            PartyEventBody::ClockPong {
                nonce: 42,
                client_send_ms: 10_000,
                host_receive_ms: 10_080,
                host_send_ms: 10_081,
                ..
            }
        ));
        let mut replica = PartyReplica::from_invite(&invite);
        for event in host.events() {
            assert_eq!(replica.apply(event).unwrap(), ApplyPartyEvent::Applied);
        }
    }

    #[test]
    fn guests_cannot_forge_host_events_and_host_controls_admission() {
        let (mut host, bootstrap) = PartyHost::create("Host", 100_000).unwrap();
        let invite = PartyInvite::from_fragment(&host.invite_fragment("cap").unwrap(), 0).unwrap();
        let guest = PartyUser::temporary("Guest").unwrap();
        let joined = host.admit(&guest.join_request(&invite).unwrap()).unwrap();
        let mut forged = joined.clone();
        forged.body = PartyEventBody::PartyEnded;
        let mut replica = PartyReplica::from_invite(&invite);
        replica.apply(&bootstrap).unwrap();
        assert!(matches!(
            replica.apply(&forged),
            Err(PartyError::InvalidSignature)
        ));
        host.set_role(guest.participant_id(), PartyRole::CoHost)
            .unwrap();
        host.kick(guest.participant_id()).unwrap();
        host.set_join_enabled(false).unwrap();
        let other = PartyUser::temporary("Other").unwrap();
        assert!(matches!(
            host.admit(&other.join_request(&invite).unwrap()),
            Err(PartyError::JoiningDisabled)
        ));
    }

    #[test]
    fn kicking_rotates_the_party_key_only_to_remaining_participants() {
        let (mut host, _) = PartyHost::create("Host", 100_000).unwrap();
        let invite = PartyInvite::from_fragment(&host.invite_fragment("cap").unwrap(), 0).unwrap();
        let removed = PartyUser::temporary("Removed").unwrap();
        let remaining = PartyUser::temporary("Remaining").unwrap();
        host.admit(&removed.join_request(&invite).unwrap()).unwrap();
        host.admit(&remaining.join_request(&invite).unwrap())
            .unwrap();
        let mut removed_channel = invite.channel();
        let mut remaining_channel = invite.channel();
        let mut host_channel = host.channel();

        let removed_event = host.kick(removed.participant_id()).unwrap();
        let (rotation, epoch, key) = host.rotate_key().unwrap();
        let removed_frame = host_channel.seal(&removed_event).unwrap();
        let rotation_frame = host_channel.seal(&rotation).unwrap();
        assert_eq!(
            removed_channel.open::<PartyEvent>(&removed_frame).unwrap(),
            removed_event
        );
        assert_eq!(
            remaining_channel
                .open::<PartyEvent>(&removed_frame)
                .unwrap(),
            removed_event
        );
        let removed_rotation = removed_channel.open::<PartyEvent>(&rotation_frame).unwrap();
        let remaining_rotation = remaining_channel
            .open::<PartyEvent>(&rotation_frame)
            .unwrap();
        let PartyEventBody::KeyRotated { envelopes, .. } = &remaining_rotation.body else {
            unreachable!()
        };
        assert!(
            removed
                .open_rotated_key(host.party_id(), epoch, envelopes)
                .unwrap()
                .is_none()
        );
        let remaining_key = remaining
            .open_rotated_key(host.party_id(), epoch, envelopes)
            .unwrap()
            .unwrap();
        assert_eq!(remaining_key, key);
        host_channel.set_key(key, epoch);
        remaining_channel.set_key(remaining_key, epoch);

        let next = host.set_playback(None, false, 0, 30_000, 8).unwrap();
        let next_frame = host_channel.seal(&next).unwrap();
        assert_eq!(
            remaining_channel.open::<PartyEvent>(&next_frame).unwrap(),
            next
        );
        assert!(matches!(
            removed_channel.open::<PartyEvent>(&next_frame),
            Err(PartyError::WrongParty)
        ));
        let PartyEventBody::KeyRotated { envelopes, .. } = removed_rotation.body else {
            unreachable!()
        };
        assert!(
            envelopes
                .iter()
                .all(|value| value.participant_id != removed.participant_id())
        );
    }

    #[test]
    fn only_promoted_cohosts_can_enqueue_directly() {
        let (mut host, _) = PartyHost::create("Host", 100_000).unwrap();
        let invite = PartyInvite::from_fragment(&host.invite_fragment("cap").unwrap(), 0).unwrap();
        let guest = PartyUser::temporary("Guest").unwrap();
        host.admit(&guest.join_request(&invite).unwrap()).unwrap();
        let denied = guest.enqueue_track(host.party_id(), track("one")).unwrap();
        assert!(matches!(
            host.accept_command(&denied),
            Err(PartyError::InvalidRole)
        ));
        host.set_role(guest.participant_id(), PartyRole::CoHost)
            .unwrap();
        let accepted = guest.enqueue_track(host.party_id(), track("two")).unwrap();
        assert!(matches!(
            host.accept_command(&accepted).unwrap().body,
            PartyEventBody::TrackQueued { .. }
        ));
    }

    #[test]
    fn ticket_bootstrap_round_trips_and_rejects_cross_session_or_tampering() {
        let (host, _) = PartyHost::create("Host", 100_000).unwrap();
        let fragment = host.invite_fragment("cap").unwrap();
        let wrapped = wrap_party_invite_fragment(&fragment, "relay-session").unwrap();
        assert_eq!(wrapped.ticket.len(), MAX_TICKET_TEXT_BYTES);
        let ticket_parts = wrapped.ticket.split('.').collect::<Vec<_>>();
        assert_eq!(ticket_parts.len(), 3);
        assert_eq!(ticket_parts[0], "v1");
        assert_eq!(ticket_parts[1], wrapped.ticket_lookup);
        assert_eq!(ticket_parts[1].len(), MAX_TICKET_COMPONENT_TEXT_BYTES);
        assert_eq!(ticket_parts[2].len(), MAX_TICKET_COMPONENT_TEXT_BYTES);
        assert_eq!(
            unwrap_party_invite_fragment(
                &wrapped.ticket,
                &wrapped.bootstrap_ciphertext,
                "relay-session"
            )
            .unwrap(),
            fragment
        );
        assert!(matches!(
            unwrap_party_invite_fragment(
                &wrapped.ticket,
                &wrapped.bootstrap_ciphertext,
                "other-session"
            ),
            Err(PartyError::InvalidTicket)
        ));
        let alternate_lookup = URL_SAFE_NO_PAD.encode([0x5a; KEY_BYTES]);
        let ticket_with_alternate_lookup = format!("v1.{alternate_lookup}.{}", ticket_parts[2]);
        // The lookup is relay routing metadata, not key material or AAD.
        assert_eq!(
            unwrap_party_invite_fragment(
                &ticket_with_alternate_lookup,
                &wrapped.bootstrap_ciphertext,
                "relay-session"
            )
            .unwrap(),
            fragment
        );
        let alternate_key = URL_SAFE_NO_PAD.encode([0xa5; KEY_BYTES]);
        let ticket_with_alternate_key = format!("v1.{}.{}", ticket_parts[1], alternate_key);
        assert!(matches!(
            unwrap_party_invite_fragment(
                &ticket_with_alternate_key,
                &wrapped.bootstrap_ciphertext,
                "relay-session"
            ),
            Err(PartyError::InvalidTicket)
        ));
        let mut tampered = wrapped.bootstrap_ciphertext.clone().into_bytes();
        tampered[0] = if tampered[0] == b'A' { b'B' } else { b'A' };
        assert!(matches!(
            unwrap_party_invite_fragment(
                &wrapped.ticket,
                std::str::from_utf8(&tampered).unwrap(),
                "relay-session"
            ),
            Err(PartyError::InvalidTicket)
        ));
    }
}
