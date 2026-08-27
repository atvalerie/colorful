# Spotify account setup

Spotify account access on the desktop provider host uses Spotify's own Web
Player login page in a Colorful-owned Chromium profile. The profile is kept in
the platform app-data directory (`spotify-browser`) and is isolated from the
user's normal browser profile. `COLORFUL_SPOTIFY_PROFILE_DIR` may be used by a
packager or test harness to select an app-owned location.

After the initial sign-in, Colorful captures the Web Player's authenticated
`open.spotify.com/api/token` response and client token over the local CDP
connection. It keeps those short-lived values in memory only. The browser's
cookie store remains the durable session; access-token refresh calls run inside
the same hidden/headless browser process with those cookies, so a visible
browser is not opened for each recommendation request.

If Spotify invalidates the profile cookies, silent restore fails and the user
must reconnect through the visible Spotify login flow. This is not an OAuth
`refresh_token` flow: Spotify's first-party Web Player endpoint mints the
short-lived bearer from its authenticated cookie session.

The isolated profile is deliberately not copied into Colorful's SQLite
database, ordinary configuration, logs, recommendation payloads, or relay.
