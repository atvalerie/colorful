import { BrowseAuth } from "./auth";
import type { TidalConfig } from "./config";

export type TrackSummary = {
  provider?: string;
  id: string;
  title: string;
  version: string | null;
  artists: string[];
  artistCredits: ArtistCredit[];
  uploader?: { id: string | null; name: string };
  mediaKind?: "song" | "video";
  albumId: string | null;
  albumTitle: string | null;
  durationMs: number | null;
  isrc: string | null;
  coverUrl: string | null;
  explicit?: boolean;
  mediaTags?: string[];
};

export type ArtistCredit = { id: string; name: string };

export type AlbumSummary = {
  id: string;
  title: string;
  version: string | null;
  artists: string[];
  artistCredits: ArtistCredit[];
  coverUrl: string | null;
  releaseDate: string | null;
  durationMs: number | null;
  numberOfTracks: number | null;
  albumType: string | null;
  explicit: boolean;
  mediaTags: string[];
};

export type ArtistSummary = {
  id: string;
  name: string;
  pictureUrl: string | null;
  isChannel?: boolean;
};

export type PlaylistSummary = {
  id: string;
  name: string;
  description: string | null;
  coverUrl: string | null;
  durationMs: number | null;
  numberOfItems: number | null;
  playlistType: string | null;
  createdAt: string | null;
  lastModifiedAt: string | null;
};

export type UserCollectionPage = {
  tracks: TrackSummary[];
  albums: AlbumSummary[];
  artists: ArtistSummary[];
  playlists: PlaylistSummary[];
  dailyMixes?: PlaylistSummary[];
  discoveryMixes?: PlaylistSummary[];
  newReleaseMixes?: PlaylistSummary[];
  mixes: PlaylistSummary[];
  cursors: Record<string, string>;
};

export type CatalogSearch = { tracks: TrackSummary[]; albums: AlbumSummary[]; artists: ArtistSummary[] };
export type CatalogSearchCursors = { tracks?: string; albums?: string; artists?: string };
export type CatalogSearchPage = CatalogSearch & { cursors: CatalogSearchCursors };
export type TrackPage = { kind: "track"; track: TrackSummary; relatedTracks: TrackSummary[] };
export type AlbumPage = { kind: "album"; album: AlbumSummary; tracks: TrackSummary[]; trackCursor?: string };
export type PlaylistPage = { kind: "playlist"; playlist: PlaylistSummary; tracks: TrackSummary[]; trackCursor?: string };
export type ArtistPage = {
  kind: "artist";
  artist: ArtistSummary;
  topTracks: TrackSummary[];
  albums: AlbumSummary[];
  trackCursor?: string;
  albumCursor?: string;
};
export type CatalogMore = {
  section: "tracks" | "albums";
  tracks?: TrackSummary[];
  albums?: AlbumSummary[];
  cursor?: string;
};

export function formatTrackTitle(title: string, version: string | null | undefined): string {
  const cleanTitle = title.trim() || "Unknown title";
  const cleanVersion = version?.trim();
  if (!cleanVersion) return cleanTitle;
  const suffix = `(${cleanVersion})`;
  return cleanTitle.toLocaleLowerCase().endsWith(suffix.toLocaleLowerCase())
    ? cleanTitle
    : `${cleanTitle} ${suffix}`;
}

export function mergeRelatedTracks(similar: TrackSummary[], radio: TrackSummary[], limit: number): TrackSummary[] {
  const interleaved: TrackSummary[] = [];
  for (let index = 0; index < Math.max(similar.length, radio.length); index += 1) {
    const similarTrack = similar[index];
    const radioTrack = radio[index];
    if (similarTrack) interleaved.push(similarTrack);
    if (radioTrack) interleaved.push(radioTrack);
  }
  return [...new Map(interleaved.map((track) => [track.id, track])).values()].slice(0, limit);
}

function albumPreference(album: AlbumSummary): number {
  const tags = new Set(album.mediaTags.map((tag) => tag.toUpperCase()));
  return (album.explicit ? 1_000 : 0)
    + (tags.has("HIRES_LOSSLESS") ? 300 : 0)
    + (tags.has("LOSSLESS") ? 200 : 0)
    + (tags.has("DOLBY_ATMOS") ? 50 : 0)
    + (album.coverUrl ? 10 : 0);
}

