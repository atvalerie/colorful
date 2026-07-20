import type { AlbumPage, AlbumSummary, ArtistCredit, ArtistPage, ArtistSummary, CatalogSearch, TrackSummary } from "./browse";

type JsonObject = Record<string, unknown>;
type Run = { text?: unknown; navigationEndpoint?: unknown };

const MUSIC_ORIGIN = "https://music.youtube.com";
const SEARCH_FILTERS = {
  songs: "EgWKAQIIAWoMEA4QChADEAQQCRAF",
  videos: "EgWKAQIQAWoMEA4QChADEAQQCRAF",
  albums: "EgWKAQIYAWoMEA4QChADEAQQCRAF",
  artists: "EgWKAQIgAWoMEA4QChADEAQQCRAF",
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

async function youtubei(endpoint: "search" | "browse" | "next", body: JsonObject): Promise<JsonObject> {
  const response = await fetch(`${MUSIC_ORIGIN}/youtubei/v1/${endpoint}?alt=json`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Origin": MUSIC_ORIGIN,
      "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/140 Safari/537.36",
      "X-Origin": MUSIC_ORIGIN,
    },
    body: JSON.stringify({
      context: { client: { clientName: "WEB_REMIX", clientVersion: clientVersion(), hl: "en", gl: "US" }, user: {} },
      ...body,
    }),
  });
  if (!response.ok) throw new Error(`YouTube Music returned HTTP ${response.status}`);
  return object(await response.json());
}

function responsiveItems(document: JsonObject): JsonObject[] {
  return children(document, "musicResponsiveListItemRenderer");
}

export async function searchYouTubeMusicCatalog(query: string): Promise<CatalogSearch> {
  const [songDocument, videoDocument, albumDocument, artistDocument] = await Promise.all([
    youtubei("search", { query, params: SEARCH_FILTERS.songs }),
    youtubei("search", { query, params: SEARCH_FILTERS.videos }),
    youtubei("search", { query, params: SEARCH_FILTERS.albums }),
    youtubei("search", { query, params: SEARCH_FILTERS.artists }),
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

export async function youtubeMusicAutomix(video: string, limit = 20): Promise<TrackSummary[]> {
  const document = await youtubei("next", {
    videoId: video,
    playlistId: `RDAMVM${video}`,
    enablePersistentPlaylistPanel: true,
  });
  const tracks = children(document, "playlistPanelVideoRenderer")
    .map(mapPlaylistTrack).filter((track): track is TrackSummary => track !== null && track.id !== video);
  return [...new Map(tracks.map((track) => [track.id, track])).values()].slice(0, Math.max(1, limit));
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
  for (const shelf of children(document, "musicShelfRenderer")) {
    for (const renderer of responsiveItems(shelf)) {
      const track = mapTrack(renderer);
      if (track) topTracks.push(track);
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
