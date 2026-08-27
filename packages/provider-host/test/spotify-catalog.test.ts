import { describe, expect, test } from "bun:test";
import {
  SPOTIFY_CATALOG_API,
  SpotifyCatalogClient,
  mapSpotifyAlbum,
  mapSpotifyPlaylist,
  mapSpotifyTrack,
} from "../src/spotify-catalog";

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}

const trackId = "4uLU6hMCjMI75M1A2tKUQC";
const albumId = "1ATL5GLyefJaxhQzSPVrLX";
const playlistId = "37i9dQZF1DXcBWIGoYBM5M";

function track(id = trackId, isrc = "USRC17607839") {
  return {
    id,
    name: "Never Gonna Give You Up",
    artists: [{ id: "artist-1", name: "Rick Astley" }],
    album: { id: albumId, name: "Whenever You Need Somebody", images: [{ url: "https://i.scdn.co/image/album" }] },
    duration_ms: 213000,
    external_ids: { isrc },
    external_urls: { spotify: `https://open.spotify.com/track/${id}` },
    explicit: false,
  };
}

describe("Spotify catalog mapping", () => {
  test("maps Spotify tracks into common metadata with an ISRC and Spotify URL", () => {
    expect(mapSpotifyTrack(track())).toEqual(expect.objectContaining({
      provider: "spotify",
      id: trackId,
      title: "Never Gonna Give You Up",
      artists: ["Rick Astley"],
      albumId,
      isrc: "USRC17607839",
      durationMs: 213000,
      webpageUrl: `https://open.spotify.com/track/${trackId}`,
    }));
  });

  test("maps album and playlist summaries while preserving item totals", () => {
    expect(mapSpotifyAlbum({
      id: albumId, name: "Album", album_type: "album", release_date: "1987-11-01",
      artists: [{ id: "artist-1", name: "Artist" }], images: [{ url: "https://i.scdn.co/image/a" }],
      tracks: { total: 12 },
    })).toEqual(expect.objectContaining({ id: albumId, numberOfTracks: 12, albumType: "ALBUM" }));
    expect(mapSpotifyPlaylist({
      id: playlistId, name: "Mix", type: "playlist", description: "A mix",
      images: [{ url: "https://i.scdn.co/image/p" }], tracks: { total: 42 },
    })).toEqual(expect.objectContaining({ id: playlistId, numberOfItems: 42, playlistType: "PLAYLIST" }));
  });
});

describe("Spotify catalog client", () => {
  test("searches all catalog kinds and returns independent pagination cursors", async () => {
    const calls: string[] = [];
    const client = new SpotifyCatalogClient({
      sessionProvider: async () => ({ accessToken: "access-token", clientToken: "client-token" }),
      fetch: async (input, init) => {
        const url = String(input);
        calls.push(url);
        expect(new Headers(init?.headers).get("authorization")).toBe("Bearer access-token");
        expect(new Headers(init?.headers).get("client-token")).toBe("client-token");
        const type = new URL(url).searchParams.get("type");
        if (type === "track") return json({ tracks: { items: [track()], next: `${SPOTIFY_CATALOG_API}/search?type=track&offset=20` } });
        if (type === "album") return json({ albums: { items: [{ id: albumId, name: "Album", artists: [], images: [], tracks: { total: 1 } }], next: `${SPOTIFY_CATALOG_API}/search?type=album&offset=20` } });
        if (type === "artist") return json({ artists: { items: [{ id: "artist-1", name: "Artist", images: [] }], next: `${SPOTIFY_CATALOG_API}/search?type=artist&offset=20` } });
        return json({ playlists: { items: [{ id: playlistId, name: "Mix", type: "playlist", images: [], tracks: { total: 2 } }], next: `${SPOTIFY_CATALOG_API}/search?type=playlist&offset=20` } });
      },
    });
    const result = await client.searchCatalog("rick astley", 20);
    expect(calls).toHaveLength(4);
    expect(result.tracks[0]?.isrc).toBe("USRC17607839");
    expect(result.playlists[0]?.id).toBe(playlistId);
    expect(result.cursors).toEqual({ tracks: "20", albums: "20", artists: "20", playlists: "20" });
  });

  test("loads album and playlist tracks, then follows detail pagination", async () => {
    const calls: string[] = [];
    const client = new SpotifyCatalogClient({
      sessionProvider: async () => ({ accessToken: "access-token", clientToken: "client-token" }),
      fetch: async (input) => {
        const url = String(input);
        calls.push(url);
        const parsed = new URL(url);
        if (parsed.pathname.endsWith(`/albums/${albumId}`)) return json({
          id: albumId, name: "Album", artists: [], images: [], tracks: {
            items: [track()], next: `${SPOTIFY_CATALOG_API}/albums/${albumId}/tracks?offset=50`,
          },
        });
        if (parsed.pathname.endsWith(`/albums/${albumId}/tracks`)) return json({ items: [track("second-track", "USRC17607840")] });
        return json({ id: playlistId, name: "Mix", type: "playlist", images: [], tracks: { total: 1, items: [track()] } });
      },
    });
    const album = await client.albumPage(albumId);
    expect(album.tracks).toHaveLength(1);
    expect(album.trackCursor).toBe("50");
    const more = await client.detailMore("album", albumId, "tracks", album.trackCursor!);
    expect(more.tracks?.[0]?.isrc).toBe("USRC17607840");
    const playlist = await client.playlistPage(playlistId);
    expect(playlist.playlist.numberOfItems).toBe(1);
    expect(playlist.tracks[0]?.isrc).toBe("USRC17607839");
    expect(calls.some((url) => url.includes(`/albums/${albumId}/tracks`))).toBe(true);
  });

  test("hydrates ISRCs omitted by simplified album-track objects", async () => {
    const client = new SpotifyCatalogClient({
      sessionProvider: async () => ({ accessToken: "access-token", clientToken: "" }),
      fetch: async (input) => {
        const url = String(input);
        if (new URL(url).pathname.endsWith(`/albums/${albumId}`)) {
          return json({ id: albumId, name: "Album", artists: [], images: [], tracks: {
            items: [{ ...track("simplified"), external_ids: undefined }],
          } });
        }
        if (new URL(url).pathname === "/v1/tracks") return json({ tracks: [track("simplified", "USRC17607841")] });
        return json({});
      },
    });
    const page = await client.albumPage(albumId);
    expect(page.tracks[0]?.isrc).toBe("USRC17607841");
  });

  test("retries once with refreshed credentials after an expired bearer", async () => {
    let force = false;
    let requests = 0;
    const client = new SpotifyCatalogClient({
      sessionProvider: async (refresh = false) => {
        force ||= refresh;
        return { accessToken: refresh ? "new-token" : "old-token", clientToken: "client-token" };
      },
      fetch: async (_input, init) => {
        requests += 1;
        const token = new Headers(init?.headers).get("authorization");
        if (token === "Bearer old-token") return json({}, 401);
        return json(track());
      },
    });
    expect((await client.track(trackId)).isrc).toBe("USRC17607839");
    expect(requests).toBe(2);
    expect(force).toBe(true);
  });
});
