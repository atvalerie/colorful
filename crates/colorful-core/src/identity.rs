//! Accountless identity and per-device key material.
//!
//! The portable core owns cryptographic key generation and recovery-envelope
//! encoding. Platform applications remain responsible for storing a
//! [`LocalIdentity`] in their native secure store and for collecting a
//! passphrase without retaining it.

use argon2::{Algorithm, Argon2, Params, Version};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fmt;
use x25519_dalek::{PublicKey as ExchangePublicKey, StaticSecret};
use zeroize::Zeroizing;

const EXPORT_FORMAT: &str = "colorful-identity-export";
const EXPORT_VERSION: u8 = 1;
const EXPORT_AAD: &[u8] = b"colorful.identity-export.v1";
const SECRET_MAGIC: &[u8; 8] = b"CFIDSEC1";
const IDENTITY_ID_DOMAIN: &[u8] = b"colorful.identity.v1";
const DEVICE_ID_DOMAIN: &[u8] = b"colorful.device.v1";
const DEVICE_CERTIFICATE_DOMAIN: &[u8] = b"colorful.device-certificate.v1";
const ID_HASH_BYTES: usize = 20;
const KEY_BYTES: usize = 32;
const SALT_BYTES: usize = 16;
const NONCE_BYTES: usize = 24;
const MAX_DEVICE_NAME_BYTES: usize = 128;
const MAX_CIPHERTEXT_BASE64_BYTES: usize = 8 * 1024;
const ARGON2_MEMORY_KIB: u32 = 64 * 1024;
const ARGON2_ITERATIONS: u32 = 3;
const ARGON2_PARALLELISM: u32 = 1;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeviceCertificate {
    pub identity_id: String,
    pub device_id: String,
    pub device_name: String,
    pub signing_public_key: [u8; KEY_BYTES],
    pub exchange_public_key: [u8; KEY_BYTES],
    pub issued_at_ms: i64,
    pub identity_signature: [u8; 64],
}

impl DeviceCertificate {
    pub fn verify(&self, identity_public_key: &[u8; KEY_BYTES]) -> bool {
        let Ok(verifying_key) = VerifyingKey::from_bytes(identity_public_key) else {
            return false;
        };
        let signature = Signature::from_bytes(&self.identity_signature);
        verifying_key
            .verify(&certificate_message(self), &signature)
            .is_ok()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IdentityProfile {
    pub identity_id: String,
    pub identity_public_key: [u8; KEY_BYTES],
    pub device: DeviceCertificate,
}

impl IdentityProfile {
    pub fn verify(&self) -> bool {
        self.identity_id == identity_id(&self.identity_public_key)
            && self.device.identity_id == self.identity_id
            && self.device.device_id
                == device_id(
                    &self.device.signing_public_key,
                    &self.device.exchange_public_key,
                )
            && valid_device_name(&self.device.device_name)
            && self.device.verify(&self.identity_public_key)
    }
}

/// Secret local identity material. It intentionally implements neither
/// `Clone` nor `Debug` so accidental logs and copies are harder to introduce.
pub struct LocalIdentity {
    profile: IdentityProfile,
    identity_signing_key: SigningKey,
    device_signing_key: SigningKey,
    device_exchange_secret: StaticSecret,
    collection_key: Zeroizing<[u8; KEY_BYTES]>,
}

impl LocalIdentity {
    pub fn generate(
        device_name: impl Into<String>,
        issued_at_ms: i64,
    ) -> Result<Self, IdentityError> {
        let device_name = device_name.into();
        if !valid_device_name(&device_name) {
            return Err(IdentityError::InvalidDeviceName);
        }

        let identity_signing_key = SigningKey::from_bytes(&random_array()?);
        let device_signing_key = SigningKey::from_bytes(&random_array()?);
        let device_exchange_secret = StaticSecret::from(random_array()?);
        let collection_key = Zeroizing::new(random_array()?);
        Self::from_parts(
            device_name,
            issued_at_ms,
            identity_signing_key,
            device_signing_key,
            device_exchange_secret,
            collection_key,
        )
    }

    pub fn profile(&self) -> &IdentityProfile {
        &self.profile
    }

    pub fn export(&self, passphrase: &str) -> Result<ProtectedIdentityExport, IdentityError> {
        if passphrase.is_empty() {
            return Err(IdentityError::EmptyPassphrase);
        }

        let plaintext = Zeroizing::new(encode_secrets(self)?);
        let salt = random_array::<SALT_BYTES>()?;
        let nonce = random_array::<NONCE_BYTES>()?;
        let key = derive_export_key(passphrase, &salt, export_params())?;
        let cipher = XChaCha20Poly1305::new(Key::from_slice(key.as_ref()));
        let ciphertext = cipher
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: plaintext.as_ref(),
                    aad: EXPORT_AAD,
                },
            )
            .map_err(|_| IdentityError::EncryptionFailed)?;

        Ok(ProtectedIdentityExport {
            format: EXPORT_FORMAT.to_owned(),
            version: EXPORT_VERSION,
            kdf: ExportKdf {
                algorithm: "argon2id".to_owned(),
                memory_kib: ARGON2_MEMORY_KIB,
                iterations: ARGON2_ITERATIONS,
                parallelism: ARGON2_PARALLELISM,
                salt: URL_SAFE_NO_PAD.encode(salt),
            },
            cipher: ExportCipher {
                algorithm: "xchacha20poly1305".to_owned(),
                nonce: URL_SAFE_NO_PAD.encode(nonce),
                ciphertext: URL_SAFE_NO_PAD.encode(ciphertext),
            },
        })
    }

