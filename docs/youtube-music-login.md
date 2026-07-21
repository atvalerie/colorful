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
4. Select a `browse?...` request and copy its **request headers**. In Chromium,
   use **Copy → Copy request headers**. In Firefox, use **Copy request headers**.
5. Open **colorful → Settings → Accounts → YouTube Music**, paste the complete
   header block, and select **Connect session**.

The pasted session is stored in the operating system credential service, not in
colorful's SQLite database or configuration files. Disconnecting the account
removes it. Treat copied headers like a password: do not post or share them.

## Why not Google OAuth?

Google still issues custom-client OAuth tokens, but YouTube Music currently
rejects those tokens on its private Innertube endpoints with HTTP 400. This is
also reproducible in upstream ytmusicapi. Browser-session authentication is its
working fallback. The official YouTube Data API cannot expose a YouTube Music
library or its personalized mixes.

## Limitations

- Browser sessions can expire or be revoked. Copy a fresh `/browse` request to
  reconnect.
- This relies on YouTube Music's private web API and may require maintenance
  when Google changes it.
- Anonymous catalog search and playback continue if the session is disconnected
  or expires.
