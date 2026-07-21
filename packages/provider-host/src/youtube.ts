import type { TrackSummary } from "./browse";

type YtDlpThumbnail = { url?: unknown; width?: unknown; height?: unknown };
type YtDlpEntry = {
  id?: unknown;
  title?: unknown;
  duration?: unknown;
  channel?: unknown;
  channel_id?: unknown;
  uploader?: unknown;
  uploader_id?: unknown;
  album?: unknown;
  thumbnail?: unknown;
  thumbnails?: unknown;
  url?: unknown;
  webpage_url?: unknown;
  http_headers?: unknown;
};

export type YouTubeTrackSummary = TrackSummary & { provider: "youtube" };

const MUSIC_ORIGIN = "https://music.youtube.com";
const sourceCache = new Map<string, { value: Record<string, unknown>; expiresAt: number }>();

function executable(): string {
  const configured = process.env.COLORFUL_YT_DLP?.trim();
  const path = configured || Bun.which("yt-dlp");
  if (!path) throw new Error("YouTube playback needs yt-dlp. Install it or set COLORFUL_YT_DLP.");
  return path;
}

async function runYtDlpOutput(arguments_: string[]): Promise<string> {
  const subprocess = Bun.spawn([executable(), ...arguments_], {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, LC_ALL: "C" },
  });
  const [exitCode, stdout, stderr] = await Promise.all([
    subprocess.exited,
    new Response(subprocess.stdout).text(),
    new Response(subprocess.stderr).text(),
  ]);
  if (exitCode !== 0) {
    const detail = stderr.trim().split("\n").at(-1)?.replace(/^ERROR:\s*/, "") ?? "unknown error";
    throw new Error(`yt-dlp could not resolve YouTube Music: ${detail}`);
  }
  return stdout;
}

async function runYtDlp(arguments_: string[]): Promise<YtDlpEntry> {
  const stdout = await runYtDlpOutput(arguments_);
  try {
    return JSON.parse(stdout) as YtDlpEntry;
  } catch {
    throw new Error("yt-dlp returned invalid YouTube metadata");
  }
}

export function parseYouTubeSourceOutput(stdout: string, videoId: string): Record<string, unknown> {
  const lines = stdout.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const uri = text(lines[0]);
  if (!uri) throw new Error("yt-dlp did not return a playable YouTube audio URL");
  let httpHeaders: Record<string, string> = {};
  try {
    const raw = JSON.parse(lines[1] ?? "{}") as unknown;
    if (raw && typeof raw === "object" && !Array.isArray(raw)) {
      httpHeaders = Object.fromEntries(Object.entries(raw)
        .filter((entry): entry is [string, string] => typeof entry[1] === "string"));
    }
  } catch {
    // The direct media URL remains usable with yt-dlp's ordinary defaults.
  }
  return {
    uri,
    httpHeaders,
    userAgent: text(httpHeaders["User-Agent"]),
    referrer: MUSIC_ORIGIN,
    webpageUrl: `${MUSIC_ORIGIN}/watch?v=${videoId}`,
  };
}

function sourceExpiry(source: Record<string, unknown>): number {
  const now = Date.now();
  try {
    const upstream = Number(new URL(String(source.uri ?? "")).searchParams.get("expire")) * 1000;
    if (Number.isFinite(upstream) && upstream > now) return Math.min(upstream - 60_000, now + 10 * 60_000);
  } catch { /* use the conservative fallback */ }
  return now + 5 * 60_000;
}

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function thumbnailFor(entry: YtDlpEntry): string | null {
  const thumbnails = Array.isArray(entry.thumbnails)
    ? entry.thumbnails.filter((thumbnail): thumbnail is YtDlpThumbnail => Boolean(thumbnail) && typeof thumbnail === "object")
    : [];
  const ranked = thumbnails
    .filter((thumbnail) => text(thumbnail.url))
    .sort((left, right) => Number(right.width ?? 0) * Number(right.height ?? 0)
      - Number(left.width ?? 0) * Number(left.height ?? 0));
  return text(ranked[0]?.url) || text(entry.thumbnail) || null;
}

export function mapYouTubeTrack(entry: YtDlpEntry): YouTubeTrackSummary | null {
  const id = text(entry.id);
  const title = text(entry.title);
  // Flat search output may also contain channels and playlists. YouTube video
  // IDs are exactly 11 URL-safe characters; everything else is not a track.
  if (id.startsWith("UC") || !/^[A-Za-z0-9_-]{11}$/.test(id) || !title) return null;
  const artist = text(entry.channel) || text(entry.uploader) || "YouTube Music";
  const artistId = text(entry.channel_id) || text(entry.uploader_id);
  const durationSeconds = Number(entry.duration);
  return {
    provider: "youtube",
    id,
    title,
    version: null,
    artists: [artist],
    artistCredits: artistId ? [{ id: artistId, name: artist }] : [],
    uploader: { id: artistId || null, name: artist },
    albumId: null,
    albumTitle: text(entry.album) || null,
    durationMs: Number.isFinite(durationSeconds) && durationSeconds > 0 ? Math.round(durationSeconds * 1000) : null,
    isrc: null,
    coverUrl: thumbnailFor(entry),
  };
}

