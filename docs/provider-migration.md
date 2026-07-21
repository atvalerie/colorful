# Provider migration map

The existing projects were inspected as local references:

- `../backend/src/providers/*`
- `../backend/src/modules/playback/*`
- `../backend/src/modules/downloads/*`
- `../backend/src/modules/catalog/artwork-palette.ts`
- `../backend/src/types/media.ts`
- `../mocha/server/src/providers/tidal/*`
- `../mocha/app/src/components/DeviceLink.tsx`

No secrets or `.env` values are copied into colorful.

## Reuse

- normalized media/provider types
- provider catalog mapping and URL-resolution behavior, migrated behind shared
  contracts a provider at a time
- sanitized request/response fixtures shared by the Rust core and transitional
  TypeScript host so both implementations must produce the same metadata
- TIDAL device authorization state and slow-down polling behavior
- access-token single-flight refresh behavior
- manifest parsing and quality mapping
- SoundCloud transcoding selection (planned; not present in colorful yet)
- artwork palette scoring, generalized to decoded pixel input
- LRCLIB integration and synced lyric parsing (planned)

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

Any provider client identifier or secret whose redistribution is not permitted
must be supplied locally at build/runtime and excluded from Git.

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
3. SoundCloud public OAuth/catalog and stream selection — next provider

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

The Linux shell uses the TypeScript provider host for network requests,
authorization, subscription checks, and playback manifest retrieval while
those pieces are migrated behind shared provider contracts and fixtures. Its
queue, current selection, and saved library now live in the same Rust/SQLite
engine used by Android instead of transient Qt models. TIDAL similar-track and
track-radio relationships are interleaved behind the provider-neutral related-
tracks contract and feed the desktop autoplay tail without displacing manually
queued tracks. The shell owns libmpv playback, prepared-next prefetch, ReplayGain
application, and resumable ffmpeg-based offline transfers.

The Linux provider host maps public YouTube Music songs, long-form and UGC
videos, releases, credited artists, uploader channels, and their pages into the
same catalog contracts using the Music web API directly. Uploader/channel
identity stays separate from musical artist credits. The host asks the system
`yt-dlp` only for ephemeral media URLs and as a fallback for the genuine
`RDAMVM<videoId>` radio queue. It also expands ordinary uploader channels beyond
YouTube Music's ten-item preview through their regular YouTube uploads feed.
This intentionally avoids permanent Python or third-party Rust client
dependencies. Android and iOS will use native resolvers rather than shipping
`yt-dlp`.

YouTube account authorization follows the same provider-neutral device-code
challenge used by native shells. The Linux host currently performs Google's TV
device exchange and stores the user-owned client credentials and refresh token
in Secret Service. Android will implement the exchange natively and store the
same logical credential bundle in Keystore; tokens never cross through the Rust
database.