    fn from_parts(
        device_name: String,
        issued_at_ms: i64,
        identity_signing_key: SigningKey,
        device_signing_key: SigningKey,
        device_exchange_secret: StaticSecret,
        collection_key: Zeroizing<[u8; KEY_BYTES]>,
    ) -> Result<Self, IdentityError> {
        if !valid_device_name(&device_name) {
            return Err(IdentityError::InvalidDeviceName);
        }

        let identity_public_key = identity_signing_key.verifying_key().to_bytes();
        let signing_public_key = device_signing_key.verifying_key().to_bytes();
        let exchange_public_key = ExchangePublicKey::from(&device_exchange_secret).to_bytes();
        let identity_id = identity_id(&identity_public_key);
        let mut device = DeviceCertificate {
            identity_id: identity_id.clone(),
            device_id: device_id(&signing_public_key, &exchange_public_key),
            device_name,
            signing_public_key,
            exchange_public_key,
            issued_at_ms,
            identity_signature: [0; 64],
        };
        device.identity_signature = identity_signing_key
            .sign(&certificate_message(&device))
            .to_bytes();
        let profile = IdentityProfile {
            identity_id,
            identity_public_key,
            device,
        };

        Ok(Self {
            profile,
            identity_signing_key,
            device_signing_key,
            device_exchange_secret,
            collection_key,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProtectedIdentityExport {
    format: String,
    version: u8,
    kdf: ExportKdf,
    cipher: ExportCipher,
}

impl ProtectedIdentityExport {
    pub fn to_json(&self) -> Result<String, IdentityError> {
        serde_json::to_string_pretty(self).map_err(IdentityError::InvalidExportJson)
    }

    pub fn from_json(json: &str) -> Result<Self, IdentityError> {
        serde_json::from_str(json).map_err(IdentityError::InvalidExportJson)
    }

    pub fn unlock(&self, passphrase: &str) -> Result<LocalIdentity, IdentityError> {
        self.validate_header()?;
        if passphrase.is_empty() {
            return Err(IdentityError::EmptyPassphrase);
        }

        let salt = decode_array::<SALT_BYTES>(&self.kdf.salt)?;
        let nonce = decode_array::<NONCE_BYTES>(&self.cipher.nonce)?;
        let ciphertext = URL_SAFE_NO_PAD
            .decode(&self.cipher.ciphertext)
            .map_err(|_| IdentityError::InvalidExportEncoding)?;
        let params = Params::new(
            self.kdf.memory_kib,
            self.kdf.iterations,
            self.kdf.parallelism,
            Some(KEY_BYTES),
        )
        .map_err(|_| IdentityError::UnsupportedExportParameters)?;
        let key = derive_export_key(passphrase, &salt, params)?;
        let cipher = XChaCha20Poly1305::new(Key::from_slice(key.as_ref()));
        let plaintext = Zeroizing::new(
            cipher
                .decrypt(
                    XNonce::from_slice(&nonce),
                    Payload {
                        msg: &ciphertext,
                        aad: EXPORT_AAD,
                    },
                )
                .map_err(|_| IdentityError::DecryptionFailed)?,
        );
        decode_secrets(&plaintext)
    }

    fn validate_header(&self) -> Result<(), IdentityError> {
        if self.format != EXPORT_FORMAT || self.version != EXPORT_VERSION {
            return Err(IdentityError::UnsupportedExportFormat);
        }
        if self.kdf.algorithm != "argon2id" || self.cipher.algorithm != "xchacha20poly1305" {
            return Err(IdentityError::UnsupportedExportFormat);
        }
        if self.kdf.memory_kib < 8 * 1024
            || self.kdf.memory_kib > 256 * 1024
            || self.kdf.iterations == 0
            || self.kdf.iterations > 10
            || self.kdf.parallelism == 0
            || self.kdf.parallelism > 4
            || self.cipher.ciphertext.len() > MAX_CIPHERTEXT_BASE64_BYTES
        {
            return Err(IdentityError::UnsupportedExportParameters);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
struct ExportKdf {
    algorithm: String,
    memory_kib: u32,
    iterations: u32,
    parallelism: u32,
    salt: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
struct ExportCipher {
    algorithm: String,
    nonce: String,
    ciphertext: String,
}

#[derive(Debug)]
pub enum IdentityError {
    Random(getrandom::Error),
    InvalidDeviceName,
    EmptyPassphrase,
    EncryptionFailed,
    DecryptionFailed,
    InvalidExportJson(serde_json::Error),
    InvalidExportEncoding,
    InvalidSecretPayload,
    UnsupportedExportFormat,
    UnsupportedExportParameters,
    KeyDerivationFailed,
}

impl fmt::Display for IdentityError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Random(error) => write!(formatter, "secure random generation failed: {error}"),
            Self::InvalidDeviceName => formatter.write_str("device name must be 1 to 128 bytes"),
            Self::EmptyPassphrase => formatter.write_str("identity export passphrase is empty"),
            Self::EncryptionFailed => formatter.write_str("identity export encryption failed"),
            Self::DecryptionFailed => formatter.write_str("identity export could not be decrypted"),
            Self::InvalidExportJson(error) => {
                write!(formatter, "invalid identity export JSON: {error}")
            }
            Self::InvalidExportEncoding => formatter.write_str("invalid identity export encoding"),
            Self::InvalidSecretPayload => formatter.write_str("invalid identity secret payload"),
            Self::UnsupportedExportFormat => {
                formatter.write_str("unsupported identity export format")
            }
            Self::UnsupportedExportParameters => {
                formatter.write_str("unsupported identity export parameters")
            }
            Self::KeyDerivationFailed => {
                formatter.write_str("identity export key derivation failed")
            }
        }
    }
}

impl std::error::Error for IdentityError {}

fn export_params() -> Params {
    Params::new(
        ARGON2_MEMORY_KIB,
        ARGON2_ITERATIONS,
        ARGON2_PARALLELISM,
        Some(KEY_BYTES),
    )
    .expect("fixed Argon2id parameters are valid")
}

fn derive_export_key(
    passphrase: &str,
    salt: &[u8; SALT_BYTES],
    params: Params,
) -> Result<Zeroizing<[u8; KEY_BYTES]>, IdentityError> {
    let mut key = Zeroizing::new([0; KEY_BYTES]);
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(passphrase.as_bytes(), salt, key.as_mut())
        .map_err(|_| IdentityError::KeyDerivationFailed)?;
    Ok(key)
}

fn random_array<const N: usize>() -> Result<[u8; N], IdentityError> {
    let mut bytes = [0; N];
    getrandom::fill(&mut bytes).map_err(IdentityError::Random)?;
    Ok(bytes)
}

fn identity_id(public_key: &[u8; KEY_BYTES]) -> String {
    stable_id("cfi_", IDENTITY_ID_DOMAIN, &[public_key])
}

fn device_id(
    signing_public_key: &[u8; KEY_BYTES],
    exchange_public_key: &[u8; KEY_BYTES],
) -> String {
    stable_id(
        "cfd_",
        DEVICE_ID_DOMAIN,
        &[signing_public_key, exchange_public_key],
    )
}

fn stable_id(prefix: &str, domain: &[u8], parts: &[&[u8]]) -> String {
    let mut digest = Sha256::new();
    digest.update(domain);
    for part in parts {
        digest.update(part);
    }
    let digest = digest.finalize();
    format!(
        "{prefix}{}",
        URL_SAFE_NO_PAD.encode(&digest[..ID_HASH_BYTES])
    )
}

fn certificate_message(certificate: &DeviceCertificate) -> Vec<u8> {
    let mut message = Vec::with_capacity(256);
    push_field(&mut message, DEVICE_CERTIFICATE_DOMAIN);
    push_field(&mut message, certificate.identity_id.as_bytes());
    push_field(&mut message, certificate.device_id.as_bytes());
    push_field(&mut message, certificate.device_name.as_bytes());
    push_field(&mut message, &certificate.signing_public_key);
    push_field(&mut message, &certificate.exchange_public_key);
    message.extend_from_slice(&certificate.issued_at_ms.to_be_bytes());
    message
}

fn push_field(target: &mut Vec<u8>, value: &[u8]) {
    target.extend_from_slice(&(value.len() as u32).to_be_bytes());
    target.extend_from_slice(value);
}

fn valid_device_name(name: &str) -> bool {
    let trimmed = name.trim();
    !trimmed.is_empty()
        && name.len() <= MAX_DEVICE_NAME_BYTES
        && !name.chars().any(char::is_control)
}

fn encode_secrets(identity: &LocalIdentity) -> Result<Vec<u8>, IdentityError> {
    let name = identity.profile.device.device_name.as_bytes();
    let name_length = u16::try_from(name.len()).map_err(|_| IdentityError::InvalidDeviceName)?;
    let mut payload = Vec::with_capacity(8 + 2 + name.len() + 8 + KEY_BYTES * 4);
    payload.extend_from_slice(SECRET_MAGIC);
    payload.extend_from_slice(&name_length.to_be_bytes());
    payload.extend_from_slice(name);
    payload.extend_from_slice(&identity.profile.device.issued_at_ms.to_be_bytes());
    payload.extend_from_slice(identity.identity_signing_key.as_bytes());
    payload.extend_from_slice(identity.device_signing_key.as_bytes());
    payload.extend_from_slice(identity.device_exchange_secret.as_bytes());
    payload.extend_from_slice(identity.collection_key.as_ref());
    Ok(payload)
}

fn decode_secrets(payload: &[u8]) -> Result<LocalIdentity, IdentityError> {
    let mut cursor = SecretCursor::new(payload);
    if cursor.take(SECRET_MAGIC.len())? != SECRET_MAGIC {
        return Err(IdentityError::InvalidSecretPayload);
    }
    let name_length = u16::from_be_bytes(cursor.array()?) as usize;
    let device_name = std::str::from_utf8(cursor.take(name_length)?)
        .map_err(|_| IdentityError::InvalidSecretPayload)?
        .to_owned();
    let issued_at_ms = i64::from_be_bytes(cursor.array()?);
    let identity_signing_key = SigningKey::from_bytes(&cursor.array()?);
    let device_signing_key = SigningKey::from_bytes(&cursor.array()?);
    let device_exchange_secret = StaticSecret::from(cursor.array()?);
    let collection_key = Zeroizing::new(cursor.array()?);
    if !cursor.is_finished() {
        return Err(IdentityError::InvalidSecretPayload);
    }
    LocalIdentity::from_parts(
        device_name,
        issued_at_ms,
        identity_signing_key,
        device_signing_key,
        device_exchange_secret,
        collection_key,
    )
}

fn decode_array<const N: usize>(encoded: &str) -> Result<[u8; N], IdentityError> {
    let decoded = URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(|_| IdentityError::InvalidExportEncoding)?;
    decoded
        .try_into()
        .map_err(|_| IdentityError::InvalidExportEncoding)
}

struct SecretCursor<'a> {
    payload: &'a [u8],
    offset: usize,
}

impl<'a> SecretCursor<'a> {
    fn new(payload: &'a [u8]) -> Self {
        Self { payload, offset: 0 }
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8], IdentityError> {
        let end = self
            .offset
            .checked_add(length)
            .ok_or(IdentityError::InvalidSecretPayload)?;
        let value = self
            .payload
            .get(self.offset..end)
            .ok_or(IdentityError::InvalidSecretPayload)?;
        self.offset = end;
        Ok(value)
    }

    fn array<const N: usize>(&mut self) -> Result<[u8; N], IdentityError> {
        self.take(N)?
            .try_into()
            .map_err(|_| IdentityError::InvalidSecretPayload)
    }

    fn is_finished(&self) -> bool {
        self.offset == self.payload.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_identity_has_a_valid_device_certificate() {
        let identity = LocalIdentity::generate("Val's PC", 1_723_456_789_000).unwrap();
        assert!(identity.profile().verify());
        assert!(identity.profile().identity_id.starts_with("cfi_"));
        assert!(identity.profile().device.device_id.starts_with("cfd_"));
        assert_ne!(
            identity.profile().identity_public_key,
            identity.profile().device.signing_public_key
        );
    }

    #[test]
    fn encrypted_export_round_trips_without_exposing_secret_fields() {
        let identity = LocalIdentity::generate("Phone", 42).unwrap();
        let expected_profile = identity.profile().clone();
        let export = identity.export("correct horse battery staple").unwrap();
        let json = export.to_json().unwrap();

        assert!(!json.contains("Phone"));
        assert!(!json.contains(&expected_profile.identity_id));

        let restored = ProtectedIdentityExport::from_json(&json)
            .unwrap()
            .unlock("correct horse battery staple")
            .unwrap();
        assert_eq!(restored.profile(), &expected_profile);
        assert!(restored.profile().verify());
    }

    #[test]
    fn wrong_passphrase_and_tampering_fail_closed() {
        let identity = LocalIdentity::generate("Laptop", 42).unwrap();
        let mut export = identity.export("right passphrase").unwrap();
        assert!(matches!(
            export.unlock("wrong passphrase"),
            Err(IdentityError::DecryptionFailed)
        ));

        let replacement = if export.cipher.ciphertext.starts_with('A') {
            "B"
        } else {
            "A"
        };
        export.cipher.ciphertext.replace_range(..1, replacement);
        assert!(matches!(
            export.unlock("right passphrase"),
            Err(IdentityError::DecryptionFailed | IdentityError::InvalidExportEncoding)
        ));
    }

    #[test]
    fn invalid_device_names_and_empty_passphrases_are_rejected() {
        assert!(matches!(
            LocalIdentity::generate("  ", 0),
            Err(IdentityError::InvalidDeviceName)
        ));
        let identity = LocalIdentity::generate("Desktop", 0).unwrap();
        assert!(matches!(
            identity.export(""),
            Err(IdentityError::EmptyPassphrase)
        ));
    }
}