function mappedEntries(document: YtDlpEntry): YouTubeTrackSummary[] {
  const entries = Array.isArray((document as { entries?: unknown }).entries)
    ? (document as { entries: unknown[] }).entries
    : [];
  const tracks: YouTubeTrackSummary[] = [];
  const seen = new Set<string>();
  for (const value of entries) {
    if (!value || typeof value !== "object") continue;
    const track = mapYouTubeTrack(value as YtDlpEntry);
    if (!track || seen.has(track.id)) continue;
    seen.add(track.id);
    tracks.push(track);
  }
  return tracks;
}

export function youtubeAvailable(): boolean {
  return Boolean(process.env.COLORFUL_YT_DLP?.trim() || Bun.which("yt-dlp"));
}

export async function searchYouTubeVideos(query: string, limit = 20, start = 1): Promise<YouTubeTrackSummary[]> {
  const safeLimit = Math.max(1, Math.min(50, Math.floor(limit)));
  const safeStart = Math.max(1, Math.floor(start));
  const end = safeStart + safeLimit - 1;
  const document = await runYtDlp([
    "--no-warnings", "--ignore-errors", "--flat-playlist", "--dump-single-json",
    "--playlist-end", String(end), `ytsearch${end}:${query}`,
  ]);
  return mappedEntries(document).slice(safeStart - 1, end);
}

export async function youtubeAutomix(videoId: string, limit = 20): Promise<YouTubeTrackSummary[]> {
  const safeLimit = Math.max(1, Math.min(50, Math.floor(limit)));
  const url = `${MUSIC_ORIGIN}/watch?v=${encodeURIComponent(videoId)}&list=RDAMVM${encodeURIComponent(videoId)}`;
  const document = await runYtDlp([
    "--no-warnings", "--ignore-errors", "--flat-playlist", "--dump-single-json",
    "--playlist-end", String(safeLimit + 1), url,
  ]);
  return mappedEntries(document).filter((track) => track.id !== videoId).slice(0, safeLimit);
}

export async function youtubeChannelVideos(channelId: string, start = 1, limit = 20): Promise<YouTubeTrackSummary[]> {
  if (!/^UC[A-Za-z0-9_-]{20,}$/.test(channelId)) throw new Error("Invalid YouTube channel ID");
  const safeStart = Math.max(1, Math.floor(start));
  const safeLimit = Math.max(1, Math.min(50, Math.floor(limit)));
  const document = await runYtDlp([
    "--no-warnings", "--ignore-errors", "--flat-playlist", "--dump-single-json",
    "--playlist-start", String(safeStart), "--playlist-end", String(safeStart + safeLimit - 1),
    `https://www.youtube.com/channel/${channelId}/videos`,
  ]);
  const channelName = text(document.channel) || text(document.uploader);
  return mappedEntries(document).slice(0, safeLimit).map((track) => channelName ? {
    ...track,
    artists: [channelName],
    artistCredits: [{ id: channelId, name: channelName }],
    uploader: { id: channelId, name: channelName },
  } : track);
}

export async function youtubeTrack(videoId: string): Promise<YouTubeTrackSummary> {
  const document = await runYtDlp([
    "--no-warnings", "--no-playlist", "--dump-single-json", "--skip-download",
    `${MUSIC_ORIGIN}/watch?v=${encodeURIComponent(videoId)}`,
  ]);
  const track = mapYouTubeTrack(document);
  if (!track) throw new Error("yt-dlp did not return valid YouTube track metadata");
  return track;
}

export async function youtubeSource(videoId: string): Promise<Record<string, unknown>> {
  const cached = sourceCache.get(videoId);
  if (cached && cached.expiresAt > Date.now() + 30_000) return cached.value;
  const stdout = await runYtDlpOutput([
    "--no-warnings", "--no-playlist", "--format", "bestaudio/best",
    "--print", "%(url)s", "--print", "%(http_headers)j",
    `${MUSIC_ORIGIN}/watch?v=${encodeURIComponent(videoId)}`,
  ]);
  const source = parseYouTubeSourceOutput(stdout, videoId);
  sourceCache.set(videoId, { value: source, expiresAt: sourceExpiry(source) });
  return source;
}
