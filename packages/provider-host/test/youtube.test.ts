import { describe, expect, test } from "bun:test";
import { mapYouTubeTrack } from "../src/youtube";

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
});
