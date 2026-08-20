import { createHash } from "node:crypto";
import { debugLog } from "./debug";
import type { YouTubeMusicPlaybackBootstrap } from "./youtube-music";

type JsonObject = Record<string, unknown>;

export interface YouTubePlayerFormat {
  itag?: unknown;
  url?: unknown;
  signatureCipher?: unknown;
  cipher?: unknown;
  mimeType?: unknown;
  bitrate?: unknown;
  audioQuality?: unknown;
  audioSampleRate?: unknown;
  audioChannels?: unknown;
  contentLength?: unknown;
  approxDurationMs?: unknown;
}

export interface YouTubePlayerResponse {
  playabilityStatus?: {
    status?: unknown;
    reason?: unknown;
    messages?: unknown;
  };
  streamingData?: {
    expiresInSeconds?: unknown;
    formats?: unknown;
    adaptiveFormats?: unknown;
  };
  videoDetails?: {
    videoId?: unknown;
    title?: unknown;
    lengthSeconds?: unknown;
    channelId?: unknown;
    author?: unknown;
    thumbnail?: unknown;
  };
}

export interface YouTubeAudioFormat {
  itag: number;
  uri: string;
  mimeType: string;
  bitrate: number;
  audioQuality: string | null;
  sampleRate: number | null;
  channels: number | null;
  contentLength: number | null;
  durationMs: number | null;
}

export interface YouTubePlaybackSource {
  uri: string;
  httpHeaders: Record<string, string>;
  userAgent: string;
  referrer: string;
  webpageUrl: string;
  mimeType: string;
  bitrate: number;
  itag: number;
  contentLength: number | null;
  durationMs: number | null;
}

export interface YouTubePlayerRequest {
  context: Record<string, unknown>;
  videoId: string;
  playbackContext: {
    contentPlaybackContext: {
      html5Preference: "HTML5_PREF_WANTS";
      signatureTimestamp: number;
    };
  };
}

export interface YouTubePlayerRequestPlan {
  url: string;
  headers: Record<string, string>;
  body: YouTubePlayerRequest;
  mediaUserAgent: string;
}

export interface YouTubeBrowserIdentity {
  cookie: string;
  authUser: string;
  visitorData: string;
  userAgent: string;
  acceptLanguage: string;
  clientVersion: string;
  retainedHeaders: Record<string, string>;
}

export interface YouTubeCipheredAudioFormat {
  format: YouTubePlayerFormat;
  url: string;
  signatureCipher: string;
  cipher: string;
}

const MUSIC_ORIGIN = "https://music.youtube.com";
const PLAYER_ORIGIN = "https://www.youtube.com";
const WEB_SAFARI_CLIENT_VERSION = "2.20260708.00.00";
const WEB_SAFARI_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)";
const TV_DOWNGRADED_CLIENT_VERSION = "5.20260707";
const TV_DOWNGRADED_USER_AGENT = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version";

function cookieValue(cookie: string, name: string): string {
  const prefix = `${name}=`;
  return cookie.split(";").map((part) => part.trim())
    .find((part) => part.startsWith(prefix))?.slice(prefix.length) ?? "";
}

function browserAuthorization(cookie: string): string {
  const timestamp = String(Math.floor(Date.now() / 1000));
  const sapisid = cookieValue(cookie, "__Secure-3PAPISID");
  if (!sapisid) throw new Error("The linked YouTube Music session is missing __Secure-3PAPISID");
  const digest = createHash("sha1").update(`${timestamp} ${sapisid} ${MUSIC_ORIGIN}`).digest("hex");
  return `SAPISIDHASH ${timestamp}_${digest}`;
}

