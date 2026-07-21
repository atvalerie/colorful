# SoundCloud account setup

colorful can search and play public SoundCloud without an account. Connecting
adds liked tracks, liked sets, your own sets, followed profiles, and access to
resources visible to your account.

## Connect

1. Sign in at [soundcloud.com](https://soundcloud.com/) in your browser.
2. Open Developer Tools, select **Network**, and use SoundCloud normally until
   a request to `api-v2.soundcloud.com` or `api.soundcloud.com` appears.
3. Select a request whose headers contain `Authorization: OAuth …`.
4. Right-click it and choose **Copy → Copy as cURL**.
5. Open **colorful → Settings → Accounts → SoundCloud**, paste the complete
   request, and select **Connect session**.

colorful parses the request locally and retains only the OAuth token in Linux
Secret Service. The URL, cookies, DataDome value, browser fingerprint headers,
and copied request text are discarded. The token is never written to colorful's
SQLite database.

Treat the copied request like a password while it is on your clipboard. Use
**Disconnect** to delete the stored token. If SoundCloud expires the session,
repeat the steps with a new request.

This imports a session belonging to your own SoundCloud account; colorful does
not provide accounts, tokens, or a way around provider access rules.
