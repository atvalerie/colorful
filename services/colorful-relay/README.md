# colorful relay backend

This is the first hosted backend slice for colorful. It provides:

- expiring opaque mailboxes for store-and-forward sync;
- expiring party-session allocation with separate host and guest capabilities;
- host-authenticated, revocable stable Discord join handles with short-lived
  one-use click tickets;
- a binary WebSocket relay that forwards ciphertext without parsing it;
- health and privacy-safe aggregate-stat endpoints for deployment checks; and
- a public HTTPS party landing page that preserves invite secrets in fragments.

State is currently process-local and bounded. A multi-instance deployment must
replace the store with an expiring encrypted mailbox/session backend before
putting more than one relay process behind a load balancer; it must not use a
plaintext database.

The service deliberately does not accept plaintext provider credentials, track
metadata, queue JSON, library records, audio URLs, or plaintext sync/party
messages. The client must encrypt payloads before using the mailbox or relay.
An explicitly requested device-to-device credential transfer may pass through
only as short-lived recipient-bound ciphertext that the service cannot
distinguish from another opaque envelope. The server sees only routing
identifiers, capability hashes, frame sizes, timing, and coarse connection
metadata.

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
GET  /discord/join
POST /v1/mailboxes
GET  /v1/mailboxes/<id>/messages
PUT  /v1/mailboxes/<id>/messages/<message-id>
DELETE /v1/mailboxes/<id>/messages/<message-id>
POST /v1/party-sessions
POST /v1/party-sessions/<id>/join-handles
DELETE /v1/party-sessions/<id>/join-handles
POST /v1/party-sessions/<id>/join-handles/revoke
POST /v1/party-sessions/<id>/join-tickets       (legacy one-use issue / compatible registration)
POST /v1/party-join-handles/mint
POST /v1/party-join-tickets/redeem
POST /v1/discord/rpc-token
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

For Discord Join Party, the host creates `v1.<handleLookup>.<bootstrapKey>` and
publishes it only in `https://colorful.valerie.sh/discord/join#...`. It
registers `handleLookup` and encrypted `bootstrapCiphertext` at
`POST /v1/party-sessions/<id>/join-handles`; the relay stores only the lookup
digest and ciphertext. On an explicit click, the client sends only
`handleLookup` to `POST /v1/party-join-handles/mint`. The relay returns a fresh
short-lived `ticketLookup`; the client combines that lookup with its locally
retained `bootstrapKey` and redeems it through
`POST /v1/party-join-tickets/redeem`. Each minted ticket expires after at most
two minutes and is deleted before redemption returns, so concurrent clicks are
independent and replay fails. Registering a new invite generation, ending the
party, disabling joins, or compare-and-revoke through the host-authenticated
revoke endpoint invalidates the stable handle and all outstanding derived
tickets. The relay never receives the bootstrap key or plaintext invite
fragment.

This is not the final connectivity stack yet. mDNS discovery, authenticated
LAN transport, ICE/STUN candidate exchange, TURN, QUIC relay transport, QR
pairing, and device revocation remain client and infrastructure work. The
party protocol itself is client-side encrypted and signed. The WebSocket
relay is a deployment-friendly encrypted-relay foundation, not a substitute
for direct LAN/P2P paths.

## Discord Ask-to-Join

Set `COLORFUL_DISCORD_CLIENT_SECRET` only in the production relay deployment
to enable the desktop client's authenticated Discord RPC flow. The relay uses
it to exchange a one-time authorization code at Discord, immediately returns
the resulting short-lived access token to the requesting desktop client, and
does not persist either value. Do not put this secret in Colorful desktop
builds or repository files; use an untracked deployment environment or secret
manager. Test Discord
accounts must be added to the application's tester list until the Discord app
has production RPC access.

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
The public Discord ticket flow intentionally issues tickets only when the relay
base URL is exactly `https://colorful.valerie.sh`; a local or arbitrary relay
cannot be used for that Discord button.

## Docker Compose deployment

The repository root includes [`compose.yaml`](../../compose.yaml). It runs one
relay process, publishes it only on VPS loopback, and creates the stable
`colorful-edge` Docker network:

```bash
git pull origin main
docker compose up -d --build
docker compose ps
curl http://127.0.0.1:8787/healthz
```

When nginx runs on the host, proxy to `http://127.0.0.1:8787`. When nginx runs
in another Compose project, attach its service to the existing network and
proxy to `http://colorful-relay:8787`:

```yaml
services:
  nginx:
    networks:
      - colorful-edge

networks:
  colorful-edge:
    external: true
    name: colorful-edge
```

The public nginx location must pass WebSocket upgrades and use long read/send
timeouts. The host port can be changed without changing the container by
setting `COLORFUL_RELAY_PORT`, for example
`COLORFUL_RELAY_PORT=18787 docker compose up -d`.

Do not scale the relay above one replica yet. Mailboxes, party allocations,
and active sockets are process-local, so scaling or restarting loses that
temporary state. No persistent volume is required or expected.
