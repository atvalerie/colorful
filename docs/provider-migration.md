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
- provider catalog mapping and URL resolution, ported behind portable Rust APIs
- sanitized request/response fixtures shared by the Rust core and transitional
  TypeScript host so both implementations must produce the same metadata
- TIDAL device authorization state and slow-down polling behavior
- access-token single-flight refresh behavior
- manifest parsing and quality mapping
- SoundCloud transcoding selection
- artwork palette scoring, generalized to decoded pixel input
- LRCLIB integration and synced lyric parsing

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
expiry. The download manager resolves that plan into resumable encrypted or
plain local media according to user settings and provider rules.

### Artwork colors

Native decoders produce a small RGB sample. The shared palette function scores
that pixel data; it does not spawn ffmpeg or restrict artwork to one hostname.
The visual layer derives contrast-safe accents and gradients from the result.

## Provider order

1. TIDAL account link, browse, stream, then offline download
2. SoundCloud public OAuth/catalog and stream selection
3. YouTube only after its product boundary is explicit; `yt-dlp` is suitable
   for a personal desktop helper but is a poor mobile runtime dependency

## Current boundary

TIDAL search-result normalization now exists in `colorful-core`. It owns ISO
duration parsing, version-aware display titles, artist and album relationships,
and artwork selection. The TypeScript provider host still owns network requests,
authorization, subscription checks, and playback manifest retrieval while those
pieces are migrated and covered with equivalent sanitized fixtures.
