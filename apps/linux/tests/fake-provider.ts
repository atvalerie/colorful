type Request = { id: number; type: string };

function reply(request: Request): unknown {
  if (request.type === "status") {
    return { id: request.id, ok: true, data: { linked: true, browseConfigured: true, deviceConfigured: true } };
  }
  if (request.type === "search") {
    return { id: request.id, ok: true, data: { tracks: [
      {
        id: "fixture-one",
        title: "A Very colorful Fixture",
        artists: ["Test Artist"],
        albumId: "album-one",
        albumTitle: "QML Delegate Tests",
        durationMs: 123000,
        isrc: null,
        coverUrl: null,
      },
      {
        id: "fixture-two",
        title: "The Second Fixture",
        artists: ["Another Artist"],
        albumId: "album-two",
        albumTitle: "No Runtime Errors",
        durationMs: 245000,
        isrc: null,
        coverUrl: null,
      },
    ] } };
  }
  return { id: request.id, ok: false, error: `Unsupported fixture request: ${request.type}` };
}

const reader = Bun.stdin.stream().pipeThrough(new TextDecoderStream()).getReader();
let buffered = "";
for (;;) {
  const { value, done } = await reader.read();
  if (done) break;
  buffered += value;
  for (;;) {
    const newline = buffered.indexOf("\n");
    if (newline < 0) break;
    const line = buffered.slice(0, newline).trim();
    buffered = buffered.slice(newline + 1);
    if (!line) continue;
    process.stdout.write(`${JSON.stringify(reply(JSON.parse(line) as Request))}\n`);
  }
}
