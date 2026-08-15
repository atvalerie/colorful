import type { TrackSummary } from "./browse";
import { debugLog } from "./debug";
import { clearYouTubeDecipherCache, decipherYouTubeFormat } from "./youtube-decipher";
import { refreshYouTubeMusicPlayerState, youtubeMusicPlayerId, youtubeMusicSignatureTimestamp, youtubeMusicVisitorData } from "./youtube-music";
import { youtubeBrowserHeaders, youtubeLinked } from "./youtube-auth";
import { parseYouTubePlayerResponse, requestAuthenticatedYouTubePlayer, requestYouTubePlayer,
  requestYouTubeWebSafariPlayer,
  requestYouTubeTvDowngradedPlayer,
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

async function decipheredInnertubeSource(
  videoId: string,
  document: unknown,
  userAgent: string,
  referrer: string,
): Promise<YouTubePlaybackSource> {
  const selected = selectYouTubeCipheredAudioFormat(document);
  const playerId = await youtubeMusicPlayerId();
  const uri = await decipherYouTubeFormat(
    playerId, selected.url, selected.signatureCipher, selected.cipher,
  );
  return parseYouTubePlayerResponse({
    playabilityStatus: { status: "OK" },
    streamingData: { adaptiveFormats: [{
      ...selected.format,
      url: uri,
      signatureCipher: undefined,
      cipher: undefined,
    }] },
  }, videoId, userAgent, referrer);
}

async function authenticatedInnertubeSource(
  videoId: string,
  visitorData: string,
  signatureTimestamp: number,
): Promise<YouTubePlaybackSource> {
  const browserHeaders = await youtubeBrowserHeaders();
  const identity = youtubeBrowserIdentity(browserHeaders, visitorData);
  const authenticated = await requestAuthenticatedYouTubePlayer(videoId, identity, signatureTimestamp);
  const source = await decipheredInnertubeSource(
    videoId, authenticated.document, authenticated.mediaUserAgent, authenticated.referrer);
  await probeYouTubeSource(source);
  return source;
}

async function webSafariHlsSource(
  videoId: string,
  visitorData: string,
  signatureTimestamp: number,
): Promise<YouTubePlaybackSource> {
  const player = await requestYouTubeWebSafariPlayer(videoId, visitorData, signatureTimestamp);
  const hlsManifestUrl = text(object(object(player.document).streamingData).hlsManifestUrl);
  if (!hlsManifestUrl.startsWith("https://")) {
    throw new Error("YouTube web player returned no HLS manifest");
  }
  const source: YouTubePlaybackSource = {
    uri: hlsManifestUrl,
    httpHeaders: { "User-Agent": player.mediaUserAgent },
    userAgent: player.mediaUserAgent,
    referrer: "https://www.youtube.com/",
    webpageUrl: `${MUSIC_ORIGIN}/watch?v=${videoId}`,
    mimeType: "application/vnd.apple.mpegurl",
    bitrate: 0,
    itag: 0,
    contentLength: null,
    durationMs: null,
  };
  await probeYouTubeSource(source);
  return source;
}

async function tvDowngradedInnertubeSource(
  videoId: string,
  visitorData: string,
  signatureTimestamp: number,
): Promise<YouTubePlaybackSource> {
  const tv = await requestYouTubeTvDowngradedPlayer(videoId, visitorData, signatureTimestamp);
  try {
    const source = parseYouTubePlayerResponse(tv.document, videoId, tv.mediaUserAgent);
    await probeYouTubeSource(source);
    return source;
  } catch (directError) {
    debugLog("youtube.source", "tv_downgraded_decipher_started", {
      videoId,
      error: directError instanceof Error ? directError.message : String(directError),
    });
    const source = await decipheredInnertubeSource(videoId, tv.document, tv.mediaUserAgent, "");
    await probeYouTubeSource(source);
    return source;
  }
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
    const publicSource = parseYouTubePlayerResponse(player.document, videoId, player.mediaUserAgent);
    await probeYouTubeSource(publicSource);
    source = publicSource;
  } catch (publicError) {
    debugLog("youtube.source", "android_vr_source_failed", {
      videoId,
      error: publicError instanceof Error ? publicError.message : String(publicError),
    });
    try {
      source = await webSafariHlsSource(videoId, visitorData, signatureTimestamp);
      debugLog("youtube.source", "web_safari_hls_completed", { videoId });
    } catch (webError) {
      debugLog("youtube.source", "web_safari_hls_failed", {
        videoId,
        error: webError instanceof Error ? webError.message : String(webError),
      });
      try {
        source = await tvDowngradedInnertubeSource(videoId, visitorData, signatureTimestamp);
        debugLog("youtube.source", "tv_downgraded_source_completed", {
          videoId,
          itag: source.itag,
          mimeType: source.mimeType,
          bitrate: source.bitrate,
        });
      } catch (tvError) {
        debugLog("youtube.source", "tv_downgraded_source_failed", {
          videoId,
          error: tvError instanceof Error ? tvError.message : String(tvError),
        });
        if (!youtubeLinked()) throw publicError;
        debugLog("youtube.source", "authenticated_decipher_started", { videoId });
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
