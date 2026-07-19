# Discord statistics widget

**Status:** Side-feature design; listening-history foundation implemented,
Discord exporter not enabled yet.

Discord's experimental Widgets v2 can render a custom application-owned view
on its owner's profile. colorful can use that view for durable listening
statistics rather than duplicating Rich Presence's current-track display.

## Data flow

```text
native playback -> qualified listen event -> local SQLite statistics
                                             |
mobile event -> encrypted device sync -------+
                                             |
                                      desktop exporter -> Discord
```

Every device records globally identified, provider-neutral listen events. Sync
merges those events idempotently. A trusted desktop calculates the combined
statistics and periodically updates the owner's Discord application widget.
When that desktop is offline, events remain local and the widget catches up on
the next sync; no colorful server needs plaintext listening history.

## Suggested fields

- top track and artist for a selected period;
- listening time and qualified play count;
- top album artwork or another optional remote image;
- an explicitly selected fun statistic such as a streak.

The custom view determines the field names and layout. The eventual exporter
maps colorful statistics to those configured names and updates only after a
qualified listen or a conservative refresh interval, not on every playback
position tick.

## Setup and secrets

Discord currently restricts custom widgets to the application owner. Each user
therefore creates and configures their own Discord application and supplies its
application ID, their Discord user ID, and a bot token. The application and
user IDs may be ordinary device-local settings. The bot token must live only in
the operating-system credential store and must never enter SQLite, logs,
exports, listening-history sync, or source control.

Provider credentials and the Discord token are not synchronized. Mobile
devices contribute listening events; an opted-in desktop performs widget
updates. The exporter must remain feature-flagged because the profile endpoint,
renderer experiment, and custom-view workflow are not a stable public Discord
API and may change without notice.
