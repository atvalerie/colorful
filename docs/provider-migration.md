# Provider migration map

The existing projects were inspected as local references:

- `../backend/src/providers/*`
- `../backend/src/modules/playback/*`
- `../backend/src/modules/downloads/*`
- `../backend/src/modules/catalog/artwork-palette.ts`
- `../backend/src/types/media.ts`
- `../mocha/server/src/providers/tidal/*`
- `../mocha/app/src/components/DeviceLink.tsx`

No user tokens or private `.env` values are copied into colorful. The public
TIDAL web/device application clients are included as overridable defaults.

## Reuse

- normalized media/provider types
- provider catalog mapping and URL-resolution behavior, migrated behind shared
  contracts a provider at a time
- sanitized request/response fixtures shared by the Rust core and transitional
  TypeScript host so both implementations must produce the same metadata
- TIDAL device authorization state and slow-down polling behavior
- access-token single-flight refresh behavior
- manifest parsing and quality mapping
- SoundCloud homepage-hydrated public client discovery and transcoding selection
- artwork palette scoring, generalized to decoded pixel input
- provider-first lyrics with TIDAL and YouTube Music sources, LRCLIB fallback,
  normalized synced-line parsing, and shared persistent caching

## Replace

- PostgreSQL repositories with device-local SQLite
- users, roles, Discord auth, TOTP, bans, rate limits, and Turnstile
- operator account pools and server lease tokens
- proxy responses and public HTTP download routes
- server-side temporary-file management

## Adapt

### Credentials

The device flow stays, but the refresh token is written directly to Android
Keystore, iOS Keychain, Windows Credential Locker, or Linux Secret Service. The
database stores only a credential handle and non-secret account metadata.

Public first-party web/device clients may be shipped as overridable defaults.
Any provider configuration whose redistribution is not permitted must instead
be supplied locally at build/runtime and excluded from Git.

### Playback and downloads

Provider adapters return a typed source plan rather than an HTTP proxy lease.
The plan may describe a progressive file, HLS, MPEG-DASH, request headers, and
expiry. The current Linux worker resolves it into checkpointed plain local
media; encryption-at-rest options and equivalent mobile workers remain future
work.

### Artwork colors

Native decoders produce a small RGB sample. The shared palette function scores
that pixel data; it does not spawn ffmpeg or restrict artwork to one hostname.
The visual layer derives contrast-safe accents and gradients from the result.

## Provider order

1. TIDAL account link, browse, stream, and Linux offline download — implemented
2. Public YouTube Music search/catalog, Linux playback/downloads, uploader
   pages, and real automix — implemented; optional browser-session credentials
   now add private Music library, playlist, account, and personalized-home data
3. SoundCloud public search/catalog, profiles, sets, related radio, pagination,
   Linux stream selection, locally imported account library, personalized home
   shelves, private-library pagination, quality-aware offline downloads, and
   optional uploader originals — implemented; write actions remain

## Current boundary

TIDAL search-result normalization exists in `colorful-core`. It owns ISO
duration parsing, version-aware display titles, artist and album relationships,
and artwork selection. Linux also collapses duplicate release/track variants
for display while retaining a preferred playable representation.

Android now has a complete native TIDAL vertical slice. Device authorization
survives Activity/process recreation, refresh tokens are encrypted with Android
Keystore, account country is cached from `/oauth2/me`, and the MediaSession
service owns refresh, manifest resolution, Rust queue commands, HLS Media3
playback, and periodic position checkpoints. The UI communicates with the
service through explicit Media3 session commands, so playback and queue work do
not depend on the Activity staying alive.

The desktop shell uses the TypeScript provider host for network requests,
authorization, subscription checks, and playback manifest retrieval while
those pieces are migrated behind shared provider contracts and fixtures. Its
queue, current selection, and saved library now live in the same Rust/SQLite
engine used by Android instead of transient Qt models. TIDAL similar-track and
track-radio relationships are interleaved behind the provider-neutral related-
tracks contract and feed the desktop autoplay tail without displacing manually
queued tracks. The shell owns libmpv playback, prepared-next prefetch, ReplayGain
application, and resumable ffmpeg-based offline transfers.

The desktop provider host maps public YouTube Music songs, long-form and UGC
videos, releases, credited artists, uploader channels, and their pages into the
same catalog contracts using the Music web API directly. Uploader/channel
identity stays separate from musical artist credits. The host asks the
Innertube player interface for ephemeral audio URLs. It bootstraps the current
public visitor identity and player signature timestamp, uses a typed Android VR
player request that returns directly usable audio formats, and validates the
playability response before selecting the best audio-only representation.
When the public player returns `LOGIN_REQUIRED`, the host makes an authenticated
WEB_REMIX request and uses the pinned `youtubei.js` player implementation to
transform its ciphered URL. The extracted URL is byte-range probed before being
returned. A native refresh-and-retry clears cached bootstrap/player state if
that transformation fails. Offline downloads use the same native
source contract and resumable FFmpeg chunk pipeline as the other providers.
Radio/automix now uses a typed `next` request with a native `RDAMVM<videoId>`
queue. The host reconstructs YouTube Music's opaque protobuf continuation from
the final watch endpoint and prefetches another radio window near the end of
each 49-track page; captured browser telemetry is not replayed. Android and iOS can reuse the typed
public request and response contract, but restricted playback needs an
equivalent native challenge solver.

Filtered YouTube Music search uses the current Songs and Videos filter
parameters and independently follows each native `musicShelfContinuation`.

Google currently rejects custom-client OAuth tokens on YouTube Music's private
Innertube endpoints. Linux therefore accepts a user-copied browser session and
stores its reduced header set in Secret Service; it never crosses through the
Rust database. The host exposes ordinary playlist browse continuations and the
Music `next` endpoint's server-side shuffle continuations to the desktop queue,
so large playlists start promptly and refill near the tail. Android still needs
a native account-session capture and Keystore implementation.

SoundCloud public access bootstraps from the web client's `apiClient` entry in
`window.__sc_hydration`. The client ID is cached in memory for six hours and
rediscovered after an authorization rejection; geo, privacy, and experiment
hydration are ignored. Public tracks resolve directly to SoundCloud's signed
progressive or HLS transcoding URL. No SoundCloud login credential is required
for public playback. When the user explicitly imports a copied API request,
only its OAuth token is retained in Secret Service; copied URLs, cookies,
DataDome identifiers, and browser fingerprint headers are discarded.
Authenticated home data comes from SoundCloud's mixed-selection shelves.
System-playlist URNs are retained as stable catalog identities and resolved to
their complete track lists only when opened. The first liked-track ID page and
the account's following IDs are cached with the loaded hub for future action
state without issuing one request per visible row.
