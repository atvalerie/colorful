import { createHash } from "node:crypto";
import type { AlbumPage, AlbumSummary, ArtistCredit, ArtistPage, ArtistSummary, CatalogSearch, PlaylistPage, PlaylistSummary, TrackSummary, UserCollectionPage } from "./browse";
import { debugLog } from "./debug";

type JsonObject = Record<string, unknown>;
type Run = { text?: unknown; navigationEndpoint?: unknown };

const MUSIC_ORIGIN = "https://music.youtube.com";
export const YOUTUBE_MUSIC_USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/140 Safari/537.36";
const MUSIC_API_KEY = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30";
const PLAYLIST_BROWSE_CURSOR = "youtube-music-browse:";
const PLAYLIST_WATCH_CURSOR = "youtube-music-watch:";
const AUTOMIX_CURSOR = "youtube-music-automix:";
const ARTIST_TRACKS_CURSOR = "youtube-music-artist-tracks:";
let accessTokenProvider: (() => Promise<string>) | null = null;
let browserHeadersProvider: (() => Promise<Record<string, string>>) | null = null;
let visitorIdPromise: Promise<string> | null = null;
let bootstrapPromise: Promise<JsonObject> | null = null;
let signatureTimestampPromise: Promise<number> | null = null;
let playerScriptUrlPromise: Promise<URL> | null = null;
const SEARCH_FILTERS = {
  songs: "EgWKAQIIAWoQEAUQBBADEAoQCRAVEBAQEQ%3D%3D",
  videos: "EgWKAQIQAWoQEAUQBBADEAoQCRAVEBAQEQ%3D%3D",
  albums: "EgWKAQIYAWoQEAUQBBADEAoQCRAVEBAQEQ%3D%3D",
  artists: "EgWKAQIgAWoQEAUQBBADEAoQCRAVEBAQEQ%3D%3D",
} as const;

function object(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : {};
}