export function deduplicateAlbums(albums: AlbumSummary[]): AlbumSummary[] {
  const result: AlbumSummary[] = [];
  const positions = new Map<string, number>();
  for (const album of albums) {
    const key = [
      album.title.trim().toLocaleLowerCase(),
      album.artists.map((artist) => artist.trim().toLocaleLowerCase()).join("\u0001"),
      album.releaseDate ?? "",
      album.numberOfTracks ?? "",
      album.albumType ?? "",
    ].join("\u0000");
    const existingIndex = positions.get(key);
    if (existingIndex === undefined) {
      positions.set(key, result.length);
      result.push(album);
    } else {
      const existing = result[existingIndex];
      if (existing && albumPreference(album) > albumPreference(existing)) result[existingIndex] = album;
    }
  }
  return result;
}

function trackPreference(track: TrackSummary): number {
  const tags = new Set((track.mediaTags ?? []).map((tag) => tag.toUpperCase()));
  return (track.explicit ? 1_000 : 0)
    + (tags.has("HIRES_LOSSLESS") ? 300 : 0)
    + (tags.has("LOSSLESS") ? 200 : 0)
    + (tags.has("DOLBY_ATMOS") ? 50 : 0)
    + (track.coverUrl ? 10 : 0);
}

export function deduplicateTracks(tracks: TrackSummary[]): TrackSummary[] {
  const result: TrackSummary[] = [];
  const positions = new Map<string, number>();
  for (const track of tracks) {
    const isrc = track.isrc?.trim().toUpperCase();
    const fallbackKey = track.durationMs === null || !track.albumTitle ? `id:${track.id}` : [
      track.title.trim().toLocaleLowerCase(),
      track.artists.map((artist) => artist.trim().toLocaleLowerCase()).join("\u0001"),
      track.albumTitle.trim().toLocaleLowerCase(),
    ].join("\u0000");
    const keys = [...(isrc ? [`isrc:${isrc}`] : []), `metadata:${fallbackKey}`];
    const existingIndex = keys.map((key) => positions.get(key)).find((position) => position !== undefined);
    if (existingIndex === undefined) {
      for (const key of keys) positions.set(key, result.length);
      result.push(track);
    } else {
      for (const key of keys) positions.set(key, existingIndex);
      const existing = result[existingIndex];
      if (existing && trackPreference(track) > trackPreference(existing)) result[existingIndex] = track;
    }
  }
  return result;
}

export function cursorFromNextLink(document: { links?: { next?: unknown; meta?: { nextCursor?: unknown } } }): string | undefined {
  const metadataCursor = document.links?.meta?.nextCursor;
  if (typeof metadataCursor === "string" && metadataCursor) return metadataCursor;
  if (typeof document.links?.next !== "string" || !document.links.next) return undefined;
  try {
    return new URL(document.links.next, "https://openapi.tidal.com").searchParams.get("page[cursor]") ?? undefined;
  } catch {
    return undefined;
  }
}

type Resource = {
  id: string;
  type: string;
  attributes?: Record<string, any>;
  relationships?: Record<string, { data?: Array<{ id: string; type: string }> }>;
};

export function isoDurationToMs(duration: string | undefined): number | null {
  if (!duration) return null;
  const match = /^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$/.exec(duration);
  if (!match) return null;
  return Math.round((Number(match[1] ?? 0) * 3600 + Number(match[2] ?? 0) * 60 + Number(match[3] ?? 0)) * 1000);
}

function resourcesFrom(document: { data?: Resource | Resource[]; included?: Resource[] }): Resource[] {
  const data = Array.isArray(document.data) ? document.data : document.data ? [document.data] : [];
  return [...new Map([...data, ...(document.included ?? [])].map((resource) => [`${resource.type}:${resource.id}`, resource])).values()];
}

