import { describe, expect, test } from "bun:test";
import { formatTrackTitle, isoDurationToMs, mapTracks } from "../src/browse";

describe("TIDAL browse mapping", () => {
  test("parses ISO durations", () => {
    expect(isoDurationToMs("PT3M12.5S")).toBe(192_500);
    expect(isoDurationToMs(undefined)).toBeNull();
  });

  test("formats track versions without duplicating an existing suffix", () => {
    expect(formatTrackTitle("Brutal", "Instrumental")).toBe("Brutal (Instrumental)");
    expect(formatTrackTitle("Brutal (Instrumental)", "instrumental")).toBe("Brutal (Instrumental)");
    expect(formatTrackTitle("Brutal", null)).toBe("Brutal");
  });

  test("normalizes a track and its relationships", () => {
    const tracks = mapTracks({ included: [
      { id: "track-1", type: "tracks", attributes: { title: "Color", version: "Live", duration: "PT2M" }, relationships: {
        artists: { data: [{ id: "artist-1", type: "artists" }] },
        albums: { data: [{ id: "album-1", type: "albums" }] },
      } },
      { id: "artist-1", type: "artists", attributes: { name: "Someone" } },
      { id: "album-1", type: "albums", attributes: { title: "Bright" }, relationships: {
        coverArt: { data: [{ id: "art-1", type: "artworks" }] },
      } },
      { id: "art-1", type: "artworks", attributes: { files: [{ href: "https://example.test/cover.jpg" }] } },
    ] });
    expect(tracks).toEqual([expect.objectContaining({
      id: "track-1",
      title: "Color (Live)",
      version: "Live",
      artists: ["Someone"],
      albumTitle: "Bright",
      coverUrl: "https://example.test/cover.jpg",
      durationMs: 120_000,
    })]);
  });
});
