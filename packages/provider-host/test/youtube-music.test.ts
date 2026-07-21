import { describe, expect, test } from "bun:test";
import { mapYouTubeMusicCollectionDocuments } from "../src/youtube-music";
import { parseYouTubeBrowserHeaders } from "../src/youtube-auth";

describe("authenticated YouTube Music mapping", () => {
  test("reads browser authentication from Chromium Copy as cURL", () => {
    const headers = parseYouTubeBrowserHeaders(String.raw`curl 'https://music.youtube.com/youtubei/v1/browse' \
      -H 'x-goog-authuser: 0' \
      -H 'cookie: SID=ignored; __Secure-3PAPISID=private-value; PREF=music' \
      -H 'user-agent: colorful-test'`);
    expect(headers["x-goog-authuser"]).toBe("0");
    expect(headers.cookie).toContain("__Secure-3PAPISID=private-value");
    expect(headers["user-agent"]).toBe("colorful-test");
  });

  test("maps private playlists and personalized mixes without confusing their IDs", () => {
    const playlist = (title: string, id: string) => ({
      musicTwoRowItemRenderer: {
        title: { runs: [{ text: title }] },
        subtitle: { runs: [{ text: "12 songs" }] },
        navigationEndpoint: { browseEndpoint: { browseId: `VL${id}` } },
        thumbnailRenderer: { musicThumbnailRenderer: { thumbnail: { thumbnails: [
          { url: `https://example.test/${id}.jpg`, width: 256, height: 256 },
        ] } } },
      },
    });
    const result = mapYouTubeMusicCollectionDocuments({
      songs: {}, albums: {}, artists: {},
      playlists: { contents: [playlist("Private list", "PL_PRIVATE")] },
      home: { contents: [playlist("My Mix", "RDCLAK_MIX")] },
    });
    expect(result.playlists).toEqual([expect.objectContaining({
      id: "PL_PRIVATE", name: "Private list", numberOfItems: 12,
    })]);
    expect(result.mixes).toEqual([expect.objectContaining({
      id: "RDCLAK_MIX", name: "My Mix", playlistType: "Mix",
    })]);
  });
});
