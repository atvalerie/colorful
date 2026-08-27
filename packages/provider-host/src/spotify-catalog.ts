import type {
  AlbumPage,
  AlbumSummary,
  ArtistPage,
  ArtistSummary,
  CatalogSearchCursors,
  CatalogSearchPage,
  PlaylistPage,
  PlaylistSummary,
  TrackPage,
  TrackSummary,
  UserCollectionPage,
} from "./browse";
import { debugLog } from "./debug";
import type { SpotifyCredentials } from "./spotify-auth";

/**
 * Spotify catalog metadata is read through the authenticated Web Player's
 * Pathfinder operations. The fetcher runs inside the hidden Web Player page,
 * preserving its first-party browser context. It is important that this
 * module never exposes a Spotify playback source: callers resolve the returned
 * ISRCs against their native playback provider (currently TIDAL).
 */
export const SPOTIFY_CATALOG_API = "https://api.spotify.com/v1";
export const SPOTIFY_PATHFINDER_API = "https://api-partner.spotify.com/pathfinder/v2/query";

const PATHFINDER_HASHES = {
  searchTracks: "59ee4a659c32e9ad894a71308207594a65ba67bb6b632b183abe97303a51fa55",
  searchAlbums: "64ae1fe6df380b038c0a65a2606d3361bc270de6870b2fdc99cf0848b1efa6d3",
  searchArtists: "270905851ba5c7faca81cfe053c2dbd8ceb4f156a0e0ef4b385af75ab69ffd13",
  searchPlaylists: "d520014e748f9ea44f7707d8df1819867ac1205e8b7f3e28f22fe5fc858921b1",
  fetchPlaylist: "86dde7b9d9356e2369414647cf6950cfed96e778e129cfdfc99aea6c1613b3b0",
  libraryV3: "390c78e5b951029bad359785e69b07b536a509c581cbcd0aded5e5067f187455",
} as const;

type Json = Record<string, unknown>;
type Fetcher = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
type SessionProvider = (force?: boolean) => Promise<Pick<SpotifyCredentials, "accessToken" | "clientToken" | "appVersion">>;

export type SpotifyCatalogClientOptions = {
  sessionProvider: SessionProvider;
  fetch?: Fetcher;
  /** Market used for artist top tracks and market-dependent playlist items. */
  market?: string;
  /** Minimum spacing between catalog requests. Defaults to 200ms. */
  minRequestIntervalMs?: number;
  /** Use the authenticated Web Player Pathfinder catalog instead of /v1. */
  pathfinder?: boolean;
  /** Hydrate internal Pathfinder tracks through spclient metadata protobuf. */
  metadataProvider?: (ids: string[]) => Promise<Array<{
    spotifyId: string;
    isrc?: string;
    title?: string;
    artists: string[];
    album?: string;
    durationMs?: number;
    explicit?: boolean;
  }>>;
};

export type SpotifyCollectionOptions = {
  limit?: number;
};

export type SpotifyCatalogSearchPage = CatalogSearchPage & {
  playlists: PlaylistSummary[];
  cursors: CatalogSearchCursors & { playlists?: string };
};

function object(value: unknown): Json {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Json : {};
}

function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function positiveInt(value: unknown): number | null {
  const number = typeof value === "number" ? value : Number(value);
  return Number.isInteger(number) && number >= 0 ? number : null;
}

function duration(value: unknown): number | null {
  const number = typeof value === "number" ? value : Number(value);
  return Number.isFinite(number) && number >= 0 ? number : null;
}

function imageUrl(value: unknown): string | null {
  const url = text(object(value).url);
  return url.startsWith("https://") ? url : null;
}

function explicit(value: unknown): boolean {
  return value === true;
}

function spotifyUrl(value: unknown): string | undefined {
  const url = text(object(object(value).external_urls).spotify).trim();
  return url.startsWith("https://open.spotify.com/") ? url : undefined;
}

function artistCredits(value: unknown): Array<{ id: string; name: string }> {
  return array(value).map((item) => {
    const artist = object(item);
    const id = text(artist.id);
    const name = text(artist.name) || "Unknown artist";
    return id ? { id, name } : null;
  }).filter((item): item is { id: string; name: string } => item !== null);
}

function albumImages(value: unknown): string | null {
  return imageUrl(array(value)[0]);
}

function releaseDate(value: unknown): string | null {
  const date = text(value);
  return date || null;
}

function mapSpotifyTrack(value: unknown): TrackSummary | null {
  const item = object(value);
  const id = text(item.id);
  if (!id) return null;
  const credits = artistCredits(item.artists);
  const album = object(item.album);
  const albumId = text(album.id) || null;
  const albumTitle = text(album.name) || null;
  const externalIds = object(item.external_ids);
  const isrc = text(externalIds.isrc).toUpperCase() || null;
  const webpageUrl = spotifyUrl(item);
  const track: TrackSummary = {
    provider: "spotify",
    id,
    title: text(item.name) || "Unknown title",
    version: null,
    artists: credits.map((artist) => artist.name),
    artistCredits: credits,
    albumId,
    albumTitle,
    durationMs: duration(item.duration_ms),
    isrc,
    coverUrl: albumImages(album.images),
    ...(webpageUrl ? { webpageUrl } : {}),
    explicit: explicit(item.explicit),
    mediaTags: [],
  };
  return track;
}

