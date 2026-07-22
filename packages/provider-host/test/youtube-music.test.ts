import { describe, expect, test } from "bun:test";
import { mapYouTubeMusicCollectionDocuments, mapYouTubeMusicPlaylistDocument, mapYouTubeMusicWatchPlaylistDocument, parseYouTubeMusicBootstrap, parseYouTubeSignatureTimestamp, youtubeMusicAutomixContinuation, youtubeMusicAutomixRequest, youtubeMusicContinuationToken, youtubeMusicPremiumStatusFromHtml } from "../src/youtube-music";
import { parseYouTubeBrowserHeaders, selectYouTubeBrowserHeaders } from "../src/youtube-auth";

describe("authenticated YouTube Music mapping", () => {
  test("extracts and merges public ytcfg bootstrap objects", () => {
    expect(parseYouTubeMusicBootstrap(`<script>
      ytcfg.set({"INNERTUBE_CLIENT_VERSION":"1.20260719.16.00","escaped":"a}b","INNERTUBE_CONTEXT":{"client":{"clientName":"WEB_REMIX","visitorData":"visitor"}}});
      ytcfg.set({"INNERTUBE_API_KEY":"public-key"});
    </script>`)).toEqual({
      INNERTUBE_CLIENT_VERSION: "1.20260719.16.00",
      escaped: "a}b",
      INNERTUBE_CONTEXT: { client: { clientName: "WEB_REMIX", visitorData: "visitor" } },
      INNERTUBE_API_KEY: "public-key",
    });
    expect(parseYouTubeSignatureTimestamp("const context={signatureTimestamp:20653,foo:true}")).toBe(20653);
    expect(parseYouTubeSignatureTimestamp("const context={foo:true}")).toBeNull();
  });

  test("reads premium membership status from YouTube Music bootstrap data", () => {
    expect(youtubeMusicPremiumStatusFromHtml('<script>ytcfg.set({"IS_SUBSCRIBER":true})</script>')).toBe("Premium");
    expect(youtubeMusicPremiumStatusFromHtml('{\\"IS_SUBSCRIBER\\":false}')).toBe("Free");
    expect(youtubeMusicPremiumStatusFromHtml("no membership state here")).toBe("Unknown");
  });

  test("reads browser authentication from Chromium Copy as cURL", () => {
    const headers = parseYouTubeBrowserHeaders(String.raw`curl 'https://music.youtube.com/youtubei/v1/browse' \
      -H 'x-goog-authuser: 0' \
      -H 'x-goog-pageid: UC_selected_profile' \
      -H 'x-youtube-client-name: 67' \
      -H 'x-youtube-client-version: 1.20260720.01.00' \
      -H 'x-youtube-bootstrap-logged-in: true' \
      -H 'x-youtube-identity-token: selected-profile-token' \
      -H 'cookie: SID=ignored; __Secure-3PAPISID=private-value; PREF=music' \
      -H 'authorization: copied-secret-that-must-not-be-stored' \
      -H 'sec-fetch-site: same-origin' \
      -H 'user-agent: colorful-test'`);
    const retained = selectYouTubeBrowserHeaders(headers);
    expect(retained["x-goog-authuser"]).toBe("0");
    expect(retained["x-goog-pageid"]).toBe("UC_selected_profile");
    expect(retained["x-youtube-client-name"]).toBe("67");
    expect(retained["x-youtube-client-version"]).toBe("1.20260720.01.00");
    expect(retained["x-youtube-bootstrap-logged-in"]).toBe("true");
    expect(retained["x-youtube-identity-token"]).toBe("selected-profile-token");
    expect(retained.cookie).toContain("__Secure-3PAPISID=private-value");
    expect(retained["user-agent"]).toBe("colorful-test");
    expect(retained.authorization).toBeUndefined();
    expect(retained["sec-fetch-site"]).toBeUndefined();
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

  test("keeps a playlist's total count instead of the loaded track count", () => {
    const track = (id: string, title: string) => ({ musicResponsiveListItemRenderer: {
      flexColumns: [
        { musicResponsiveListItemFlexColumnRenderer: { text: { runs: [{
          text: title, navigationEndpoint: { watchEndpoint: { videoId: id } },
        }] } } },
        { musicResponsiveListItemFlexColumnRenderer: { text: { runs: [{ text: "Artist" }] } } },
      ],
    } });
    const page = mapYouTubeMusicPlaylistDocument({
      header: { musicResponsiveHeaderRenderer: {
        title: { runs: [{ text: "Huge playlist" }] },
        secondSubtitle: { runs: [{ text: "2,844 tracks" }, { text: " • " }, { text: "99+ hours" }] },
      } },
      contents: [track("one", "One"), track("two", "Two")],
      shelf: { musicPlaylistShelfRenderer: { contents: [{ continuationItemRenderer: {
        continuationEndpoint: { continuationCommand: { token: "browse-next" } },
      } }] } },
    }, "PL_HUGE");
    expect(page.playlist.numberOfItems).toBe(2844);
    expect(page.tracks).toHaveLength(2);
    expect(page.trackCursor).toBe("youtube-music-browse:browse-next");
  });

  test("maps YouTube's server-shuffled watch queue and its continuation", () => {
    const item = (id: string, title: string) => ({ playlistPanelVideoRenderer: {
      title: { runs: [{ text: title }] },
      navigationEndpoint: { watchEndpoint: { videoId: id } },
      longBylineText: { runs: [{ text: "Artist", navigationEndpoint: { browseEndpoint: { browseId: "UC_artist" } } }] },
      lengthText: { runs: [{ text: "3:21" }] },
    } });
    const result = mapYouTubeMusicWatchPlaylistDocument({ panel: { playlistPanelRenderer: {
      contents: [
        item("random-b", "Random B"), item("random-a", "Random A"),
        { continuationItemRenderer: { continuationEndpoint: { continuationCommand: { token: "shuffle-next" } } } },
      ],
    } } });
    expect(result.tracks.map((track) => track.id)).toEqual(["random-b", "random-a"]);
    expect(result.cursor).toBe("youtube-music-watch:shuffle-next");
  });

  test("builds a minimal typed automix request without captured browser telemetry", () => {
    const request = youtubeMusicAutomixRequest("abcdefghijk");
    expect(request).toEqual({
      videoId: "abcdefghijk",
      playlistId: "RDAMVMabcdefghijk",
      enablePersistentPlaylistPanel: true,
      isAudioOnly: true,
      tunerSettingValue: "AUTOMIX_SETTING_NORMAL",
    });
    expect(request).not.toHaveProperty("adSignalsInfo");
    expect(request).not.toHaveProperty("clickTracking");
    expect(request).not.toHaveProperty("loggingContext");
    expect(request).not.toHaveProperty("responsiveSignals");
  });

  test("reconstructs YouTube Music's radio continuation from the last queue item", () => {
    const continuation = youtubeMusicAutomixContinuation({ navigationEndpoint: { watchEndpoint: {
      videoId: "ptPVhXvT_5s",
      playlistId: "RDAMVMFv4lKPcmSIY",
      index: 49,
      params: "OAHyAQIIAZIEI1FQdW5sWWNZSjRzNy1mbjh3ZFAyaS1nMW1aN2xaMkREZGRQ",
      playlistSetVideoId: "D625AB40294D381D",
    } } });
    expect(continuation).toBe("CDIShAESC3B0UFZoWHZUXzVzIhFSREFNVk1GdjRsS1BjbVNJWTJKd0FFQjhnRUFtZ01EQ05nRWtnUWpVVkIxYm14WlkxbEtOSE0zTFdadU9IZGtVREpwTFdjeGJWbzNiRm95UkVSa1pGRDZCUUElM0Q4MdABAfoBEEQ2MjVBQjQwMjk0RDM4MUQYCg%3D%3D");
  });

  test("reads filtered-search pagination from a music shelf continuation", () => {
    expect(youtubeMusicContinuationToken({ continuationContents: { musicShelfContinuation: {
      contents: [],
      continuations: [{ nextContinuationData: { continuation: "search-next" } }],
    } } })).toBe("search-next");
  });
});
