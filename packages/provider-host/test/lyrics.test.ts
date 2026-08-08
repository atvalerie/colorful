import { describe, expect, test } from "bun:test";
import { parseSyncedLyrics, preferLyrics, type LyricsDocument } from "../src/lyrics";

describe("lyrics normalization", () => {
  test("parses and orders LRC timestamps", () => {
    expect(parseSyncedLyrics("[00:10.50]later\n[00:01.005]first\n[00:10.50][00:20]repeat"))
      .toEqual([
        { startMs: 1_005, text: "first" },
        { startMs: 10_500, text: "later" },
        { startMs: 10_500, text: "repeat" },
        { startMs: 20_000, text: "repeat" },
      ]);
  });

  test("ignores metadata and invalid timestamps", () => {
    expect(parseSyncedLyrics("[ar:Someone]\n[00:99.00]nope\nplain")) .toEqual([]);
  });

  test("prefers synced fallback lyrics over plain provider lyrics", () => {
    const base: LyricsDocument = {
      trackId: "1", provider: "tidal", source: "tidal", sourceLabel: "TIDAL",
      synced: false, instrumental: false, lines: [], plainText: "plain",
      romanizedLines: [], romanizedText: "", romanizedSynced: false, fetchedAtMs: 1,
    };
    const synced: LyricsDocument = {
      ...base, source: "lrclib", sourceLabel: "LRCLIB", synced: true,
      lines: [{ startMs: 1000, text: "timed" }],
    };
    expect(preferLyrics(base, synced)).toBe(synced);
    expect(preferLyrics({ ...base, synced: true }, synced)?.source).toBe("tidal");
  });
});