function mapSpotifyAlbum(value: unknown): AlbumSummary | null {
  const item = object(value);
  const id = text(item.id);
  if (!id) return null;
  const credits = artistCredits(item.artists);
  const total = positiveInt(object(item.tracks).total);
  return {
    id,
    title: text(item.name) || "Unknown album",
    version: null,
    artists: credits.map((artist) => artist.name),
    artistCredits: credits,
    coverUrl: albumImages(item.images),
    releaseDate: releaseDate(item.release_date),
    // Spotify album summaries do not include a total duration. The detail
    // page computes it from its items when that information is available.
    durationMs: null,
    numberOfTracks: total,
    albumType: text(item.album_type).toUpperCase() || null,
    explicit: explicit(item.explicit),
    mediaTags: [],
  };
}

function mapSpotifyPlaylist(value: unknown): PlaylistSummary | null {
  const item = object(value);
  const id = text(item.id);
  if (!id) return null;
  const type = text(item.type).toUpperCase() || "PLAYLIST";
  const itemPage = object(item.items).total !== undefined ? item.items : item.tracks;
  return {
    id,
    name: text(item.name) || "Untitled playlist",
    description: text(item.description) || null,
    coverUrl: albumImages(item.images),
    durationMs: null,
    numberOfItems: positiveInt(object(itemPage).total),
    playlistType: type,
    createdAt: null,
    lastModifiedAt: null,
  };
}

function mapSpotifyArtist(value: unknown): ArtistSummary | null {
  const item = object(value);
  const id = text(item.id);
  if (!id) return null;
  return {
    id,
    name: text(item.name) || "Unknown artist",
    pictureUrl: albumImages(item.images),
  };
}

function spotifyUriId(value: unknown, kind?: string): string {
  const item = object(value);
  const uri = text(item.uri) || text(item._uri);
  if (uri) {
    const prefix = kind ? `spotify:${kind}:` : "spotify:";
    const marker = uri.indexOf(prefix);
    if (marker >= 0) return uri.slice(marker + prefix.length).split(":")[0] ?? "";
    const generic = uri.match(/^spotify:[^:]+:([A-Za-z0-9]{22})$/);
    if (generic?.[1]) return generic[1];
  }
  return text(item.id);
}

function pathfinderSources(value: unknown): string | null {
  const source = array(object(value).sources)[0];
  return imageUrl(source);
}

function pathfinderArtistCredits(value: unknown): Array<{ id: string; name: string }> {
  const entries = array(object(value).items);
  return unique(entries.map((entry) => {
    const artist = object(entry);
    const profile = object(artist.profile);
    const id = spotifyUriId(artist, "artist");
    const name = text(profile.name) || text(artist.name);
    return id && name ? { id, name } : null;
  }));
}

function mapPathfinderTrack(value: unknown): TrackSummary | null {
  const item = object(value);
  const id = spotifyUriId(item, "track");
  if (!id) return null;
  const album = object(item.albumOfTrack);
  const credits = pathfinderArtistCredits(item.artists);
  const albumId = spotifyUriId(album, "album") || null;
  const albumTitle = text(album.name) || null;
  const trackDuration = object(item.trackDuration);
  const itemDuration = object(item.duration);
  const durationMs = duration(trackDuration.totalMilliseconds ?? itemDuration.totalMilliseconds);
  const image = pathfinderSources(album.coverArt);
  const label = text(object(item.contentRating).label).toUpperCase();
  return {
    provider: "spotify",
    id,
    title: text(item.name) || "Unknown title",
    version: null,
    artists: credits.map((artist) => artist.name),
    artistCredits: credits,
    albumId,
    albumTitle,
    durationMs,
    isrc: null,
    coverUrl: image,
    webpageUrl: `https://open.spotify.com/track/${id}`,
    explicit: label === "EXPLICIT" || item.explicit === true,
    mediaTags: [],
  };
}

function mapPathfinderAlbum(value: unknown): AlbumSummary | null {
  const item = object(value);
  const id = spotifyUriId(item, "album");
  if (!id) return null;
  const credits = pathfinderArtistCredits(item.artists);
  const date = object(item.date);
  return {
    id,
    title: text(item.name) || "Unknown album",
    version: null,
    artists: credits.map((artist) => artist.name),
    artistCredits: credits,
    coverUrl: pathfinderSources(item.coverArt),
    releaseDate: text(date.isoString) || (positiveInt(date.year) ? String(positiveInt(date.year)) : null),
    durationMs: null,
    numberOfTracks: null,
    albumType: text(item.type).toUpperCase() || null,
    explicit: text(object(item.contentRating).label).toUpperCase() === "EXPLICIT",
    mediaTags: [],
  };
}

function mapPathfinderArtist(value: unknown): ArtistSummary | null {
  const item = object(value);
  const id = spotifyUriId(item, "artist");
  if (!id) return null;
  return {
    id,
    name: text(object(item.profile).name) || text(item.name) || "Unknown artist",
    pictureUrl: pathfinderSources(object(item.visuals).avatarImage),
  };
}

function mapPathfinderPlaylist(value: unknown): PlaylistSummary | null {
  const item = object(value);
  const id = spotifyUriId(item, "playlist");
  if (!id) return null;
  const images = array(object(item.images).items);
  const image = images.length ? pathfinderSources(images[0]) : null;
  const owner = object(object(item.ownerV2).data);
  const total = positiveInt(object(item.content).totalCount);
  return {
    id,
    name: text(item.name) || "Untitled playlist",
    description: text(item.description) || null,
    coverUrl: image,
    durationMs: null,
    numberOfItems: total,
    playlistType: text(item.format).toUpperCase() || "PLAYLIST",
    createdAt: null,
    lastModifiedAt: null,
    ...(text(owner.name) ? { ownerName: text(owner.name) } : {}),
  } as PlaylistSummary;
}

