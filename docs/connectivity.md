# Party connectivity

**Status:** Design only. Party discovery, signaling, direct transports, and
relays are not implemented.

Manual port forwarding is not part of the normal party flow.

## Connection ladder

The planned connection ladder tries transports in this order:

1. **Same LAN:** discover peers with mDNS and connect directly.
2. **Internet direct:** exchange ICE candidates through a small signaling
   service, use STUN to discover public mappings, and attempt UDP hole punching.
3. **Relay:** if carrier-grade NAT, symmetric NAT, a school/work firewall, or
   an IPv6/IPv4 mismatch prevents a direct path, route encrypted packets through
   TURN or a colorful QUIC relay.

A relay is the general answer when neither peer can accept inbound traffic.
There is no protocol trick that guarantees a direct connection through every
NAT. The relay can remain deliberately boring: it sees session identifiers,
timing, and byte counts, but not credentials, queue contents, or audio payloads.

## Minimal hosted pieces

- a stateless HTTPS/WebSocket signaling endpoint
- one or more STUN/TURN endpoints (coturn is a viable self-hosted baseline)
- optional short-lived invite records with no music library storage

These services would coordinate or relay a party; the music application would
still run on each device. The design requires self-hostable endpoints and
configurable server URLs.

## What a party synchronizes

Prefer sharing commands and references over restreaming provider audio:

- queue operations with stable operation IDs
- provider + track ID and normalized metadata
- host monotonic timestamp, media position, play/pause state, and rate
- reactions, votes, and presence

Each participant resolves and plays the track with their own provider session.
This saves bandwidth, retains quality, and avoids handing account tokens to the
host or guests. Local files can use an explicitly enabled encrypted media
transfer mode.

## Clock and drift

Peers estimate host clock offset using repeated ping samples. Playback starts at
a scheduled future host time. Small drift is corrected gradually; large drift
or a seek causes a hard reposition. The host is authoritative in the first
version, while queue edits use idempotent operations so reconnects are safe.

## Security baseline

- invite contains a random session capability, not a reusable account token
- ephemeral session keys and authenticated encrypted transport
- provider credentials never enter party messages
- replay protection and monotonically increasing operation sequence
- host can revoke a peer and rotate the session key
- relay allocations and invite records expire automatically