export function youtubeBrowserIdentity(headers: Record<string, string>, fallbackVisitorData: string): YouTubeBrowserIdentity {
  const cookie = headers.cookie ?? "";
  if (!cookie) throw new Error("The linked YouTube Music session is missing its Cookie header");
  const retainedHeaders = Object.fromEntries(Object.entries(headers).filter(([name, value]) =>
    Boolean(value) && (name.startsWith("x-goog-") || name.startsWith("x-youtube-"))
      && name !== "x-goog-authuser" && name !== "x-goog-visitor-id"
      && name !== "x-youtube-client-name" && name !== "x-youtube-client-version"));
  return {
    cookie,
    authUser: headers["x-goog-authuser"] ?? "0",
    visitorData: headers["x-goog-visitor-id"] ?? fallbackVisitorData,
    userAgent: headers["user-agent"] || "Mozilla/5.0",
    acceptLanguage: headers["accept-language"] ?? "",
    clientVersion: headers["x-youtube-client-version"] || "1.20260719.16.00",
    retainedHeaders,
  };
}

export function buildYouTubePlayerRequest(
  videoId: string,
  signatureTimestamp: number,
  bootstrap: YouTubeMusicPlaybackBootstrap,
): YouTubePlayerRequestPlan {
  if (!/^[A-Za-z0-9_-]{11}$/.test(videoId)) throw new Error("Invalid YouTube video ID");
  if (!bootstrap.visitorData.trim()) throw new Error("YouTube Music player requires visitor data");
  if (!Number.isSafeInteger(signatureTimestamp) || signatureTimestamp <= 0) {
    throw new Error("YouTube Music player requires a valid signature timestamp");
  }
  return {
    url: `${MUSIC_ORIGIN}/youtubei/v1/player?prettyPrint=false`,
    headers: {
      "Content-Type": "application/json",
      "User-Agent": bootstrap.userAgent,
      "X-Youtube-Client-Name": bootstrap.clientNumber,
      "X-Youtube-Client-Version": bootstrap.clientVersion,
      "X-Goog-Visitor-Id": bootstrap.visitorData,
      Origin: MUSIC_ORIGIN,
    },
    body: {
      context: bootstrap.context,
      videoId,
      playbackContext: {
        contentPlaybackContext: {
          html5Preference: "HTML5_PREF_WANTS",
          signatureTimestamp,
        },
      },
    },
    mediaUserAgent: bootstrap.userAgent,
  };
}

export async function requestYouTubePlayer(
  videoId: string,
  signatureTimestamp: number,
  bootstrap: YouTubeMusicPlaybackBootstrap,
): Promise<{ document: unknown; mediaUserAgent: string }> {
  const plan = buildYouTubePlayerRequest(videoId, signatureTimestamp, bootstrap);
  const response = await fetch(plan.url, {
    method: "POST",
    headers: plan.headers,
    body: JSON.stringify(plan.body),
  });
  const document: unknown = await response.json().catch(() => ({}));
  const playability = (document as { playabilityStatus?: { status?: unknown } }).playabilityStatus?.status;
  debugLog("youtube.player", "response", {
    videoId,
    httpStatus: response.status,
    playabilityStatus: typeof playability === "string" ? playability : "missing",
  });
  if (!response.ok) throw new Error(`YouTube player returned HTTP ${response.status}`);
  return { document, mediaUserAgent: plan.mediaUserAgent };
}

export function buildYouTubeWebSafariPlayerRequest(
  videoId: string,
  visitorData: string,
  signatureTimestamp: number,
): { url: string; headers: Record<string, string>; body: Record<string, unknown>; mediaUserAgent: string } {
  if (!/^[A-Za-z0-9_-]{11}$/.test(videoId)) throw new Error("Invalid YouTube video ID");
  if (!visitorData.trim()) throw new Error("YouTube Music player requires visitor data");
  if (!Number.isSafeInteger(signatureTimestamp) || signatureTimestamp <= 0) {
    throw new Error("YouTube Music player requires a valid signature timestamp");
  }
  return {
    url: `${PLAYER_ORIGIN}/youtubei/v1/player?prettyPrint=false`,
    headers: {
      "Content-Type": "application/json",
      "User-Agent": WEB_SAFARI_USER_AGENT,
      "X-Youtube-Client-Name": "1",
      "X-Youtube-Client-Version": WEB_SAFARI_CLIENT_VERSION,
      "X-Goog-Visitor-Id": visitorData,
      Origin: PLAYER_ORIGIN,
    },
    body: {
      context: { client: {
        clientName: "WEB",
        clientVersion: WEB_SAFARI_CLIENT_VERSION,
        userAgent: WEB_SAFARI_USER_AGENT,
        hl: "en",
        gl: "US",
        visitorData,
      } },
      videoId,
      playbackContext: { contentPlaybackContext: {
        html5Preference: "HTML5_PREF_WANTS",
        signatureTimestamp,
      } },
      contentCheckOk: true,
      racyCheckOk: true,
    },
    mediaUserAgent: WEB_SAFARI_USER_AGENT,
  };
}

