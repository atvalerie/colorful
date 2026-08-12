# Hosted backend boundary

The hosted colorful services are coordination infrastructure, not a music
library server or provider proxy.

## Service roles

The first service is `services/colorful-relay`. It provides:

- short-lived opaque mailboxes for encrypted store-and-forward operations;
- short-lived party session allocation with separate host and guest
  capabilities; and
- a binary WebSocket relay for ciphertext when LAN or direct P2P connectivity
  is unavailable.

The planned connection ladder remains:

1. authenticated mDNS/LAN transport;
2. ICE/STUN direct connectivity;
3. TURN or colorful QUIC relay fallback; and
4. encrypted mailbox delivery when devices are not online together.

The relay is a fallback, not the party protocol. Clock synchronization, queue
operations, replay protection, guest admission, host authority, key rotation,
and revocation remain client-side protocol work.

The service does not register identities. Identity creation, device keys,
pairing confirmation, recovery exports, permissions, encryption, and party
ownership live in clients. See [social-model.md](social-model.md).

## What the service may see

The service necessarily sees limited transport metadata:

- opaque mailbox/session identifiers;
- capability hashes, never the raw capability after creation;
- connection timing, frame sizes, and coarse network metadata; and
- expiry, quota, and delivery state.

It must not receive provider refresh tokens, browser sessions, signed media
URLs, local paths, plaintext track metadata, playlist names, library records,
listening history, or audio payloads. Clients must encrypt sync and party
messages before sending them. A relay forwards binary frames without parsing
their application contents.

The mailbox store must be replaced with an expiring encrypted-at-rest backend
before running multiple service instances. The storage operator must not have
keys that decrypt application payloads. Public deployments also need TLS,
rate limiting, connection limits, abuse controls, metrics that avoid payload
logging, and a deletion/expiry process.

## Share and invite URLs

Public web links and private capabilities are different things.

```text
https://colorful.valerie.sh/share/<public-id>
https://colorful.valerie.sh/party/<session-id>#<guest-capability>
```

The HTTPS page may explain colorful and offer an install/download fallback.
It must not put a party or mailbox capability in a query string or server-side
HTML. The fragment is not sent in the HTTP request, so the landing service
cannot store or log the capability. A client-side page may turn the fragment
into a `colorful://` launch after an explicit user click.

For a public track share, any title/artwork/provider metadata shown in the
preview is an intentional public disclosure and must be generated from a
separate opt-in share record. It must never be inferred by uploading a local
library snapshot. Private sync and party links use generic previews and keep
their encrypted payloads out of social metadata.

## Current implementation status

Implemented: bounded in-memory opaque mailboxes, expiry, idempotent message
insertion, capability separation, binary WebSocket forwarding, request/frame
limits, and health checks.

Not implemented: mDNS/LAN transport, ICE/STUN, TURN, QUIC, robust reconnects,
party clock correction and post-kick key rotation,
durable encrypted mailbox storage, public share pages, and client integration.
The Rust core supplies encrypted host-authoritative party frames and queue
suggestion contracts, and the Qt desktop connects them to the binary WebSocket
relay; see [parties.md](parties.md).
