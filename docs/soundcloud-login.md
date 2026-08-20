# SoundCloud account setup

colorful can search and play public SoundCloud without an account. Connecting
adds personalized home shelves, liked tracks, liked sets, your own sets,
followed profiles, profile recommendations, and access to resources visible to
your account.

## Connect with a browser

1. Open **colorful → Settings → Accounts → SoundCloud** and select **Sign in**.
2. colorful opens an installed Chromium-based browser with an isolated temporary
   profile. Helium, Chrome, Edge, Chromium, Brave, Vivaldi, and Opera are
   discovered on Windows, Linux, and macOS; `COLORFUL_BROWSER_EXECUTABLE` can
   select another compatible build.
3. Sign in and open your Library. colorful recognizes the authenticated account
   request, verifies the account, closes the browser, and removes the profile.

The password and browser cookies are never retained. colorful extracts and
stores only SoundCloud's OAuth session token in the operating system credential
service.

## Manual fallback

If a supported Chromium-based browser is unavailable, sign in at
[soundcloud.com](https://soundcloud.com/), open Developer Tools, and use
SoundCloud normally until
   a request to `api-v2.soundcloud.com` or `api.soundcloud.com` appears.
Select a request whose headers contain `Authorization: OAuth …`, choose
**Copy → Copy as cURL**, then paste the complete
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

## Mobile and future OAuth flow

The browser-capture helper is a desktop adapter, not part of the SoundCloud
provider contract. SoundCloud's current public API supports OAuth 2.1
authorization code with PKCE and custom callback schemes for desktop and mobile
apps. A future iOS adapter should use `ASWebAuthenticationSession`; Android
should use a Custom Tab and verified callback. Both can then pass the verified
token into the same provider/session contract.

SoundCloud currently classifies all registered clients as confidential and
requires a client secret during token exchange. colorful must therefore use a
properly registered deployment and safe exchange design before enabling that
flow; it must not embed a reusable client secret in a mobile or desktop binary.
See the [official SoundCloud API authentication guide](https://developers.soundcloud.com/docs/api/).
Until that deployment exists, trusted-device sync may explicitly transfer the
minimal verified SoundCloud credential from desktop. This remains an opt-in
secure-store import, not ordinary account synchronization.