export async function requestYouTubeWebSafariPlayer(
  videoId: string,
  visitorData: string,
  signatureTimestamp: number,
): Promise<{ document: unknown; mediaUserAgent: string }> {
  const plan = buildYouTubeWebSafariPlayerRequest(videoId, visitorData, signatureTimestamp);
  const response = await fetch(plan.url, {
    method: "POST",
    headers: plan.headers,
    body: JSON.stringify(plan.body),
  });
  const document: unknown = await response.json().catch(() => ({}));
  const playability = (document as { playabilityStatus?: { status?: unknown } }).playabilityStatus?.status;
  debugLog("youtube.player", "web_safari_response", {
    videoId,
    httpStatus: response.status,
    playabilityStatus: typeof playability === "string" ? playability : "missing",
  });
  if (!response.ok) throw new Error(`YouTube web player returned HTTP ${response.status}`);
  return { document, mediaUserAgent: plan.mediaUserAgent };
}

export function buildYouTubeTvDowngradedPlayerRequest(
  videoId: string,
  visitorData: string,
  signatureTimestamp: number,
): { url: string; headers: Record<string, string>; body: Record<string, unknown>; mediaUserAgent: string } {
  if (!/^[A-Za-z0-9_-]{11}$/.test(videoId)) throw new Error("Invalid YouTube video ID");
  if (!visitorData.trim()) throw new Error("YouTube Music player requires visitor data");
  if (!Number.isSafeInteger(signatureTimestamp) || signatureTimestamp <= 0) {
    throw new Error("YouTube Music player requires a valid signature timestamp");
  }
  return {
    url: `${PLAYER_ORIGIN}/youtubei/v1/player?prettyPrint=false`,
    headers: {
      "Content-Type": "application/json",
      "User-Agent": TV_DOWNGRADED_USER_AGENT,
      "X-Youtube-Client-Name": "7",
      "X-Youtube-Client-Version": TV_DOWNGRADED_CLIENT_VERSION,
      "X-Goog-Visitor-Id": visitorData,
      Origin: PLAYER_ORIGIN,
    },
    body: {
      context: {
        client: {
          clientName: "TVHTML5",
          clientVersion: TV_DOWNGRADED_CLIENT_VERSION,
          hl: "en",
          gl: "US",
          visitorData,
        },
      },
      videoId,
      playbackContext: { contentPlaybackContext: {
        html5Preference: "HTML5_PREF_WANTS",
        signatureTimestamp,
      } },
      contentCheckOk: true,
      racyCheckOk: true,
    },
    mediaUserAgent: TV_DOWNGRADED_USER_AGENT,
  };
}

export async function requestYouTubeTvDowngradedPlayer(
  videoId: string,
  visitorData: string,
  signatureTimestamp: number,
): Promise<{ document: unknown; mediaUserAgent: string }> {
  const plan = buildYouTubeTvDowngradedPlayerRequest(videoId, visitorData, signatureTimestamp);
  const response = await fetch(plan.url, {
    method: "POST",
    headers: plan.headers,
    body: JSON.stringify(plan.body),
  });
  const document: unknown = await response.json().catch(() => ({}));
  const playability = (document as { playabilityStatus?: { status?: unknown } }).playabilityStatus?.status;
  debugLog("youtube.player", "tv_downgraded_response", {
    videoId,
    httpStatus: response.status,
    playabilityStatus: typeof playability === "string" ? playability : "missing",
  });
  if (!response.ok) throw new Error(`YouTube TV player returned HTTP ${response.status}`);
  return { document, mediaUserAgent: plan.mediaUserAgent };
}

