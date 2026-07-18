# Multi-device sync

**Status:** Proposed architecture; not implemented yet.

## Product goal

Colorful should keep a personal music library consistent across the owner's
devices without turning the application into a conventional server-backed
streaming service. Devices must remain useful offline, and sync infrastructure
must not be able to read library contents or provider credentials.

## Recommended model

Use a hybrid transport:

1. Sync directly over the LAN when possible.
2. Attempt an internet P2P connection through ICE/STUN when both devices are
   online.
3. Fall back to TURN for live connections that cannot traverse NAT.
4. Use an end-to-end encrypted mailbox for store-and-forward sync when devices
   are not online simultaneously.

Pure P2P remains an available privacy mode, with the explicit limitation that
two devices must overlap online before their changes can converge. The mailbox
may be hosted by Colorful, self-hosted, or disabled.

## Device pairing and trust

- Every installation creates a device identity key pair.
- The first device creates a random collection key.
- Pairing uses a QR code or short-lived invite shown by an already trusted
  device.
- The invite transfers the collection key encrypted to the new device.
- Trusted devices are listed locally and can be individually revoked.
- Revocation rotates future access keys; recovery and lost-device behavior must
  be designed before implementation.

The mailbox receives encrypted envelopes and routing identifiers. It never
receives the collection key, TIDAL refresh token, plaintext library, playlist
names, or listening history.

## Data that syncs

- likes and saved-library membership
- playlists, playlist metadata, and track ordering
- playback history and optional scrobble state
- provider references and normalized metadata snapshots
- device-independent preferences
- optional queue snapshots
- optional current track and position for “continue on another device”

## Data that does not sync by default

- provider credentials; each device links its own TIDAL account
- downloaded or cached provider audio; each device downloads its own copy
- output device, volume, local paths, storage quota, and platform permissions
- secrets belonging to party sessions

Local-file transfer can be a separate, explicitly enabled encrypted feature.

## Local data model

Each device writes changes to an append-only operation journal alongside the
materialized SQLite library. Operations have:

- a globally unique operation ID
- originating device ID
- collection and entity ID
- per-device sequence number
- logical timestamp
- encrypted payload

The journal makes retries idempotent and allows offline devices to exchange
only missing operations. Periodic encrypted snapshots prevent a new device
from replaying an unbounded history.

## Merge behavior

| Data | Merge rule |
| --- | --- |
| Likes/library membership | Last operation wins; removals leave tombstones |
| Playback history | Append-only set keyed by event ID |
| Playlist metadata | Per-field last-writer-wins register |
| Playlist ordering | Ordered-list CRDT with stable entry IDs |
| Settings | Per-field rule; device-local settings are excluded |
| Current playback | Explicit handoff record, not continuous state merging |

Wall-clock time alone must not decide conflicts because device clocks drift.
Ordering should use per-device sequence numbers plus a logical clock and stable
device-ID tie-breaker.

## Playback handoff

Library sync and live playback control are distinct features. Handoff publishes
a short-lived record containing the provider track reference, queue snapshot,
position, paused/playing state, and host monotonic timestamp. The receiving
device resolves the track through its own provider account and starts locally.

This does not restream TIDAL audio or transfer provider tokens.

## Relationship to parties

Sync and parties may share discovery, authenticated transport, relay, and
encryption primitives, but they have different authority models:

- sync trusts the owner's paired devices and converges durable personal data;
- a party trusts temporary guests and synchronizes ephemeral playback state.

Party guests never gain access to the personal sync collection.

## Proposed delivery order

1. Define versioned sync operations and add the local SQLite journal.
2. Implement two-device export/import fixture tests with deterministic merging.
3. Add QR pairing and device/revocation management.
4. Add direct LAN sync.
5. Add encrypted mailbox store-and-forward.
6. Reuse ICE/TURN connectivity for remote direct sync.
7. Add playback handoff after durable library sync is reliable.

## Acceptance criteria

- Two offline devices can edit the same library and converge deterministically.
- Replaying an operation never duplicates a track or history event.
- A mailbox database disclosure reveals no music metadata or credentials.
- A revoked device cannot decrypt operations created after revocation.
- A new device can bootstrap from a snapshot and then apply newer operations.
- P2P-only mode works without a mailbox and clearly reports delayed sync.
- Downloads and provider credentials never transfer implicitly.

