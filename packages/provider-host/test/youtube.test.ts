import { describe, expect, test } from "bun:test";
import { mapYouTubeTrack, parseYouTubeSourceOutput } from "../src/youtube";

describe("YouTube Music mapping", () => {
  test("maps yt-dlp metadata into a provider-aware track", () => {
    expect(mapYouTubeTrack({
      id: "abcdefghijk",
      title: "A colorful song",
      duration: 123.456,
      channel: "An Artist - Topic",
      channel_id: "channel-one",
      album: "A Record",
      thumbnails: [
        { url: "https://img.test/small.jpg", width: 120, height: 90 },
        { url: "https://img.test/large.jpg", width: 720, height: 720 },
      ],
    })).toEqual({
      provider: "youtube",
      id: "abcdefghijk",
      title: "A colorful song",
      version: null,
      artists: ["An Artist - Topic"],
      artistCredits: [{ id: "channel-one", name: "An Artist - Topic" }],
      uploader: { id: "channel-one", name: "An Artist - Topic" },
      albumId: null,
      albumTitle: "A Record",
      durationMs: 123_456,
      isrc: null,
      coverUrl: "https://img.test/large.jpg",
    });
  });

  test("rejects playlist placeholders without a usable video identity", () => {
    expect(mapYouTubeTrack({ title: "Missing ID" })).toBeNull();
    expect(mapYouTubeTrack({ id: "missing-title" })).toBeNull();
    expect(mapYouTubeTrack({ id: "UCNw2hq-0-3", title: "A channel-shaped result" })).toBeNull();
    expect(mapYouTubeTrack({ id: "UCNw2hq-0-3-Wideo", title: "A channel" })).toBeNull();
    expect(mapYouTubeTrack({ id: "PL123456789012345", title: "A playlist" })).toBeNull();
  });

  test("parses the lightweight playback URL and headers output", () => {
    expect(parseYouTubeSourceOutput([
      "https://rr.example/videoplayback?expire=9999999999",
      JSON.stringify({ "User-Agent": "colorful-test", Accept: "*/*" }),
    ].join("\n"), "abcdefghijk")).toEqual({
      uri: "https://rr.example/videoplayback?expire=9999999999",
      httpHeaders: { "User-Agent": "colorful-test", Accept: "*/*" },
      userAgent: "colorful-test",
      referrer: "https://music.youtube.com",
      webpageUrl: "https://music.youtube.com/watch?v=abcdefghijk",
    });
  });
});
