import type { BrowseClient, TrackSummary } from "./browse";
import { youtubeMusicLyrics } from "./youtube-music";

const LRCLIB_BASE_URL = "https://lrclib.net/api";
const LRCLIB_TIMEOUT_MS = 8_000;
const DURATION_TOLERANCE_SECONDS = 3;

export type LyricLine = {
  startMs: number | null;
  text: string;
};

export type LyricsDocument = {
  trackId: string;
  provider: string;
  source: "tidal" | "youtube_music" | "lrclib";
  sourceLabel: string;
  synced: boolean;
  instrumental: boolean;
  lines: LyricLine[];
  plainText: string;
  romanizedLines: LyricLine[];
  romanizedText: string;
  romanizedSynced: boolean;
  fetchedAtMs: number;
};

type NativeLyrics = { plain: string | null; synced: string | null; romanized?: string | null };
type LrclibRecord = {
  trackName?: string;
  artistName?: string;
  duration?: number;
  instrumental?: boolean;
  plainLyrics?: string | null;
  syncedLyrics?: string | null;
};

function clean(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

export function parseSyncedLyrics(value: string): LyricLine[] {
  const lines: LyricLine[] = [];
  for (const rawLine of value.split(/\r?\n/)) {
    const matches = [...rawLine.matchAll(/\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]/g)];
    if (!matches.length) continue;
    const text = rawLine.replace(/\[[^\]]+\]/g, "").trim();
    for (const match of matches) {
      const minutes = Number(match[1]);
      const seconds = Number(match[2]);
      const fraction = match[3] ?? "";
      const milliseconds = fraction.length === 3 ? Number(fraction)
        : fraction.length === 2 ? Number(fraction) * 10
        : fraction.length === 1 ? Number(fraction) * 100 : 0;
      if (!Number.isFinite(minutes) || !Number.isFinite(seconds) || seconds >= 60) continue;
      lines.push({ startMs: (minutes * 60 + seconds) * 1_000 + milliseconds, text });
    }
  }
  return lines.sort((left, right) => (left.startMs ?? 0) - (right.startMs ?? 0));
}

function plainLines(value: string): LyricLine[] {
  return value.split(/\r?\n/).map((text) => ({ startMs: null, text: text.trim() }));
}

function document(track: TrackSummary & { provider?: string }, source: LyricsDocument["source"],
  label: string, lyrics: NativeLyrics, instrumental = false): LyricsDocument | null {
  const syncedText = clean(lyrics.synced);
  const plainText = clean(lyrics.plain) ?? "";
  const romanizedText = clean(lyrics.romanized) ?? "";
  const syncedLines = syncedText ? parseSyncedLyrics(syncedText) : [];
  const romanizedSyncedLines = romanizedText ? parseSyncedLyrics(romanizedText) : [];
  const romanizedPlainLines = romanizedText ? plainLines(romanizedText) : [];
  const alignedRomanizedLines = !romanizedSyncedLines.length
    && syncedLines.length === romanizedPlainLines.length
    ? romanizedPlainLines.map((line, index) => ({ ...line, startMs: syncedLines[index]?.startMs ?? null }))
    : [];
  const romanizedLines = romanizedSyncedLines.length
    ? romanizedSyncedLines : alignedRomanizedLines.length ? alignedRomanizedLines : romanizedPlainLines;
  if (!instrumental && !plainText && !syncedLines.length && !romanizedLines.length) return null;
  return {
    trackId: track.id,
    provider: track.provider ?? "tidal",
    source,
    sourceLabel: label,
    synced: syncedLines.length > 0,
    instrumental,
    lines: syncedLines.length ? syncedLines : plainLines(plainText),
    plainText,
    romanizedLines,
    romanizedText,
    romanizedSynced: romanizedSyncedLines.length > 0 || alignedRomanizedLines.length > 0,
    fetchedAtMs: Date.now(),
  };
}

export function preferLyrics(native: LyricsDocument | null, fallback: LyricsDocument | null): LyricsDocument | null {
  if (native?.synced) return native;
  if (fallback?.synced) return fallback;
  return native ?? fallback;
}

function lrclibCandidate(records: LrclibRecord[], durationMs: number | null): LrclibRecord | null {
  const durationSeconds = durationMs === null ? null : durationMs / 1_000;
  const matching = durationSeconds === null ? records : records.filter((record) =>
    typeof record.duration === "number"
      && Math.abs(record.duration - durationSeconds) <= DURATION_TOLERANCE_SECONDS);
  const candidates = matching.length ? matching : records;
  return candidates.find((record) => clean(record.syncedLyrics)) ?? candidates[0] ?? null;
}

async function lrclib(track: TrackSummary & { provider?: string }): Promise<LyricsDocument | null> {
  if (!track.title || !track.artists.length) return null;
  const params = new URLSearchParams({
    track_name: track.title,
    artist_name: track.artists.join(", "),
  });
  if (track.albumTitle && track.durationMs !== null) {
    params.set("album_name", track.albumTitle);
    params.set("duration", String(Math.round(track.durationMs / 1_000)));
  }
  const fetchJson = async (path: string): Promise<unknown> => {
    const response = await fetch(`${LRCLIB_BASE_URL}${path}`, {
      headers: { "User-Agent": "colorful/0.1 (https://github.com/valerie-sh/colorful)" },
      signal: AbortSignal.timeout(LRCLIB_TIMEOUT_MS),
    });
    return response.ok ? response.json() : null;
  };
  try {
    const exact = await fetchJson(`/get?${params}`) as LrclibRecord | null;
    const candidates: LrclibRecord[] = exact ? [exact] : [];
    if (!clean(exact?.syncedLyrics)) {
      const search = new URLSearchParams({ track_name: track.title, artist_name: track.artists[0] ?? "" });
      try {
        const results = await fetchJson(`/search?${search}`);
        if (Array.isArray(results)) candidates.push(...results as LrclibRecord[]);
      } catch {
        // The exact plain result remains useful if the broader synced search
        // times out independently.
      }
    }
    const candidate = lrclibCandidate(candidates, track.durationMs);
    if (!candidate) return null;
    return document(track, "lrclib", "LRCLIB", {
      plain: clean(candidate.plainLyrics),
      synced: clean(candidate.syncedLyrics),
    }, candidate.instrumental === true);
  } catch {
    return null;
  }
}

export async function resolveLyrics(
  browse: BrowseClient,
  track: TrackSummary & { provider?: string },
): Promise<LyricsDocument | null> {
  const provider = track.provider ?? "tidal";
  let native: LyricsDocument | null = null;
  try {
    if (provider === "tidal") {
      native = document(track, "tidal", "TIDAL", await browse.trackLyrics(track.id));
    } else if (provider === "youtube") {
      native = document(track, "youtube_music", "YouTube Music", await youtubeMusicLyrics(track.id));
    }
  } catch {
    native = null;
  }
  if (native?.synced) return native;
  return preferLyrics(native, await lrclib(track));
}
