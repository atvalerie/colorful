/**
 * Spotify Web Player recommendation protocol.
 *
 * This module deliberately only accepts an already-authenticated session (or
 * a provider for one). Browser login and cookie/token lifetime management stay
 * with the host application. The provider is queried for every HTTP request,
 * which lets the host refresh its cookie-backed bearer without this protocol
 * layer retaining an expired token.
 */

import { debugLog } from "./debug";

export type SpotifyTrack = {
  spotifyId: string;
  uri: string;
  isrc?: string;
  title?: string;
  artists: string[];
  album?: string;
  durationMs?: number;
  explicit?: boolean;
};

export type SpotifyWebSession = {
  accessToken: string;
  clientToken?: string;
  appVersion?: string;
  expiresAtMs?: number;
  clientId?: string;
};

export type SpotifySessionProvider =
  | SpotifyWebSession
  | (() => SpotifyWebSession | Promise<SpotifyWebSession>);

/** Compatibility aliases for code shared with the standalone protocol probe. */
export type WebSession = SpotifyWebSession;

export type SpotifyRecommendationResult = {
  seed: SpotifyTrack;
  recommendations: SpotifyTrack[];
  isrcBatch: string[];
  diagnostics: {
    source: "spotify-track-radio";
    requested: number;
    returned: number;
    withIsrc: number;
    stationUri: string;
    hydration: "complete" | "unavailable";
    hydrationError?: string;
  };
};

export type RecommendationResult = SpotifyRecommendationResult;

export type SpotifySeedInput = {
  trackId?: string;
  isrc?: string;
  /** IDs returned by the host's authenticated Spotify Web search. */
  candidateTrackIds?: string[];
};

export type SpotifyRecommendationClientOptions = {
  sessionProvider: SpotifySessionProvider;
  /** Injectable for tests; defaults to the host's global fetch. */
  fetch?: SpotifyFetch;
};

export type SpotifyRecommendationRequestOptions = {
  fetch?: SpotifyFetch;
};

/** The part of the platform fetch contract needed by this module. */
export type SpotifyFetch = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

export type SpotifyErrorCode =
  | "auth_required"
  | "auth_expired"
  | "account_restricted"
  | "rate_limited"
  | "endpoint_changed"
  | "seed_not_found"
  | "no_recommendations"
  | "malformed_response";

export class SpotifyRecommendationError extends Error {
  constructor(
    readonly code: SpotifyErrorCode,
    message: string,
    readonly status?: number,
  ) {
    super(message);
    this.name = "SpotifyRecommendationError";
  }
}

/** Backwards-compatible name used by the standalone protocol probe. */
export const OracleError = SpotifyRecommendationError;

const TRACK_ID = /^[A-Za-z0-9]{22}$/;
const ISRC = /^[A-Z]{2}[A-Z0-9]{3}\d{7}$/;
const BASE62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
const decoder = new TextDecoder();
// This is the host used by the Web Player for first-party spclient calls in
// the captured browser session. The AP resolver is still preferred when it is
// readable, but a page-origin fetch to apresolve.spotify.com can fail CORS
// before returning a response. Metadata and radio remain available through
// the same authenticated spclient host in that case.
const FALLBACK_SPCLIENT = "spclient.wg.spotify.com";

type Fetcher = SpotifyFetch;

function safeRequestLabel(rawUrl: string): string {
  try {
    const url = new URL(rawUrl);
    return `${url.hostname}${url.pathname}`;
  } catch {
    return "invalid-url";
  }
}