export function mapTracks(document: { data?: Resource | Resource[]; included?: Resource[] }): TrackSummary[] {
  const resources = resourcesFrom(document);
  const artists = new Map(resources.filter((resource) => resource.type === "artists").map((resource) => [resource.id, resource]));
  const albums = new Map(resources.filter((resource) => resource.type === "albums").map((resource) => [resource.id, resource]));
  const artwork = new Map(resources.filter((resource) => resource.type === "artworks").map((resource) => [resource.id, resource]));
  return resources.filter((resource) => resource.type === "tracks").map((track) => {
    const version = typeof track.attributes?.version === "string" && track.attributes.version.trim()
      ? track.attributes.version.trim()
      : null;
    const albumId = track.relationships?.albums?.data?.[0]?.id ?? null;
    const album = albumId ? albums.get(albumId) : undefined;
    const coverId = album?.relationships?.coverArt?.data?.[0]?.id;
    const cover = coverId ? artwork.get(coverId) : undefined;
    const artistIds = track.relationships?.artists?.data?.map((item) => item.id) ?? [];
    const artistCredits = artistIds.map((id) => ({ id, name: String(artists.get(id)?.attributes?.name ?? "") })).filter((artist) => artist.name);
    return {
      id: track.id,
      title: formatTrackTitle(String(track.attributes?.title ?? "Unknown title"), version),
      version,
      artists: artistCredits.map((artist) => artist.name),
      artistCredits,
      albumId,
      albumTitle: album ? String(album.attributes?.title ?? "") || null : null,
      durationMs: isoDurationToMs(track.attributes?.duration),
      isrc: typeof track.attributes?.isrc === "string" ? track.attributes.isrc : null,
      coverUrl: typeof cover?.attributes?.files?.[0]?.href === "string"
        ? cover.attributes.files[0].href
        : typeof album?.attributes?.imageLinks?.[0]?.href === "string"
          ? album.attributes.imageLinks[0].href
          : null,
      explicit: track.attributes?.explicit === true,
      mediaTags: Array.isArray(track.attributes?.mediaTags)
        ? track.attributes.mediaTags.filter((tag: unknown): tag is string => typeof tag === "string")
        : [],
    };
  });
}

function artworkUrl(resource: Resource | undefined, artwork: Map<string, Resource>, relationship = "coverArt"): string | null {
  const artworkId = resource?.relationships?.[relationship]?.data?.[0]?.id;
  const linked = artworkId ? artwork.get(artworkId) : undefined;
  return typeof linked?.attributes?.files?.[0]?.href === "string"
    ? linked.attributes.files[0].href
    : typeof resource?.attributes?.imageLinks?.[0]?.href === "string"
      ? resource.attributes.imageLinks[0].href
      : null;
}

export function mapAlbums(document: { data?: Resource | Resource[]; included?: Resource[] }): AlbumSummary[] {
  const resources = resourcesFrom(document);
  const artists = new Map(resources.filter((resource) => resource.type === "artists").map((resource) => [resource.id, resource]));
  const artwork = new Map(resources.filter((resource) => resource.type === "artworks").map((resource) => [resource.id, resource]));
  return resources.filter((resource) => resource.type === "albums").map((album) => {
    const artistIds = album.relationships?.artists?.data?.map((item) => item.id) ?? [];
    const artistCredits = artistIds.map((id) => ({ id, name: String(artists.get(id)?.attributes?.name ?? "") })).filter((artist) => artist.name);
    const version = typeof album.attributes?.version === "string" && album.attributes.version.trim() ? album.attributes.version.trim() : null;
    return {
      id: album.id,
      title: formatTrackTitle(String(album.attributes?.title ?? "Unknown album"), version),
      version,
      artists: artistCredits.map((artist) => artist.name),
      artistCredits,
      coverUrl: artworkUrl(album, artwork),
      releaseDate: typeof album.attributes?.releaseDate === "string" ? album.attributes.releaseDate : null,
      durationMs: isoDurationToMs(album.attributes?.duration),
      numberOfTracks: Number.isFinite(album.attributes?.numberOfItems) ? Number(album.attributes?.numberOfItems) : null,
      albumType: typeof album.attributes?.albumType === "string" ? album.attributes.albumType : null,
      explicit: album.attributes?.explicit === true,
      mediaTags: Array.isArray(album.attributes?.mediaTags)
        ? album.attributes.mediaTags.filter((tag: unknown): tag is string => typeof tag === "string")
        : [],
    };
  });
}

export function mapArtists(document: { data?: Resource | Resource[]; included?: Resource[] }): ArtistSummary[] {
  const resources = resourcesFrom(document);
  const artwork = new Map(resources.filter((resource) => resource.type === "artworks").map((resource) => [resource.id, resource]));
  return resources.filter((resource) => resource.type === "artists").map((artist) => ({
    id: artist.id,
    name: String(artist.attributes?.name ?? "Unknown artist"),
    pictureUrl: artworkUrl(artist, artwork, "profileArt"),
  }));
}

