# iOS UI and design system

**Status:** Design baseline for the native iOS client, 2026-08-16.

The iOS client should feel unmistakably like colorful while respecting the
interaction patterns of iOS. It is a native SwiftUI product with a shared
visual language, not a desktop QML layout compressed onto a phone.

## Visual direction

Colorful's identity comes from its content layer:

- near-black layered backgrounds;
- bright, album-art-derived accent colors;
- sharp album tiles and compact track rows;
- restrained borders and offset block shadows;
- strong white typography with muted secondary text;
- geometric artwork that supplies color and atmosphere.

Keep most content surfaces opaque and graphic. Use small corner radii, normally
0–8 points, and reserve stronger shadows for hero artwork and primary actions.
Do not turn every surface into a rounded, blurred card.

## Native iOS layer

Use SwiftUI's standard `TabView`, `NavigationStack`, toolbars, search,
menus, sheets, alerts, and controls. On iOS versions that provide Liquid
Glass, let those official components supply the native floating control layer.
Custom Liquid Glass belongs around navigation and transient controls rather
than behind the main content.

Recommended split:

| Layer | Treatment |
| --- | --- |
| Album art, shelves, track lists, library content | Colorful's dark opaque/blocky treatment |
| Tab bar, toolbars, search, menus, queue/device sheets | Native iOS components and Liquid Glass where available |
| Play button, active track, sync state, provider badges | Colorful accent, tint, and rectangular emphasis |
| Full player background | Artwork-derived Colorful treatment with native controls above it |

For custom glass controls, prefer a lightly squared shape over a default
capsule, and use tint only to communicate prominence or state. Group related
glass controls so their transitions remain coherent. Older deployment targets
must receive an opaque/translucent fallback with the same geometry and spacing.

## Artwork-driven color

Album artwork is part of the product's visual state, not decoration. The
currently playing album should influence the full-player background, player
accent, progress tint, active-track treatment, and relevant collection hero
surfaces.

Rules:

- Derive a small palette from decoded artwork pixels, then score colors for
  saturation, luminance, and contrast instead of choosing the brightest pixel.
- Use a darkened/blurred artwork gradient behind the full player, with a
  contrast-safe foreground layer for text and controls. Native glass controls
  sit above this layer rather than being recolored until they become unreadable.
- Keep Home, Library, Offline, and Settings mostly stable and dark. Dynamic
  color should create context around the active album, not make every screen
  flash between unrelated colors.
- Animate palette changes briefly when the track changes. Respect Reduce Motion
  by switching without the transition.
- Cache the result by the stable artwork/media key. Artwork loading or palette
  extraction failure falls back to the provider accent and must never delay
  playback.
- Respect a user-selected fixed accent mode. Album mode is the default, matching
  the Linux client's existing `appearance/accentMode` contract.

The current Swift model still exposes a provider-based fallback accent on
`CoreTrack`; replacing that fallback with a shared artwork palette is a
follow-up implementation task before the iOS visual pass is considered
complete.

## Navigation model

The initial phone structure is:

- **Home:** personalized cross-provider shelves and recently played content;
- **Library:** saved tracks, albums, artists, and Colorful playlists;
- **Offline:** downloads, transfer state, storage, and offline playback;
- **Settings:** accounts, playback, appearance, storage, sync, and diagnostics.

Search is available from the native toolbar/search experience. Provider pages,
albums, artists, playlists, lyrics, and settings detail screens use a
navigation stack. The queue is a sheet. The mini-player sits above the tab
bar and expands into the full player.

Desktop-to-iOS mapping:

| Desktop surface | iOS presentation |
| --- | --- |
| `HomePage.qml` | Home tab with horizontal shelves |
| Combined search in `Main.qml` | Toolbar search and dedicated result view |
| `CatalogPage.qml` | Navigation-stack catalog screens |
| `LibraryPage.qml` | Library tab and detail screens |
| `DownloadsPage.qml` | Offline tab |
| Queue side panel | Queue sheet or player accessory |
| `LyricsPanel.qml` | Lyrics sheet/full-player section |
| `SettingsPage.qml` | Settings navigation list and detail screens |
| Party panels | Later feature, likely a sheet or focused room screen |

## Interaction rules

- Preserve a minimum 44-point hit target for controls.
- Prefer swipe-back, sheets, context menus, and long-press actions over tiny
  always-visible desktop buttons.
- Keep the primary play action available from search, catalog details, library,
  downloads, and the full player.
- Make queue state visible without forcing the user into a separate desktop
  panel.
- Support Dynamic Type, VoiceOver labels, reduced motion, increased contrast,
  and non-color indicators for playback/download/sync state.
- Use system typography for readable body content; reserve any custom display
  face for controlled branding where it does not interfere with Dynamic Type.
- Use SF Symbols for ordinary system actions and custom Colorful assets for
  brand-specific artwork or controls.

## Design tokens

The implementation should centralize these values in a SwiftUI theme rather
than scattering literals through views:

- background, elevated surface, separator, primary text, and muted text;
- current accent and contrast-safe accent foreground;
- artwork gradient and shadow treatment;
- content margins, shelf spacing, row height, and control hit size;
- typography roles and Dynamic Type policies;
- native-material availability and fallback behavior.
