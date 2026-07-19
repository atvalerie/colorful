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

function executable(): string {
  const configured = process.env.COLORFUL_YT_DLP?.trim();
  const path = configured || Bun.which("yt-dlp");
  if (!path) throw new Error("YouTube playback needs yt-dlp. Install it or set COLORFUL_YT_DLP.");
  return path;
}

async function runYtDlp(arguments_: string[]): Promise<YtDlpEntry> {
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
  try {
    return JSON.parse(stdout) as YtDlpEntry;
  } catch {
    throw new Error("yt-dlp returned invalid YouTube metadata");
  }
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

export async function searchYouTubeMusic(query: string, limit = 20): Promise<YouTubeTrackSummary[]> {
  const safeLimit = Math.max(1, Math.min(50, Math.floor(limit)));
  const document = await runYtDlp([
    "--no-warnings", "--ignore-errors", "--flat-playlist", "--dump-single-json",
    "--playlist-end", String(safeLimit), `ytsearch${safeLimit}:${query}`,
  ]);
  return mappedEntries(document).slice(0, safeLimit);
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
  const document = await runYtDlp([
    "--no-warnings", "--no-playlist", "--dump-single-json",
    "--format", "bestaudio/best", `${MUSIC_ORIGIN}/watch?v=${encodeURIComponent(videoId)}`,
  ]);
  const uri = text(document.url);
  if (!uri) throw new Error("yt-dlp did not return a playable YouTube audio URL");
  const rawHeaders = document.http_headers;
  const httpHeaders = rawHeaders && typeof rawHeaders === "object" && !Array.isArray(rawHeaders)
    ? Object.fromEntries(Object.entries(rawHeaders).filter((entry): entry is [string, string] => typeof entry[1] === "string"))
    : {};
  return {
    uri,
    httpHeaders,
    userAgent: text(httpHeaders["User-Agent"]),
    referrer: MUSIC_ORIGIN,
    webpageUrl: text(document.webpage_url) || `${MUSIC_ORIGIN}/watch?v=${videoId}`,
  };
}
