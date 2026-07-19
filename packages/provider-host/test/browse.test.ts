import { describe, expect, test } from "bun:test";
import { cursorFromNextLink, formatTrackTitle, isoDurationToMs, mapTracks, mergeRelatedTracks, type TrackSummary } from "../src/browse";

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

  test("interleaves similar tracks and radio without duplicates", () => {
    const track = (id: string): TrackSummary => ({
      id, title: id, version: null, artists: [], albumId: null,
      albumTitle: null, durationMs: null, isrc: null, coverUrl: null,
    });
    expect(mergeRelatedTracks(
      [track("similar-1"), track("shared"), track("similar-2")],
      [track("radio-1"), track("shared"), track("radio-2")],
      5,
    ).map(({ id }) => id)).toEqual(["similar-1", "radio-1", "shared", "similar-2", "radio-2"]);
  });

  test("reads TIDAL's opaque pagination cursor from the next link", () => {
    expect(cursorFromNextLink({ links: {
      next: "https://openapi.tidal.com/v2/tracks/123/relationships/radio?page%5Bcursor%5D=next-page",
    } })).toBe("next-page");
    expect(cursorFromNextLink({ links: {} })).toBeUndefined();
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

  test("maps the same sanitized fixture as the portable Rust adapter", async () => {
    const fixture = await Bun.file(new URL("../../../fixtures/tidal/search-tracks.json", import.meta.url)).json();
    const tracks = mapTracks(fixture);

    expect(tracks).toHaveLength(2);
    expect(tracks[0]).toEqual(expect.objectContaining({
      title: "Brutal (Instrumental)",
      version: "Instrumental",
      durationMs: 151_000,
      coverUrl: "https://example.test/brutal.jpg",
    }));
    expect(tracks[1]).toEqual(expect.objectContaining({
      title: "Brutal (Live)",
      artists: ["GERXMV/P", "Someone Else"],
      durationMs: 192_500,
    }));
  });
});
