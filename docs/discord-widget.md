# Discord statistics widget

> [!WARNING]
> Discord Widgets v2 is an experimental, undocumented profile feature. Discord
> currently restricts custom widgets to the owner of the application that
> defines them. Portal experiments, endpoints, scopes, payloads, and rendering
> behavior may change or disappear without notice.

**colorful status:** qualified history, all-time track/artist/album aggregates,
Secret Service token storage, and the opt-in Linux exporter are implemented.
Multi-period selection and cross-device history are not implemented yet.

This guide is adapted and paraphrased from Chloe Cinders' excellent
[How to make Discord widgets](https://chloecinders.com/archived/discord-widgets)
tutorial. Use the original guide for current Developer Portal experiment
snippets and screenshots. Do not assume an old snippet is safe or functional
without reading it first.

## What colorful's widget is—and is not

Rich Presence describes the track playing right now. The profile widget
instead presents durable all-time statistics such as:

- top artist, track, and album;
- qualified play count and listening time;
- top album artwork;
- a compact mini-profile and activity summary.

All aggregation happens on the user's devices:

```text
native playback -> qualified listen event -> local SQLite statistics
                                             │
mobile event -> encrypted device sync -------┤
                                             │
                                      desktop exporter -> Discord
```

If the opted-in desktop is offline, the widget simply remains stale until that
desktop receives newer events and refreshes it. No colorful server needs the
plaintext history or a Discord credential.

## Before starting

You need:

- a Discord account with Developer Mode enabled;
- access to the [Discord Developer Portal](https://discord.com/developers/applications);
- a Discord application that you personally own;
- comfort using browser developer tools and experimental features;
- a safe place in the OS credential store for the eventual bot token; and
- acceptance that Discord may break or remove the widget.

Do not paste a Discord bot token into an issue, chat, screenshot, source file,
`.env` committed to Git, shell history, or colorful's SQLite database. Reset it
immediately in the Developer Portal if it is exposed.

## 1. Create the Discord application

1. Open the Discord Developer Portal and create a new application for your
   personal colorful widget.
2. Record its **Application ID**. This is not the bot token and does not need to
   be treated as a secret.
3. In **OAuth2**, register `http://127.0.0.1/callback` as a Redirect URI, or
   register another URI that you will enter into colorful. The values must
   match exactly.
4. In the application's **Games → Social SDK** area, complete the access form.
   The archived tutorial identifies Widgets v2 as part of this access.
5. Return to the application overview after access is enabled.

Discord's navigation and eligibility rules can change. If the Social SDK or
Games section is absent, consult the current portal and the original tutorial
before trying to force an outdated workflow.

## 2. Enable the widget configuration editor

The widget editor is hidden behind a Developer Portal experiment. The archived
guide currently enables `2026-03-widget-config-editor` with Variant 1 through
the browser console.

1. Open the original tutorial at
   [Setting up your Application and Developer Portal](https://chloecinders.com/archived/discord-widgets#setting-up-your-application-and-developer-portal).
2. Read the warning and inspect the current snippet before running it. Browser
   console snippets execute with the privileges of the page you are logged into.
3. Run the tutorial's current editor-enablement snippet in the Developer Portal
   console.
4. Use the portal's back navigation and reopen the application as described by
   the tutorial. Refreshing may discard the temporary experiment override.
5. Confirm that a **Widget** page appears in the application's Games section.

colorful deliberately does not vendor the Webpack snippet: it is Discord
implementation detail, changes independently of colorful, and is maintained by
the tutorial's author.

## 3. Design the colorful widget

Create a widget in the editor and complete all required surfaces:

- **Widget Top**
- **Widget Bottom**
- **Add Widget Preview**

The editor distinguishes static application content from per-user data. Use
static strings/assets for branding and **User Data** for values colorful will
refresh. Provide useful fallbacks so a new or temporarily stale profile does
not look broken.

The published colorful widget uses this fixed first-version contract:

| Field | Kind | Example |
| --- | --- | --- |
| `top_artwork` | dynamic remote image | top-album artwork URL |
| `top_title` | dynamic text | `Most Played Album` |
| `top_subtitle_1` | dynamic text | `Album - Artist` |
| `top_subtitle_2` | dynamic text | album play count |
| `total_listened` | dynamic number/duration | listened milliseconds, rounded to one second |
| `play_count` | dynamic number | qualified plays |
| `top_artist_name` | dynamic text | most-listened artist |
| `top_artist_plays` | dynamic number | qualified plays credited to that artist |
| `top_track_name` | dynamic text | most-listened track |
| `top_track_plays` | dynamic number | qualified plays on that track |
| `mini_label` | dynamic text | `Most Played Track` |
| `mini_text` | dynamic text | `Track - Artist` |
| `mini_artwork` | dynamic remote image | top-track artwork URL |
| `activity_summary` | dynamic text | compact all-time summary |

The exact published surface definition is stored in
[`discord-widget-config.json`](discord-widget-config.json), with a matching
[`sample profile`](discord-widget-profile.sample.json). Field names can become
configurable later; the initial personal build deliberately targets this one
known layout.

Use the editor's **Sample Data** panel to populate every dynamic field, inspect
the filled-in design, and generate its JSON. Save that generated JSON locally
without adding secrets. Then save and publish the widget.

A colorful payload has this general shape:

```json
{
  "username": "colorful",
  "data": {
    "dynamic": [
      { "type": 1, "name": "top_title", "value": "Most Played Album" },
      { "type": 1, "name": "top_artist_name", "value": "Someone" },
      { "type": 2, "name": "play_count", "value": 613 },
      { "type": 3, "name": "top_artwork", "value": { "url": "https://example.invalid/art.jpg" } }
    ]
  }
}
```

Treat the numeric `type` values as experimental Discord protocol details, not a
stable colorful contract.

## 4. Authorize the application

According to the archived workflow, the widget identity must be authorized to
use Discord's social layer:

1. Add an OAuth2 redirect URI in the application. Use a URI you control or can
   safely complete; do not deploy a public redirect that leaks tokens.
2. Generate an authorization URL containing the `openid` and
   `sdk.social_layer` scopes.
3. Select the configured redirect URI.
4. Follow the original guide's current response-type instructions and open the
   generated URL while logged into the widget owner's Discord account.
5. Check Discord's **Authorized Apps** settings and verify that the application
   is present before continuing.

The requested social-layer authorization can display broad permissions. Do not
authorize an application you do not own and trust.

## 5. Prepare the application identity

An owner-only widget needs a profile identity. The archived tutorial creates or
updates identity `0` with:

```text
PATCH /api/v9/applications/{application_id}/users/{discord_user_id}/identities/0/profile
Authorization: Bot {bot_token}
```

The body contains the published widget's dynamic user-data payload. colorful
uses the locally selected Discord application and the published field mapping.
It normally learns the Discord User ID from the local Rich Presence IPC `READY`
event, but the integration panel provides an owner-ID override for multi-client
and multi-account setups. Only the bot token is secret.

Enter the token only in colorful's local integration panel. Linux passes it to
Secret Service over standard input; it never enters SQLite, command-line
arguments, logs, or sync. Mobile devices do not need it.

## 6. Add the widget to your profile

The archived guide reports a second renderer experiment,
`2026-03-application-widget-v2-renderer`, using Variant 1. It also points to the
Discord Previews community for the current client/browser snippets that add the
owner's widget to the profile or make it appear in the **Add Widget** menu.

1. Read the tutorial's current
   [Displaying the Widget on your Profile](https://chloecinders.com/archived/discord-widgets#displaying-the-widget-on-your-profile)
   section.
2. Enable the renderer experiment only if you understand the current snippet.
3. Add the widget to the same account that owns the application.
4. Open the profile from another account or session to confirm that the widget
   is actually visible rather than only locally previewed.

Discord Previews currently provides this universal auto-add snippet. Run it in
the Discord desktop/web client console only after reading it, and replace
`APPLICATION_ID` with the application snowflake configured in colorful:

```js
let _mods = webpackChunkdiscord_app.push([[Symbol()], {}, e => e.c]);
webpackChunkdiscord_app.pop();

let findByProps = (...props) => {
    for (let module of Object.values(_mods)) {
        try {
            if (!module.exports || module.exports === window) continue;
            if (props.every(prop => module.exports?.[prop])) return module.exports;
            for (let key in module.exports) {
                if (props.every(prop => module.exports?.[key]?.[prop])
                    && module.exports[key][Symbol.toStringTag] !== "IntlMessagesProxy") {
                    return module.exports[key];
                }
            }
        } catch {}
    }
};

const api = findByProps("Bo", "Cu").Bo;
async function addWidget(appId) {
    const id = findByProps("getCurrentUser").getCurrentUser().id;
    const currentWidgets = (await api.get("/users/" + id + "/profile")).body.widgets;
    if (currentWidgets.map(widget => widget.data?.application_id).includes(appId)) {
        console.log("Already in your widgets — remove it via Discord to re-add");
        return;
    }
    currentWidgets.unshift({data: {type: "application", application_id: appId}});
    await api.put({url: "/users/@me/widgets", body: {widgets: currentWidgets}});
}

addWidget("APPLICATION_ID");
```

This calls Discord's own profile and widget endpoints as the currently logged-in
user. It does not need a bot token. The Webpack module names are private Discord
implementation details and can stop working without notice. Never paste a bot
token or OAuth access token into the Discord console.

Because owner-only restrictions were introduced specifically to curb arbitrary
custom widgets, do not attempt to impersonate Discord staff, mislead viewers,
or bypass the ownership restriction.

## 7. Configure colorful

1. Open **Settings → Integrations** in the Linux client.
2. Enter the Application ID of the Discord application that owns your widget
   configuration and select **Save application ID**. This ID is also used for
   Rich Presence.
3. Enter the exact OAuth2 Redirect URI registered in the Developer Portal and
   select **Save redirect URI**. The default is Discord's documented desktop
   Social SDK URI, `http://127.0.0.1/callback`.
4. Make sure Discord has connected to colorful at least once so the owner ID is
   discovered automatically. Verify the displayed ID against Discord's
   **Developer Mode → Copy User ID** value. If another local Discord client or
   account was detected, enter the correct ID and select **Save owner ID**.
5. Select **Authorize widget** and approve the `openid` and
   `sdk.social_layer` request in Discord. The implicit access token in the final
   redirect URL is not needed by colorful and must not be copied into the bot
   token field.
6. Paste the application bot token into **Discord playback statistics** and select
   **Store token**. The token field clears immediately.
7. Select **Publish now** after the first qualified listen if an immediate test
   is needed.
8. Use **Disable** to stop publishing without deleting the credential, or
   **Forget token** to remove it from Secret Service.

The application and widget layouts are user-owned and can be styled independently.
The dynamic data field names must currently match the contract in this guide.
Bot tokens are stored separately for each Application ID.

Automatic publishing is coalesced, skips identical payloads, and runs no more
than once every 15 minutes. A manual publish is limited to once per minute.
Discord failures never affect playback or listening-history persistence.

## Troubleshooting checklist

- **Widget page missing:** re-check Social SDK access and the current editor
  experiment; an old portal snippet may have expired.
- **Only fallback values appear:** confirm that sample/published field names and
  payload names match exactly.
- **Stats still syncing:** open Discord once so IPC can identify the owner, then
  verify authorization, application ownership, identity `0`, and the PATCH response.
- **Discord code 50025:** complete the Social SDK form, then authorize again
  with `response_type=token` and a Redirect URI that exactly matches one
  registered under OAuth2; the application identity's OAuth2 authorization is
  missing or invalid. Also verify that the displayed owner ID is the same
  account that completed authorization.
- **Discord code 50026:** authorize again with both `openid` and
  `sdk.social_layer` scopes.
- **HTTP 401 / Discord code 50014:** reset the application bot token and use
  **Replace token** locally.
- **Widget visible only to you:** verify the application identity and inspect the
  profile from another account/session.
- **Invalid scope:** confirm Social SDK access and consult the current tutorial.
- **Bot token exposed:** reset it immediately, then replace the locally stored
  credential.
- **Widget disappears after a Discord update:** assume the experiment changed;
  disable the exporter and consult current Discord Previews information.

## Security and sync rules

- Bot tokens and provider credentials never enter SQLite or sync.
- The user ID learned from Discord IPC is a device-local, non-secret setting.
- Listening events already use globally unique IDs and merge idempotently; the
  transport that will exchange them is still planned.
- Once sync exists, a trusted desktop computes the combined statistics and
  publishes them.
- Revoking the Discord credential disables publishing without deleting history.
- The widget adapter remains optional and feature-flagged.

## Attribution and further reading

- [Chloe Cinders: How to make Discord widgets](https://chloecinders.com/archived/discord-widgets)
- [Discord Developer Portal](https://discord.com/developers/applications)
- [xivwidget example implementation](https://github.com/chloecinders/xivwidget)

The setup research and experimental discovery belong to the tutorial's author
and the Discord Previews contributors credited there. colorful's documentation
adds only the project-specific statistics, secret-storage, and sync design.