export function mapPlaylists(document: { data?: Resource | Resource[]; included?: Resource[] }): PlaylistSummary[] {
  const resources = resourcesFrom(document);
  const artwork = new Map(resources.filter((resource) => resource.type === "artworks").map((resource) => [resource.id, resource]));
  return resources.filter((resource) => resource.type === "playlists").map((playlist) => ({
    id: playlist.id,
    name: String(playlist.attributes?.name ?? "Untitled playlist"),
    description: typeof playlist.attributes?.description === "string" ? playlist.attributes.description : null,
    coverUrl: artworkUrl(playlist, artwork),
    durationMs: isoDurationToMs(playlist.attributes?.duration),
    numberOfItems: Number.isFinite(playlist.attributes?.numberOfItems) ? Number(playlist.attributes?.numberOfItems) : null,
    playlistType: typeof playlist.attributes?.playlistType === "string" ? playlist.attributes.playlistType : null,
    createdAt: typeof playlist.attributes?.createdAt === "string" ? playlist.attributes.createdAt : null,
    lastModifiedAt: typeof playlist.attributes?.lastModifiedAt === "string" ? playlist.attributes.lastModifiedAt : null,
  }));
}

type AccessTokenProvider = { getAccessToken(force?: boolean): Promise<string> };

export class BrowseClient {
  private readonly auth: AccessTokenProvider;

  constructor(private readonly config: TidalConfig, auth?: AccessTokenProvider) {
    this.auth = auth ?? new BrowseAuth(config);
  }

  private async get(path: string, params: Record<string, string> = {}, useCountryCode = true): Promise<any> {
    const base = this.config.apiBaseUrl.endsWith("/") ? this.config.apiBaseUrl : `${this.config.apiBaseUrl}/`;
    const url = new URL(path, base);
    if (useCountryCode) url.searchParams.set("countryCode", this.config.countryCode);
    for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
    const request = async (force: boolean) => fetch(url, {
      headers: { Authorization: `Bearer ${await this.auth.getAccessToken(force)}`, Accept: "application/vnd.api+json" },
    });
    let response = await request(false);
    if (response.status === 401) response = await request(true);
    if (!response.ok) throw new Error(`TIDAL catalog request failed (${response.status}): ${await response.text()}`);
    return response.json();
  }

  private async hydrateMissingArtwork(tracks: TrackSummary[]): Promise<TrackSummary[]> {
    const missingAlbumIds = [...new Set(tracks.filter((track) => !track.coverUrl && track.albumId).map((track) => track.albumId!))];
    if (missingAlbumIds.length === 0) return tracks;
    try {
      const albumDocument = await this.get("albums", {
        include: "coverArt,artists",
        "filter[id]": missingAlbumIds.slice(0, 20).join(","),
      });
      const resources = resourcesFrom(albumDocument);
      const albums = new Map(resources.filter((resource) => resource.type === "albums").map((resource) => [resource.id, resource]));
      const artwork = new Map(resources.filter((resource) => resource.type === "artworks").map((resource) => [resource.id, resource]));
      return tracks.map((track) => {
        const album = track.albumId ? albums.get(track.albumId) : undefined;
        const coverId = album?.relationships?.coverArt?.data?.[0]?.id;
        const coverUrl = coverId ? artwork.get(coverId)?.attributes?.files?.[0]?.href : undefined;
        return { ...track, coverUrl: track.coverUrl ?? (typeof coverUrl === "string" ? coverUrl : null) };
      });
    } catch {
      return tracks;
    }
  }

  private async hydrateTracks(tracks: TrackSummary[]): Promise<TrackSummary[]> {
    if (tracks.length === 0) return tracks;
    try {
      const document = await this.get("tracks", {
        include: "albums,artists",
        "filter[id]": tracks.slice(0, 20).map((track) => track.id).join(","),
      });
      const hydrated = new Map((await this.hydrateMissingArtwork(mapTracks(document))).map((track) => [track.id, track]));
      return tracks.map((track) => hydrated.get(track.id) ?? track);
    } catch {
      return this.hydrateMissingArtwork(tracks);
    }
  }

  private async hydrateAlbums(albums: AlbumSummary[]): Promise<AlbumSummary[]> {
    if (albums.length === 0) return albums;
    try {
      const document = await this.get("albums", {
        include: "coverArt,artists",
        "filter[id]": albums.slice(0, 20).map((album) => album.id).join(","),
      });
      const hydrated = new Map(mapAlbums(document).map((album) => [album.id, album]));
      return albums.map((album) => hydrated.get(album.id) ?? album);
    } catch {
      return albums;
    }
  }

