# Discord Social SDK

Colorful uses Discord's Social SDK for desktop party presence, native Discord
invites, and Ask to Join. The older local Discord RPC transport remains in the
source tree for basic-presence fallback work, but it must not publish alongside
the Social SDK because Discord would show two conflicting activities.

## Developer Portal setup

The Colorful Discord application must have Social SDK enabled in the Discord
Developer Portal. In **OAuth2**, configure the desktop redirect URI:

```text
http://127.0.0.1/callback
```

For the current desktop implementation, enable **Public Client**. The client
uses PKCE, receives a code through the SDK's local callback server, and asks
the SDK to exchange it. Discord refresh tokens are stored using Colorful's
per-user credential storage; they are never sent to the party relay.

## Pinned runtime

The required SDK subset is committed under `third_party/discord_social_sdk`:

- `include/discordpp.h` and `include/cdiscord.h`
- Windows x64 release import library and `discord_partner_sdk.dll`
- Linux x64 release `libdiscord_partner_sdk.so`
- Discord's bundled open-source notices

Windows packages place the DLL beside `colorful.exe`. Linux packages install
the shared object under `usr/lib`; the desktop executable has an `$ORIGIN/../lib`
rpath, so the AppImage does not require a system-wide installation or
`LD_LIBRARY_PATH` tweak.

## Party security

Discord receives the existing opaque, revocable Colorful party ticket as the
activity join secret. It is not a raw party capability. On acceptance, the
desktop client redeems it with the Colorful relay, which issues fresh
short-lived join material. Leaving a party or disabling joins revokes its
public handle.
