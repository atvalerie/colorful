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
import type { SpotifyCredentials } from "./spotify-auth";

/**
 * Spotify catalog metadata is read through the Web API with the bearer which
 * the first-party Web Player issued for the linked profile.  It is important
 * that this module never exposes a Spotify playback source: callers resolve
 * the returned ISRCs against their native playback provider (currently
 * TIDAL).
 */
export const SPOTIFY_CATALOG_API = "https://api.spotify.com/v1";

type Json = Record<string, unknown>;
type Fetcher = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
type SessionProvider = (force?: boolean) => Promise<Pick<SpotifyCredentials, "accessToken" | "clientToken">>;

export type SpotifyCatalogClientOptions = {
  sessionProvider: SessionProvider;
  fetch?: Fetcher;
  /** Market used for artist top tracks and market-dependent playlist items. */
  market?: string;
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
  return {
    id,
    name: text(item.name) || "Untitled playlist",
    description: text(item.description) || null,
    coverUrl: albumImages(item.images),
    durationMs: null,
    numberOfItems: positiveInt(object(item.tracks).total),
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

  constructor(options: SpotifyCatalogClientOptions) {
    this.sessionProvider = options.sessionProvider;
    this.fetcher = options.fetch ?? globalThis.fetch;
    this.market = text(options.market).toUpperCase() || "US";
  }

  private async get(path: string, params: Record<string, string> = {}): Promise<unknown> {
    const url = new URL(path, `${SPOTIFY_CATALOG_API}/`);
    for (const [key, value] of Object.entries(params)) {
      if (value) url.searchParams.set(key, value);
    }
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
    if (!response.ok) {
      if (response.status === 401) throw new Error("Spotify catalog session expired");
      if (response.status === 403) throw new Error("Spotify catalog access was denied for this account");
      if (response.status === 429) throw new Error("Spotify catalog rate limit reached");
      throw new Error(`Spotify catalog request failed (${response.status})`);
    }
    return response.json();
  }

  /** Album and playlist endpoints often return simplified tracks without
   * external_ids. Hydrate those IDs in Spotify's 50-track batch endpoint so
   * ISRC matching remains available throughout the catalog, not only in
   * search results. */
  private async hydrateTrackIsrcs(tracks: TrackSummary[]): Promise<TrackSummary[]> {
    const missing = tracks.filter((track) => !track.isrc).map((track) => track.id);
    if (!missing.length) return tracks;
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

  async searchCatalog(query: string, limit = 20, cursors: CatalogSearchCursors & { playlists?: string } = {}): Promise<SpotifyCatalogSearchPage> {
    const normalized = query.trim();
    if (!normalized) throw new Error("Spotify search query is empty");
    const pageLimit = String(Math.max(1, Math.min(50, Math.trunc(limit))));
    const current = asCursorMap(cursors);
    const responses = await Promise.allSettled([
      this.get("search", { q: normalized, type: "track", limit: pageLimit, offset: cursorOffset(current.tracks), market: this.market }),
      this.get("search", { q: normalized, type: "album", limit: pageLimit, offset: cursorOffset(current.albums), market: this.market }),
      this.get("search", { q: normalized, type: "artist", limit: pageLimit, offset: cursorOffset(current.artists), market: this.market }),
      this.get("search", { q: normalized, type: "playlist", limit: pageLimit, offset: cursorOffset(current.playlists), market: this.market }),
    ]);
    if (responses.every((response) => response.status === "rejected")) {
      throw (responses[0] as PromiseRejectedResult).reason;
    }
    const [tracks, albums, artists, playlists] = responses.map((response) =>
      response.status === "fulfilled" ? response.value : {}) as [Json, Json, Json, Json];
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
    const document = object(await this.get(`playlists/${encodeURIComponent(playlistId)}`, {
      fields: "name,description,images,type,owner,tracks(total,next,items(track(id,name,artists,album,duration_ms,external_ids,external_urls,explicit)))",
      limit: "100", market: this.market,
    }));
    const playlist = mapSpotifyPlaylist(document);
    if (!playlist) throw new Error("Spotify did not return that playlist");
    const tracks = await this.hydrateTrackIsrcs(tracksFromPage(document.tracks));
    const trackCursor = nextOffset(document.tracks);
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
    if (kind === "album" && section === "tracks") {
      const document = await this.get(`albums/${encodeURIComponent(resourceId)}/tracks`, { limit: "50", offset, market: this.market });
      const next = nextOffset(document);
      const tracks = await this.hydrateTrackIsrcs(tracksFromPage(document));
      return next ? { section: "tracks", tracks, cursor: next }
        : { section: "tracks", tracks };
    }
    if (kind === "playlist" && section === "tracks") {
      const document = await this.get(`playlists/${encodeURIComponent(resourceId)}/tracks`, {
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