function object(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function number(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function artistsFrom(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value.flatMap((item) => {
      if (typeof item === "string" && item.trim()) return [item.trim()];
      const name = text(object(item).name);
      return name ? [name] : [];
    });
  }
  const artist = text(value);
  return artist ? [artist] : [];
}

/** Normalize one track object returned by Spotify's Web Player JSON APIs. */
export function spotifyWebTrack(value: unknown): SpotifyTrack | undefined {
  const item = object(value);
  const uri = text(item.uri) ?? text(item.track_uri) ?? text(item.trackUri);
  const id = text(item.id) ?? uri?.match(/^spotify:track:([A-Za-z0-9]{22})$/)?.[1];
  if (!id || !TRACK_ID.test(id)) return undefined;

  const album = object(item.album);
  const externalIds = object(item.external_ids ?? item.externalIds);
  const result: SpotifyTrack = {
    spotifyId: id,
    uri: uri ?? `spotify:track:${id}`,
    artists: artistsFrom(item.artists ?? item.artist_name ?? item.artistName),
  };
  const isrc = text(externalIds.isrc ?? item.isrc)?.toUpperCase();
  const title = text(item.name ?? item.title);
  const albumName = text(album.name ?? item.album_name ?? item.albumName);
  const durationMs = number(item.duration_ms ?? item.durationMs ?? item.duration);
  if (isrc) result.isrc = isrc;
  if (title) result.title = title;
  if (albumName) result.album = albumName;
  if (durationMs !== undefined) result.durationMs = durationMs;
  if (typeof item.explicit === "boolean") result.explicit = item.explicit;
  return result;
}

/** Collect Spotify track IDs from arbitrarily nested Web Player responses. */
export function collectTrackIds(value: unknown): string[] {
  const found = new Set<string>();
  const seen = new Set<object>();
  const visit = (item: unknown): void => {
    if (typeof item === "string") {
      const match = item.match(/spotify:track:([A-Za-z0-9]{22})/);
      if (match?.[1]) found.add(match[1]);
      return;
    }
    if (!item || typeof item !== "object" || seen.has(item)) return;
    seen.add(item);
    if (Array.isArray(item)) {
      for (const child of item) visit(child);
      return;
    }
    const candidate = spotifyWebTrack(item);
    if (candidate) found.add(candidate.spotifyId);
    for (const child of Object.values(item as Record<string, unknown>)) visit(child);
  };
  visit(value);
  return [...found];
}

/** Collect continuation URLs without making assumptions about response shape. */
export function collectNextPageUrls(value: unknown): string[] {
  const found = new Set<string>();
  const seen = new Set<object>();
  const visit = (item: unknown): void => {
    if (!item || typeof item !== "object" || seen.has(item)) return;
    seen.add(item);
    if (Array.isArray(item)) {
      for (const child of item) visit(child);
      return;
    }
    for (const [key, child] of Object.entries(item as Record<string, unknown>)) {
      if (/next.*page.*url/i.test(key) && typeof child === "string" && child) found.add(child);
      else visit(child);
    }
  };
  visit(value);
  return [...found];
}

type ProtobufField = { number: number; wire: number; value: bigint | Uint8Array };

function readVarint(bytes: Uint8Array, offset: number): { value: bigint; offset: number } {
  let value = 0n;
  let shift = 0n;
  while (offset < bytes.length && shift <= 63n) {
    const byte = bytes[offset++]!;
    value |= BigInt(byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) return { value, offset };
    shift += 7n;
  }
  throw new SpotifyRecommendationError("malformed_response", "Spotify returned malformed protobuf metadata");
}

function readFields(bytes: Uint8Array): ProtobufField[] {
  const result: ProtobufField[] = [];
  let offset = 0;
  while (offset < bytes.length) {
    const tag = readVarint(bytes, offset);
    offset = tag.offset;
    const number = Number(tag.value >> 3n);
    const wire = Number(tag.value & 7n);
    if (number <= 0) throw new SpotifyRecommendationError("malformed_response", "Spotify metadata contained an invalid protobuf field");
    if (wire === 0) {
      const decoded = readVarint(bytes, offset);
      offset = decoded.offset;
      result.push({ number, wire, value: decoded.value });
    } else if (wire === 2) {
      const length = readVarint(bytes, offset);
      offset = length.offset;
      if (length.value > BigInt(bytes.length - offset)) {
        throw new SpotifyRecommendationError("malformed_response", "Spotify returned truncated protobuf metadata");
      }
      const end = offset + Number(length.value);
      result.push({ number, wire, value: bytes.subarray(offset, end) });
      offset = end;
    } else if (wire === 1) {
      offset += 8;
    } else if (wire === 5) {
      offset += 4;
    } else {
      throw new SpotifyRecommendationError("malformed_response", `Spotify metadata used unsupported protobuf wire type ${wire}`);
    }
    if (offset > bytes.length) throw new SpotifyRecommendationError("malformed_response", "Spotify returned truncated protobuf metadata");
  }
  return result;
}

function fieldBytes(field: ProtobufField | undefined): Uint8Array | undefined {
  return field?.wire === 2 ? field.value as Uint8Array : undefined;
}

function fieldString(field: ProtobufField | undefined): string | undefined {
  const value = fieldBytes(field);
  return value ? decoder.decode(value) : undefined;
}

function nestedFields(source: ProtobufField[], number: number): ProtobufField[][] {
  return source.filter((field) => field.number === number).flatMap((field) => {
    const value = fieldBytes(field);
    return value ? [readFields(value)] : [];
  });
}

function firstField(source: ProtobufField[], number: number): ProtobufField | undefined {
  return source.find((field) => field.number === number);
}

function sint32(field: ProtobufField | undefined): number | undefined {
  if (!field || field.wire !== 0) return undefined;
  const value = field.value as bigint;
  return Number((value >> 1n) ^ -(value & 1n));
}

/** Convert a Spotify base62 ID to the 128-bit hexadecimal metadata GID. */
export function spotifyIdToHex(id: string): string {
  let value = 0n;
  for (const character of id) {
    const digit = BASE62.indexOf(character);
    if (digit < 0) throw new SpotifyRecommendationError("seed_not_found", "Spotify track ID contains an invalid character");
    value = value * 62n + BigInt(digit);
  }
  return value.toString(16).padStart(32, "0");
}

/** Decode the subset of metadata/4/track protobuf fields used by Colorful. */
export function decodeTrackMetadata(payload: Uint8Array, spotifyId: string): SpotifyTrack {
  if (!TRACK_ID.test(spotifyId)) throw new SpotifyRecommendationError("seed_not_found", "Spotify track ID is invalid");
  const track = readFields(payload);
  const artists = nestedFields(track, 4).flatMap((artist) => {
    const name = fieldString(firstField(artist, 2));
    return name ? [name] : [];
  });
  const albumFields = nestedFields(track, 3)[0];
  const externalIds = nestedFields(track, 10).map((external) => ({
    type: fieldString(firstField(external, 1))?.toLowerCase(),
    id: fieldString(firstField(external, 2)),
  }));
  const isrc = externalIds.find((external) => external.type === "isrc")?.id?.toUpperCase();
  const title = fieldString(firstField(track, 2));
  const album = albumFields ? fieldString(firstField(albumFields, 2)) : undefined;
  const durationMs = sint32(firstField(track, 7));
  const explicitField = firstField(track, 9);
  const result: SpotifyTrack = { spotifyId, uri: `spotify:track:${spotifyId}`, artists };
  if (isrc) result.isrc = isrc;
  if (title) result.title = title;
  if (album) result.album = album;
  if (durationMs !== undefined) result.durationMs = durationMs;
  if (explicitField?.wire === 0) result.explicit = explicitField.value !== 0n;
  return result;
}

function headers(session: SpotifyWebSession, accept: string): Record<string, string> {
  if (!session.accessToken.trim()) {
    throw new SpotifyRecommendationError("auth_required", "Spotify session has no access token");
  }
  return {
    accept,
    authorization: `Bearer ${session.accessToken}`,
    ...(session.clientToken ? { "client-token": session.clientToken } : {}),
    "app-platform": "WebPlayer",
    ...(session.appVersion ? { "spotify-app-version": session.appVersion } : {}),
  };
}

function requestError(response: Response, url: string, reason?: string): SpotifyRecommendationError {
  const label = safeRequestLabel(url);
  const suffix = reason ? `, ${reason.replace(/[^A-Za-z0-9_-]/g, "").slice(0, 64)}` : "";
  if (response.status === 401) return new SpotifyRecommendationError("auth_expired", `Spotify session expired at ${label}`, 401);
  if (response.status === 403) return new SpotifyRecommendationError("account_restricted", `Spotify rejected ${label}${suffix}`, 403);
  if (response.status === 429) return new SpotifyRecommendationError("rate_limited", `Spotify rate limited ${label}${suffix}`, 429);
  return new SpotifyRecommendationError("endpoint_changed", `Spotify request to ${label} failed (${response.status}${suffix})`, response.status);
}

function normalizeSpclientAddress(value: string): string {
  const address = value.trim().replace(/\/+$/, "");
  if (!address) throw new SpotifyRecommendationError("malformed_response", "Spotify AP resolver returned no spclient address");
  try {
    const url = new URL(address.includes("://") ? address : `https://${address}`);
    if (url.protocol !== "https:") throw new Error("unsupported protocol");
    return url.host.replace(/:\d+$/, "");
  } catch {
    throw new SpotifyRecommendationError("malformed_response", "Spotify AP resolver returned an invalid spclient address");
  }
}

function hmToHttps(raw: string, spclient: string): string {
  if (raw.startsWith("hm://")) return `https://${spclient}/${raw.slice("hm://".length)}`;
  if (raw.startsWith("https://")) {
    try {
      const url = new URL(raw);
      if (url.host.replace(/:\d+$/, "") === spclient) return raw;
    } catch {
      // Fall through to the consistent malformed-continuation error below.
    }
  }
  throw new SpotifyRecommendationError("malformed_response", "Spotify context contained an unsupported continuation URL");
}

function provider(value: SpotifySessionProvider): () => Promise<SpotifyWebSession> {
  return typeof value === "function"
    ? async () => await value()
    : async () => value;
}

function defaultFetcher(): Fetcher {
  if (typeof globalThis.fetch !== "function") throw new Error("This host does not provide fetch");
  return (input, init) => globalThis.fetch(input, init);
}

function validLimit(limit: number): number {
  if (!Number.isFinite(limit) || limit < 1) {
    throw new SpotifyRecommendationError("no_recommendations", "Recommendation limit must be at least 1");
  }
  return Math.min(100, Math.trunc(limit));
}

export class SpotifyRecommendationClient {
  private readonly getSession: () => Promise<SpotifyWebSession>;
  private readonly fetcher: Fetcher;

  constructor(options: SpotifyRecommendationClientOptions) {
    this.getSession = provider(options.sessionProvider);
    this.fetcher = options.fetch ?? defaultFetcher();
  }

  /** Resolve the current dynamic spclient host used by Spotify's Web Player. */
  async resolveSpclient(): Promise<string> {
    try {
      const response = await this.fetcher("https://apresolve.spotify.com/?type=spclient");
      if (!response.ok) throw requestError(response, "https://apresolve.spotify.com/?type=spclient");
      const body = await response.json().catch(() => null) as { spclient?: unknown } | null;
      const address = body && Array.isArray(body.spclient) ? text(body.spclient[0]) : undefined;
      if (!address) throw new SpotifyRecommendationError("malformed_response", "Spotify AP resolver returned no spclient address");
      return normalizeSpclientAddress(address);
    } catch (error) {
      // The authenticated page can still reach the static Web Player spclient
      // host even when the resolver is not CORS-readable from Runtime.evaluate.
      // Do not turn a resolver transport quirk into an unavailable catalog.
      debugLog("spotify.recommendations", "spclient_resolver_fallback", {
        error: error instanceof Error ? error.message : String(error),
        host: FALLBACK_SPCLIENT,
      });
      return FALLBACK_SPCLIENT;
    }
  }

  private async jsonRequest(url: string): Promise<unknown> {
    const session = await this.getSession();
    const response = await this.fetcher(url, { headers: headers(session, "application/json") });
    if (!response.ok) {
      const body = await response.json().catch(() => ({})) as Record<string, unknown>;
      const nested = body.error && typeof body.error === "object" ? body.error as Record<string, unknown> : {};
      throw requestError(response, url, text(body.reason ?? nested.reason));
    }
    return response.json();
  }

  private async protobufRequest(url: string): Promise<Uint8Array> {
    const session = await this.getSession();
    const response = await this.fetcher(url, { headers: headers(session, "application/x-protobuf") });
    if (response.ok) return new Uint8Array(await response.arrayBuffer());
    throw requestError(response, url);
  }

  private async hydrateTracks(ids: string[], spclient: string): Promise<SpotifyTrack[]> {
    const result: SpotifyTrack[] = [];
    const pending = [...ids];
    const worker = async (): Promise<void> => {
      while (pending.length) {
        const id = pending.shift();
        if (!id) return;
        try {
          const payload = await this.protobufRequest(`https://${spclient}/metadata/4/track/${spotifyIdToHex(id)}`);
          result.push(decodeTrackMetadata(payload, id));
        } catch (error) {
          // Missing/unavailable metadata should not discard the complete radio
          // result. Authentication, throttling, and schema errors still stop.
          if (error instanceof SpotifyRecommendationError && error.status === 404) continue;
          throw error;
        }
      }
    };
    await Promise.all(Array.from({ length: Math.min(4, pending.length) }, () => worker()));
    const order = new Map(ids.map((id, index) => [id, index]));
    return result.sort((left, right) => (order.get(left.spotifyId) ?? 0) - (order.get(right.spotifyId) ?? 0));
  }

  /** Hydrate catalog track IDs through the Web Player metadata endpoint.
   * The catalog uses this to obtain ISRCs without calling the public Web API. */
  async trackMetadata(ids: string[]): Promise<SpotifyTrack[]> {
    const valid = [...new Set(ids.map((id) => id.trim()))]
      .filter((id) => TRACK_ID.test(id)).slice(0, 50);
    if (!valid.length) return [];
    return this.hydrateTracks(valid, await this.resolveSpclient());
  }

  /** Resolve an exact Spotify track for an ISRC using metadata protobuf verification. */
  async resolveSeed(input: SpotifySeedInput): Promise<SpotifyTrack> {
    if (input.trackId) {
      const spotifyId = input.trackId.trim();
      if (TRACK_ID.test(spotifyId)) return { spotifyId, uri: `spotify:track:${spotifyId}`, artists: [] };
      throw new SpotifyRecommendationError("seed_not_found", "The supplied Spotify track ID is invalid");
    }
    if (input.isrc) {
      const isrc = input.isrc.trim().toUpperCase();
      if (!ISRC.test(isrc)) throw new SpotifyRecommendationError("seed_not_found", "The supplied ISRC is invalid");
      const ids = [...new Set((input.candidateTrackIds ?? []).map((id) => id.trim()))]
        .filter((id) => TRACK_ID.test(id)).slice(0, 50);
      if (!ids.length) throw new SpotifyRecommendationError("seed_not_found", "Spotify web search returned no track candidates for the ISRC");
      const tracks = await this.hydrateTracks(ids, await this.resolveSpclient());
      const exact = tracks.find((track) => track.isrc === isrc);
      if (exact) return exact;
    }
    throw new SpotifyRecommendationError("seed_not_found", "No Spotify track matched the supplied seed");
  }

  /** Fetch track-radio recommendations and hydrate their metadata/ISRCs. */
  async recommendations(seed: SpotifyTrack, requestedLimit: number): Promise<SpotifyRecommendationResult> {
    const limit = validLimit(requestedLimit);
    const spclient = await this.resolveSpclient();
    const stationUri = `spotify:station:track:${seed.spotifyId}`;
    const initialUrl = `https://${spclient}/context-resolve/v1/${stationUri}`;
    const ids = new Set<string>();
    const visited = new Set<string>();
    const queue = [initialUrl];

    while (queue.length && ids.size < limit + 1) {
      const url = queue.shift()!;
      if (visited.has(url)) continue;
      visited.add(url);
      const body = await this.jsonRequest(url);
      for (const id of collectTrackIds(body)) ids.add(id);
      for (const next of collectNextPageUrls(body)) {
        const resolved = hmToHttps(next, spclient);
        if (!visited.has(resolved)) queue.push(resolved);
      }
    }

    ids.delete(seed.spotifyId);
    const selected = [...ids].slice(0, limit);
    if (!selected.length) throw new SpotifyRecommendationError("no_recommendations", "Spotify returned no track recommendations for the seed");

    let tracks: SpotifyTrack[];
    let hydration: "complete" | "unavailable" = "complete";
    let hydrationError: string | undefined;
    try {
      tracks = await this.hydrateTracks(selected, spclient);
    } catch (error) {
      if (!(error instanceof SpotifyRecommendationError) || ![403, 429].includes(error.status ?? 0)) throw error;
      hydration = "unavailable";
      hydrationError = error.message;
      tracks = selected.map((spotifyId) => ({ spotifyId, uri: `spotify:track:${spotifyId}`, artists: [] }));
    }

    const deduped = new Map<string, SpotifyTrack>();
    for (const track of tracks) deduped.set(track.isrc ?? track.spotifyId, track);
    const normalized = [...deduped.values()].slice(0, limit);
    const isrcBatch = normalized.flatMap((track) => track.isrc ? [track.isrc] : []);
    return {
      seed,
      recommendations: normalized,
      isrcBatch,
      diagnostics: {
        source: "spotify-track-radio",
        requested: limit,
        returned: normalized.length,
        withIsrc: isrcBatch.length,
        stationUri,
        hydration,
        ...(hydrationError ? { hydrationError } : {}),
      },
    };
  }

  async recommend(input: SpotifySeedInput, requestedLimit: number): Promise<SpotifyRecommendationResult> {
    const seed = await this.resolveSeed(input);
    return this.recommendations(seed, requestedLimit);
  }
}

/** Convenience API for hosts that do not need to retain a client instance. */
export async function resolveSeed(
  input: SpotifySeedInput,
  sessionProvider: SpotifySessionProvider,
  options: SpotifyRecommendationRequestOptions = {},
): Promise<SpotifyTrack> {
  const client = options.fetch
    ? new SpotifyRecommendationClient({ sessionProvider, fetch: options.fetch })
    : new SpotifyRecommendationClient({ sessionProvider });
  return client.resolveSeed(input);
}

/** Convenience API mirroring the standalone PoC's recommendations function. */
export async function recommendations(
  seed: SpotifyTrack,
  limit: number,
  sessionProvider: SpotifySessionProvider,
  options: SpotifyRecommendationRequestOptions = {},
): Promise<SpotifyRecommendationResult> {
  const client = options.fetch
    ? new SpotifyRecommendationClient({ sessionProvider, fetch: options.fetch })
    : new SpotifyRecommendationClient({ sessionProvider });
  return client.recommendations(seed, limit);
}
