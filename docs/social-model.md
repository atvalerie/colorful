# Identity, devices, sync, and parties

Compact product decisions for the future sync/party system.

## Core model

- No central identity registrar, SSO, or required account.
- An **identity** is a random local cryptographic trust anchor created on at
  least one device before persistent device sync can be enabled.
- One identity may have multiple independently usable **devices**. A phone and
  PC are separate playback endpoints and may both join a party.
- A casual one-off party may use a temporary device identity without creating a
  persistent identity.
- Offer an encrypted identity export/recovery file using a user-chosen
  passphrase, optionally additionally protected by the platform secure store.
  Exact recovery UX remains open.

## Pairing and sync

- Pairing requires explicit local confirmation on both devices.
- Both devices independently display a short numeric safety code derived from
  the authenticated exchange; pairing proceeds only when codes match and both
  users confirm.
- The implemented cryptographic foundation and remaining platform work are
  tracked in [identity-and-pairing.md](identity-and-pairing.md).
- Sync is opt-in and requires an identity first.
- Never replicate provider credentials as ordinary sync state. A user may
  explicitly transfer a provider-scoped credential between mutually confirmed
  devices when the destination cannot authorize directly; it travels only as
  recipient-bound end-to-end encrypted payload and is imported into the native
  secure store. Never transfer signed media URLs, local paths, downloaded
  audio/cache files, output devices, platform permissions, or device secrets.
- History and active-device presence are independently opt-in. Queue snapshots,
  handoff, and remote control are separately controllable. EQ and ordinary
  device preferences remain local by default.
- A paired device may automatically control another only when remote-control
  permission is enabled. Local playback remains independent otherwise.
- Lost-device revocation blocks future access and rotates future collection
  keys; already-local non-secret data is not retroactively erased.

## Parties

- Parties are temporary encrypted sessions across devices, separate from the
  owner's sync collection.
- Joining is instant through a short-lived invite. The host may kick guests or
  disable joining/listen-along from Discord/RPC.
- Guests listen and may suggest tracks. The host controls playback; guests may
  become co-hosts through explicit host/session rules.
- If a participant lacks the provider or entitlement, that device skips locally
  and shows unavailable. The host never proxies audio or credentials. A future
  compatible-track fallback is separate work.
- If the host leaves and more than one distinct identity remains, ownership
  transfers automatically to an eligible participant. If no other identity
  remains, the party stops but its queue is retained locally.
- A second device of the same identity is still a separate device participant;
  ownership decisions use distinct identities where applicable, not raw count.

## Connectivity and privacy

1. authenticated LAN/P2P;
2. ICE/STUN direct internet connectivity;
3. public relay fallback, with self-hosted relay support; and
4. encrypted mailbox delivery when participants are offline.

All application payloads are end-to-end encrypted. Relays/mailboxes see only
routing identifiers, expiry, timing, sizes, and coarse connection data. Relay
use, sync, presence, remote control, and parties are independently opt-in.

## Discord

- The phone needs no Discord libraries or credentials.
- When enabled, phone presence travels through the colorful channel to a paired
  desktop, which publishes local Discord RPC.
- Standard RPC exposes **Open in colorful** and **Listen along** where Discord
  supports it. Party participation can be disabled from RPC and guests can be
  kicked.
- Participant counts and richer controls may later use an optional
  Vencord/Equicord/BetterDiscord plugin; colorful must work without it.
- Public track shares may expose provider/title/artist/artwork metadata and can
  be generated without credentials. Private sync/party links use generic
  previews; capabilities stay in URL fragments or secure app storage, never
  query strings or server-rendered metadata.
