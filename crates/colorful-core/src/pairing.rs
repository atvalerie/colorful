//! Two-device pairing with an ephemeral X25519 exchange and a numeric safety
//! code that must be confirmed locally on both devices.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fmt;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

const PROTOCOL_VERSION: u8 = 1;
const SESSION_ID_BYTES: usize = 16;
const KEY_BYTES: usize = 32;
const NONCE_BYTES: usize = 24;
const CONFIRMATION_BYTES: usize = 32;
const MIN_INVITE_LIFETIME_MS: i64 = 30_000;
const MAX_INVITE_LIFETIME_MS: i64 = 10 * 60_000;
const MAX_ENVELOPE_PLAINTEXT_BYTES: usize = 64 * 1024;
const MAX_ENVELOPE_BASE64_BYTES: usize = 96 * 1024;
const TRANSCRIPT_DOMAIN: &[u8] = b"colorful.pairing.transcript.v1";
const SAFETY_CODE_INFO: &[u8] = b"colorful.pairing.safety-code.v1";
const MASTER_KEY_INFO: &[u8] = b"colorful.pairing.master-key.v1";
const INVITER_SEND_INFO: &[u8] = b"colorful.pairing.inviter-to-joiner.v1";
const JOINER_SEND_INFO: &[u8] = b"colorful.pairing.joiner-to-inviter.v1";
const CONFIRMATION_DOMAIN: &[u8] = b"colorful.pairing.confirmation.v1";
const ENVELOPE_DOMAIN: &[u8] = b"colorful.pairing.envelope.v1";

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PairingRole {
    Inviter,
    Joiner,
}

impl PairingRole {
    fn opposite(self) -> Self {
        match self {
            Self::Inviter => Self::Joiner,
            Self::Joiner => Self::Inviter,
        }
    }