  private async hydrateArtists(artists: ArtistSummary[]): Promise<ArtistSummary[]> {
    if (artists.length === 0) return artists;
    try {
      const document = await this.get("artists", {
        include: "profileArt",
        "filter[id]": artists.slice(0, 20).map((artist) => artist.id).join(","),
      });
      const hydrated = new Map(mapArtists(document).map((artist) => [artist.id, artist]));
      return artists.map((artist) => hydrated.get(artist.id) ?? artist);
    } catch {
      return artists;
    }
  }

  private async hydratePlaylists(playlists: PlaylistSummary[]): Promise<PlaylistSummary[]> {
    if (playlists.length === 0) return playlists;
    try {
      const document = await this.get("playlists", {
        include: "coverArt",
        "filter[id]": playlists.slice(0, 20).map((playlist) => playlist.id).join(","),
      });
      const hydrated = new Map(mapPlaylists(document).map((playlist) => [playlist.id, playlist]));
      return playlists.map((playlist) => hydrated.get(playlist.id) ?? playlist);
    } catch {
      return playlists;
    }
  }

  private async userRelationship(path: string, include: string, cursor?: string): Promise<any> {
    return this.get(path, {
      include,
      locale: "en-US",
      "page[limit]": "20",
      ...(cursor ? { "page[cursor]": cursor } : {}),
    }, false);
  }

  async userCollection(userId: string): Promise<UserCollectionPage> {
    const root = `userCollections/${encodeURIComponent(userId)}/relationships`;
    const [tracks, albums, artists, playlists, myMixes, discoveryMixes, newArrivalMixes] = await Promise.allSettled([
      this.userRelationship(`${root}/tracks`, "tracks"),
      this.userRelationship(`${root}/albums`, "albums"),
      this.userRelationship(`${root}/artists`, "artists"),
      this.userRelationship(`${root}/playlists`, "playlists"),
      this.userRelationship("userRecommendations/me/relationships/myMixes", "myMixes"),
      this.userRelationship("userRecommendations/me/relationships/discoveryMixes", "discoveryMixes"),
      this.userRelationship("userRecommendations/me/relationships/newArrivalMixes", "newArrivalMixes"),
    ]);
    const collectionResults = [tracks, albums, artists, playlists];
    if (collectionResults.every((result) => result.status === "rejected")) {
      throw (tracks as PromiseRejectedResult).reason;
    }
    const cursors: Record<string, string> = {};
    const remember = (section: string, result: PromiseSettledResult<any>) => {
      if (result.status !== "fulfilled") return;
      const cursor = cursorFromNextLink(result.value);
      if (cursor) cursors[section] = cursor;
    };
    remember("tracks", tracks); remember("albums", albums); remember("artists", artists); remember("playlists", playlists);
    remember("dailyMixes", myMixes);
    remember("discoveryMixes", discoveryMixes);
    remember("newReleaseMixes", newArrivalMixes);
    const hydrateMixResult = async (result: PromiseSettledResult<any>): Promise<PlaylistSummary[]> =>
      result.status === "fulfilled" ? this.hydratePlaylists(mapPlaylists(result.value)) : [];
    const [dailyMixValues, discoveryMixValues, newReleaseMixValues] = await Promise.all([
      hydrateMixResult(myMixes), hydrateMixResult(discoveryMixes), hydrateMixResult(newArrivalMixes),
    ]);
    const mixValues = [...new Map(
      [...dailyMixValues, ...discoveryMixValues, ...newReleaseMixValues].map((item) => [item.id, item]),
    ).values()];
    return {
      tracks: tracks.status === "fulfilled" ? await this.hydrateTracks(mapTracks(tracks.value)) : [],
      albums: albums.status === "fulfilled" ? deduplicateAlbums(await this.hydrateAlbums(mapAlbums(albums.value))) : [],
      artists: artists.status === "fulfilled" ? await this.hydrateArtists(mapArtists(artists.value)) : [],
      playlists: playlists.status === "fulfilled" ? await this.hydratePlaylists(mapPlaylists(playlists.value)) : [],
      dailyMixes: dailyMixValues,
      discoveryMixes: discoveryMixValues,
      newReleaseMixes: newReleaseMixValues,
      mixes: mixValues,
      cursors,
    };
  }

