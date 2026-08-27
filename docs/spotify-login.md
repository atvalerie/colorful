# Spotify catalog and recommendations

Spotify is an optional catalog, discovery, and recommendation source on the
desktop provider host. It does not provide audio playback in Colorful: Spotify
tracks are matched back to TIDAL by ISRC, and TIDAL remains the playback source.

## Connect Spotify

The first sign-in opens Spotify's own Web Player login page in a Chromium
profile owned by Colorful. The profile is isolated from the user's normal
browser and kept in the platform app-data directory as `spotify-browser`.
`COLORFUL_SPOTIFY_PROFILE_DIR` may be used by a packager or test harness to
select an app-owned location.

Colorful does not receive or store the Spotify password. After sign-in, the
provider host captures the Web Player's authenticated `open.spotify.com/api/token`
response and client token over the local CDP connection. Those short-lived
values stay in memory. The browser's cookie store is the durable session, and
the same profile is used by a hidden/headless browser for background refreshes.
A visible browser is therefore needed only for the initial sign-in or a later
re-authentication, not for every recommendation request. Depending on the
desktop environment, the isolated Chromium background session may briefly
appear as a browser process or taskbar icon during restore or refresh. It does
not open an interactive login page and should not repeatedly steal focus.

This is a cookie-backed Web Player session, not an OAuth `refresh_token` flow.
If Spotify invalidates the saved cookies, silent restore stops and Spotify must
be connected again. Unlinking Spotify removes the linked marker and clears the
isolated profile's cookies and site storage.

## What Colorful uses Spotify for

For a TIDAL track with an ISRC, Colorful asks the authenticated Web Player to
find Spotify track candidates for that ISRC. It verifies candidates against
Spotify track metadata, then requests related tracks from Spotify's discovery
service. The returned Spotify tracks are matched to TIDAL by ISRC before they
are offered to the queue. Spotify supplies discovery and metadata; TIDAL
supplies the playable track.

The available recommendation modes are:

- **TIDAL only** — use TIDAL related tracks and do not ask Spotify.
- **Spotify only** — always use Spotify personalization, then match results to
  playable TIDAL tracks. A linked Spotify session is required.
- **Automatic** — use TIDAL first and use Spotify when TIDAL has no usable
  recommendations or its related-track request fails. A linked Spotify session
  is required for the fallback path.

A free Spotify account is supported for this metadata and recommendation integration;
Colorful does not require Spotify Premium. The features Spotify grants to an
account or Web Player session still determine whether a particular request is
available. TIDAL access is still required to play the matched results.

## Spotify catalog

When linked, the Search view and Spotify section expose Spotify tracks,
albums, artists, playlists, saved tracks and albums, followed artists, and
personalized playlists such as Daily Mix, Discover Weekly, Release Radar, and
Daylist when Spotify includes them in the account response. Album, artist, and
playlist pages are read-only metadata views. Pagination is supported for
search results and catalog sections.

Spotify catalog tracks retain their Spotify ID and ISRC for display and
matching. A track is playable only when TIDAL returns an exact ISRC match;
unmatched metadata remains visible but cannot be queued, saved, or played.

## Account information and privacy

When available, Colorful may show the linked Spotify profile name, account ID,
subscription label, region, avatar, and profile link in Settings. This is
best-effort display metadata and is not required for recommendations. Email is
not retained or displayed.

Spotify cookies remain inside the isolated browser profile. Bearer tokens and
client tokens are kept in provider-host memory and are not written to the
Colorful SQLite database, ordinary configuration, logs, recommendation
payloads, or relay. Requests go directly from the desktop provider host to
Spotify and TIDAL; Colorful has no central account server or Spotify-token
relay.

## Current limits and future work

This integration relies partly on Spotify Web Player endpoints and response
formats, including Pathfinder and track metadata services, that Spotify may
change without notice. An internet connection and a valid Spotify session are
required.

Spotify playlist editing/import and Spotify audio playback are intentionally
not implemented. The integration is read-only on Spotify and uses the native
TIDAL playback path for matched tracks.