export async function requestAuthenticatedYouTubePlayer(
  videoId: string,
  identity: YouTubeBrowserIdentity,
  signatureTimestamp: number,
): Promise<{ document: unknown; mediaUserAgent: string; referrer: string }> {
  if (!/^[A-Za-z0-9_-]{11}$/.test(videoId)) throw new Error("Invalid YouTube video ID");
  const body = {
    context: {
      client: {
        clientName: "WEB_REMIX",
        clientVersion: identity.clientVersion,
        hl: "en",
        gl: "US",
        visitorData: identity.visitorData,
        userAgent: identity.userAgent,
        platform: "DESKTOP",
        clientFormFactor: "UNKNOWN_FORM_FACTOR",
      },
      user: { lockedSafetyMode: false },
      request: { useSsl: true },
    },
    videoId,
    playbackContext: { contentPlaybackContext: {
      html5Preference: "HTML5_PREF_WANTS",
      signatureTimestamp,
    } },
    contentCheckOk: true,
    racyCheckOk: true,
  } as const;
  const response = await fetch(`${MUSIC_ORIGIN}/youtubei/v1/player?prettyPrint=false`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": browserAuthorization(identity.cookie),
      "Cookie": identity.cookie,
      "User-Agent": identity.userAgent,
      ...(identity.acceptLanguage ? { "Accept-Language": identity.acceptLanguage } : {}),
      ...identity.retainedHeaders,
      "X-Goog-AuthUser": identity.authUser,
      "X-Goog-Visitor-Id": identity.visitorData,
      "X-Youtube-Client-Name": "67",
      "X-Youtube-Client-Version": identity.clientVersion,
      "Origin": MUSIC_ORIGIN,
      "X-Origin": MUSIC_ORIGIN,
    },
    body: JSON.stringify(body),
  });
  const document: unknown = await response.json().catch(() => ({}));
  const playability = (document as { playabilityStatus?: { status?: unknown } }).playabilityStatus?.status;
  debugLog("youtube.player", "authenticated_response", {
    videoId,
    httpStatus: response.status,
    playabilityStatus: typeof playability === "string" ? playability : "missing",
  });
  if (!response.ok) throw new Error(`Authenticated YouTube player returned HTTP ${response.status}`);
  return { document, mediaUserAgent: identity.userAgent, referrer: `${MUSIC_ORIGIN}/` };
}

