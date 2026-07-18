# colorful Design Lab

A disposable React prototype for working out colorful's visual language before
porting approved UI and interactions into the native QML client. Nothing here
connects to TIDAL or production state.

From the repository root:

```bash
./scripts/run-design-lab.sh
```

Open `http://localhost:4173`. Vite hot reloads edits under `src/` while keeping
the browser open. The toolbar switches desktop/mobile canvases, sample screens,
and album-driven palettes.

For another device on the same LAN, open `http://<this-computer-ip>:4173`.

Static deployment output is produced with:

```bash
cd apps/design-lab
bun run build
```

The generated `dist/` directory can be served by any static host.

