# Party connectivity

**Status:** The hosted opaque relay foundation exists under
`services/colorful-relay`, and the Rust core implements encrypted,
host-authoritative party events. The Qt desktop can create/join through the
relay and follow basic host playback; a native two-client relay test passes.
The desktop now performs encrypted clock sampling and bounded drift correction.
Automatic relay reconnect, signed snapshot recovery, retained-history
compaction, and post-kick key rotation are implemented. Discovery, signaling,
and direct transports are not implemented. See [parties.md](parties.md).

Manual port forwarding is not part of the normal party flow.

Parties may use a temporary device identity without persistent sync identity
creation. Broader identity and ownership decisions are in
[social-model.md](social-model.md).

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

Guests send signed clock probes inside the end-to-end encrypted party channel.
The host returns signed receive/send timestamps, allowing the guest to estimate
round-trip time and host clock offset with the four-timestamp NTP calculation.
Samples more than 50 ms above the best observed RTT are ignored, and accepted
offsets are smoothed against a local monotonic clock so ordinary wall-clock
jumps do not directly drive playback.

The desktop compares its decoder position with the predicted host position four
times per second and filters the noisy decoder samples. It does not alter audio
for ordinary sub-90 ms variation. A moderate error must persist for at least 1.5
seconds before a stable 0.995x or 1.005x correction begins, and hysteresis keeps
that rate unchanged until drift falls below 35 ms. Only persistent drift beyond
500 ms causes a hard seek, limited to once every three seconds. The host
republishes a signed timeline anchor once per second and immediately after
track, seek, or play-state changes.

Adaptive streams can begin audible playback before mpv resumes frequent media
position notifications. Once mpv reports its actual playback-restart event, the
desktop advances a local monotonic media clock between decoder samples. It
freezes that estimate on pause or buffering and re-anchors whenever mpv supplies
a new position. This keeps UI and party timeline publication moving without
mistaking provider URL resolution or preroll time for audible playback.

Party diagnostics are opt-in under Settings > Sync. They expose local RTT,
estimated clock offset, filtered playback drift, correction rate/state, accepted
clock samples, hard resync count, and playback generation. The preference and
measurements remain local and are not added to relay traffic.

The host publishes the ordered queue as one signed, encrypted snapshot whenever
it changes. Applying it atomically keeps guest queue UI consistent across
additions, removals, reordering, and duplicates without exposing metadata to the
relay. The guest still resolves only the current and following provider sources
for playback, and appends the following source to mpv's prepared playlist for a
natural gapless transition when both providers expose compatible full-length
media. A late or unprepared guest catches up to the live host position after
loading instead of delaying the whole party. Explicit future-time start barriers
and per-device output-latency calibration remain future refinements.

A newly admitted guest receives one signed current-state event containing the
participant set, join policy, queue, and latest playback record. Both new and
already-connected guests may securely advance to that host-signed sequence, so
the UI does not animate through every obsolete queue snapshot retained by the
host.

## Security baseline

- invite contains a random session capability, not a reusable account token
- ephemeral session keys and authenticated encrypted transport
- provider credentials never enter party messages
- replay protection and monotonically increasing operation sequence
- host can revoke a peer and rotate the session key
- relay allocations and invite records expire automatically