function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function string(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function children(root: unknown, key: string, output: JsonObject[] = []): JsonObject[] {
  if (Array.isArray(root)) {
    for (const value of root) children(value, key, output);
  } else if (root && typeof root === "object") {
    for (const [name, value] of Object.entries(root)) {
      if (name === key && value && typeof value === "object" && !Array.isArray(value)) output.push(value as JsonObject);
      children(value, key, output);
    }
  }
  return output;
}

function runs(value: unknown): Run[] {
  return array(object(value).runs).filter((run): run is Run => Boolean(run) && typeof run === "object");
}

function runText(value: unknown): string {
  return runs(value).map((run) => string(run.text)).join("").trim() || string(object(value).simpleText);
}

function browseId(run: Run): string {
  return string(object(object(run.navigationEndpoint).browseEndpoint).browseId);
}

function browsePageType(run: Run): string {
  const endpoint = object(object(run.navigationEndpoint).browseEndpoint);
  const configs = object(endpoint.browseEndpointContextSupportedConfigs);
  return string(object(configs.browseEndpointContextMusicConfig).pageType);
}

function videoId(run: Run): string {
  return string(object(object(run.navigationEndpoint).watchEndpoint).videoId);
}

function rendererBrowseId(renderer: JsonObject): string {
  return string(object(object(renderer.navigationEndpoint).browseEndpoint).browseId)
    || children(renderer, "browseEndpoint").map((endpoint) => string(endpoint.browseId)).find(Boolean) || "";
}

function columnRuns(renderer: JsonObject, index: number): Run[] {
  const column = object(array(renderer.flexColumns)[index]);
  return runs(object(object(column.musicResponsiveListItemFlexColumnRenderer).text));
}

function thumbnail(root: unknown): string | null {
  const candidates = children(root, "thumbnail")
    .flatMap((document) => array(document.thumbnails))
    .map(object)
    .filter((item) => string(item.url))
    .sort((left, right) => Number(right.width ?? 0) * Number(right.height ?? 0)
      - Number(left.width ?? 0) * Number(left.height ?? 0));
  const url = string(candidates[0]?.url);
  return url ? url.replace(/^\/\//, "https://") : null;
}

function durationMs(text: string): number | null {
  if (!/^\d+(?::\d+){1,2}$/.test(text)) return null;
  const parts = text.split(":").map(Number);
  let seconds = 0;
  for (const part of parts) seconds = seconds * 60 + part;
  return seconds > 0 ? seconds * 1000 : null;
}

function isArtistId(id: string): boolean {
  return id.startsWith("UC") || id.startsWith("MPLA");
}

function creditsFrom(runs_: Run[]): ArtistCredit[] {
  const seen = new Set<string>();
  const result: ArtistCredit[] = [];
  for (const run of runs_) {
    const id = browseId(run);
    const name = string(run.text);
    if (!id || !name || !isArtistId(id) || seen.has(id)) continue;
    seen.add(id);
    result.push({ id, name });
  }
  return result;
}

function explicit(root: unknown): boolean {
  return children(root, "musicInlineBadgeRenderer").some((badge) => {
    const label = string(object(badge.accessibilityData).label).toLocaleLowerCase();
    return label.includes("explicit");
  });
}

function mapTrack(renderer: JsonObject): TrackSummary | null {
  const titleRuns = columnRuns(renderer, 0);
  const metadataRuns = columnRuns(renderer, 1);
  const id = titleRuns.map(videoId).find(Boolean)
    || children(renderer, "watchEndpoint").map((endpoint) => string(endpoint.videoId)).find(Boolean) || "";
  const title = titleRuns.map((run) => string(run.text)).join("").trim();
  if (!id || !title) return null;
  const artistCredits = creditsFrom(metadataRuns);
  const albumRun = metadataRuns.find((run) => browseId(run).startsWith("MPRE"));
  const fixedRuns = array(renderer.fixedColumns).flatMap((column) =>
    runs(object(object(object(column).musicResponsiveListItemFixedColumnRenderer).text)));
  const length = [...metadataRuns, ...fixedRuns].reverse().map((run) => string(run.text))
    .find((value) => /^\d+(?::\d+){1,2}$/.test(value)) || "";
  return {
    id,
    title,
    version: null,
    artists: artistCredits.map((artist) => artist.name),
    artistCredits,
    albumId: albumRun ? browseId(albumRun) : null,
    albumTitle: albumRun ? string(albumRun.text) : null,
    durationMs: durationMs(length),
    isrc: null,
    coverUrl: thumbnail(renderer),
    explicit: explicit(renderer),
    mediaKind: "song",
  };
}

function mapVideo(renderer: JsonObject): TrackSummary | null {
  const titleRuns = columnRuns(renderer, 0);
  const metadataRuns = columnRuns(renderer, 1);
  const id = titleRuns.map(videoId).find(Boolean)
    || children(renderer, "watchEndpoint").map((endpoint) => string(endpoint.videoId)).find(Boolean) || "";
  const title = titleRuns.map((run) => string(run.text)).join("").trim();
  if (!id || !title) return null;
  const uploaderRun = metadataRuns.find((run) => browseId(run).startsWith("UC"));
  const uploaderId = uploaderRun ? browseId(uploaderRun) : null;
  const uploaderName = uploaderRun ? string(uploaderRun.text) : "YouTube Music";
  const length = [...metadataRuns].reverse().map((run) => string(run.text))
    .find((value) => /^\d+(?::\d+){1,2}$/.test(value)) || "";
  const uploader = { id: uploaderId, name: uploaderName };
  return {
    id,
    title,
    version: null,
    artists: [uploaderName],
    artistCredits: uploaderId ? [{ id: uploaderId, name: uploaderName }] : [],
    uploader,
    albumId: null,
    albumTitle: null,
    durationMs: durationMs(length),
    isrc: null,
    coverUrl: thumbnail(renderer),
    explicit: false,
    mediaKind: "video",
  };
}

function mapAlbum(renderer: JsonObject): AlbumSummary | null {
  const titleRuns = columnRuns(renderer, 0);
  const metadataRuns = columnRuns(renderer, 1);
  const navigableRuns = [...titleRuns, ...metadataRuns];
  const albumRun = navigableRuns.find((run) => browseId(run).startsWith("MPRE"));
  const id = albumRun ? browseId(albumRun) : rendererBrowseId(renderer);
  const title = titleRuns.map((run) => string(run.text)).join("").trim() || (albumRun ? string(albumRun.text) : "");
  if (!id || !title) return null;
  const artistCredits = creditsFrom(metadataRuns);
  const year = metadataRuns.map((run) => string(run.text)).find((value) => /^\d{4}$/.test(value)) || null;
  const type = metadataRuns.map((run) => string(run.text)).find((value) => /^(album|single|ep)$/i.test(value)) || null;
  return {
    id,
    title,
    version: null,
    artists: artistCredits.map((artist) => artist.name),
    artistCredits,
    coverUrl: thumbnail(renderer),
    releaseDate: year,
    durationMs: null,
    numberOfTracks: null,
    albumType: type,
    explicit: explicit(renderer),
    mediaTags: [],
  };
}

function mapArtist(renderer: JsonObject): ArtistSummary | null {
  const allRuns = array(renderer.flexColumns).flatMap((column) =>
    runs(object(object(object(column).musicResponsiveListItemFlexColumnRenderer).text)));
  const artistRun = allRuns.find((run) => isArtistId(browseId(run)));
  const fallbackId = rendererBrowseId(renderer);
  const id = artistRun ? browseId(artistRun) : (isArtistId(fallbackId) ? fallbackId : "");
  const name = artistRun ? string(artistRun.text) : string(allRuns[0]?.text);
  const endpointRun = artistRun || allRuns.find((run) => browseId(run) === id);
  return id && name ? {
    id,
    name,
    pictureUrl: thumbnail(renderer),
    isChannel: endpointRun ? browsePageType(endpointRun) === "MUSIC_PAGE_TYPE_USER_CHANNEL" : false,
  } : null;
}

function clientVersion(): string {
  const now = new Date();
  const date = `${now.getUTCFullYear()}${String(now.getUTCMonth() + 1).padStart(2, "0")}${String(now.getUTCDate()).padStart(2, "0")}`;
  return `1.${date}.01.00`;
}

export function parseYouTubeMusicBootstrap(html: string): JsonObject {
  const marker = "ytcfg.set(";
  const merged: JsonObject = {};
  let searchFrom = 0;
  while (searchFrom < html.length) {
    const markerIndex = html.indexOf(marker, searchFrom);
    if (markerIndex < 0) break;
    const start = markerIndex + marker.length;
    let depth = 0;
    let quoted = false;
    let escaped = false;
    let end = -1;
    for (let index = start; index < html.length; index += 1) {
      const character = html[index];
      if (quoted) {
        if (escaped) escaped = false;
        else if (character === "\\") escaped = true;
        else if (character === "\"") quoted = false;
        continue;
      }
      if (character === "\"") quoted = true;
      else if (character === "{") depth += 1;
      else if (character === "}") {
        depth -= 1;
        if (depth === 0) {
          end = index + 1;
          break;
        }
      }
    }
    if (end > start) {
      try {
        const value = object(JSON.parse(html.slice(start, end)) as unknown);
        Object.assign(merged, value);
      } catch {
        // Some pages also call ytcfg.set with JavaScript object literals. The
        // server bootstrap is strict JSON; ignore unrelated executable input.
      }
      searchFrom = end;
    } else {
      searchFrom = start;
    }
  }
  return merged;
}

async function youtubeMusicBootstrap(): Promise<JsonObject> {
  if (!bootstrapPromise) {
    bootstrapPromise = fetch(MUSIC_ORIGIN, {
      headers: { "User-Agent": YOUTUBE_MUSIC_USER_AGENT },
    }).then(async (response) => {
      if (!response.ok) throw new Error(`YouTube Music bootstrap returned HTTP ${response.status}`);
      const config = parseYouTubeMusicBootstrap(await response.text());
      if (!string(config.INNERTUBE_CLIENT_VERSION) || !Object.keys(object(config.INNERTUBE_CONTEXT)).length) {
        throw new Error("YouTube Music bootstrap did not contain an Innertube client context");
      }
      return config;
    }).catch((error) => {
      bootstrapPromise = null;
      throw error;
    });
  }
  return bootstrapPromise;
}

export function parseYouTubeSignatureTimestamp(script: string): number | null {
  const value = Number(script.match(/signatureTimestamp\s*:\s*(\d{4,6})/)?.[1]);
  return Number.isSafeInteger(value) && value > 0 ? value : null;
}

async function youtubeMusicPlayerScriptUrl(): Promise<URL> {
  if (!playerScriptUrlPromise) {
    playerScriptUrlPromise = youtubeMusicBootstrap().then((bootstrap) => {
      const playerConfigs = object(bootstrap.WEB_PLAYER_CONTEXT_CONFIGS);
      const playerConfig = Object.values(playerConfigs).map(object)
        .find((config) => string(config.jsUrl));
      const relativeUrl = string(playerConfig?.jsUrl);
      if (!relativeUrl) throw new Error("YouTube Music bootstrap did not contain a player script URL");
      return new URL(relativeUrl, MUSIC_ORIGIN);
    }).catch((error) => {
      playerScriptUrlPromise = null;
      throw error;
    });
  }
  return playerScriptUrlPromise;
}

export async function youtubeMusicPlayerId(): Promise<string> {
  const playerId = (await youtubeMusicPlayerScriptUrl()).pathname.match(/\/s\/player\/([^/]+)\//)?.[1] ?? "";
  if (!playerId) throw new Error("YouTube Music player script URL did not contain a player ID");
  return playerId;
}

export async function youtubeMusicSignatureTimestamp(): Promise<number> {
  if (!signatureTimestampPromise) {
    signatureTimestampPromise = (async () => {
      const response = await fetch(await youtubeMusicPlayerScriptUrl(), {
        headers: { "User-Agent": YOUTUBE_MUSIC_USER_AGENT },
      });
      if (!response.ok) throw new Error(`YouTube Music player script returned HTTP ${response.status}`);
      const timestamp = parseYouTubeSignatureTimestamp(await response.text());
      if (!timestamp) throw new Error("YouTube Music player script did not contain a signature timestamp");
      return timestamp;
    })().catch((error) => {
      signatureTimestampPromise = null;
      throw error;
    });
  }
  return signatureTimestampPromise;
}

export async function youtubeMusicVisitorData(): Promise<string> {
  const bootstrap = await youtubeMusicBootstrap();
  const visitor = string(object(object(bootstrap.INNERTUBE_CONTEXT).client).visitorData);
  if (!visitor) throw new Error("YouTube Music bootstrap did not contain visitor data");
  return visitor;
}

export function refreshYouTubeMusicPlayerState(): void {
  bootstrapPromise = null;
  signatureTimestampPromise = null;
  playerScriptUrlPromise = null;
  visitorIdPromise = null;
}

export function setYouTubeMusicAccessTokenProvider(provider: (() => Promise<string>) | null): void {
  accessTokenProvider = provider;
}

export function setYouTubeMusicBrowserHeadersProvider(provider: (() => Promise<Record<string, string>>) | null): void {
  browserHeadersProvider = provider;
}

export type YouTubeSearchCursors = {
  songs?: string;
  videos?: string;
  albums?: string;
  artists?: string;
};

export interface YouTubeMusicAutomixRequest extends JsonObject {
  videoId: string;
  playlistId: string;
  enablePersistentPlaylistPanel: true;
  isAudioOnly: true;
  tunerSettingValue: "AUTOMIX_SETTING_NORMAL";
}

export function youtubeMusicAutomixRequest(video: string): YouTubeMusicAutomixRequest {
  if (!/^[A-Za-z0-9_-]{11}$/.test(video)) throw new Error("Invalid YouTube video ID");
  return {
    videoId: video,
    playlistId: `RDAMVM${video}`,
    enablePersistentPlaylistPanel: true,
    isAudioOnly: true,
    tunerSettingValue: "AUTOMIX_SETTING_NORMAL",
  };
}

function protobufVarint(value: number): Uint8Array {
  if (!Number.isSafeInteger(value) || value < 0) throw new Error("Invalid protobuf integer");
  const bytes: number[] = [];
  do {
    const next = value % 128;
    value = Math.floor(value / 128);
    bytes.push(next | (value ? 0x80 : 0));
  } while (value);
  return Uint8Array.from(bytes);
}

function protobufBytes(field: number, value: Uint8Array): Uint8Array {
  return Uint8Array.from([
    ...protobufVarint(field * 8 + 2),
    ...protobufVarint(value.length),
    ...value,
  ]);
}

function protobufString(field: number, value: string): Uint8Array {
  return protobufBytes(field, new TextEncoder().encode(value));
}

function protobufInteger(field: number, value: number): Uint8Array {
  return Uint8Array.from([...protobufVarint(field * 8), ...protobufVarint(value)]);
}

function protobufMessage(...fields: Uint8Array[]): Uint8Array {
  return Uint8Array.from(fields.flatMap((field) => [...field]));
}

function protobufStringField(encoded: string, wantedField: number): string {
  let bytes: Uint8Array;
  try {
    bytes = Buffer.from(decodeURIComponent(encoded).replace(/-/g, "+").replace(/_/g, "/"), "base64");
  } catch {
    return "";
  }
  let offset = 0;
  const readVarint = (): number | null => {
    let value = 0;
    let multiplier = 1;
    for (let count = 0; count < 10 && offset < bytes.length; ++count) {
      const byte = bytes[offset++]!;
      value += (byte & 0x7f) * multiplier;
      if (!(byte & 0x80)) return Number.isSafeInteger(value) ? value : null;
      multiplier *= 128;
    }
    return null;
  };
  while (offset < bytes.length) {
    const tag = readVarint();
    if (tag === null) return "";
    const field = Math.floor(tag / 8);
    const wire = tag % 8;
    if (wire === 0) {
      if (readVarint() === null) return "";
      continue;
    }
    if (wire === 1) {
      offset += 8;
      continue;
    }
    if (wire === 5) {
      offset += 4;
      continue;
    }
    if (wire !== 2) return "";
    const length = readVarint();
    if (length === null || offset + length > bytes.length) return "";
    const value = bytes.slice(offset, offset + length);
    offset += length;
    if (field === wantedField) return new TextDecoder().decode(value);
  }
  return "";
}

function encodedProtobuf(message: Uint8Array): string {
  return encodeURIComponent(Buffer.from(message).toString("base64"));
}

function encodedCursor(value: JsonObject): string {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function decodedCursor(value: string): JsonObject {
  try {
    return object(JSON.parse(Buffer.from(value, "base64url").toString("utf8")));
  } catch {
    return {};
  }
}

/** Build the continuation YouTube Music normally emits after its 50-item radio window. */
export function youtubeMusicAutomixContinuation(renderer: JsonObject): string {
  const endpoint = object(object(renderer.navigationEndpoint).watchEndpoint);
  const currentVideo = string(endpoint.videoId);
  const playlistId = string(endpoint.playlistId);
  const playlistSetVideoId = string(endpoint.playlistSetVideoId);
  const index = Number(endpoint.index);
  const queueId = protobufStringField(string(endpoint.params), 66);
  if (!/^[A-Za-z0-9_-]{11}$/.test(currentVideo)
      || !/^RDAMVM[A-Za-z0-9_-]{11}$/.test(playlistId)
      || !/^[A-Fa-f0-9]{16}$/.test(playlistSetVideoId)
      || !Number.isSafeInteger(index) || index < 0
      || !/^[A-Za-z0-9_-]{16,128}$/.test(queueId)) return "";

  const queue = protobufMessage(
    protobufInteger(24, 1),
    protobufString(30, ""),
    protobufBytes(51, protobufInteger(1, 600)),
    protobufString(66, queueId),
    protobufString(95, ""),
  );
  const state = protobufMessage(
    protobufString(2, currentVideo),
    protobufString(4, playlistId),
    protobufString(6, encodedProtobuf(queue)),
    protobufInteger(7, index),
    protobufInteger(26, 1),
    protobufString(31, playlistSetVideoId),
  );
  return encodedProtobuf(protobufMessage(
    protobufInteger(1, index + 1),
    protobufBytes(2, state),
    protobufInteger(3, 10),
  ));
}

function cookieValue(cookie: string, name: string): string {
  const prefix = `${name}=`;
  return cookie.split(";").map((part) => part.trim()).find((part) => part.startsWith(prefix))?.slice(prefix.length) ?? "";
}

function browserAuthorization(cookie: string): string {
  const timestamp = String(Math.floor(Date.now() / 1000));
  const sapisid = cookieValue(cookie, "__Secure-3PAPISID");
  const digest = createHash("sha1").update(`${timestamp} ${sapisid} ${MUSIC_ORIGIN}`).digest("hex");
  return `SAPISIDHASH ${timestamp}_${digest}`;
}

async function visitorId(): Promise<string> {
  if (!visitorIdPromise) {
    visitorIdPromise = fetch(MUSIC_ORIGIN, {
      headers: { "User-Agent": YOUTUBE_MUSIC_USER_AGENT },
    }).then(async (response) => {
      if (!response.ok) return "";
      const html = await response.text();
      return html.match(/"VISITOR_DATA"\s*:\s*"([^"]+)"/)?.[1] ?? "";
    }).catch(() => "");
  }
  return visitorIdPromise;
}

export type YouTubeiEndpoint = "search" | "browse" | "next" | "account/account_menu";

export async function youtubei(endpoint: YouTubeiEndpoint, body: JsonObject,
  accountRequired = false): Promise<JsonObject> {
  let accessToken = "";
  let browserHeaders: Record<string, string> = {};
  if (browserHeadersProvider) browserHeaders = await browserHeadersProvider().catch(() => ({}));
  if (accessTokenProvider) {
    try {
      accessToken = await accessTokenProvider();
    } catch (error) {
      if (accountRequired) throw error;
    }
  }
  const browserCookie = browserHeaders.cookie ?? "";
  const browserAuthUser = browserHeaders["x-goog-authuser"] ?? "0";
  if (accountRequired && !browserCookie && !accessToken) throw new Error("Connect your YouTube Music account first");
  const visitor = browserHeaders["x-goog-visitor-id"] ?? ((accessToken || browserCookie) ? await visitorId() : "");
  const retainedIdentityHeaders = Object.fromEntries(Object.entries(browserHeaders).filter(([name]) =>
    (name.startsWith("x-goog-") || name.startsWith("x-youtube-"))
      && name !== "x-goog-authuser" && name !== "x-goog-visitor-id"));
  const browserClientVersion = browserHeaders["x-youtube-client-version"] || clientVersion();
  const response = await fetch(`${MUSIC_ORIGIN}/youtubei/v1/${endpoint}?alt=json${browserCookie ? `&key=${MUSIC_API_KEY}` : ""}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "*/*",
      "Origin": MUSIC_ORIGIN,
      "User-Agent": YOUTUBE_MUSIC_USER_AGENT,
      ...(browserCookie ? {
        "Authorization": browserAuthorization(browserCookie),
        "Cookie": browserCookie,
        ...retainedIdentityHeaders,
        "X-Goog-AuthUser": browserAuthUser,
        ...(browserHeaders["user-agent"] ? { "User-Agent": browserHeaders["user-agent"] } : {}),
        ...(browserHeaders["accept-language"] ? { "Accept-Language": browserHeaders["accept-language"] } : {}),
        ...(visitor ? { "X-Goog-Visitor-Id": visitor } : {}),
        "X-Origin": MUSIC_ORIGIN,
      } : accessToken ? {
        "Authorization": `Bearer ${accessToken}`,
        "X-Goog-Request-Time": String(Math.floor(Date.now() / 1000)),
        "Cookie": "SOCS=CAI",
        ...(visitor ? { "X-Goog-Visitor-Id": visitor } : {}),
      } : { "X-Origin": MUSIC_ORIGIN }),
    },
    body: JSON.stringify({
      context: { client: { clientName: "WEB_REMIX", clientVersion: browserClientVersion, hl: "en", gl: "US" }, user: {} },
      ...body,
    }),
  });
  const document = object(await response.json().catch(() => ({})));
  if (!response.ok) {
    const detail = string(object(document.error).message);
    throw new Error(`YouTube Music returned HTTP ${response.status}${detail ? `: ${detail}` : ""}`);
  }
  return document;
}

function requireAccount(): void {
  if (!accessTokenProvider && !browserHeadersProvider) throw new Error("Connect your YouTube Music account first");
}

function responsiveItems(document: JsonObject): JsonObject[] {
  return children(document, "musicResponsiveListItemRenderer");
}

export async function searchYouTubeMusicCatalog(query: string, cursors: YouTubeSearchCursors = {}): Promise<CatalogSearch & { cursors: YouTubeSearchCursors }> {
  const continuation = Object.keys(cursors).length > 0;
  const page = (filter: keyof typeof SEARCH_FILTERS, cursor?: string) => continuation && !cursor
    ? Promise.resolve({})
    : youtubei("search", cursor ? { continuation: cursor } : { query, params: SEARCH_FILTERS[filter] });
  const [songDocument, videoDocument, albumDocument, artistDocument] = await Promise.all([
    page("songs", cursors.songs),
    page("videos", cursors.videos),
    page("albums", cursors.albums),
    page("artists", cursors.artists),
  ]);
  const songs = responsiveItems(songDocument).map(mapTrack).filter((item): item is TrackSummary => Boolean(item));
  const videos = responsiveItems(videoDocument).map(mapVideo).filter((item): item is TrackSummary => Boolean(item));
  const tracks: TrackSummary[] = [];
  for (let index = 0; index < Math.max(songs.length, videos.length); index += 1) {
    const song = songs[index];
    const video = videos[index];
    if (song) tracks.push(song);
    if (video) tracks.push(video);
  }
  const videoChannels: ArtistSummary[] = tracks.flatMap((track) =>
    track.mediaKind === "video" && track.uploader?.id
      ? [{ id: track.uploader.id, name: track.uploader.name, pictureUrl: null, isChannel: true }]
      : []);
  const artists = [
    ...responsiveItems(artistDocument).map(mapArtist),
    ...videoChannels,
  ].filter((item): item is ArtistSummary => Boolean(item));
  return {
    tracks: [...new Map(tracks.map((track) => [track.id, track])).values()],
    albums: responsiveItems(albumDocument).map(mapAlbum).filter((item): item is AlbumSummary => Boolean(item)),
    artists: [...new Map(artists.map((artist) => [artist.id, artist])).values()],
    cursors: {
      ...(youtubeMusicContinuationToken(songDocument) ? { songs: youtubeMusicContinuationToken(songDocument) } : {}),
      ...(youtubeMusicContinuationToken(videoDocument) ? { videos: youtubeMusicContinuationToken(videoDocument) } : {}),
      ...(youtubeMusicContinuationToken(albumDocument) ? { albums: youtubeMusicContinuationToken(albumDocument) } : {}),
      ...(youtubeMusicContinuationToken(artistDocument) ? { artists: youtubeMusicContinuationToken(artistDocument) } : {}),
    },
  };
}

function mapPlaylistTrack(renderer: JsonObject): TrackSummary | null {
  const id = string(object(object(renderer.navigationEndpoint).watchEndpoint).videoId)
    || string(object(object(renderer.playNavigationEndpoint).watchEndpoint).videoId);
  const title = runText(renderer.title);
  if (!id || !title) return null;
  const metadataRuns = [...runs(renderer.longBylineText), ...runs(renderer.shortBylineText)];
  const artistCredits = creditsFrom(metadataRuns);
  const albumRun = metadataRuns.find((run) => browseId(run).startsWith("MPRE"));
  return {
    id,
    title,
    version: null,
    artists: artistCredits.map((artist) => artist.name),
    artistCredits,
    albumId: albumRun ? browseId(albumRun) : null,
    albumTitle: albumRun ? string(albumRun.text) : null,
    durationMs: durationMs(runText(renderer.lengthText)),
    isrc: null,
    coverUrl: thumbnail(renderer),
    explicit: explicit(renderer),
  };
}

function mapTwoRowVideo(renderer: JsonObject): TrackSummary | null {
  const id = string(object(object(renderer.navigationEndpoint).watchEndpoint).videoId)
    || children(renderer, "watchEndpoint").map((endpoint) => string(endpoint.videoId)).find(Boolean) || "";
  const title = runText(renderer.title);
  if (!id || !title) return null;
  const metadataRuns = runs(renderer.subtitle);
  const uploaderRun = metadataRuns.find((run) => browseId(run).startsWith("UC"));
  const uploaderId = uploaderRun ? browseId(uploaderRun) : null;
  const uploaderName = uploaderRun ? string(uploaderRun.text) : "YouTube Music";
  return {
    id,
    title,
    version: null,
    artists: [uploaderName],
    artistCredits: uploaderId ? [{ id: uploaderId, name: uploaderName }] : [],
    uploader: { id: uploaderId, name: uploaderName },
    albumId: null,
    albumTitle: null,
    durationMs: null,
    isrc: null,
    coverUrl: thumbnail(renderer),
    explicit: false,
    mediaKind: "video",
  };
}

export async function youtubeMusicTrackMetadata(video: string): Promise<TrackSummary | null> {
  const document = await youtubei("next", { videoId: video, enablePersistentPlaylistPanel: true });
  for (const renderer of children(document, "playlistPanelVideoRenderer")) {
    const track = mapPlaylistTrack(renderer);
    if (track?.id === video) return track;
  }
  return null;
}

export async function youtubeMusicLyrics(video: string): Promise<{ plain: string | null; synced: string | null }> {
  const next = await youtubei("next", { videoId: video, enablePersistentPlaylistPanel: true });
  const lyricsEndpoint = children(next, "browseEndpoint").find((endpoint) =>
    string(endpoint.browseId).startsWith("MPLYt")
      || string(object(object(endpoint.browseEndpointContextSupportedConfigs)
        .browseEndpointContextMusicConfig).pageType).includes("LYRICS"));
  const browse = string(lyricsEndpoint?.browseId);
  if (!browse) return { plain: null, synced: null };
  const page = await youtubei("browse", { browseId: browse });
  const shelf = children(page, "musicDescriptionShelfRenderer")[0]
    ?? children(page, "descriptionShelfRenderer")[0];
  const plain = shelf ? runText(shelf.description) || runText(shelf.text) : "";
  return { plain: plain || null, synced: null };
}

export interface YouTubeMusicAutomixPage {
  tracks: TrackSummary[];
  cursor: string;
}

function mapYouTubeMusicAutomixDocument(document: JsonObject, excludedVideo = ""): YouTubeMusicAutomixPage {
  const renderers = children(document, "playlistPanelVideoRenderer");
  const tracks = renderers.map(mapPlaylistTrack)
    .filter((track): track is TrackSummary => track !== null && track.id !== excludedVideo);
  const unique = [...new Map(tracks.map((track) => [track.id, track])).values()];
  const continuation = renderers.length ? youtubeMusicAutomixContinuation(renderers.at(-1)!) : "";
  return { tracks: unique, cursor: continuation ? `${AUTOMIX_CURSOR}${continuation}` : "" };
}

export async function youtubeMusicAutomixPage(video: string): Promise<YouTubeMusicAutomixPage> {
  const startedAt = Date.now();
  const document = await youtubei("next", youtubeMusicAutomixRequest(video));
  const page = mapYouTubeMusicAutomixDocument(document, video);
  if (!page.tracks.length) throw new Error("YouTube Music returned an empty automix queue");
  debugLog("youtube.automix", "page_resolved", {
    videoId: video, trackCount: page.tracks.length, hasCursor: Boolean(page.cursor), elapsedMs: Date.now() - startedAt,
  });
  return page;
}

export async function youtubeMusicAutomixMore(cursor: string): Promise<YouTubeMusicAutomixPage> {
  if (!cursor.startsWith(AUTOMIX_CURSOR)) throw new Error("Invalid YouTube Music automix cursor");
  const continuation = cursor.slice(AUTOMIX_CURSOR.length);
  if (!continuation) throw new Error("Empty YouTube Music automix cursor");
  const startedAt = Date.now();
  const page = mapYouTubeMusicAutomixDocument(await youtubei("next", { continuation }));
  if (!page.tracks.length) throw new Error("YouTube Music returned an empty automix continuation");
  debugLog("youtube.automix", "continuation_resolved", {
    trackCount: page.tracks.length, hasCursor: Boolean(page.cursor), elapsedMs: Date.now() - startedAt,
  });
  return page;
}

export async function youtubeMusicAutomix(video: string, limit = 20): Promise<TrackSummary[]> {
  return (await youtubeMusicAutomixPage(video)).tracks.slice(0, Math.max(1, limit));
}

function titleOfCarousel(carousel: JsonObject): string {
  return children(carousel.header, "musicCarouselShelfBasicHeaderRenderer")
    .map((header) => runText(header.title)).find(Boolean) || "";
}

export async function youtubeMusicArtist(artistId: string): Promise<ArtistPage> {
  const document = await youtubei("browse", { browseId: artistId.replace(/^MPLA/, "") });
  const immersiveHeader = children(document, "musicImmersiveHeaderRenderer")[0];
  const visualHeader = children(document, "musicVisualHeaderRenderer")[0];
  const header = immersiveHeader
    || visualHeader
    || children(document, "musicDetailHeaderRenderer")[0] || {};
  const artist: ArtistSummary = {
    id: artistId,
    name: runText(header.title) || "YouTube Music artist",
    pictureUrl: thumbnail(header),
    isChannel: Boolean(visualHeader && !immersiveHeader),
  };
  const topTracks: TrackSummary[] = [];
  const albums: AlbumSummary[] = [];
  let trackCursor = "";
  for (const shelf of children(document, "musicShelfRenderer")) {
    for (const renderer of responsiveItems(shelf)) {
      const track = mapTrack(renderer);
      if (track) topTracks.push(track);
    }
    const endpoint = object(shelf.bottomEndpoint);
    const browse = object(endpoint.browseEndpoint);
    const browseId = string(browse.browseId);
    const params = string(browse.params);
    if (browseId && runText(shelf.bottomText).toLocaleLowerCase().includes("show all")) {
      trackCursor = `${ARTIST_TRACKS_CURSOR}${encodedCursor({ browseId, ...(params ? { params } : {}) })}`;
    }
  }
  for (const carousel of children(document, "musicCarouselShelfRenderer")) {
    const heading = titleOfCarousel(carousel).toLocaleLowerCase();
    if (heading.includes("video")) {
      for (const renderer of children(carousel, "musicTwoRowItemRenderer")) {
        const track = mapTwoRowVideo(renderer);
        if (track) topTracks.push(track);
      }
    }
    if (!heading.includes("album") && !heading.includes("single") && !heading.includes("release")) continue;
    for (const renderer of children(carousel, "musicTwoRowItemRenderer")) {
      const titleRuns = runs(renderer.title);
      const subtitleRuns = runs(renderer.subtitle);
      const albumRun = [...titleRuns, ...subtitleRuns].find((run) => browseId(run).startsWith("MPRE"));
      const id = albumRun ? browseId(albumRun) : string(object(object(renderer.navigationEndpoint).browseEndpoint).browseId);
      const title = runText(renderer.title);
      if (!id.startsWith("MPRE") || !title) continue;
      const artistCredits = creditsFrom(subtitleRuns);
      const year = subtitleRuns.map((run) => string(run.text)).find((value) => /^\d{4}$/.test(value)) || null;
      albums.push({ id, title, version: null, artists: artistCredits.map((credit) => credit.name), artistCredits,
        coverUrl: thumbnail(renderer), releaseDate: year, durationMs: null, numberOfTracks: null,
        albumType: heading.includes("single") ? "Single" : "Album", explicit: explicit(renderer), mediaTags: [] });
    }
  }
  return {
    kind: "artist",
    artist,
    topTracks: [...new Map(topTracks.map((track) => [track.id, track])).values()],
    albums: [...new Map(albums.map((album) => [album.id, album])).values()],
    ...(trackCursor ? { trackCursor } : {}),
  };
}

export async function youtubeMusicArtistTracksMore(cursor: string): Promise<{ tracks: TrackSummary[]; cursor: string }> {
  if (!cursor.startsWith(ARTIST_TRACKS_CURSOR)) throw new Error("Invalid YouTube Music artist tracks cursor");
  const state = decodedCursor(cursor.slice(ARTIST_TRACKS_CURSOR.length));
  const browseId = string(state.browseId);
  const params = string(state.params);
  const continuation = string(state.continuation);
  if ((!browseId || !/^[A-Za-z0-9_-]{10,128}$/.test(browseId)) && !continuation)
    throw new Error("Invalid YouTube Music artist tracks state");
  const document = await youtubei("browse", continuation
    ? { continuation }
    : { browseId, ...(params ? { params } : {}) });
  const next = youtubeMusicContinuationToken(document);
  return {
    tracks: tracksFromDocument(document),
    cursor: next ? `${ARTIST_TRACKS_CURSOR}${encodedCursor({ continuation: next })}` : "",
  };
}

export async function youtubeMusicAlbum(albumId: string): Promise<AlbumPage> {
  const document = await youtubei("browse", { browseId: albumId });
  const header = children(document, "musicDetailHeaderRenderer")[0]
    || children(document, "musicResponsiveHeaderRenderer")[0] || {};
  const title = runText(header.title) || "YouTube Music release";
  const subtitleRuns = [...runs(header.subtitle), ...runs(header.straplineTextOne)];
  const secondSubtitleRuns = runs(header.secondSubtitle);
  const artistCredits = creditsFrom([...subtitleRuns, ...secondSubtitleRuns]);
  const year = [...subtitleRuns, ...secondSubtitleRuns].map((run) => string(run.text))
    .find((value) => /^\d{4}$/.test(value)) || null;
  const type = [...subtitleRuns, ...secondSubtitleRuns].map((run) => string(run.text))
    .find((value) => /^(album|single|ep)$/i.test(value)) || null;
  const album: AlbumSummary = {
    id: albumId,
    title,
    version: null,
    artists: artistCredits.map((artist) => artist.name),
    artistCredits,
    coverUrl: thumbnail(header),
    releaseDate: year,
    durationMs: null,
    numberOfTracks: null,
    albumType: type,
    explicit: explicit(header),
    mediaTags: [],
  };
  const tracks = responsiveItems(document).map(mapTrack).filter((track): track is TrackSummary => Boolean(track))
    .map((track) => ({
      ...track,
      albumId: track.albumId || albumId,
      albumTitle: track.albumTitle || title,
      coverUrl: track.coverUrl || album.coverUrl,
      artists: track.artists.length > 0 ? track.artists : album.artists,
      artistCredits: track.artistCredits.length > 0 ? track.artistCredits : artistCredits,
    }));
  album.numberOfTracks = tracks.length || null;
  return { kind: "album", album, tracks: [...new Map(tracks.map((track) => [track.id, track])).values()] };
}

function playlistIdFrom(renderer: JsonObject): string {
  const watchIds = children(renderer, "watchEndpoint").map((endpoint) => string(endpoint.playlistId)).filter(Boolean);
  const browseIds = children(renderer, "browseEndpoint").map((endpoint) => string(endpoint.browseId)).filter(Boolean);
  const id = watchIds[0] || browseIds.find((value) => value.startsWith("VL")) || "";
  return id.startsWith("VL") ? id.slice(2) : id;
}

function countFromRuns(values: Run[]): number | null {
  for (const run of values) {
    const match = string(run.text).replaceAll(",", "").match(/\b(\d+)\s+(?:songs?|tracks?|videos?)\b/i);
    if (match?.[1]) return Number(match[1]);
  }
  return null;
}

function mapPlaylist(renderer: JsonObject): PlaylistSummary | null {
  const id = playlistIdFrom(renderer);
  const title = runText(renderer.title) || columnRuns(renderer, 0).map((run) => string(run.text)).join("").trim();
  if (!id || !title) return null;
  const subtitleRuns = [...runs(renderer.subtitle), ...columnRuns(renderer, 1)];
  return {
    id,
    name: title,
    description: subtitleRuns.map((run) => string(run.text)).join("").trim() || null,
    coverUrl: thumbnail(renderer),
    durationMs: null,
    numberOfItems: countFromRuns(subtitleRuns),
    playlistType: id.startsWith("RD") ? "Mix" : "YouTube Music",
    createdAt: null,
    lastModifiedAt: null,
  };
}

function mapTwoRowAlbum(renderer: JsonObject): AlbumSummary | null {
  const titleRuns = runs(renderer.title);
  const subtitleRuns = runs(renderer.subtitle);
  const albumRun = [...titleRuns, ...subtitleRuns].find((run) => browseId(run).startsWith("MPRE"));
  const id = albumRun ? browseId(albumRun) : rendererBrowseId(renderer);
  const title = runText(renderer.title);
  if (!id.startsWith("MPRE") || !title) return null;
  const artistCredits = creditsFrom(subtitleRuns);
  const year = subtitleRuns.map((run) => string(run.text)).find((value) => /^\d{4}$/.test(value)) || null;
  const type = subtitleRuns.map((run) => string(run.text)).find((value) => /^(album|single|ep)$/i.test(value)) || null;
  return { id, title, version: null, artists: artistCredits.map((artist) => artist.name), artistCredits,
    coverUrl: thumbnail(renderer), releaseDate: year, durationMs: null, numberOfTracks: null,
    albumType: type, explicit: explicit(renderer), mediaTags: [] };
}

function mapTwoRowArtist(renderer: JsonObject): ArtistSummary | null {
  const titleRuns = runs(renderer.title);
  const subtitleRuns = runs(renderer.subtitle);
  const run = [...titleRuns, ...subtitleRuns].find((candidate) => isArtistId(browseId(candidate)));
  const id = run ? browseId(run) : rendererBrowseId(renderer);
  const name = runText(renderer.title) || (run ? string(run.text) : "");
  return isArtistId(id) && name ? { id, name, pictureUrl: thumbnail(renderer), isChannel: id.startsWith("UC") } : null;
}

function unique<T extends { id: string }>(items: T[]): T[] {
  return [...new Map(items.map((item) => [item.id, item])).values()];
}

function tracksFromDocument(document: JsonObject): TrackSummary[] {
  return unique([
    ...responsiveItems(document).map(mapTrack),
    ...children(document, "musicPlaylistShelfRenderer").flatMap((shelf) =>
      responsiveItems(shelf).map(mapTrack)),
  ].filter((item): item is TrackSummary => Boolean(item)));
}

function albumsFromDocument(document: JsonObject): AlbumSummary[] {
  return unique([
    ...responsiveItems(document).map(mapAlbum),
    ...children(document, "musicTwoRowItemRenderer").map(mapTwoRowAlbum),
  ].filter((item): item is AlbumSummary => Boolean(item)));
}

function artistsFromDocument(document: JsonObject): ArtistSummary[] {
  return unique([
    ...responsiveItems(document).map(mapArtist),
    ...children(document, "musicTwoRowItemRenderer").map(mapTwoRowArtist),
  ].filter((item): item is ArtistSummary => Boolean(item)));
}

function playlistsFromDocument(document: JsonObject): PlaylistSummary[] {
  return unique([
    ...children(document, "musicTwoRowItemRenderer").map(mapPlaylist),
    ...children(document, "musicResponsiveListItemRenderer").map(mapPlaylist),
  ].filter((item): item is PlaylistSummary => Boolean(item)));
}

export type YouTubeMusicAccount = {
  accountName: string;
  channelHandle: string | null;
  accountPhotoUrl: string | null;
  premiumStatus: "Premium" | "Free" | "Unknown";
};

export function youtubeMusicPremiumStatusFromHtml(html: string): YouTubeMusicAccount["premiumStatus"] {
  const match = html.match(/\\?"IS_SUBSCRIBER\\?"\s*:\s*(true|false)/i);
  if (!match) return "Unknown";
  return match[1]?.toLowerCase() === "true" ? "Premium" : "Free";
}

async function youtubeMusicPremiumStatus(): Promise<YouTubeMusicAccount["premiumStatus"]> {
  if (!browserHeadersProvider) return "Unknown";
  try {
    const headers = await browserHeadersProvider();
    const response = await fetch(MUSIC_ORIGIN, { headers: {
      "Cookie": headers.cookie ?? "",
      "User-Agent": headers["user-agent"] ?? "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/140 Safari/537.36",
      ...(headers["accept-language"] ? { "Accept-Language": headers["accept-language"] } : {}),
    } });
    if (!response.ok) return "Unknown";
    return youtubeMusicPremiumStatusFromHtml(await response.text());
  } catch {
    return "Unknown";
  }
}

export async function youtubeMusicAccount(): Promise<YouTubeMusicAccount> {
  requireAccount();
  const [document, premiumStatus] = await Promise.all([
    youtubei("account/account_menu", {}, true),
    youtubeMusicPremiumStatus(),
  ]);
  const header = children(document, "activeAccountHeaderRenderer")[0] || {};
  const accountName = runText(header.accountName);
  const channelHandle = runText(header.channelHandle);
  if (!accountName && !channelHandle)
    throw new Error("YouTube Music did not return an active account; reconnect from a logged-in /browse request");
  return {
    accountName: accountName || "YouTube Music account",
    channelHandle: channelHandle || null,
    accountPhotoUrl: thumbnail(header),
    premiumStatus,
  };
}

export async function youtubeMusicCollection(): Promise<UserCollectionPage> {
  requireAccount();
  const [songDocument, albumDocument, artistDocument, playlistDocument, homeDocument] = await Promise.all([
    youtubei("browse", { browseId: "FEmusic_liked_videos" }, true),
    youtubei("browse", { browseId: "FEmusic_liked_albums" }, true),
    youtubei("browse", { browseId: "FEmusic_library_corpus_track_artists" }, true),
    youtubei("browse", { browseId: "FEmusic_liked_playlists" }, true),
    youtubei("browse", { browseId: "FEmusic_home" }, true),
  ]);
  return mapYouTubeMusicCollectionDocuments({
    songs: songDocument, albums: albumDocument, artists: artistDocument,
    playlists: playlistDocument, home: homeDocument,
  });
}

export function mapYouTubeMusicCollectionDocuments(documents: {
  songs: JsonObject;
  albums: JsonObject;
  artists: JsonObject;
  playlists: JsonObject;
  home: JsonObject;
}): UserCollectionPage {
  const playlists = playlistsFromDocument(documents.playlists);
  const homePlaylists = playlistsFromDocument(documents.home);
  return {
    tracks: tracksFromDocument(documents.songs),
    albums: albumsFromDocument(documents.albums),
    artists: artistsFromDocument(documents.artists),
    playlists,
    mixes: homePlaylists.filter((playlist) => playlist.id.startsWith("RD") || !playlists.some((item) => item.id === playlist.id)),
    cursors: {},
  };
}

export async function youtubeMusicPlaylist(playlistId: string): Promise<PlaylistPage> {
  const cleanId = playlistId.replace(/^VL/, "");
  const document = await youtubei("browse", { browseId: `VL${cleanId}` }, accessTokenProvider !== null || browserHeadersProvider !== null);
  return mapYouTubeMusicPlaylistDocument(document, cleanId);
}

export function mapYouTubeMusicPlaylistDocument(document: JsonObject, playlistId: string): PlaylistPage {
  const cleanId = playlistId.replace(/^VL/, "");
  const header = children(document, "musicDetailHeaderRenderer")[0]
    || children(document, "musicResponsiveHeaderRenderer")[0]
    || children(document, "musicEditablePlaylistDetailHeaderRenderer")[0] || {};
  const playlist: PlaylistSummary = {
    id: cleanId,
    name: runText(header.title) || "YouTube Music playlist",
    description: runText(header.description) || null,
    coverUrl: thumbnail(header),
    durationMs: null,
    numberOfItems: null,
    playlistType: cleanId.startsWith("RD") ? "Mix" : "YouTube Music",
    createdAt: null,
    lastModifiedAt: null,
  };
  const tracks = tracksFromDocument(document).map((track) => ({ ...track, coverUrl: track.coverUrl || playlist.coverUrl }));
  const headerCount = countFromRuns([
    ...runs(header.secondSubtitle),
    ...runs(header.subtitle),
    ...runs(header.straplineTextOne),
  ]);
  playlist.numberOfItems = headerCount ?? (tracks.length || null);
  const continuation = youtubeMusicContinuationToken(document);
  return {
    kind: "playlist", playlist, tracks,
    ...(continuation ? { trackCursor: `${PLAYLIST_BROWSE_CURSOR}${continuation}` } : {}),
  };
}

export function youtubeMusicContinuationToken(document: JsonObject): string {
  const playlistRoots = [
    ...children(document, "musicShelfRenderer"),
    ...children(document, "musicShelfContinuation"),
    ...children(document, "musicPlaylistShelfRenderer"),
    ...children(document, "musicPlaylistShelfContinuation"),
    ...children(document, "appendContinuationItemsAction")
      .filter((action) => children(action, "musicResponsiveListItemRenderer").length > 0),
  ];
  for (const root of playlistRoots) {
    const token = children(root, "nextContinuationData").map((item) => string(item.continuation)).find(Boolean)
      || children(root, "reloadContinuationData").map((item) => string(item.continuation)).find(Boolean)
      || children(root, "continuationCommand").map((item) => string(item.token)).find(Boolean);
    if (token) return token;
  }
  return "";
}

function watchContinuationToken(document: JsonObject): string {
  const roots = [
    ...children(document, "playlistPanelRenderer"),
    ...children(document, "playlistPanelContinuation"),
    ...children(document, "appendContinuationItemsAction")
      .filter((action) => children(action, "playlistPanelVideoRenderer").length > 0),
  ];
  for (const root of roots) {
    const token = children(root, "nextContinuationData").map((item) => string(item.continuation)).find(Boolean)
      || children(root, "reloadContinuationData").map((item) => string(item.continuation)).find(Boolean)
      || children(root, "continuationCommand").map((item) => string(item.token)).find(Boolean);
    if (token) return token;
  }
  return "";
}

export async function youtubeMusicShuffledPlaylist(playlistId: string): Promise<{ tracks: TrackSummary[]; cursor: string }> {
  const cleanId = playlistId.replace(/^VL/, "");
  const document = await youtubei("next", {
    playlistId: cleanId,
    params: "wAEB8gECKAE%3D",
    enablePersistentPlaylistPanel: true,
    isAudioOnly: true,
    tunerSettingValue: "AUTOMIX_SETTING_NORMAL",
  });
  return mapYouTubeMusicWatchPlaylistDocument(document);
}

export function mapYouTubeMusicWatchPlaylistDocument(document: JsonObject): { tracks: TrackSummary[]; cursor: string } {
  const tracks = children(document, "playlistPanelVideoRenderer")
    .map(mapPlaylistTrack).filter((track): track is TrackSummary => track !== null);
  const continuation = watchContinuationToken(document);
  return { tracks, cursor: continuation ? `${PLAYLIST_WATCH_CURSOR}${continuation}` : "" };
}

export async function youtubeMusicPlaylistMore(cursor: string): Promise<{ tracks: TrackSummary[]; cursor: string }> {
  if (cursor.startsWith(AUTOMIX_CURSOR)) return youtubeMusicAutomixMore(cursor);
  if (cursor.startsWith(PLAYLIST_BROWSE_CURSOR)) {
    const document = await youtubei("browse", { continuation: cursor.slice(PLAYLIST_BROWSE_CURSOR.length) });
    const continuation = youtubeMusicContinuationToken(document);
    return {
      tracks: tracksFromDocument(document),
      cursor: continuation ? `${PLAYLIST_BROWSE_CURSOR}${continuation}` : "",
    };
  }
  if (cursor.startsWith(PLAYLIST_WATCH_CURSOR)) {
    const document = await youtubei("next", { continuation: cursor.slice(PLAYLIST_WATCH_CURSOR.length) });
    return mapYouTubeMusicWatchPlaylistDocument(document);
  }
  throw new Error("Invalid YouTube Music playlist cursor");
}