  async userCollectionMore(userId: string, section: string, cursor: string): Promise<{ section: string; items: unknown[]; cursor?: string }> {
    const recommendationRelationships: Record<string, string> = {
      dailyMixes: "myMixes",
      discoveryMixes: "discoveryMixes",
      newReleaseMixes: "newArrivalMixes",
    };
    const recommendation = recommendationRelationships[section];
    if (!["tracks", "albums", "artists", "playlists"].includes(section) && !recommendation)
      throw new Error(`Cannot paginate collection ${section}`);
    const document = recommendation
      ? await this.userRelationship(`userRecommendations/me/relationships/${recommendation}`, recommendation, cursor)
      : await this.userRelationship(
        `userCollections/${encodeURIComponent(userId)}/relationships/${section}`,
        section,
        cursor,
      );
    const items = section === "tracks" ? await this.hydrateTracks(mapTracks(document))
      : section === "albums" ? deduplicateAlbums(await this.hydrateAlbums(mapAlbums(document)))
      : section === "artists" ? await this.hydrateArtists(mapArtists(document))
      : await this.hydratePlaylists(mapPlaylists(document));
    const next = cursorFromNextLink(document);
    return { section, items, ...(next ? { cursor: next } : {}) };
  }

  private async relationshipTrackPage(
    path: string,
    params: Record<string, string> = {},
    cursor?: string,
  ): Promise<{ tracks: TrackSummary[]; cursor?: string }> {
    const document = await this.get(path, {
      ...params,
      "page[limit]": "20",
      ...(cursor ? { "page[cursor]": cursor } : {}),
    });
    const nextCursor = cursorFromNextLink(document);
    return { tracks: await this.hydrateTracks(mapTracks(document)), ...(nextCursor ? { cursor: nextCursor } : {}) };
  }

  private async relationshipAlbumPage(path: string, cursor?: string): Promise<{ albums: AlbumSummary[]; cursor?: string }> {
    const document = await this.get(path, {
      include: "albums",
      "page[limit]": "20",
      ...(cursor ? { "page[cursor]": cursor } : {}),
    });
    const nextCursor = cursorFromNextLink(document);
    return {
      albums: deduplicateAlbums(await this.hydrateAlbums(mapAlbums(document))),
      ...(nextCursor ? { cursor: nextCursor } : {}),
    };
  }

  private async relationshipTracks(
    trackId: string,
    relationship: "similarTracks" | "radio",
    limit: number,
  ): Promise<TrackSummary[]> {
    const tracks: TrackSummary[] = [];
    const seenIds = new Set<string>();
    const seenCursors = new Set<string>();
    let cursor: string | undefined;
    while (tracks.length < limit) {
      let document: any;
      try {
        document = await this.get(`tracks/${encodeURIComponent(trackId)}/relationships/${relationship}`, {
          include: `${relationship}.albums,${relationship}.artists`,
          "page[limit]": String(Math.min(20, limit - tracks.length)),
          ...(cursor ? { "page[cursor]": cursor } : {}),
        });
      } catch (error) {
        if (tracks.length > 0) break;
        throw error;
      }
      for (const track of mapTracks(document)) {
        if (seenIds.has(track.id)) continue;
        seenIds.add(track.id);
        tracks.push(track);
      }
      const nextCursor = cursorFromNextLink(document);
      if (!nextCursor || seenCursors.has(nextCursor)) break;
      seenCursors.add(nextCursor);
      cursor = nextCursor;
    }
    return tracks;
  }

  async searchTracks(query: string, limit = 30): Promise<TrackSummary[]> {
    const document = await this.get(`searchResults/${encodeURIComponent(query)}/relationships/tracks`, {
      include: "tracks.albums,tracks.artists",
      collapseBy: "FINGERPRINT",
      "page[limit]": String(Math.max(1, Math.min(limit, 20))),
    });
    return deduplicateTracks(await this.hydrateMissingArtwork(mapTracks(document)));
  }

