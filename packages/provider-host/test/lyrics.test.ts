import { describe, expect, test } from "bun:test";
import { parseSyncedLyrics, preferLyrics, romanizeLyricsLines, type LyricsDocument } from "../src/lyrics";

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

  test("leaves Latin-only lines without a romanized toggle", async () => {
    const lines = [{ startMs: 1250, text: "Hello, world!" }, { startMs: 2500, text: "and more" }];
    expect(await romanizeLyricsLines(lines)).toEqual([]);
  });

  test("preserves timestamps and line count for mixed scripts", async () => {
    const lines = [
      { startMs: 1000, text: "Hello 世界" },
      { startMs: 2500, text: "안녕" },
      { startMs: 4000, text: "สวัสดี" },
    ];
    const romanized = await romanizeLyricsLines(lines);
    expect(romanized).toHaveLength(lines.length);
    expect(romanized.map((line) => line.startMs)).toEqual(lines.map((line) => line.startMs));
  });

  test("romanizes Japanese Kanji and kana with contextual readings", async () => {
    expect(await romanizeLyricsLines([{ startMs: 1000, text: "感じ取れたら手を繋ごう" }]))
      .toEqual([{ startMs: 1000, text: "kanjitore tara te o tsunagō" }]);
  });

  test("romanizes Chinese while preserving embedded Latin text", async () => {
    expect(await romanizeLyricsLines([{ startMs: null, text: "Hello 世界!" }]))
      .toEqual([{ startMs: null, text: "Hello shi jie!" }]);
  });

  test("converts Hanja to Hangul before Korean romanization", async () => {
    expect(await romanizeLyricsLines([{ startMs: 2000, text: "大韓民國은 民主共和國이다." }]))
      .toEqual([{ startMs: 2000, text: "daehanmingugeun minjugonghwagugida." }]);
  });

  test("romanizes Thai locally", async () => {
    expect(await romanizeLyricsLines([{ startMs: 3000, text: "สวัสดีครับ" }]))
      .toEqual([{ startMs: 3000, text: "swasdikhrab" }]);
  });
});
