# YouTube Music account setup

colorful can search and play public YouTube Music without an account. Connecting
an account additionally enables its private library, saved albums and artists,
private playlists, and personalized mixes.

colorful does not ship a shared Google OAuth client. You create and control the
credentials used by your installation.

## Create the credentials

1. Open the [Google Cloud Console](https://console.cloud.google.com/).
2. Create or select a project.
3. Open **APIs & Services → Library** and enable **YouTube Data API v3**.
4. Configure the OAuth consent screen. For a personal project, keeping the app
   in testing and adding your Google account as a test user is sufficient.
5. Open **APIs & Services → Credentials**.
6. Create an **OAuth client ID** with application type
   **TVs and Limited Input devices**.
7. Copy its client ID and client secret.

## Connect colorful

1. Open **Settings → Accounts → YouTube Music**.
2. Paste the client ID and client secret, then select **Connect**.
3. Open the Google approval page shown by colorful and enter the device code.
4. Choose the YouTube identity whose Music library you want to use.

The client credentials and refresh token are stored together in the operating
system credential service. They are never written to colorful's SQLite database
or configuration files. Disconnecting the account removes the stored entry.

## Limitations

- This uses the same custom-client OAuth approach documented by ytmusicapi and
  the YouTube scope requested by its device flow.
- Google may show an unverified-app warning for a personal testing project.
- OAuth access does not expose uploaded-music management. That requires browser
  session authentication, which colorful deliberately does not request.
- Brand-account selection is not implemented yet.

Anonymous catalog and playback continue to work if the account is disconnected
or the private-library request fails.