  async searchCatalog(query: string, limit = 20, cursors: CatalogSearchCursors = {}): Promise<CatalogSearchPage> {
    const pageLimit = String(Math.max(1, Math.min(limit, 20)));
    const encoded = encodeURIComponent(query);
    const continuation = Object.keys(cursors).length > 0;
    const [tracksResult, albumsResult, artistsResult] = await Promise.allSettled([
      continuation && !cursors.tracks ? Promise.resolve(null) : this.get(`searchResults/${encoded}/relationships/tracks`, {
        include: "tracks.albums,tracks.artists", collapseBy: "FINGERPRINT", "page[limit]": pageLimit,
        ...(cursors.tracks ? { "page[cursor]": cursors.tracks } : {}),
      }),
      continuation && !cursors.albums ? Promise.resolve(null) : this.get(`searchResults/${encoded}/relationships/albums`, {
        include: "albums", "page[limit]": pageLimit,
        ...(cursors.albums ? { "page[cursor]": cursors.albums } : {}),
      }),
      continuation && !cursors.artists ? Promise.resolve(null) : this.get(`searchResults/${encoded}/relationships/artists`, {
        include: "artists", "page[limit]": pageLimit,
        ...(cursors.artists ? { "page[cursor]": cursors.artists } : {}),
      }),
    ]);
    if (tracksResult.status === "rejected" && albumsResult.status === "rejected" && artistsResult.status === "rejected") throw tracksResult.reason;
    return {
      tracks: tracksResult.status === "fulfilled" && tracksResult.value
        ? deduplicateTracks(await this.hydrateMissingArtwork(mapTracks(tracksResult.value))) : [],
      albums: albumsResult.status === "fulfilled" && albumsResult.value
        ? deduplicateAlbums(await this.hydrateAlbums(mapAlbums(albumsResult.value))) : [],
      artists: artistsResult.status === "fulfilled" && artistsResult.value
        ? await this.hydrateArtists(mapArtists(artistsResult.value)) : [],
      cursors: {
        ...(tracksResult.status === "fulfilled" && tracksResult.value && cursorFromNextLink(tracksResult.value)
          ? { tracks: cursorFromNextLink(tracksResult.value)! } : {}),
        ...(albumsResult.status === "fulfilled" && albumsResult.value && cursorFromNextLink(albumsResult.value)
          ? { albums: cursorFromNextLink(albumsResult.value)! } : {}),
        ...(artistsResult.status === "fulfilled" && artistsResult.value && cursorFromNextLink(artistsResult.value)
          ? { artists: cursorFromNextLink(artistsResult.value)! } : {}),
      },
    };
  }

  async trackPage(trackId: string): Promise<TrackPage> {
    const document = await this.get(`tracks/${encodeURIComponent(trackId)}`, { include: "albums,artists" });
    const track = (await this.hydrateMissingArtwork(mapTracks(document)))[0];
    if (!track) throw new Error("TIDAL did not return that track");
    return { kind: "track", track, relatedTracks: await this.relatedTracks(trackId, 20).catch(() => []) };
  }

  async trackLyrics(trackId: string): Promise<{ plain: string | null; synced: string | null }> {
    const document = await this.get(`tracks/${encodeURIComponent(trackId)}/relationships/lyrics`, {
      include: "lyrics",
    });
    const lyrics = resourcesFrom(document).find((resource) => resource.type === "lyrics");
    const attributes = lyrics?.attributes ?? {};
    const firstText = (names: string[]): string | null => {
      for (const name of names) {
        const value = attributes[name];
        if (typeof value === "string" && value.trim()) return value.trim();
      }
      return null;
    };
    return {
      plain: firstText(["text", "lyrics", "body", "content"]),
      synced: firstText(["subtitles", "syncLyrics", "lrc", "lrcText"]),
    };
  }

  async albumPage(albumId: string): Promise<AlbumPage> {
    const encoded = encodeURIComponent(albumId);
    const [albumDocument, trackPage] = await Promise.all([
      this.get(`albums/${encoded}`, { include: "artists,coverArt" }),
      this.relationshipTrackPage(`albums/${encoded}/relationships/items`, { include: "items" })
        .catch((): { tracks: TrackSummary[]; cursor?: string } => ({ tracks: [] })),
    ]);
    const album = mapAlbums(albumDocument)[0];
    if (!album) throw new Error("TIDAL did not return that album");
    return { kind: "album", album, tracks: trackPage.tracks, ...(trackPage.cursor ? { trackCursor: trackPage.cursor } : {}) };
  }

  async playlistPage(playlistId: string): Promise<PlaylistPage> {
    const encoded = encodeURIComponent(playlistId);
    const [playlistDocument, trackPage] = await Promise.all([
      this.get(`playlists/${encoded}`, { include: "coverArt" }),
      this.relationshipTrackPage(`playlists/${encoded}/relationships/items`, { include: "items" })
        .catch((): { tracks: TrackSummary[]; cursor?: string } => ({ tracks: [] })),
    ]);
    const playlist = mapPlaylists(playlistDocument)[0];
    if (!playlist) throw new Error("TIDAL did not return that playlist");
    return { kind: "playlist", playlist, tracks: trackPage.tracks, ...(trackPage.cursor ? { trackCursor: trackPage.cursor } : {}) };
  }

