import { describe, expect, test } from "bun:test";
import { mapSoundCloudHome, mapSoundCloudPlaylist, mapSoundCloudTrack, parseSoundCloudAuthorization, parseSoundCloudBootstrap, selectSoundCloudTranscoding } from "../src/soundcloud";

describe("SoundCloud public catalog", () => {
  test("prefers progressive audio for playback and offline downloads", () => {
    const selected = selectSoundCloudTranscoding([
      { url: "hls", preset: "opus_0_0", format: { protocol: "hls", mime_type: "audio/ogg; codecs=opus" } },
      { url: "progressive", preset: "mp3_0_1", format: { protocol: "progressive", mime_type: "audio/mpeg" } },
    ]);
    expect(selected?.url).toBe("progressive");
  });

  test("falls back to HLS when no progressive transcoding exists", () => {
    const selected = selectSoundCloudTranscoding([
      { url: "hls", preset: "opus_0_0", format: { protocol: "hls", mime_type: "audio/ogg; codecs=opus" } },
    ]);
    expect(selected?.url).toBe("hls");
  });

  test("discovers the public API client from homepage hydration", () => {
    const html = `<script>window.__sc_hydration = [
      {"hydratable":"features","data":{"value":"quoted ] bracket"}},
      {"hydratable":"statsigClientInitializeResponse","data":{"configString":"{\\"appVersion\\":\\"1784221259\\"}"}},
      {"hydratable":"apiClient","data":{"id":"public-client-id","isExpiring":false}}
    ];</script>`;
    expect(parseSoundCloudBootstrap(html)).toEqual({
      clientId: "public-client-id",
      appVersion: "1784221259",
    });
  });

  test("maps public tracks with profile identity and larger artwork", () => {
    expect(mapSoundCloudTrack({
      id: 42,
      kind: "track",
      title: "A loud thing",
      full_duration: 123_456,
      artwork_url: "https://i1.sndcdn.com/artworks-test-large.jpg",
      publisher_metadata: { album_title: "A set", isrc: "PL-TEST-26", explicit: true },
      user: { id: 7, username: "Someone" },
    })).toEqual(expect.objectContaining({
      provider: "soundcloud",
      id: "42",
      title: "A loud thing",
      durationMs: 123_456,
      artists: ["Someone"],
      artistCredits: [{ id: "7", name: "Someone" }],
      albumTitle: "A set",
      coverUrl: "https://i1.sndcdn.com/artworks-test-t500x500.jpg",
    }));
  });

  test("keeps only the OAuth token from a copied cURL request", () => {
    expect(parseSoundCloudAuthorization(`curl 'https://api-v2.soundcloud.com/me' \\
      -H 'Accept: application/json' \\
      -H 'Authorization: OAuth account-token' \\
      -H 'x-datadome-clientid: fingerprint'`)).toBe("account-token");
    expect(parseSoundCloudAuthorization("Authorization: OAuth raw-header-token"))
      .toBe("raw-header-token");
    expect(() => parseSoundCloudAuthorization("curl https://soundcloud.com"))
      .toThrow("Authorization: OAuth");
  });

  test("maps sets into collection cards without losing their size", () => {
    expect(mapSoundCloudPlaylist({
      id: 99,
      kind: "playlist",
      title: "All night",
      track_count: 84,
      duration: 7_200_000,
      set_type: "playlist",
      user: { id: 7, username: "Someone" },
    })).toEqual(expect.objectContaining({
      provider: "soundcloud",
      id: "99",
      title: "All night",
      numberOfTracks: 84,
      albumType: "PLAYLIST",
    }));
  });

  test("maps personalized home shelves and system playlists", () => {
    expect(mapSoundCloudHome({ collection: [{
      title: "Made for you",
      items: { collection: [{
        id: "soundcloud:system-playlists:weekly:42",
        kind: "system-playlist",
        title: "Weekly Wave",
        short_description: "Updated every Monday",
        calculated_artwork_url: "https://i1.sndcdn.com/artworks-test-large.jpg",
        playlist_type: "PLAYLIST",
        tracks: [{ id: 1 }, { id: 2 }],
        user: { id: 193, username: "SoundCloud" },
      }] },
    }] } as any)).toEqual([{
      title: "Made for you",
      items: [expect.objectContaining({
        id: "soundcloud:system-playlists:weekly:42",
        title: "Weekly Wave",
        artists: ["Updated every Monday"],
        coverUrl: "https://i1.sndcdn.com/artworks-test-t500x500.jpg",
        numberOfTracks: 2,
      })],
    }]);
  });
});
