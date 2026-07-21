# YouTube Music account setup

colorful can search and play public YouTube Music without an account. Connecting
your browser session additionally enables private playlists, liked music, saved
albums and artists, and personalized mixes.

## Connect your session

1. Open a fresh private/incognito window in Firefox, Chrome, or Chromium, then
   sign in at [music.youtube.com](https://music.youtube.com/). A private session
   produces a cleaner cookie set and usually remains usable by colorful longer.
2. Open the browser developer tools and select the **Network** tab.
3. In YouTube Music, open **Library**. Filter the requests for `browse`.
4. Select a `browse?...` request. In Chromium, use **Copy → Copy as cURL**;
   some builds do not expose a separate request-headers option. In Firefox, use
   **Copy request headers**. Copy the request while the YouTube profile/channel
   whose library you want is active; colorful retains its identity header.
5. Open **colorful → Settings → Accounts → YouTube Music**, paste the complete
   header block, and select **Connect session**.

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

- Browser sessions can expire or be revoked. Copy a fresh `/browse` request to
  reconnect.
- With multiple signed-in Google accounts, capture the request from a private
  window containing only the intended account. YouTube's `X-Goog-AuthUser`
  index otherwise may select a different, empty library.
- If an older colorful build restores as signed in but shows the wrong profile
  or no private playlists, disconnect it and reconnect from a fresh request.
- This relies on YouTube Music's private web API and may require maintenance
  when Google changes it.
- Anonymous catalog search and playback continue if the session is disconnected
  or expires.
