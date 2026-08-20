# YouTube Music account setup

colorful can search and play public YouTube Music without an account. Connecting
your browser session additionally enables private playlists, liked music, saved
albums and artists, and personalized mixes.

## Connect with a browser

1. Open **colorful → Settings → Accounts → YouTube Music** and select **Sign in**.
2. colorful opens an installed Chromium-based browser with an isolated temporary
   profile. Helium, Chrome, Edge, Chromium, Brave, Vivaldi, and Opera are
   discovered on Windows, Linux, and macOS; `COLORFUL_BROWSER_EXECUTABLE` can
   select another compatible build.
   Current Helium Windows builds have an upstream Google sign-in rejection, so
   colorful selects another installed browser for YouTube Music when possible.
3. Sign in, choose the YouTube profile/channel whose library you want, and open
   **Library**. colorful recognizes the authenticated request, verifies the
   selected account, closes the temporary browser, and removes its profile.

The browser is a separate, normal Chromium window rather than an embedded web
view. colorful observes only that isolated window over a loopback connection;
the password and form contents never enter colorful. Only the minimal YouTube
Music cookie and account-selection headers are retained in the operating system
credential service.

## Manual fallback

If a supported Chromium-based browser is unavailable, sign in at
[music.youtube.com](https://music.youtube.com/), open Developer Tools and find a
logged-in `/youtubei/v1/browse` request. In Chromium, use **Copy → Copy as cURL**;
   some builds do not expose a separate request-headers option. In Firefox, use
**Copy request headers**. Paste it into the manual fallback field and select
**Connect session**.

The pasted session is stored in the operating system credential service, not in
colorful's SQLite database or configuration files. Disconnecting the account
removes it. Treat copied headers like a password: do not post or share them.
colorful verifies that YouTube returns an active account before marking the
session connected; a public HTTP 200 response is not treated as authentication.

## Why not Google OAuth?

Google still issues custom-client OAuth tokens, but YouTube Music currently
rejects those tokens on its private Innertube endpoints with HTTP 400. This is
also reproducible in upstream ytmusicapi. Browser-session authentication is its
working fallback. The official YouTube Data API cannot expose a YouTube Music
library or its personalized mixes.

## Limitations

- Browser sessions can expire or be revoked. Select **Reconnect** to repeat the
  isolated browser flow.
- With multiple YouTube profiles/channels, select the intended profile before
  opening Library. colorful retains the profile-selection identity header.
- If an older colorful build restores as signed in but shows the wrong profile
  or no private playlists, disconnect it and reconnect from a fresh request.
- This relies on YouTube Music's private web API and may require maintenance
  when Google changes it.
- Anonymous catalog search and playback continue if the session is disconnected
  or expires.

## Mobile boundary

The DevTools capture helper is desktop-only. It is not compiled into or treated
as a dependency of the iOS or Android provider implementations. A normal native
OAuth callback cannot return YouTube Music's HttpOnly browser cookies, and the
official YouTube Data API does not expose a YouTube Music library. Account
library support on mobile therefore remains a separate adapter problem; public
catalog and playback must continue to work without it. We should not hide a web
view or copy the desktop CDP mechanism into a mobile shell. Once trusted-device
sync is implemented, the user may explicitly send the verified, minimal browser
session from desktop over the end-to-end encrypted pairing channel. The mobile
shell must verify it and import it directly into Keychain or Keystore; provider
device binding may still reject the transferred session.
