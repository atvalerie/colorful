# Listening parties

**Status:** Protocol v2 of the portable Rust core implements a host-authoritative
party protocol. The Qt desktop has a minimal create/join interface, private
party-link dispatch, a native WebSocket relay client, participant controls, and
host playback following, encrypted clock sampling, drift correction, and
next-track preloading. Late joiners receive one signed current-state snapshot
instead of replaying every historical queue revision. A native two-client integration test synchronizes a
signed clock sample through the real opaque relay. This remains an experimental
MVP: ownership transfer, output-latency calibration, direct transports, and
production relay deployment are not complete. Discord's public **Join Party**
button uses an expiring ticket; native Discord Ask-to-Join is not implemented
and would require authenticated RPC or Discord Social SDK support.

## Implemented core

- temporary random party identities, without requiring a persistent sync
  identity or central account;
- a private invite fragment containing separate relay and end-to-end
  capabilities;
- host-signed, monotonically sequenced party events;
- self-signed join requests and participant-signed track suggestions;
- host admission control, guest/co-host roles, kicking, and disabling joins;
- host promotion/demotion of co-hosts; co-hosts may append signed tracks to the
  party queue while playback remains host-authoritative;
- provider track references and display metadata, never provider credentials,
  signed media URLs, or audio; ordinary remote artwork URLs are included inside
  the encrypted payload so guest queue rows can render covers;
- host-authoritative playback records with position, host time, and generation;
- guest-signed clock probes and host-signed clock responses, encrypted like all
  other party traffic;
- filtered host-clock offset estimation, bounded playback-rate correction, and
  rate-limited hard resynchronization;
- a monotonic media-position fallback anchored to mpv's actual playback restart
  event, preventing delayed adaptive-stream position reports from publishing a
  stale 0:00 timeline;
- atomic encrypted full-queue snapshots, including ordering, removals, and
  duplicate tracks with distinct entry IDs;
- transient guest playback that does not overwrite the local persistent queue
  or trigger local radio/autoplay;
- a read-only guest view of the host queue plus UI and backend enforcement that
  prevents guests from locally issuing play, pause, seek, skip, shuffle, or
  repeat commands;
- clean timeline re-anchoring on host pause/resume transitions; and
- next-track provider-source preloading for
  best-effort gapless transitions;
- XChaCha20-Poly1305 encrypted frames that the relay can forward as opaque
  binary data; and
- replay rejection for commands, frames, and authoritative state events;
- bounded automatic relay reconnect followed by signed current-state recovery;
- signed guest departure with graceful WebSocket shutdown, so leaving removes
  the temporary participant from host and guest state without trusting relay
  connection metadata;
- idempotent retransmission of an identical signed join request and silent
  rejection of stale, foreign, or otherwise invalid relay frames at the UI
  boundary;
- snapshot compaction of retained host event history;
- post-kick party-key rotation with one X25519-wrapped replacement-key envelope
  per remaining participant, excluding the removed participant; and
- HTTPS share links at `colorful.valerie.sh`, with the E2E secret remaining in
  the URL fragment and a `colorful://`/repository landing page;
- a public Discord Join Party ticket, controlled by the Discord **Join Party
  button** setting, in the form `v1.<lookup>.<bootstrapKey>`. It is single-use,
  expires after 90 seconds, and is issued only for the production HTTPS relay.
  The relay stores a lookup hash and encrypted bootstrap ciphertext; it never
  receives `bootstrapKey` or the combined ticket.

The shared party key provides confidentiality from the relay. It does not prove
host authority because every participant knows it, so authoritative events are
also signed by the temporary host key embedded in the invite. Guest commands
are accepted only after their temporary signing key has been admitted.

## Current test topology

Core tests instantiate an isolated host and guest as if they were two desktop
processes. A second native integration executable creates two independent
party ABI handles and two Qt WebSocket clients, allocates a real relay session,
then verifies that the encrypted join/state exchange converges through the Bun
relay. Neither layer requires Android.

Covered behavior includes joining, queue suggestions, atomic queue replacement
(including duplicate ordering and stale-track removal), playback updates, clock
probe authority and encrypted relay delivery,
promotion, kicking, disabled joining, duplicate operations, frame replay,
ciphertext modification, and forged host events. The relay separately tests
binary WebSocket forwarding without inspecting frames.

## Next vertical slice

1. Add explicit future-time start barriers, device-output latency calibration,
   and richer unavailable-track handling.
2. Persist active sessions across full app restarts where explicitly opted in.
3. Add automatic host transfer using distinct identities and retain the local
   queue when the last identity leaves.
4. Add LAN discovery/direct transport, then ICE/STUN, while retaining the
   existing relay as fallback.
5. Add richer suggestion UI and unavailable-track presentation.
6. Add authenticated Discord Ask-to-Join through RPC or Social SDK.

Kicking rotates the frame-encryption key before subsequent application traffic.
The removed peer can still observe opaque relay traffic but receives no wrapped
replacement key and cannot decrypt the next epoch. The host invite fragment is
regenerated at the same boundary, invalidating copies of the previous invite.

Product authority for roles, ownership, opt-in behavior, and unavailable tracks
remains [social-model.md](social-model.md). Connectivity details are in
[connectivity.md](connectivity.md).
