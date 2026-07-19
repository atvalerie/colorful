import { BrowseAuth } from "./auth";
import type { TidalConfig } from "./config";

export type TrackSummary = {
  id: string;
  title: string;
  version: string | null;
  artists: string[];
  artistCredits: ArtistCredit[];
  albumId: string | null;
  albumTitle: string | null;
  durationMs: number | null;
  isrc: string | null;
  coverUrl: string | null;
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
};

export type CatalogSearch = { tracks: TrackSummary[]; albums: AlbumSummary[]; artists: ArtistSummary[] };
export type TrackPage = { kind: "track"; track: TrackSummary; relatedTracks: TrackSummary[] };
export type AlbumPage = { kind: "album"; album: AlbumSummary; tracks: TrackSummary[]; trackCursor?: string };
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

export function cursorFromNextLink(document: { links?: { next?: unknown } }): string | undefined {
  if (typeof document.links?.next !== "string" || !document.links.next) return undefined;
  try {
    return new URL(document.links.next).searchParams.get("page[cursor]") ?? undefined;
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

export class BrowseClient {
  private readonly auth: BrowseAuth;

  constructor(private readonly config: TidalConfig, auth?: BrowseAuth) {
    this.auth = auth ?? new BrowseAuth(config);
  }

  private async get(path: string, params: Record<string, string> = {}): Promise<any> {
    const base = this.config.apiBaseUrl.endsWith("/") ? this.config.apiBaseUrl : `${this.config.apiBaseUrl}/`;
    const url = new URL(path, base);
    url.searchParams.set("countryCode", this.config.countryCode);
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
      "page[limit]": String(Math.max(1, Math.min(limit, 20))),
    });
    return this.hydrateMissingArtwork(mapTracks(document));
  }

  async searchCatalog(query: string, limit = 20): Promise<CatalogSearch> {
    const pageLimit = String(Math.max(1, Math.min(limit, 20)));
    const encoded = encodeURIComponent(query);
    const [tracksResult, albumsResult, artistsResult] = await Promise.allSettled([
      this.searchTracks(query, limit),
      this.get(`searchResults/${encoded}/relationships/albums`, { include: "albums", "page[limit]": pageLimit }),
      this.get(`searchResults/${encoded}/relationships/artists`, { include: "artists", "page[limit]": pageLimit }),
    ]);
    if (tracksResult.status === "rejected" && albumsResult.status === "rejected" && artistsResult.status === "rejected") throw tracksResult.reason;
    return {
      tracks: tracksResult.status === "fulfilled" ? tracksResult.value : [],
      albums: albumsResult.status === "fulfilled" ? deduplicateAlbums(await this.hydrateAlbums(mapAlbums(albumsResult.value))) : [],
      artists: artistsResult.status === "fulfilled" ? await this.hydrateArtists(mapArtists(artistsResult.value)) : [],
    };
  }

  async trackPage(trackId: string): Promise<TrackPage> {
    const document = await this.get(`tracks/${encodeURIComponent(trackId)}`, { include: "albums,artists" });
    const track = (await this.hydrateMissingArtwork(mapTracks(document)))[0];
    if (!track) throw new Error("TIDAL did not return that track");
    return { kind: "track", track, relatedTracks: await this.relatedTracks(trackId, 20).catch(() => []) };
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