function pathfinderItemData(value: unknown): Json {
  const item = object(value);
  const nested = object(object(item.itemV2).data);
  if (Object.keys(nested).length) return nested;
  const legacy = object(object(item.item).data);
  if (Object.keys(legacy).length) return legacy;
  const wrapped = object(item.data);
  return Object.keys(wrapped).length ? wrapped : item;
}

function pathfinderPaging(value: unknown): { next?: string; total?: number } {
  const page = object(value);
  const paging = object(page.pagingInfo);
  const total = positiveInt(page.totalCount);
  const explicitNext = positiveInt(paging.nextOffset);
  const offset = positiveInt(paging.offset);
  const limit = positiveInt(paging.limit);
  const next = explicitNext ?? (total !== null && offset !== null && limit !== null && offset + limit < total ? offset + limit : null);
  return { ...(next !== null ? { next: String(next) } : {}), ...(total !== null ? { total } : {}) };
}

function pageItems(value: unknown): unknown[] {
  return array(object(value).items);
}

function nextOffset(value: unknown): string | undefined {
  const next = text(object(value).next);
  if (!next) return undefined;
  try {
    const offset = new URL(next).searchParams.get("offset");
    return offset && positiveInt(offset) !== null ? offset : undefined;
  } catch {
    return undefined;
  }
}

function cursorOffset(cursor: string | undefined): string {
  if (!cursor) return "0";
  try {
    const parsed = new URL(cursor);
    return parsed.searchParams.get("offset") ?? "0";
  } catch {
    return positiveInt(cursor) === null ? "0" : String(positiveInt(cursor));
  }
}

function unique<T extends { id: string }>(values: Array<T | null>): T[] {
  return [...new Map(values.filter((value): value is T => value !== null).map((value) => [value.id, value])).values()];
}

function tracksFromPage(value: unknown): TrackSummary[] {
  const page = object(value).items ? value : object(value).tracks;
  return unique(pageItems(page).map((item) => {
    // Playlist and saved-track responses wrap the actual track in `track`.
    const wrapped = object(item).track;
    return mapSpotifyTrack(wrapped && typeof wrapped === "object" ? wrapped : item);
  }));
}

function totalDuration(tracks: TrackSummary[]): number | null {
  if (!tracks.length || tracks.some((track) => track.durationMs === null)) return null;
  return tracks.reduce((total, track) => total + (track.durationMs ?? 0), 0);
}

function asCursorMap(value: CatalogSearchCursors | undefined): CatalogSearchCursors {
  return value ?? {};
}

function isPersonalizedMix(value: PlaylistSummary): boolean {
  return /discover weekly|release radar|daily mix|daylist|on repeat|repeat rewind|your time capsule|blend/i.test(value.name);
}

export class SpotifyCatalogClient {
  private readonly sessionProvider: SessionProvider;
  private readonly fetcher: Fetcher;
  private readonly market: string;
  private readonly minRequestIntervalMs: number;
  private readonly pathfinderEnabled: boolean;
  private readonly metadataProvider?: SpotifyCatalogClientOptions["metadataProvider"];
  private requestTail: Promise<void> = Promise.resolve();
  private lastRequestAt = 0;
  private rateLimitedUntil = 0;

  constructor(options: SpotifyCatalogClientOptions) {
    this.sessionProvider = options.sessionProvider;
    this.fetcher = options.fetch ?? globalThis.fetch;
    this.market = text(options.market).toUpperCase() || "US";
    this.minRequestIntervalMs = Math.max(0, Math.trunc(options.minRequestIntervalMs ?? 200));
    this.pathfinderEnabled = options.pathfinder === true;
    this.metadataProvider = options.metadataProvider;
  }

