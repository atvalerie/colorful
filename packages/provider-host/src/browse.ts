import { BrowseAuth } from "./auth";
import type { TidalConfig } from "./config";

export type TrackSummary = {
  id: string;
  title: string;
  version: string | null;
  artists: string[];
  albumId: string | null;
  albumTitle: string | null;
  durationMs: number | null;
  isrc: string | null;
  coverUrl: string | null;
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
    return {
      id: track.id,
      title: formatTrackTitle(String(track.attributes?.title ?? "Unknown title"), version),
      version,
      artists: artistIds.map((id) => String(artists.get(id)?.attributes?.name ?? "")).filter(Boolean),
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

  async searchTracks(query: string, limit = 30): Promise<TrackSummary[]> {
    const document = await this.get(`searchResults/${encodeURIComponent(query)}/relationships/tracks`, {
      include: "tracks.albums,tracks.artists",
      "page[limit]": String(Math.max(1, Math.min(limit, 50))),
    });
    return this.hydrateMissingArtwork(mapTracks(document));
  }

  async relatedTracks(trackId: string, limit = 20): Promise<TrackSummary[]> {
    const document = await this.get(`tracks/${encodeURIComponent(trackId)}/relationships/similarTracks`, {
      include: "similarTracks.albums,similarTracks.artists",
      "page[limit]": String(Math.max(1, Math.min(limit, 50))),
    });
    return this.hydrateMissingArtwork(mapTracks(document));
  }
}
