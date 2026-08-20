# Identity and device pairing

**Status:** The portable Rust core implements identity/device key generation,
first-device certification, encrypted recovery exports, and the cryptographic
two-device confirmation channel. Platform secure storage, pairing UI,
trusted-device persistence, collection-key transfer records, and revocation are
still pending. The protocol has not received an independent security audit and
must not be described as audited merely because it uses audited primitives.

## Local identity material

Creating an identity generates independent random secrets for:

- the accountless identity root (Ed25519);
- the local device signing key (Ed25519);
- the local device key-agreement key (X25519); and
- the sync collection key (256 random bits).

Identity and device IDs are domain-separated SHA-256 fingerprints. The first
device receives an identity-root-signed certificate binding its name, signing
key, exchange key, and issue time to the identity. Secret-bearing Rust types do
not implement `Clone` or `Debug`, and key buffers use zeroization where the
underlying audited libraries permit it.

The Rust core does not write these secrets to ordinary SQLite storage.
Applications must place local secret state in Android Keystore, Apple Keychain,
Windows Credential Manager/DPAPI, or an equivalent native secure store.

## Recovery export

The optional recovery export is versioned JSON containing only KDF parameters,
salt, nonce, and ciphertext. The encrypted payload contains the identity root,
current device secrets, collection key, device name, and certificate issue
time.

- KDF: Argon2id v1.3, 64 MiB, three iterations, one lane.
- Encryption: XChaCha20-Poly1305 with a random 192-bit nonce.
- Passphrases must be non-empty and are never stored in the export.
- Import places strict bounds on KDF cost and ciphertext size before expensive
  work to reduce denial-of-service risk from a hostile file.
- Wrong passphrases and modified ciphertext fail authentication without
  returning partial identity state.

Importing this file restores the same device. Creating an additional device is
the pairing flow, not recovery-file import.

## Pairing confirmation channel

1. The trusted device creates a random session ID and ephemeral X25519 key. The
   invite expires after 30 seconds to 10 minutes.
2. The joining device validates the invite and returns its own ephemeral
   X25519 key.
3. Both derive keys from the shared secret and a transcript that binds the
   protocol version, session, expiry, and both ephemeral keys.
4. Both independently display the same zero-padded six-digit safety code.
5. Each user must confirm locally. Each device then sends a role-bound HMAC
   confirmation; receiving one's reflected confirmation is rejected.
6. Only after both confirmations does the core expose a short-lived encrypted
   transfer channel. Inviter-to-joiner and joiner-to-inviter use separate keys,
   and every XChaCha20-Poly1305 envelope binds the session transcript as
   associated data. The core enforces the invite expiry for transfers and
   rejects an authenticated envelope nonce if it is replayed.

The invite may be transported by QR, `colorful://`, LAN discovery, or the
opaque relay. Those carriers do not become trusted: the matching code and both
local confirmations authenticate the exchange.

## Next protocol work

- Define the versioned new-device enrollment request and encrypted response.
- Persist trusted device certificates and explicit per-feature permissions.
- Transfer the current collection-key epoch independently from optional
  provider credentials. Define a separately approved, provider-scoped transfer
  envelope and permission; never include platform identity/device secrets.
- Define revocation operations and rotate future collection keys.
- Add platform secure-store adapters and pairing screens.
- Obtain independent protocol/implementation review before production use.

The product authority remains [social-model.md](social-model.md); the broader
sync delivery plan is in [sync.md](sync.md).