  async artistPage(artistId: string): Promise<ArtistPage> {
    const encoded = encodeURIComponent(artistId);
    const [artistResult, tracksResult, albumsResult] = await Promise.allSettled([
      this.get(`artists/${encoded}`, { include: "profileArt" }),
      this.relationshipTrackPage(`artists/${encoded}/relationships/tracks`, { include: "tracks", collapseBy: "FINGERPRINT" }),
      this.relationshipAlbumPage(`artists/${encoded}/relationships/albums`),
    ]);
    if (artistResult.status === "rejected") throw artistResult.reason;
    const artist = mapArtists(artistResult.value)[0];
    if (!artist) throw new Error("TIDAL did not return that artist");
    return {
      kind: "artist",
      artist,
      topTracks: tracksResult.status === "fulfilled" ? tracksResult.value.tracks : [],
      albums: albumsResult.status === "fulfilled" ? albumsResult.value.albums : [],
      ...(tracksResult.status === "fulfilled" && tracksResult.value.cursor ? { trackCursor: tracksResult.value.cursor } : {}),
      ...(albumsResult.status === "fulfilled" && albumsResult.value.cursor ? { albumCursor: albumsResult.value.cursor } : {}),
    };
  }

  async catalogMore(kind: string, resourceId: string, section: string, cursor: string): Promise<CatalogMore> {
    const encoded = encodeURIComponent(resourceId);
    if (kind === "album" && section === "tracks") {
      const page = await this.relationshipTrackPage(`albums/${encoded}/relationships/items`, { include: "items" }, cursor);
      return { section: "tracks", tracks: page.tracks, ...(page.cursor ? { cursor: page.cursor } : {}) };
    }
    if (kind === "playlist" && section === "tracks") {
      const page = await this.relationshipTrackPage(`playlists/${encoded}/relationships/items`, { include: "items" }, cursor);
      return { section: "tracks", tracks: page.tracks, ...(page.cursor ? { cursor: page.cursor } : {}) };
    }
    if (kind === "artist" && section === "tracks") {
      const page = await this.relationshipTrackPage(
        `artists/${encoded}/relationships/tracks`,
        { include: "tracks", collapseBy: "FINGERPRINT" },
        cursor,
      );
      return { section: "tracks", tracks: page.tracks, ...(page.cursor ? { cursor: page.cursor } : {}) };
    }
    if (kind === "artist" && section === "albums") {
      const page = await this.relationshipAlbumPage(`artists/${encoded}/relationships/albums`, cursor);
      return { section: "albums", albums: page.albums, ...(page.cursor ? { cursor: page.cursor } : {}) };
    }
    throw new Error(`Cannot paginate ${kind} ${section}`);
  }

  async allAlbumTracks(albumId: string, limit = 500): Promise<TrackSummary[]> {
    const path = `albums/${encodeURIComponent(albumId)}/relationships/items`;
    const tracks: TrackSummary[] = [];
    const seenIds = new Set<string>();
    const seenCursors = new Set<string>();
    let cursor: string | undefined;
    while (tracks.length < limit) {
      const page = await this.relationshipTrackPage(path, { include: "items" }, cursor);
      for (const track of page.tracks) {
        if (!seenIds.has(track.id)) {
          seenIds.add(track.id);
          tracks.push(track);
        }
      }
      if (!page.cursor || seenCursors.has(page.cursor)) break;
      seenCursors.add(page.cursor);
      cursor = page.cursor;
    }
    return tracks;
  }

  async relatedTracks(trackId: string, limit = 20): Promise<TrackSummary[]> {
    const normalizedLimit = Math.max(1, Math.min(limit, 100));
    const relationshipLimit = Math.ceil(normalizedLimit / 2);
    const [similarResult, radioResult] = await Promise.allSettled([
      this.relationshipTracks(trackId, "similarTracks", relationshipLimit),
      this.relationshipTracks(trackId, "radio", relationshipLimit),
    ]);
    if (similarResult.status === "rejected" && radioResult.status === "rejected") {
      throw similarResult.reason;
    }
    const similar = similarResult.status === "fulfilled" ? similarResult.value : [];
    const radio = radioResult.status === "fulfilled" ? radioResult.value : [];
    return this.hydrateMissingArtwork(mergeRelatedTracks(similar, radio, normalizedLimit));
  }
}
