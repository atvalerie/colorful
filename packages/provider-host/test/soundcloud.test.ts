import { describe, expect, test } from "bun:test";
import { mapSoundCloudPlaylist, mapSoundCloudTrack, parseSoundCloudAuthorization, parseSoundCloudBootstrap } from "../src/soundcloud";

describe("SoundCloud public catalog", () => {
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
});
