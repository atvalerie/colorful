# colorful relay backend

This is the first hosted backend slice for colorful. It provides:

- expiring opaque mailboxes for store-and-forward sync;
- expiring party-session allocation with separate host and guest capabilities;
- a binary WebSocket relay that forwards ciphertext without parsing it; and
- health and privacy-safe aggregate-stat endpoints for deployment checks; and
- a public HTTPS party landing page that preserves invite secrets in fragments.

State is currently process-local and bounded. A multi-instance deployment must
replace the store with an expiring encrypted mailbox/session backend before
putting more than one relay process behind a load balancer; it must not use a
plaintext database.

The service deliberately does not accept provider credentials, track metadata,
queue JSON, library records, audio URLs, or plaintext sync/party messages. The
client must encrypt payloads before using the mailbox or relay. The server sees
only routing identifiers, capability hashes, frame sizes, timing, and coarse
connection metadata.

`GET /stats` is intentionally public and aggregate-only. It reports uptime,
active mailbox/session/connection counts, cumulative allocation/connection
counts, and forwarded frame/byte totals. It never includes IP addresses,
session or mailbox identifiers, capabilities, invite fragments, track metadata,
ciphertext, or per-party breakdowns.

## Endpoints

```text
GET  /healthz
GET  /stats
GET  /party/<session-id>
POST /v1/mailboxes
GET  /v1/mailboxes/<id>/messages
PUT  /v1/mailboxes/<id>/messages/<message-id>
DELETE /v1/mailboxes/<id>/messages/<message-id>
POST /v1/party-sessions
GET  /v1/party-sessions/<id>/relay   (WebSocket upgrade)
```

Mailbox and party creation return bearer capabilities once. Clients should
keep them in the platform secure store and pass them in `Authorization`; they
must not put them in URLs or ordinary application logs. Party relay frames are
binary-only. Text frames are rejected so the server cannot accidentally become
an application protocol parser.

The party landing page sends `no-store` and `no-referrer` headers. Browsers do
not transmit the private fragment after `#`; client-side code carries it into
the `colorful://` link and otherwise offers the GitHub repository.

This is not the final connectivity stack yet. mDNS discovery, authenticated
LAN transport, ICE/STUN candidate exchange, TURN, QUIC relay transport, QR
pairing, and device revocation remain client and infrastructure work. The
party protocol itself is client-side encrypted and signed. The WebSocket
relay is a deployment-friendly encrypted-relay foundation, not a substitute
for direct LAN/P2P paths.

See [`docs/backend.md`](../../docs/backend.md) for the complete hosted-service
boundary and the HTTPS/custom-scheme share-link model.

## Development

```bash
bun test
bunx tsc --noEmit
bun src/main.ts
```

The checked-in `Dockerfile` is only a process image. Put it behind a TLS
terminator and an abuse/rate-limiting edge; do not expose the development
loopback process directly to the public internet.

Use `COLORFUL_RELAY_HOST` and `COLORFUL_RELAY_PORT` to configure binding. Keep
the development default bound to loopback; a public deployment must sit behind
TLS, authentication-aware rate limiting, connection limits, and a rate-limiting
edge. The service does not terminate application-layer end-to-end encryption.
