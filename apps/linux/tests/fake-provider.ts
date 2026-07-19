type Request = { id: number; type: string; payload?: Record<string, unknown> };

const track = {
  id: "fixture-one",
  title: "A Very colorful Fixture",
  version: null,
  artists: ["Test Artist"],
  artistCredits: [{ id: "artist-one", name: "Test Artist" }],
  albumId: "album-one",
  albumTitle: "QML Delegate Tests",
  durationMs: 123000,
  isrc: null,
  coverUrl: null,
};

function reply(request: Request): unknown {
  if (request.type === "status") {
    return { id: request.id, ok: true, data: { linked: true, browseConfigured: true, deviceConfigured: true } };
  }
  if (request.type === "search") {
    return { id: request.id, ok: true, data: { tracks: [
      track,
      {
        id: "fixture-two",
        title: "The Second Fixture",
        version: null,
        artists: ["Another Artist"],
        artistCredits: [{ id: "artist-two", name: "Another Artist" }],
        albumId: "album-two",
        albumTitle: "No Runtime Errors",
        durationMs: 245000,
        isrc: null,
        coverUrl: null,
      },
    ], albums: [{
      id: "album-one", title: "QML Delegate Tests", version: null,
      artists: ["Test Artist"], artistCredits: [{ id: "artist-one", name: "Test Artist" }],
      coverUrl: null, releaseDate: "2026-07-19", durationMs: 123000,
      numberOfTracks: 1, albumType: "ALBUM", explicit: false,
    }], artists: [{ id: "artist-one", name: "Test Artist", pictureUrl: null }] } };
  }
  if (request.type === "detail" && request.payload?.kind === "track") {
    return { id: request.id, ok: true, data: { kind: "track", track, relatedTracks: [track] } };
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
