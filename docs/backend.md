# Hosted backend boundary

The hosted colorful services are coordination infrastructure, not a music
library server or provider proxy.

## Service roles

The first service is `services/colorful-relay`. It provides:

- short-lived opaque mailboxes for encrypted store-and-forward operations;
- short-lived party session allocation with separate host and guest
  capabilities;
- host-authenticated, one-use public Discord join tickets; and
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

It must not receive plaintext provider refresh tokens, browser sessions, signed
media URLs, local paths, plaintext track metadata, playlist names, library
records, listening history, or audio payloads. Clients must encrypt sync and
party messages before sending them. An explicit device credential handoff may
use the mailbox only as short-lived recipient-bound ciphertext; the service
must not know its payload type. A relay forwards binary frames without parsing
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
https://colorful.valerie.sh/discord/join#v1.<ticket-lookup>.<bootstrap-key>
```

The HTTPS page may explain colorful and offer an install/download fallback.
It must not put a party or mailbox capability in a query string or server-side
HTML. The fragment is not sent in the HTTP request, so the landing service
cannot store or log the capability. A client-side page may turn the fragment
into a `colorful://` launch after an explicit user click.

The Discord Join Party ticket is a 90-second, one-use wrapper around the
encrypted party invite bootstrap. The host authenticates issuance with the
party host capability. On redemption, the client sends only `ticketLookup` to
`POST /v1/party-join-tickets/redeem`; the relay returns the session and
encrypted bootstrap ciphertext, while `bootstrapKey` remains in the URL
fragment and is used locally. The relay stores only a digest of the lookup and
deletes the ticket before returning it, so replay fails. Hosts issue these
tickets only when using `https://colorful.valerie.sh` as the relay.

## Discord Ask-to-Join

When the host enables **Ask to Join**, the desktop client uses Discord's local
RPC authorization prompt. The returned one-time authorization code is sent to
`POST /v1/discord/rpc-token` on the official relay; the relay exchanges it
with Discord using its deployment-only `COLORFUL_DISCORD_CLIENT_SECRET` and
returns the short-lived user access token to that same desktop client. The
client authenticates its local Discord RPC connection, receives join requests,
and sends Discord's accept or decline command only after the host chooses in
Colorful.

The relay never receives a party invite fragment, bootstrap key, party frames,
or the resulting Discord token after returning it. It stores none of the OAuth
codes or access tokens. The app secret must never be added to a desktop build
or repository; use an untracked deployment environment or secret manager. The Discord application needs the test
accounts added as approved testers until Discord approves the application for
general RPC use.

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
durable encrypted mailbox storage, and public share pages.
The Rust core supplies encrypted host-authoritative party frames and queue
suggestion contracts, and the Qt desktop connects them to the binary WebSocket
relay; see [parties.md](parties.md).
