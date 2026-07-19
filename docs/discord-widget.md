# Discord statistics widget

> [!WARNING]
> Discord Widgets v2 is an experimental, undocumented profile feature. Discord
> currently restricts custom widgets to the owner of the application that
> defines them. Portal experiments, endpoints, scopes, payloads, and rendering
> behavior may change or disappear without notice.

**colorful status:** qualified listening history and local statistics are
implemented. Widget setup UI, Secret Service storage, and the Discord exporter
are not implemented yet.

This guide is adapted and paraphrased from Chloe Cinders' excellent
[How to make Discord widgets](https://chloecinders.com/archived/discord-widgets)
tutorial. Use the original guide for current Developer Portal experiment
snippets and screenshots. Do not assume an old snippet is safe or functional
without reading it first.

## What colorful's widget is—and is not

Rich Presence describes the track playing right now. The proposed profile
widget instead presents durable statistics such as:

- top artist and track for a chosen period;
- qualified play count and listening time;
- top album artwork;
- an optional streak or another explicitly selected statistic.

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
3. In the application's **Games → Social SDK** area, complete the access form.
   The archived tutorial identifies Widgets v2 as part of this access.
4. Return to the application overview after access is enabled.

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

Recommended colorful data-field names:

| Field | Kind | Example |
| --- | --- | --- |
| `period` | dynamic text | `Last 30 days` |
| `top_artist` | dynamic text | `Someone` |
| `top_track` | dynamic text | `A very good track` |
| `listening_time` | dynamic text | `42h 18m` |
| `play_count` | dynamic number | `613` |
| `top_artwork` | dynamic remote image | album artwork URL |

The names are a proposed colorful convention, not Discord-reserved fields. If
you choose different names, the future colorful exporter must be configured to
match them exactly.

Use the editor's **Sample Data** panel to populate every dynamic field, inspect
the filled-in design, and generate its JSON. Save that generated JSON locally
without adding secrets. Then save and publish the widget.

A future colorful payload will have this general shape:

```json
{
  "username": "colorful",
  "data": {
    "dynamic": [
      { "type": 1, "name": "period", "value": "Last 30 days" },
      { "type": 1, "name": "top_artist", "value": "Someone" },
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

The body contains the published widget's dynamic user-data payload. You will
eventually provide colorful with:

- the non-secret Discord Application ID;
- your non-secret Discord User ID;
- the exact dynamic-field mapping; and
- the bot token, entered locally into the OS credential store.

Do not send the bot token to the maintainer. The planned colorful setup flow
will accept it locally, verify the identity request, store it through Secret
Service/Credential Locker, and discard the plaintext input. Mobile devices do
not need it; only an opted-in desktop exporter does.

Until that exporter exists, follow the original tutorial's
[Application Identities](https://chloecinders.com/archived/discord-widgets#application-identities)
section if you want to test the identity manually. Prefer an interactive secret
input over embedding the token in a command that will remain in shell history.

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

Because owner-only restrictions were introduced specifically to curb arbitrary
custom widgets, do not attempt to impersonate Discord staff, mislead viewers,
or bypass the ownership restriction.

## 7. Configure colorful when the exporter lands

The planned desktop configuration will include:

```text
enabled             false by default
application_id      device-local setting
discord_user_id     device-local setting
identity_id         0 by default
period              7 days / 30 days / all time
field_mapping       user-configurable names
bot_token           OS credential store only
minimum_refresh     conservative rate limit
```

The exporter will refresh after a qualified listen changes aggregate values or
after a conservative interval. It will not PATCH Discord on every position
update. Failures will never interrupt playback or corrupt listening history.

## Troubleshooting checklist

- **Widget page missing:** re-check Social SDK access and the current editor
  experiment; an old portal snippet may have expired.
- **Only fallback values appear:** confirm that sample/published field names and
  payload names match exactly.
- **Stats still syncing:** verify authorization, application ownership, Discord
  user ID, identity `0`, and the identity PATCH response.
- **Widget visible only to you:** verify the application identity and inspect the
  profile from another account/session.
- **Invalid scope:** confirm Social SDK access and consult the current tutorial.
- **Bot token exposed:** reset it immediately, then replace the locally stored
  credential.
- **Widget disappears after a Discord update:** assume the experiment changed;
  disable the exporter and consult current Discord Previews information.

## Security and sync rules

- Bot tokens and provider credentials never enter SQLite or sync.
- Application/user IDs and field mappings may remain device-local settings.
- Listening events sync with globally unique IDs and merge idempotently.
- A trusted desktop computes the combined statistics and publishes them.
- Revoking the Discord credential disables publishing without deleting history.
- The widget adapter remains optional and feature-flagged.

## Attribution and further reading

- [Chloe Cinders: How to make Discord widgets](https://chloecinders.com/archived/discord-widgets)
- [Discord Developer Portal](https://discord.com/developers/applications)
- [xivwidget example implementation](https://github.com/chloecinders/xivwidget)

The setup research and experimental discovery belong to the tutorial's author
and the Discord Previews contributors credited there. colorful's documentation
adds only the project-specific statistics, secret-storage, and sync design.
