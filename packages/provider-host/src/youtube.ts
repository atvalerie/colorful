import type { TrackSummary } from "./browse";
import { debugLog } from "./debug";
import { clearYouTubeDecipherCache, decipherYouTubeFormat } from "./youtube-decipher";
import { refreshYouTubeMusicPlayerState, youtubeMusicPlayerId, youtubeMusicSignatureTimestamp, youtubeMusicVisitorData } from "./youtube-music";
import { youtubeBrowserHeaders, youtubeLinked } from "./youtube-auth";
import { parseYouTubePlayerResponse, requestAuthenticatedYouTubePlayer, requestYouTubePlayer,
  selectYouTubeCipheredAudioFormat, youtubeBrowserIdentity, type YouTubePlaybackSource } from "./youtube-player";

export type YouTubeTrackSummary = TrackSummary & { provider: "youtube" };

const MUSIC_ORIGIN = "https://music.youtube.com";
const sourceCache = new Map<string, { value: YouTubePlaybackSource; expiresAt: number }>();

async function probeYouTubeSource(source: YouTubePlaybackSource): Promise<void> {
  const response = await fetch(source.uri, {
    headers: {
      Range: "bytes=0-1023",
      ...(source.userAgent ? { "User-Agent": source.userAgent } : {}),
      ...(source.referrer ? { Referer: source.referrer } : {}),
    },
    signal: AbortSignal.timeout(5_000),
  });
  await response.body?.cancel().catch(() => undefined);
  if (response.status !== 200 && response.status !== 206) {
    throw new Error(`Deciphered YouTube media probe returned HTTP ${response.status}`);
  }
}

async function authenticatedInnertubeSource(
  videoId: string,
  visitorData: string,
  signatureTimestamp: number,
): Promise<YouTubePlaybackSource> {
  const browserHeaders = await youtubeBrowserHeaders();
  const identity = youtubeBrowserIdentity(browserHeaders, visitorData);
  const authenticated = await requestAuthenticatedYouTubePlayer(videoId, identity, signatureTimestamp);
  const selected = selectYouTubeCipheredAudioFormat(authenticated.document);
  const playerId = await youtubeMusicPlayerId();
  const uri = await decipherYouTubeFormat(
    playerId, selected.url, selected.signatureCipher, selected.cipher,
  );
  const source = parseYouTubePlayerResponse({
    playabilityStatus: { status: "OK" },
    streamingData: { adaptiveFormats: [{
      ...selected.format,
      url: uri,
      signatureCipher: undefined,
      cipher: undefined,
    }] },
  }, videoId, authenticated.mediaUserAgent, authenticated.referrer);
  await probeYouTubeSource(source);
  return source;
}

