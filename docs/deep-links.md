# colorful links

The desktop application registers the `colorful://` URI scheme. Opening a
link starts colorful if necessary, or forwards the link to the existing
desktop instance.

Supported catalog links are:

```text
colorful://track/<provider>/<id>
colorful://album/<provider>/<id>
colorful://artist/<provider>/<id>
colorful://playlist/<provider>/<id>
```

`provider` is one of `tidal`, `youtube`, or `soundcloud`. The identifier must
be percent-encoded when it contains reserved URL characters. Links open the
catalog page; they do not start playback or transfer provider credentials.

Linux registers the scheme through the installed desktop entry. Windows
registers it for the current user through the Inno Setup installer. Portable
Windows archives do not modify the registry automatically.

The reserved private party form is:

```text
colorful://party/<relay-session>#<private-fragment>
```

The fragment contains both the relay guest capability and a distinct
end-to-end party secret. It is deliberately absent from server requests and
social preview metadata. The desktop dispatches this form into the experimental
party join panel.

The Discord public Join Party form is:

```text
https://colorful.valerie.sh/discord/join#v1.<ticket-lookup>.<bootstrap-key>
colorful://discord/join#v1.<ticket-lookup>.<bootstrap-key>
```

The two URL-safe 32-byte values form a 90-second, one-use ticket. The landing
page preserves `location.hash` client-side and carries it into the custom URI;
the fragment is never sent in the HTTPS request. On redemption, colorful sends
only `ticket-lookup` to the relay. The relay returns encrypted bootstrap
ciphertext, and the client uses the locally retained `bootstrap-key` to unwrap
the private invite. Native Discord Ask-to-Join uses the same opaque stable
handle as a Discord activity join secret. Discord shares that secret only after
the host approves the request; Colorful then mints a fresh one-use ticket and
opens this same join path.