  private async pathfinder(operationName: string, sha256Hash: string, variables: Record<string, unknown>): Promise<unknown> {
    let release!: () => void;
    const previous = this.requestTail;
    this.requestTail = new Promise<void>((resolve) => { release = resolve; });
    try {
      const now = Date.now();
      if (this.rateLimitedUntil > now) {
        const retryIn = Math.ceil((this.rateLimitedUntil - now) / 1_000);
        throw new Error(`Spotify catalog rate limited; retry in ${retryIn}s`);
      }
      await previous;
      const afterPrevious = Date.now();
      if (this.rateLimitedUntil > afterPrevious) {
        const retryIn = Math.ceil((this.rateLimitedUntil - afterPrevious) / 1_000);
        throw new Error(`Spotify catalog rate limited; retry in ${retryIn}s`);
      }
      const elapsed = afterPrevious - this.lastRequestAt;
      const wait = this.minRequestIntervalMs - elapsed;
      if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
      let session = await this.sessionProvider(false);
      if (!session.accessToken.trim()) throw new Error("Spotify catalog requires a linked Spotify account");
      const request = () => this.fetcher(SPOTIFY_PATHFINDER_API, {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json;charset=UTF-8",
          Authorization: `Bearer ${session.accessToken}`,
          ...(session.clientToken ? { "Client-Token": session.clientToken } : {}),
          "App-Platform": "WebPlayer",
          ...(session.appVersion ? { "Spotify-App-Version": session.appVersion } : {}),
        },
        body: JSON.stringify({
          variables,
          operationName,
          extensions: { persistedQuery: { version: 1, sha256Hash } },
        }),
      });
      let response = await request();
      if (response.status === 401) {
        session = await this.sessionProvider(true);
        response = await request();
      }
      this.lastRequestAt = Date.now();
      const document = object(await response.json().catch(() => ({})));
      if (!response.ok) {
        const nested = object(document.error);
        const reason = text(document.reason) || text(nested.reason) || text(document.message) || text(nested.message);
        const retryAfter = response.headers.get("retry-after") ?? "";
        if (response.status === 429) {
          const seconds = Number(retryAfter);
          this.rateLimitedUntil = Date.now() + (Number.isFinite(seconds) && seconds > 0 ? Math.min(300_000, seconds * 1_000) : 5_000);
          debugLog("spotify.catalog", "pathfinder_rate_limited", { operationName, reason: reason || "unknown", retryAfter: retryAfter || undefined });
        }
        throw new Error(`Spotify Pathfinder request failed (${response.status}${reason ? `: ${reason}` : ""}${retryAfter ? `; retry after ${retryAfter}s` : ""})`);
      }
      const errors = array(document.errors).map((error) => text(object(error).message)).filter(Boolean);
      if (errors.length) throw new Error(`Spotify Pathfinder ${operationName} failed: ${errors[0]}`);
      return document;
    } finally {
      release();
    }
  }

  private async get(path: string, params: Record<string, string> = {}): Promise<unknown> {
    const url = new URL(path, `${SPOTIFY_CATALOG_API}/`);
    for (const [key, value] of Object.entries(params)) {
      if (value) url.searchParams.set(key, value);
    }
    let release!: () => void;
    const previous = this.requestTail;
    this.requestTail = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    try {
      const now = Date.now();
      if (this.rateLimitedUntil > now) {
        const retryIn = Math.ceil((this.rateLimitedUntil - now) / 1_000);
        throw new Error(`Spotify catalog rate limited; retry in ${retryIn}s`);
      }
      const wait = this.minRequestIntervalMs - (now - this.lastRequestAt);
      if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
      let session = await this.sessionProvider(false);
      if (!session.accessToken.trim()) throw new Error("Spotify catalog requires a linked Spotify account");
      const request = () => this.fetcher(url, {
        headers: {
          Accept: "application/json",
          Authorization: `Bearer ${session.accessToken}`,
          ...(session.clientToken ? { "Client-Token": session.clientToken } : {}),
          "App-Platform": "WebPlayer",
        },
      });
      let response = await request();
      if (response.status === 401) {
        session = await this.sessionProvider(true);
        response = await request();
      }
      this.lastRequestAt = Date.now();
      if (!response.ok) {
        const body = object(await response.json().catch(() => ({})));
        const nested = object(body.error);
        const reason = text(body.reason) || text(nested.reason) || text(body.message) || text(nested.message);
        const retryAfter = response.headers.get("retry-after") ?? "";
        if (response.status === 401) throw new Error("Spotify catalog session expired");
        if (response.status === 403) throw new Error("Spotify catalog access was denied for this account");
        if (response.status === 429) {
          const retrySeconds = Number(retryAfter);
          const cooldownMs = Number.isFinite(retrySeconds) && retrySeconds > 0
            ? Math.min(5 * 60_000, retrySeconds * 1_000) : 5_000;
          this.rateLimitedUntil = Date.now() + cooldownMs;
          debugLog("spotify.catalog", "rate_limited", {
            path, reason: reason || "unknown", retryAfter: retryAfter || undefined,
          });
          const detail = reason ? ` (${reason})` : "";
          const retry = retryAfter ? `; retry after ${retryAfter}s` : "";
          throw new Error(`Spotify catalog rate limit reached${detail}${retry}`);
        }
        throw new Error(`Spotify catalog request failed (${response.status}${reason ? `: ${reason}` : ""})`);
      }
      return response.json();
    } finally {
      release();
    }
  }

  /** Album and playlist endpoints often return simplified tracks without
   * external_ids. Hydrate those IDs in Spotify's 50-track batch endpoint so
   * ISRC matching remains available throughout the catalog, not only in
   * search results. */
  private async hydrateTrackIsrcs(tracks: TrackSummary[]): Promise<TrackSummary[]> {
    const missing = tracks.filter((track) => !track.isrc).map((track) => track.id);
    if (!missing.length) return tracks;
    if (this.metadataProvider) {
      try {
        const hydrated = new Map<string, Awaited<ReturnType<NonNullable<SpotifyCatalogClientOptions["metadataProvider"]>>>[number]>();
        for (let index = 0; index < missing.length; index += 50) {
          for (const value of await this.metadataProvider(missing.slice(index, index + 50))) hydrated.set(value.spotifyId, value);
        }
        return tracks.map((track) => {
          const value = hydrated.get(track.id);
          if (!value) return track;
          return {
            ...track,
            title: value.title || track.title,
            artists: value.artists.length ? value.artists : track.artists,
            durationMs: value.durationMs ?? track.durationMs,
            isrc: value.isrc?.toUpperCase() ?? track.isrc,
            ...(value.explicit === undefined ? {} : { explicit: value.explicit }),
            ...(value.album ? { albumTitle: value.album } : {}),
          };
        });
      } catch (error) {
        debugLog("spotify.catalog", "metadata_unavailable", {
          error: error instanceof Error ? error.message : String(error), count: missing.length,
        });
        return tracks;
      }
    }
    if (this.pathfinderEnabled) return tracks;
    const hydrated = new Map<string, TrackSummary>();
    try {
      for (let index = 0; index < missing.length; index += 50) {
        const ids = missing.slice(index, index + 50).join(",");
        const document = object(await this.get("tracks", { ids, market: this.market }));
        for (const value of array(document.tracks)) {
          const mapped = mapSpotifyTrack(value);
          if (mapped) hydrated.set(mapped.id, mapped);
        }
      }
    } catch {
      return tracks;
    }
    return tracks.map((track) => hydrated.get(track.id) ?? track);
  }

  private async searchPathfinder(query: string, limit: number, cursors: CatalogSearchCursors & { playlists?: string }): Promise<SpotifyCatalogSearchPage> {
    const normalized = query.trim();
    const offset = (cursor: string | undefined): number => Number(cursorOffset(cursor)) || 0;
    const common = {
      includePreReleases: false,
      includeAlbumPreReleases: false,
      numberOfTopResults: 20,
      searchTerm: normalized,
      includeAudiobooks: true,
      includeAuthors: false,
      includeEpisodeContentRatingsV2: true,
    };
    const specs = [
      ["tracks", "searchTracks", PATHFINDER_HASHES.searchTracks, { ...common, offset: offset(cursors.tracks), limit: Math.min(50, limit) }],
      ["albums", "searchAlbums", PATHFINDER_HASHES.searchAlbums, { ...common, offset: offset(cursors.albums), limit: Math.min(50, limit) }],
      ["artists", "searchArtists", PATHFINDER_HASHES.searchArtists, { ...common, offset: offset(cursors.artists), limit: Math.min(50, limit) }],
      ["playlists", "searchPlaylists", PATHFINDER_HASHES.searchPlaylists, { ...common, offset: offset(cursors.playlists), limit: Math.min(50, limit) }],
    ] as const;
    const documents = await Promise.all(specs.map(([, operation, hash, variables]) => this.pathfinder(operation, hash, variables)));
    const search = (document: unknown) => object(object(object(document).data).searchV2);
    const trackPage = object(search(documents[0]).tracksV2);
    const albumPage = object(search(documents[1]).albumsV2);
    const artistPage = object(search(documents[2]).artists);
    const playlistPage = object(search(documents[3]).playlists);
    const tracks = await this.hydrateTrackIsrcs(unique(array(trackPage.items).map((item) => mapPathfinderTrack(pathfinderItemData(item)))));
    const albums = unique(array(albumPage.items).map((item) => mapPathfinderAlbum(pathfinderItemData(item))));
    const artists = unique(array(artistPage.items).map((item) => mapPathfinderArtist(pathfinderItemData(item))));
    const playlists = unique(array(playlistPage.items).map((item) => mapPathfinderPlaylist(pathfinderItemData(item))));
    const result: CatalogSearchCursors & { playlists?: string } = {};
    const trackNext = pathfinderPaging(trackPage).next;
    const albumNext = pathfinderPaging(albumPage).next;
    const artistNext = pathfinderPaging(artistPage).next;
    const playlistNext = pathfinderPaging(playlistPage).next;
    if (trackNext) result.tracks = trackNext;
    if (albumNext) result.albums = albumNext;
    if (artistNext) result.artists = artistNext;
    if (playlistNext) result.playlists = playlistNext;
    return { tracks, albums, artists, playlists, cursors: result };
  }

  async searchCatalog(query: string, limit = 20, cursors: CatalogSearchCursors & { playlists?: string } = {}): Promise<SpotifyCatalogSearchPage> {
    const normalized = query.trim();
    if (!normalized) throw new Error("Spotify search query is empty");
    if (this.pathfinderEnabled) return this.searchPathfinder(normalized, Math.max(1, Math.min(50, Math.trunc(limit))), cursors);
    const pageLimit = String(Math.max(1, Math.min(50, Math.trunc(limit))));
    const current = asCursorMap(cursors);
    const offsets = [cursorOffset(current.tracks), cursorOffset(current.albums), cursorOffset(current.artists), cursorOffset(current.playlists)];
    const kinds = ["track", "album", "artist", "playlist"] as const;
    // The legacy Web API path accepts a comma-separated type list. Pathfinder
    // uses one persisted operation per section and the request gate keeps
    // those operations from creating a burst against the Web Player backend.
    const combined = new Set(offsets).size === 1;
    type Settled = { status: "fulfilled"; value: unknown } | { status: "rejected"; reason: unknown };
    const responses: Settled[] = combined
      ? [await this.get("search", {
        q: normalized, type: kinds.join(","), limit: pageLimit, offset: offsets[0]!, market: this.market,
      }).then((value) => ({ status: "fulfilled", value } as Settled), (reason) => ({ status: "rejected", reason } as Settled))]
      : await Promise.all(kinds.map((kind, index) => this.get("search", {
        q: normalized, type: kind, limit: pageLimit, offset: offsets[index]!, market: this.market,
      }).then((value) => ({ status: "fulfilled", value } as Settled), (reason) => ({ status: "rejected", reason } as Settled))));
    if (responses.every((response) => response.status === "rejected")) {
      throw (responses[0] as PromiseRejectedResult).reason;
    }
    const first = responses[0]!;
    const [tracks, albums, artists, playlists] = combined
      ? [
        first.status === "fulfilled" ? { tracks: object(first.value).tracks } : {},
        first.status === "fulfilled" ? { albums: object(first.value).albums } : {},
        first.status === "fulfilled" ? { artists: object(first.value).artists } : {},
        first.status === "fulfilled" ? { playlists: object(first.value).playlists } : {},
      ] as [Json, Json, Json, Json]
      : responses.map((response) => response.status === "fulfilled" ? response.value : {}) as [Json, Json, Json, Json];
    const result: CatalogSearchCursors & { playlists?: string } = {};
    const trackCursor = nextOffset(object(tracks).tracks);
    const albumCursor = nextOffset(object(albums).albums);
    const artistCursor = nextOffset(object(artists).artists);
    const playlistCursor = nextOffset(object(playlists).playlists);
    if (trackCursor) result.tracks = trackCursor;
    if (albumCursor) result.albums = albumCursor;
    if (artistCursor) result.artists = artistCursor;
    if (playlistCursor) result.playlists = playlistCursor;
    return {
      tracks: unique(array(object(tracks).tracks ? pageItems(object(tracks).tracks) : []).map(mapSpotifyTrack)),
      albums: unique(array(object(albums).albums ? pageItems(object(albums).albums) : []).map(mapSpotifyAlbum)),
      artists: unique(array(object(artists).artists ? pageItems(object(artists).artists) : []).map(mapSpotifyArtist)),
      playlists: unique(array(object(playlists).playlists ? pageItems(object(playlists).playlists) : []).map(mapSpotifyPlaylist)),
      cursors: result,
    };
  }

  async track(trackId: string): Promise<TrackSummary> {
    if (this.pathfinderEnabled) {
      // Track details are already part of the search/playlist envelopes. A
      // direct detail operation is not stable, so use metadata protobuf for a
      // single canonical item and retain the common summary shape.
      const values = await this.metadataProvider?.([trackId]);
      const value = values?.[0];
      if (value) {
        return {
          provider: "spotify", id: value.spotifyId, title: value.title || "Unknown title", version: null,
          artists: value.artists, artistCredits: [], albumId: null, albumTitle: value.album || null,
          durationMs: value.durationMs ?? null, isrc: value.isrc?.toUpperCase() ?? null, coverUrl: null,
          webpageUrl: `https://open.spotify.com/track/${value.spotifyId}`, explicit: value.explicit === true, mediaTags: [],
        };
      }
      throw new Error("Spotify did not return that track");
    }
    const value = mapSpotifyTrack(await this.get(`tracks/${encodeURIComponent(trackId)}`));
    if (!value) throw new Error("Spotify did not return that track");
    return value;
  }

  async albumPage(albumId: string): Promise<AlbumPage> {
    const document = object(await this.get(`albums/${encodeURIComponent(albumId)}`, {
      limit: "50", market: this.market,
    }));
    const album = mapSpotifyAlbum(document);
    if (!album) throw new Error("Spotify did not return that album");
    const tracks = await this.hydrateTrackIsrcs(tracksFromPage(document.tracks));
    const hydratedAlbum = {
      ...album,
      durationMs: totalDuration(tracks),
    };
    const trackCursor = nextOffset(document.tracks);
    const result: AlbumPage = {
      kind: "album",
      album: hydratedAlbum,
      tracks,
    };
    if (trackCursor) result.trackCursor = trackCursor;
    return result;
  }

  async playlistPage(playlistId: string): Promise<PlaylistPage> {
    if (this.pathfinderEnabled) {
      const document = object(await this.pathfinder("fetchPlaylist", PATHFINDER_HASHES.fetchPlaylist, {
        uri: `spotify:playlist:${playlistId}`,
        offset: 0,
        limit: 25,
        enableWatchFeedEntrypoint: true,
        includeEpisodeContentRatingsV2: true,
      }));
      const playlistDocument = object(object(document.data).playlistV2);
      const content = object(playlistDocument.content);
      const playlist = mapPathfinderPlaylist(playlistDocument);
      if (!playlist) throw new Error("Spotify did not return that playlist");
      const tracks = await this.hydrateTrackIsrcs(unique(array(content.items).map((item) => mapPathfinderTrack(pathfinderItemData(item)))));
      const page = pathfinderPaging(content);
      const result: PlaylistPage = {
        kind: "playlist",
        playlist: { ...playlist, numberOfItems: page.total ?? playlist.numberOfItems, durationMs: totalDuration(tracks) },
        tracks,
      };
      if (page.next) result.trackCursor = page.next;
      return result;
    }
    const document = object(await this.get(`playlists/${encodeURIComponent(playlistId)}`, {
      // Spotify renamed the playlist item container from `tracks` to `items`.
      // Keep the parser tolerant of the legacy shape for older responses.
      fields: "name,description,images,type,owner,items(total,next,items(track(id,name,artists,album,duration_ms,external_ids,external_urls,explicit)))",
      limit: "100", market: this.market,
    }));
    const playlist = mapSpotifyPlaylist(document);
    if (!playlist) throw new Error("Spotify did not return that playlist");
    const itemPage = document.items ?? document.tracks;
    const tracks = await this.hydrateTrackIsrcs(tracksFromPage(itemPage));
    const trackCursor = nextOffset(itemPage);
    const result: PlaylistPage = {
      kind: "playlist",
      playlist: { ...playlist, durationMs: totalDuration(tracks) },
      tracks,
    };
    if (trackCursor) result.trackCursor = trackCursor;
    return result;
  }

  async artistPage(artistId: string): Promise<ArtistPage> {
    const [artistDocument, topTracksDocument, albumsDocument] = await Promise.all([
      this.get(`artists/${encodeURIComponent(artistId)}`),
      this.get(`artists/${encodeURIComponent(artistId)}/top-tracks`, { market: this.market }),
      this.get(`artists/${encodeURIComponent(artistId)}/albums`, { limit: "50", market: this.market }),
    ]);
    const artist = mapSpotifyArtist(artistDocument);
    if (!artist) throw new Error("Spotify did not return that artist");
    const topTracks = await this.hydrateTrackIsrcs(array(object(topTracksDocument).tracks).map(mapSpotifyTrack).filter((item): item is TrackSummary => item !== null));
    const albums = unique(pageItems(albumsDocument).map(mapSpotifyAlbum));
    const albumCursor = nextOffset(albumsDocument);
    return albumCursor ? { kind: "artist", artist, topTracks, albums, albumCursor }
      : { kind: "artist", artist, topTracks, albums };
  }

  async detailMore(kind: string, resourceId: string, section: string, cursor: string): Promise<{
    section: "tracks" | "albums";
    tracks?: TrackSummary[];
    albums?: AlbumSummary[];
    cursor?: string;
  }> {
    const offset = cursorOffset(cursor);
    if (this.pathfinderEnabled && kind === "playlist" && section === "tracks") {
      const document = object(await this.pathfinder("fetchPlaylist", PATHFINDER_HASHES.fetchPlaylist, {
        uri: `spotify:playlist:${resourceId}`,
        offset: Number(offset) || 0,
        limit: 50,
        includeEpisodeContentRatingsV2: true,
      }));
      const content = object(object(object(document.data).playlistV2).content);
      const tracks = await this.hydrateTrackIsrcs(unique(array(content.items).map((item) => mapPathfinderTrack(pathfinderItemData(item)))));
      const next = pathfinderPaging(content).next;
      return next ? { section: "tracks", tracks, cursor: next } : { section: "tracks", tracks };
    }
    if (kind === "album" && section === "tracks") {
      const document = await this.get(`albums/${encodeURIComponent(resourceId)}/tracks`, { limit: "50", offset, market: this.market });
      const next = nextOffset(document);
      const tracks = await this.hydrateTrackIsrcs(tracksFromPage(document));
      return next ? { section: "tracks", tracks, cursor: next }
        : { section: "tracks", tracks };
    }
    if (kind === "playlist" && section === "tracks") {
      const document = await this.get(`playlists/${encodeURIComponent(resourceId)}/items`, {
        limit: "100", offset, market: this.market,
      });
      const next = nextOffset(document);
      const tracks = await this.hydrateTrackIsrcs(tracksFromPage(document));
      return next ? { section: "tracks", tracks, cursor: next }
        : { section: "tracks", tracks };
    }
    if (kind === "artist" && section === "albums") {
      const document = await this.get(`artists/${encodeURIComponent(resourceId)}/albums`, { limit: "50", offset, market: this.market });
      const next = nextOffset(document);
      const albums = unique(pageItems(document).map(mapSpotifyAlbum));
      return next ? { section: "albums", albums, cursor: next } : { section: "albums", albums };
    }
    throw new Error(`Cannot paginate Spotify ${kind} ${section}`);
  }

  async collection(options: SpotifyCollectionOptions = {}): Promise<UserCollectionPage> {
    const limit = String(Math.max(1, Math.min(50, Math.trunc(options.limit ?? 50))));
    if (this.pathfinderEnabled) {
      const document = object(await this.pathfinder("libraryV3", PATHFINDER_HASHES.libraryV3, {
        order: null,
        textFilter: "",
        features: ["LIKED_SONGS", "YOUR_EPISODES_V2", "PRERELEASES", "PRERELEASES_V2", "CLIPS", "EVENTS"],
        limit: Number(limit),
        offset: 0,
        flatten: false,
        expandedFolders: [],
        folderUri: null,
        includeFoldersWhenFlattening: true,
      }));
      const library = object(object(object(document.data).me).libraryV3);
      const entries = array(library.items);
      const playlists = unique(entries.map((entry) => {
        const data = pathfinderItemData(object(entry).item);
        return text(data.__typename) === "Playlist" ? mapPathfinderPlaylist(data) : null;
      }));
      const albums = unique(entries.map((entry) => {
        const data = pathfinderItemData(object(entry).item);
        return text(data.__typename) === "Album" ? mapPathfinderAlbum(data) : null;
      }));
      const artists = unique(entries.map((entry) => {
        const data = pathfinderItemData(object(entry).item);
        return text(data.__typename) === "Artist" ? mapPathfinderArtist(data) : null;
      }));
      const pseudo = entries.map((entry) => pathfinderItemData(object(entry).item))
        .find((data) => text(data.__typename) === "PseudoPlaylist" && text(data.uri) === "spotify:collection:tracks");
      let likedTracks: TrackSummary[] = [];
      if (pseudo) {
        try {
          const likedDocument = object(await this.pathfinder("fetchPlaylist", PATHFINDER_HASHES.fetchPlaylist, {
            uri: "spotify:collection:tracks", offset: 0, limit: Number(limit), includeEpisodeContentRatingsV2: true,
          }));
          const content = object(object(object(likedDocument.data).playlistV2).content);
          likedTracks = await this.hydrateTrackIsrcs(unique(array(content.items).map((item) => mapPathfinderTrack(pathfinderItemData(item)))));
        } catch (error) {
          debugLog("spotify.catalog", "liked_tracks_unavailable", { error: error instanceof Error ? error.message : String(error) });
        }
      }
      const allPlaylists = playlists;
      const mixes = allPlaylists.filter(isPersonalizedMix);
      const userPlaylists = allPlaylists.filter((playlist) => !isPersonalizedMix(playlist));
      const cursors: Record<string, string> = {};
      const next = pathfinderPaging(library).next;
      if (next) cursors.library = next;
      return { tracks: likedTracks, albums, artists, playlists: userPlaylists, mixes, cursors };
    }
    const [savedTracks, savedAlbums, playlists, following] = await Promise.allSettled([
      this.get("me/tracks", { limit, market: this.market }),
      this.get("me/albums", { limit, market: this.market }),
      this.get("me/playlists", { limit }),
      this.get("me/following", { type: "artist", limit }),
    ]);
    const tracks = savedTracks.status === "fulfilled" ? tracksFromPage(savedTracks.value) : [];
    const albums = savedAlbums.status === "fulfilled" ? unique(pageItems(savedAlbums.value).map((item) => mapSpotifyAlbum(object(item).album))) : [];
    const playlistValues = playlists.status === "fulfilled" ? unique(pageItems(playlists.value).map(mapSpotifyPlaylist)) : [];
    const mixes = playlistValues.filter(isPersonalizedMix);
    const userPlaylists = playlistValues.filter((playlist) => !isPersonalizedMix(playlist));
    const artists = following.status === "fulfilled"
      ? unique(pageItems(object(following.value).artists).map(mapSpotifyArtist))
      : [];
    if (!tracks.length && !albums.length && !playlistValues.length && !artists.length
        && [savedTracks, savedAlbums, playlists, following].every((result) => result.status === "rejected")) {
      throw (savedTracks as PromiseRejectedResult).reason;
    }
    const cursors: Record<string, string> = {};
    const remember = (key: string, result: PromiseSettledResult<unknown>, source = result): void => {
      if (source.status !== "fulfilled") return;
      const cursor = nextOffset(source.value);
      if (cursor) cursors[key] = cursor;
    };
    remember("tracks", savedTracks);
    remember("albums", savedAlbums);
    remember("playlists", playlists);
    remember("artists", following, following);
    return {
      tracks,
      albums,
      artists,
      playlists: userPlaylists,
      mixes,
      cursors,
    };
  }

  async collectionMore(section: string, cursor: string): Promise<{ section: string; items: unknown[]; cursor?: string }> {
    const offset = cursorOffset(cursor);
    const limit = section === "playlists" ? "50" : "50";
    if (this.pathfinderEnabled) {
      if (section === "tracks") {
        const document = object(await this.pathfinder("fetchPlaylist", PATHFINDER_HASHES.fetchPlaylist, {
          uri: "spotify:collection:tracks", offset: Number(offset) || 0, limit: Number(limit), includeEpisodeContentRatingsV2: true,
        }));
        const content = object(object(object(document.data).playlistV2).content);
        const items = await this.hydrateTrackIsrcs(unique(array(content.items).map((item) => mapPathfinderTrack(pathfinderItemData(item)))));
        const next = pathfinderPaging(content).next;
        return next ? { section, items, cursor: next } : { section, items };
      }
      const document = object(await this.pathfinder("libraryV3", PATHFINDER_HASHES.libraryV3, {
        order: null,
        textFilter: "",
        features: ["LIKED_SONGS", "YOUR_EPISODES_V2", "PRERELEASES", "PRERELEASES_V2", "CLIPS", "EVENTS"],
        limit: Number(limit),
        offset: Number(offset) || 0,
        flatten: false,
        expandedFolders: [],
        folderUri: null,
        includeFoldersWhenFlattening: true,
      }));
      const library = object(object(object(document.data).me).libraryV3);
      const items = array(library.items).map((entry) => pathfinderItemData(object(entry).item));
      const typed = section === "playlists" ? "Playlist" : section === "albums" ? "Album" : section === "artists" ? "Artist" : "Track";
      const mapped = typed === "Playlist"
        ? unique(items.filter((item) => text(item.__typename) === typed).map(mapPathfinderPlaylist))
        : typed === "Album"
          ? unique(items.filter((item) => text(item.__typename) === typed).map(mapPathfinderAlbum))
          : typed === "Artist"
            ? unique(items.filter((item) => text(item.__typename) === typed).map(mapPathfinderArtist))
            : await this.hydrateTrackIsrcs(unique(items.filter((item) => text(item.__typename) === typed).map(mapPathfinderTrack)));
      const next = pathfinderPaging(library).next;
      return next ? { section, items: mapped, cursor: next } : { section, items: mapped };
    }
    let document: unknown;
    if (section === "tracks") document = await this.get("me/tracks", { limit, offset, market: this.market });
    else if (section === "albums") document = await this.get("me/albums", { limit, offset, market: this.market });
    else if (section === "playlists") document = await this.get("me/playlists", { limit, offset });
    else if (section === "artists") document = await this.get("me/following", { type: "artist", limit, offset });
    else throw new Error(`Cannot paginate Spotify collection ${section}`);
    const items = section === "tracks"
      ? tracksFromPage(document)
      : section === "albums"
        ? unique(pageItems(document).map((item) => mapSpotifyAlbum(object(item).album)))
        : section === "playlists"
          ? unique(pageItems(document).map(mapSpotifyPlaylist))
          : unique(pageItems(object(document).artists).map(mapSpotifyArtist));
    const next = nextOffset(document);
    return next ? { section, items, cursor: next } : { section, items };
  }

  async albumTracks(albumId: string): Promise<TrackSummary[]> {
    const first = await this.get(`albums/${encodeURIComponent(albumId)}/tracks`, { limit: "50", market: this.market });
    const tracks = await this.hydrateTrackIsrcs(tracksFromPage(first));
    const cursor = nextOffset(first);
    if (!cursor) return tracks;
    const second = await this.get(`albums/${encodeURIComponent(albumId)}/tracks`, { limit: "50", offset: cursor, market: this.market });
    return unique([...tracks, ...await this.hydrateTrackIsrcs(tracksFromPage(second))]);
  }
}

export { mapSpotifyAlbum, mapSpotifyArtist, mapSpotifyPlaylist, mapSpotifyTrack };