function sourceExpiry(source: { uri: string }): number {
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

function object(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function thumbnailFrom(value: unknown): string | null {
  const thumbnails = Array.isArray(object(value).thumbnails)
    ? (object(value).thumbnails as unknown[]).map(object)
    : [];
  const ranked = thumbnails
    .filter((thumbnail) => text(thumbnail.url))
    .sort((left, right) => Number(right.width ?? 0) * Number(right.height ?? 0)
      - Number(left.width ?? 0) * Number(left.height ?? 0));
  return text(ranked[0]?.url) || null;
}

export function mapYouTubePlayerTrack(document: unknown, requestedVideoId = ""): YouTubeTrackSummary | null {
  const details = object(object(document).videoDetails);
  const id = text(details.videoId) || requestedVideoId;
  const title = text(details.title);
  if (!/^[A-Za-z0-9_-]{11}$/.test(id) || !title) return null;
  const artist = text(details.author) || "YouTube Music";
  const artistId = text(details.channelId);
  const durationSeconds = Number(details.lengthSeconds);
  return {
    provider: "youtube",
    id,
    title,
    version: null,
    artists: [artist],
    artistCredits: artistId ? [{ id: artistId, name: artist }] : [],
    uploader: { id: artistId || null, name: artist },
    albumId: null,
    albumTitle: null,
    durationMs: Number.isFinite(durationSeconds) && durationSeconds > 0 ? Math.round(durationSeconds * 1000) : null,
    isrc: null,
    coverUrl: thumbnailFrom(details.thumbnail),
  };
}

export function youtubeAvailable(): boolean {
  return true;
}

export async function youtubeTrack(videoId: string): Promise<YouTubeTrackSummary> {
  if (!/^[A-Za-z0-9_-]{11}$/.test(videoId)) throw new Error("Invalid YouTube video ID");
  const [visitorData, signatureTimestamp] = await Promise.all([
    youtubeMusicVisitorData(), youtubeMusicSignatureTimestamp(),
  ]);
  const player = await requestYouTubePlayer(videoId, visitorData, signatureTimestamp);
  let track = mapYouTubePlayerTrack(player.document, videoId);
  if (!track && youtubeLinked()) {
    const identity = youtubeBrowserIdentity(await youtubeBrowserHeaders(), visitorData);
    const authenticated = await requestAuthenticatedYouTubePlayer(videoId, identity, signatureTimestamp);
    track = mapYouTubePlayerTrack(authenticated.document, videoId);
  }
  if (!track) throw new Error("YouTube player returned no usable track metadata");
  return track;
}

export async function youtubeSource(videoId: string, refresh = false): Promise<YouTubePlaybackSource> {
  if (!/^[A-Za-z0-9_-]{11}$/.test(videoId)) throw new Error("Invalid YouTube video ID");
  if (refresh) {
    sourceCache.delete(videoId);
    debugLog("youtube.source", "cache_bypassed", { videoId });
  }
  const cached = sourceCache.get(videoId);
  if (cached && cached.expiresAt > Date.now() + 30_000) {
    debugLog("youtube.source", "cache_hit", { videoId, expiresInMs: cached.expiresAt - Date.now() });
    return cached.value;
  }
  debugLog("youtube.source", "resolve_started", { videoId });
  const [visitorData, signatureTimestamp] = await Promise.all([
    youtubeMusicVisitorData(),
    youtubeMusicSignatureTimestamp(),
  ]);
  const player = await requestYouTubePlayer(videoId, visitorData, signatureTimestamp);
  let source: YouTubePlaybackSource;
  try {
    source = parseYouTubePlayerResponse(player.document, videoId, player.mediaUserAgent);
  } catch (error) {
    if (!youtubeLinked()) throw error;
    debugLog("youtube.source", "authenticated_decipher_started", { videoId });
    try {
      source = await authenticatedInnertubeSource(videoId, visitorData, signatureTimestamp);
      debugLog("youtube.source", "authenticated_decipher_completed", {
        videoId,
        itag: source.itag,
        mimeType: source.mimeType,
        bitrate: source.bitrate,
      });
    } catch (decipherError) {
      debugLog("youtube.source", "authenticated_decipher_failed", {
        videoId,
        error: decipherError instanceof Error ? decipherError.message : String(decipherError),
      });
      debugLog("youtube.source", "native_refresh_retry_started", { videoId });
      refreshYouTubeMusicPlayerState();
      clearYouTubeDecipherCache();
      try {
        const [freshVisitorData, freshSignatureTimestamp] = await Promise.all([
          youtubeMusicVisitorData(), youtubeMusicSignatureTimestamp(),
        ]);
        source = await authenticatedInnertubeSource(videoId, freshVisitorData, freshSignatureTimestamp);
        debugLog("youtube.source", "native_refresh_retry_completed", {
          videoId,
          itag: source.itag,
          mimeType: source.mimeType,
          bitrate: source.bitrate,
        });
      } catch (retryError) {
        const retryMessage = retryError instanceof Error ? retryError.message : String(retryError);
        debugLog("youtube.source", "native_refresh_retry_failed", { videoId, error: retryMessage });
        throw new Error(`Native YouTube playback failed after refreshing the player: ${retryMessage}`);
      }
    }
  }
  const expiresAt = sourceExpiry(source);
  sourceCache.set(videoId, { value: source, expiresAt });
  debugLog("youtube.source", "resolve_completed", {
    videoId,
    itag: source.itag,
    mimeType: source.mimeType,
    bitrate: source.bitrate,
    expiresInMs: expiresAt - Date.now(),
  });
  return source;
}