    fn wire_byte(self) -> u8 {
        match self {
            Self::Inviter => 1,
            Self::Joiner => 2,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PairingInvite {
    pub protocol_version: u8,
    pub session_id: [u8; SESSION_ID_BYTES],
    pub expires_at_ms: i64,
    pub inviter_ephemeral_public_key: [u8; KEY_BYTES],
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PairingResponse {
    pub protocol_version: u8,
    pub session_id: [u8; SESSION_ID_BYTES],
    pub joiner_ephemeral_public_key: [u8; KEY_BYTES],
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PairingConfirmation {
    pub protocol_version: u8,
    pub session_id: [u8; SESSION_ID_BYTES],
    pub role: PairingRole,
    pub authentication_tag: [u8; CONFIRMATION_BYTES],
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PairingEnvelope {
    pub protocol_version: u8,
    pub session_id: [u8; SESSION_ID_BYTES],
    pub nonce: [u8; NONCE_BYTES],
    pub ciphertext: String,
}

/// Inviter state contains an ephemeral secret and must not be logged or cloned.
pub struct PairingInviter {
    invite: PairingInvite,
    ephemeral_secret: StaticSecret,
}

impl PairingInviter {
    pub fn start(now_ms: i64, lifetime_ms: i64) -> Result<Self, PairingError> {
        if !(MIN_INVITE_LIFETIME_MS..=MAX_INVITE_LIFETIME_MS).contains(&lifetime_ms) {
            return Err(PairingError::InvalidInviteLifetime);
        }
        let expires_at_ms = now_ms
            .checked_add(lifetime_ms)
            .ok_or(PairingError::InvalidInviteLifetime)?;
        let ephemeral_secret = StaticSecret::from(random_array()?);
        let invite = PairingInvite {
            protocol_version: PROTOCOL_VERSION,
            session_id: random_array()?,
            expires_at_ms,
            inviter_ephemeral_public_key: PublicKey::from(&ephemeral_secret).to_bytes(),
        };
        Ok(Self {
            invite,
            ephemeral_secret,
        })
    }

    pub fn invite(&self) -> &PairingInvite {
        &self.invite
    }

    pub fn receive(
        self,
        response: &PairingResponse,
        now_ms: i64,
    ) -> Result<PairingVerification, PairingError> {
        validate_invite(&self.invite, now_ms)?;
        if response.protocol_version != PROTOCOL_VERSION
            || response.session_id != self.invite.session_id
        {
            return Err(PairingError::SessionMismatch);
        }
        derive_verification(
            PairingRole::Inviter,
            &self.invite,
            response,
            self.ephemeral_secret,
            response.joiner_ephemeral_public_key,
        )
    }
}

pub struct PairingJoiner;

impl PairingJoiner {
    pub fn respond(
        invite: &PairingInvite,
        now_ms: i64,
    ) -> Result<(PairingResponse, PairingVerification), PairingError> {
        validate_invite(invite, now_ms)?;
        let ephemeral_secret = StaticSecret::from(random_array()?);
        let response = PairingResponse {
            protocol_version: PROTOCOL_VERSION,
            session_id: invite.session_id,
            joiner_ephemeral_public_key: PublicKey::from(&ephemeral_secret).to_bytes(),
        };
        let verification = derive_verification(
            PairingRole::Joiner,
            invite,
            &response,
            ephemeral_secret,
            invite.inviter_ephemeral_public_key,
        )?;
        Ok((response, verification))
    }
}

/// Key-agreement result awaiting explicit confirmation on the local device.
/// Session encryption is intentionally unavailable at this stage.
pub struct PairingVerification {
    role: PairingRole,
    session_id: [u8; SESSION_ID_BYTES],
    expires_at_ms: i64,
    transcript_hash: [u8; KEY_BYTES],
    master_key: Zeroizing<[u8; KEY_BYTES]>,
    safety_code: u32,
}

impl PairingVerification {
    pub fn safety_code(&self) -> String {
        format!("{:06}", self.safety_code)
    }

    pub fn confirm(self) -> Result<ConfirmedPairing, PairingError> {
        let confirmation = confirmation_for(
            self.role,
            &self.session_id,
            &self.transcript_hash,
            &self.master_key,
        )?;
        Ok(ConfirmedPairing {
            verification: self,
            confirmation,
        })
    }
}

/// Locally confirmed pairing awaiting the other device's authenticated
/// confirmation message.
pub struct ConfirmedPairing {
    verification: PairingVerification,
    confirmation: PairingConfirmation,
}

impl ConfirmedPairing {
    pub fn confirmation(&self) -> &PairingConfirmation {
        &self.confirmation
    }

    pub fn finish(
        self,
        peer_confirmation: &PairingConfirmation,
    ) -> Result<PairingSession, PairingError> {
        let verification = &self.verification;
        if peer_confirmation.protocol_version != PROTOCOL_VERSION
            || peer_confirmation.session_id != verification.session_id
            || peer_confirmation.role != verification.role.opposite()
        {
            return Err(PairingError::InvalidPeerConfirmation);
        }
        verify_confirmation(
            peer_confirmation,
            &verification.transcript_hash,
            &verification.master_key,
        )?;

        let inviter_send = derive_subkey(
            &verification.master_key,
            &verification.transcript_hash,
            INVITER_SEND_INFO,
        )?;
        let joiner_send = derive_subkey(
            &verification.master_key,
            &verification.transcript_hash,
            JOINER_SEND_INFO,
        )?;
        let (send_key, receive_key) = match verification.role {
            PairingRole::Inviter => (inviter_send, joiner_send),
            PairingRole::Joiner => (joiner_send, inviter_send),
        };
        Ok(PairingSession {
            session_id: verification.session_id,
            expires_at_ms: verification.expires_at_ms,
            transcript_hash: verification.transcript_hash,
            send_key,
            receive_key,
            sent_nonces: HashSet::new(),
            received_nonces: HashSet::new(),
        })
    }
}

/// A mutually confirmed short-lived channel for transferring the encrypted
/// pairing package. Transport code may relay the envelope as opaque bytes.
pub struct PairingSession {
    session_id: [u8; SESSION_ID_BYTES],
    expires_at_ms: i64,
    transcript_hash: [u8; KEY_BYTES],
    send_key: Zeroizing<[u8; KEY_BYTES]>,
    receive_key: Zeroizing<[u8; KEY_BYTES]>,
    sent_nonces: HashSet<[u8; NONCE_BYTES]>,
    received_nonces: HashSet<[u8; NONCE_BYTES]>,
}

impl PairingSession {
    pub fn seal(&mut self, plaintext: &[u8], now_ms: i64) -> Result<PairingEnvelope, PairingError> {
        self.ensure_active(now_ms)?;
        if plaintext.len() > MAX_ENVELOPE_PLAINTEXT_BYTES {
            return Err(PairingError::EnvelopeTooLarge);
        }
        let nonce = loop {
            let candidate = random_array()?;
            if self.sent_nonces.insert(candidate) {
                break candidate;
            }
        };
        let cipher = XChaCha20Poly1305::new(Key::from_slice(self.send_key.as_ref()));
        let aad = envelope_aad(&self.session_id, &self.transcript_hash);
        let ciphertext = cipher
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: plaintext,
                    aad: &aad,
                },
            )
            .map_err(|_| PairingError::EncryptionFailed)?;
        Ok(PairingEnvelope {
            protocol_version: PROTOCOL_VERSION,
            session_id: self.session_id,
            nonce,
            ciphertext: URL_SAFE_NO_PAD.encode(ciphertext),
        })
    }

    pub fn open(
        &mut self,
        envelope: &PairingEnvelope,
        now_ms: i64,
    ) -> Result<Zeroizing<Vec<u8>>, PairingError> {
        self.ensure_active(now_ms)?;
        if envelope.protocol_version != PROTOCOL_VERSION || envelope.session_id != self.session_id {
            return Err(PairingError::SessionMismatch);
        }
        if self.received_nonces.contains(&envelope.nonce) {
            return Err(PairingError::ReplayedEnvelope);
        }
        if envelope.ciphertext.len() > MAX_ENVELOPE_BASE64_BYTES {
            return Err(PairingError::EnvelopeTooLarge);
        }
        let ciphertext = URL_SAFE_NO_PAD
            .decode(&envelope.ciphertext)
            .map_err(|_| PairingError::InvalidEnvelope)?;
        let cipher = XChaCha20Poly1305::new(Key::from_slice(self.receive_key.as_ref()));
        let aad = envelope_aad(&self.session_id, &self.transcript_hash);
        let plaintext = cipher
            .decrypt(
                XNonce::from_slice(&envelope.nonce),
                Payload {
                    msg: &ciphertext,
                    aad: &aad,
                },
            )
            .map_err(|_| PairingError::DecryptionFailed)?;
        self.received_nonces.insert(envelope.nonce);
        Ok(Zeroizing::new(plaintext))
    }

    fn ensure_active(&self, now_ms: i64) -> Result<(), PairingError> {
        if now_ms > self.expires_at_ms {
            Err(PairingError::InviteExpired)
        } else {
            Ok(())
        }
    }
}

#[derive(Debug)]
pub enum PairingError {
    Random(getrandom::Error),
    InvalidInviteLifetime,
    UnsupportedProtocol,
    InviteExpired,
    SessionMismatch,
    InvalidPeerKey,
    KeyDerivationFailed,
    InvalidPeerConfirmation,
    EnvelopeTooLarge,
    InvalidEnvelope,
    ReplayedEnvelope,
    EncryptionFailed,
    DecryptionFailed,
}

impl fmt::Display for PairingError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Random(error) => write!(formatter, "secure random generation failed: {error}"),
            Self::InvalidInviteLifetime => formatter.write_str("invalid pairing invite lifetime"),
            Self::UnsupportedProtocol => formatter.write_str("unsupported pairing protocol"),
            Self::InviteExpired => formatter.write_str("pairing invite expired"),
            Self::SessionMismatch => formatter.write_str("pairing session does not match"),
            Self::InvalidPeerKey => formatter.write_str("invalid pairing peer key"),
            Self::KeyDerivationFailed => formatter.write_str("pairing key derivation failed"),
            Self::InvalidPeerConfirmation => {
                formatter.write_str("peer did not confirm this pairing")
            }
            Self::EnvelopeTooLarge => formatter.write_str("pairing envelope is too large"),
            Self::InvalidEnvelope => formatter.write_str("invalid pairing envelope"),
            Self::ReplayedEnvelope => formatter.write_str("pairing envelope was already received"),
            Self::EncryptionFailed => formatter.write_str("pairing encryption failed"),
            Self::DecryptionFailed => {
                formatter.write_str("pairing envelope could not be decrypted")
            }
        }
    }
}

impl std::error::Error for PairingError {}

fn validate_invite(invite: &PairingInvite, now_ms: i64) -> Result<(), PairingError> {
    if invite.protocol_version != PROTOCOL_VERSION {
        return Err(PairingError::UnsupportedProtocol);
    }
    let Some(remaining_ms) = invite.expires_at_ms.checked_sub(now_ms) else {
        return Err(PairingError::InvalidInviteLifetime);
    };
    if remaining_ms < 0 {
        return Err(PairingError::InviteExpired);
    }
    if remaining_ms > MAX_INVITE_LIFETIME_MS {
        return Err(PairingError::InvalidInviteLifetime);
    }
    Ok(())
}

fn derive_verification(
    role: PairingRole,
    invite: &PairingInvite,
    response: &PairingResponse,
    local_secret: StaticSecret,
    peer_public_bytes: [u8; KEY_BYTES],
) -> Result<PairingVerification, PairingError> {
    let shared_secret = Zeroizing::new(
        local_secret
            .diffie_hellman(&PublicKey::from(peer_public_bytes))
            .to_bytes(),
    );
    if shared_secret.iter().all(|byte| *byte == 0) {
        return Err(PairingError::InvalidPeerKey);
    }
    let transcript_hash = pairing_transcript_hash(invite, response);
    let hkdf = Hkdf::<Sha256>::new(Some(&transcript_hash), shared_secret.as_ref());
    let mut code_bytes = [0; 4];
    hkdf.expand(SAFETY_CODE_INFO, &mut code_bytes)
        .map_err(|_| PairingError::KeyDerivationFailed)?;
    let safety_code = u32::from_be_bytes(code_bytes) % 1_000_000;
    let mut master_key = Zeroizing::new([0; KEY_BYTES]);
    hkdf.expand(MASTER_KEY_INFO, master_key.as_mut())
        .map_err(|_| PairingError::KeyDerivationFailed)?;
    Ok(PairingVerification {
        role,
        session_id: invite.session_id,
        expires_at_ms: invite.expires_at_ms,
        transcript_hash,
        master_key,
        safety_code,
    })
}

fn pairing_transcript_hash(invite: &PairingInvite, response: &PairingResponse) -> [u8; KEY_BYTES] {
    let mut digest = Sha256::new();
    digest.update(TRANSCRIPT_DOMAIN);
    digest.update([invite.protocol_version]);
    digest.update(invite.session_id);
    digest.update(invite.expires_at_ms.to_be_bytes());
    digest.update(invite.inviter_ephemeral_public_key);
    digest.update([response.protocol_version]);
    digest.update(response.session_id);
    digest.update(response.joiner_ephemeral_public_key);
    digest.finalize().into()
}

fn confirmation_for(
    role: PairingRole,
    session_id: &[u8; SESSION_ID_BYTES],
    transcript_hash: &[u8; KEY_BYTES],
    master_key: &[u8; KEY_BYTES],
) -> Result<PairingConfirmation, PairingError> {
    let mut mac = <HmacSha256 as Mac>::new_from_slice(master_key)
        .map_err(|_| PairingError::KeyDerivationFailed)?;
    mac.update(CONFIRMATION_DOMAIN);
    mac.update(transcript_hash);
    mac.update(&[role.wire_byte()]);
    Ok(PairingConfirmation {
        protocol_version: PROTOCOL_VERSION,
        session_id: *session_id,
        role,
        authentication_tag: mac.finalize().into_bytes().into(),
    })
}

fn verify_confirmation(
    confirmation: &PairingConfirmation,
    transcript_hash: &[u8; KEY_BYTES],
    master_key: &[u8; KEY_BYTES],
) -> Result<(), PairingError> {
    let mut mac = <HmacSha256 as Mac>::new_from_slice(master_key)
        .map_err(|_| PairingError::KeyDerivationFailed)?;
    mac.update(CONFIRMATION_DOMAIN);
    mac.update(transcript_hash);
    mac.update(&[confirmation.role.wire_byte()]);
    mac.verify_slice(&confirmation.authentication_tag)
        .map_err(|_| PairingError::InvalidPeerConfirmation)
}

fn derive_subkey(
    master_key: &[u8; KEY_BYTES],
    transcript_hash: &[u8; KEY_BYTES],
    info: &[u8],
) -> Result<Zeroizing<[u8; KEY_BYTES]>, PairingError> {
    let hkdf = Hkdf::<Sha256>::new(Some(transcript_hash), master_key);
    let mut key = Zeroizing::new([0; KEY_BYTES]);
    hkdf.expand(info, key.as_mut())
        .map_err(|_| PairingError::KeyDerivationFailed)?;
    Ok(key)
}

fn envelope_aad(session_id: &[u8; SESSION_ID_BYTES], transcript_hash: &[u8; KEY_BYTES]) -> Vec<u8> {
    let mut aad = Vec::with_capacity(ENVELOPE_DOMAIN.len() + SESSION_ID_BYTES + KEY_BYTES);
    aad.extend_from_slice(ENVELOPE_DOMAIN);
    aad.extend_from_slice(session_id);
    aad.extend_from_slice(transcript_hash);
    aad
}

fn random_array<const N: usize>() -> Result<[u8; N], PairingError> {
    let mut bytes = [0; N];
    getrandom::fill(&mut bytes).map_err(PairingError::Random)?;
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn confirmed_sessions() -> (PairingSession, PairingSession) {
        let inviter = PairingInviter::start(1_000, 60_000).unwrap();
        let invite = inviter.invite().clone();
        let (response, joiner_verification) = PairingJoiner::respond(&invite, 2_000).unwrap();
        let inviter_verification = inviter.receive(&response, 2_000).unwrap();
        assert_eq!(
            inviter_verification.safety_code(),
            joiner_verification.safety_code()
        );

        let inviter_confirmed = inviter_verification.confirm().unwrap();
        let joiner_confirmed = joiner_verification.confirm().unwrap();
        let inviter_confirmation = inviter_confirmed.confirmation().clone();
        let joiner_confirmation = joiner_confirmed.confirmation().clone();
        (
            inviter_confirmed.finish(&joiner_confirmation).unwrap(),
            joiner_confirmed.finish(&inviter_confirmation).unwrap(),
        )
    }

    #[test]
    fn both_devices_display_the_same_six_digit_code_and_confirm() {
        let (mut inviter, mut joiner) = confirmed_sessions();
        let envelope = inviter
            .seal(b"encrypted collection key package", 2_001)
            .unwrap();
        assert_eq!(
            joiner.open(&envelope, 2_001).unwrap().as_slice(),
            b"encrypted collection key package"
        );

        let reply = joiner.seal(b"pairing complete", 2_002).unwrap();
        assert_eq!(
            inviter.open(&reply, 2_002).unwrap().as_slice(),
            b"pairing complete"
        );
    }

    #[test]
    fn reflected_local_confirmation_is_rejected() {
        let inviter = PairingInviter::start(0, 60_000).unwrap();
        let invite = inviter.invite().clone();
        let (response, _) = PairingJoiner::respond(&invite, 1).unwrap();
        let confirmed = inviter.receive(&response, 1).unwrap().confirm().unwrap();
        let reflected = confirmed.confirmation().clone();
        assert!(matches!(
            confirmed.finish(&reflected),
            Err(PairingError::InvalidPeerConfirmation)
        ));
    }

    #[test]
    fn substituted_ephemeral_key_cannot_authenticate() {
        let inviter = PairingInviter::start(0, 60_000).unwrap();
        let invite = inviter.invite().clone();
        let (response, joiner_verification) = PairingJoiner::respond(&invite, 1).unwrap();
        let attacker_secret = StaticSecret::from(random_array::<KEY_BYTES>().unwrap());
        let mut substituted = response;
        substituted.joiner_ephemeral_public_key = PublicKey::from(&attacker_secret).to_bytes();
        let inviter_confirmed = inviter.receive(&substituted, 1).unwrap().confirm().unwrap();
        let joiner_confirmation = joiner_verification.confirm().unwrap();
        assert!(matches!(
            inviter_confirmed.finish(joiner_confirmation.confirmation()),
            Err(PairingError::InvalidPeerConfirmation)
        ));
    }

    #[test]
    fn expired_invites_and_oversized_lifetimes_are_rejected() {
        assert!(matches!(
            PairingInviter::start(0, MAX_INVITE_LIFETIME_MS + 1),
            Err(PairingError::InvalidInviteLifetime)
        ));
        let inviter = PairingInviter::start(0, MIN_INVITE_LIFETIME_MS).unwrap();
        assert!(matches!(
            PairingJoiner::respond(inviter.invite(), MIN_INVITE_LIFETIME_MS + 1),
            Err(PairingError::InviteExpired)
        ));
        let mut forged_lifetime = inviter.invite().clone();
        forged_lifetime.expires_at_ms = MAX_INVITE_LIFETIME_MS + 1;
        assert!(matches!(
            PairingJoiner::respond(&forged_lifetime, 0),
            Err(PairingError::InvalidInviteLifetime)
        ));
    }

    #[test]
    fn tampered_or_wrong_direction_envelopes_fail_closed() {
        let (mut inviter, mut joiner) = confirmed_sessions();
        let mut envelope = inviter.seal(b"secret", 2_001).unwrap();
        let replacement = if envelope.ciphertext.starts_with('A') {
            "B"
        } else {
            "A"
        };
        envelope.ciphertext.replace_range(..1, replacement);
        assert!(matches!(
            joiner.open(&envelope, 2_001),
            Err(PairingError::DecryptionFailed)
        ));

        let own_envelope = inviter.seal(b"cannot loop back", 2_001).unwrap();
        assert!(matches!(
            inviter.open(&own_envelope, 2_001),
            Err(PairingError::DecryptionFailed)
        ));
    }

    #[test]
    fn sessions_expire_and_authenticated_envelopes_cannot_be_replayed() {
        let (mut inviter, mut joiner) = confirmed_sessions();
        let envelope = inviter.seal(b"one shot", 2_001).unwrap();
        assert_eq!(
            joiner.open(&envelope, 2_001).unwrap().as_slice(),
            b"one shot"
        );
        assert!(matches!(
            joiner.open(&envelope, 2_002),
            Err(PairingError::ReplayedEnvelope)
        ));
        assert!(matches!(
            inviter.seal(b"too late", 61_001),
            Err(PairingError::InviteExpired)
        ));
    }
}