function object(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function positiveNumber(value: unknown): number | null {
  const number = typeof value === "number" ? value
    : typeof value === "string" && value.trim() ? Number(value) : Number.NaN;
  return Number.isFinite(number) && number > 0 ? number : null;
}

function formatFrom(value: unknown): YouTubeAudioFormat | null {
  const raw = object(value) as YouTubePlayerFormat;
  const itag = positiveNumber(raw.itag);
  const uri = text(raw.url);
  const mimeType = text(raw.mimeType);
  const bitrate = positiveNumber(raw.bitrate);
  if (!itag || !uri.startsWith("https://") || !mimeType.toLowerCase().startsWith("audio/") || !bitrate) {
    return null;
  }
  return {
    itag,
    uri,
    mimeType,
    bitrate,
    audioQuality: text(raw.audioQuality) || null,
    sampleRate: positiveNumber(raw.audioSampleRate),
    channels: positiveNumber(raw.audioChannels),
    contentLength: positiveNumber(raw.contentLength),
    durationMs: positiveNumber(raw.approxDurationMs),
  };
}

function qualityRank(format: YouTubeAudioFormat): number {
  const quality = format.audioQuality ?? "";
  const namedQuality = quality.includes("HIGH") ? 3 : quality.includes("MEDIUM") ? 2
    : quality.includes("LOW") ? 1 : 0;
  // Prefer a higher advertised quality, then the actual encoded bitrate. Opus
  // usually wins at comparable rates, while AAC remains a natural fallback.
  const codecPreference = format.mimeType.includes("opus") ? 2
    : format.mimeType.includes("mp4a") ? 1 : 0;
  return namedQuality * 1_000_000_000 + format.bitrate * 10 + codecPreference;
}

function rawQualityRank(format: YouTubePlayerFormat): number {
  const quality = text(format.audioQuality);
  const namedQuality = quality.includes("HIGH") ? 3 : quality.includes("MEDIUM") ? 2
    : quality.includes("LOW") ? 1 : 0;
  const mimeType = text(format.mimeType);
  const codecPreference = mimeType.includes("opus") ? 2 : mimeType.includes("mp4a") ? 1 : 0;
  return namedQuality * 1_000_000_000 + (positiveNumber(format.bitrate) ?? 0) * 10 + codecPreference;
}

function playabilityError(response: YouTubePlayerResponse): string | null {
  const status = text(response.playabilityStatus?.status);
  if (!status || status === "OK") return null;
  const reason = text(response.playabilityStatus?.reason);
  const messages = array(response.playabilityStatus?.messages).map(text).filter(Boolean).join(" ");
  return `YouTube Music playback is ${status.toLowerCase()}${reason || messages ? `: ${reason || messages}` : ""}`;
}

export function youtubePlayerRequiresLogin(document: unknown): boolean {
  return text((object(document) as YouTubePlayerResponse).playabilityStatus?.status) === "LOGIN_REQUIRED";
}

export function selectYouTubeAudioFormat(document: unknown): YouTubeAudioFormat {
  const response = object(document) as YouTubePlayerResponse;
  const unavailable = playabilityError(response);
  if (unavailable) throw new Error(unavailable);
  const streamingData = response.streamingData ?? {};
  const rawFormats = [...array(streamingData.adaptiveFormats), ...array(streamingData.formats)];
  const formats = rawFormats.map(formatFrom).filter((format): format is YouTubeAudioFormat => format !== null);
  formats.sort((left, right) => qualityRank(right) - qualityRank(left));
  const selected = formats[0];
  if (selected) {
    debugLog("youtube.player", "format_selected", {
      itag: selected.itag,
      mimeType: selected.mimeType,
      bitrate: selected.bitrate,
      contentLength: selected.contentLength,
      durationMs: selected.durationMs,
    });
    return selected;
  }

  const ciphered = rawFormats.some((value) => {
    const format = object(value) as YouTubePlayerFormat;
    return text(format.mimeType).toLowerCase().startsWith("audio/")
      && Boolean(text(format.signatureCipher) || text(format.cipher));
  });
  if (ciphered) {
    throw new Error("YouTube Music returned only ciphered audio formats; player signature handling needs an update");
  }
  throw new Error("YouTube Music returned no directly playable audio format");
}

export function selectYouTubeCipheredAudioFormat(document: unknown): YouTubeCipheredAudioFormat {
  const response = object(document) as YouTubePlayerResponse;
  const unavailable = playabilityError(response);
  if (unavailable) throw new Error(unavailable);
  const streamingData = response.streamingData ?? {};
  const formats = [...array(streamingData.adaptiveFormats), ...array(streamingData.formats)]
    .map((value) => object(value) as YouTubePlayerFormat)
    .filter((format) => text(format.mimeType).toLowerCase().startsWith("audio/")
      && Boolean(text(format.url) || text(format.signatureCipher) || text(format.cipher)))
    .sort((left, right) => rawQualityRank(right) - rawQualityRank(left));
  const format = formats[0];
  if (!format) throw new Error("Authenticated YouTube Music returned no audio format to decipher");
  return {
    format,
    url: text(format.url),
    signatureCipher: text(format.signatureCipher),
    cipher: text(format.cipher),
  };
}

export function parseYouTubePlayerResponse(
  document: unknown,
  videoId: string,
  userAgent: string,
  referrer = "",
): YouTubePlaybackSource {
  if (!/^[A-Za-z0-9_-]{11}$/.test(videoId)) throw new Error("Invalid YouTube video ID");
  const format = selectYouTubeAudioFormat(document);
  return {
    uri: format.uri,
    httpHeaders: { "User-Agent": userAgent },
    userAgent,
    referrer,
    webpageUrl: `${MUSIC_ORIGIN}/watch?v=${videoId}`,
    mimeType: format.mimeType,
    bitrate: format.bitrate,
    itag: format.itag,
    contentLength: format.contentLength,
    durationMs: format.durationMs,
  };
}
