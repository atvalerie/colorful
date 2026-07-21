import type { AlbumSummary, ArtistSummary, PlaylistSummary, TrackSummary, UserCollectionPage } from "./browse";

const WEB_ORIGIN = "https://soundcloud.com";
const API_ORIGIN = "https://api-v2.soundcloud.com";
const DISCOVERY_TTL_MS = 6 * 60 * 60 * 1000;

type SoundCloudUser = {
  id?: unknown;
  username?: unknown;
  avatar_url?: unknown;
  permalink_url?: unknown;
};

type SoundCloudTranscoding = {
  url?: unknown;
  preset?: unknown;
  quality?: unknown;
  format?: { protocol?: unknown; mime_type?: unknown };
};

type SoundCloudTrack = {
  id?: unknown;
  kind?: unknown;
  title?: unknown;
  artwork_url?: unknown;
  duration?: unknown;
  full_duration?: unknown;
  permalink_url?: unknown;
  streamable?: unknown;
  track_authorization?: unknown;
  publisher_metadata?: { album_title?: unknown; isrc?: unknown; explicit?: unknown };
  media?: { transcodings?: unknown };
  user?: SoundCloudUser;
};

type SoundCloudPlaylist = {
  id?: unknown;
  kind?: unknown;
  title?: unknown;
  artwork_url?: unknown;
  duration?: unknown;
  track_count?: unknown;
  is_album?: unknown;
  set_type?: unknown;
  created_at?: unknown;
  last_modified?: unknown;
  release_date?: unknown;
  tracks?: unknown;
  user?: SoundCloudUser;
};

type SoundCloudCollection = {
  collection?: unknown;
  next_href?: unknown;
};

export type SoundCloudBootstrap = {
  clientId: string;
  appVersion?: string;
};

let bootstrapCache: (SoundCloudBootstrap & { discoveredAt: number }) | null = null;
let accessToken = "";
const anonymousUserId = Array.from({ length: 4 }, () => Math.floor(100000 + Math.random() * 900000)).join("-");

function string(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function identifier(value: unknown): string {
  return typeof value === "string" || typeof value === "number" ? String(value).trim() : "";
}

function number(value: unknown): number | null {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function artwork(url: unknown): string | null {
  const source = string(url);
  if (!source) return null;
  return source.replace(/-(?:large|t\d+x\d+|original|crop)\.(jpg|jpeg|png|webp)(?=$|\?)/i, "-t500x500.$1");
}

function userArtist(user: SoundCloudUser | undefined): ArtistSummary | null {
  const id = identifier(user?.id);
  const name = string(user?.username);
  if (!id || !name) return null;
  return { provider: "soundcloud" as any, id, name, pictureUrl: artwork(user?.avatar_url) } as ArtistSummary;
}

export function mapSoundCloudTrack(raw: SoundCloudTrack): TrackSummary | null {
  const id = identifier(raw.id);
  const title = string(raw.title);
  if (!id || !title) return null;
  const artist = userArtist(raw.user);
  const artistName = artist?.name ?? "SoundCloud";
  const artistId = artist?.id ?? "";
  return {
    provider: "soundcloud" as any,
    id,
    title,
    version: null,
    artists: [artistName],
    artistCredits: artistId ? [{ id: artistId, name: artistName }] : [],
    uploader: { id: artistId || null, name: artistName },
    albumId: null,
    albumTitle: string(raw.publisher_metadata?.album_title) || null,
    durationMs: number(raw.full_duration) ?? number(raw.duration),
    isrc: string(raw.publisher_metadata?.isrc) || null,
    coverUrl: artwork(raw.artwork_url ?? raw.user?.avatar_url),
    explicit: raw.publisher_metadata?.explicit === true,
  } as TrackSummary;
}

export function mapSoundCloudPlaylist(raw: SoundCloudPlaylist): AlbumSummary | null {
  const id = identifier(raw.id);
  const title = string(raw.title);
  if (!id || !title) return null;
  const artist = userArtist(raw.user);
  const artistName = artist?.name ?? "SoundCloud";
  const artistId = artist?.id ?? "";
  return {
    provider: "soundcloud" as any,
    id,
    title,
    version: null,
    artists: [artistName],
    artistCredits: artistId ? [{ id: artistId, name: artistName }] : [],
    coverUrl: artwork(raw.artwork_url ?? raw.user?.avatar_url),
    releaseDate: string(raw.release_date) || string(raw.created_at) || null,
    durationMs: number(raw.duration),
    numberOfTracks: number(raw.track_count) ?? array(raw.tracks).length,
    albumType: raw.is_album === true ? "ALBUM" : "PLAYLIST",
    explicit: false,
    mediaTags: [],
  } as AlbumSummary;
}

export function mapSoundCloudArtist(raw: SoundCloudUser): ArtistSummary | null {
  return userArtist(raw);
}

function hydrationArray(html: string): unknown[] {
  const marker = "window.__sc_hydration";
  const markerIndex = html.indexOf(marker);
  if (markerIndex < 0) throw new Error("SoundCloud homepage did not contain hydration data");
  const start = html.indexOf("[", markerIndex + marker.length);
  if (start < 0) throw new Error("SoundCloud hydration data is malformed");
  let depth = 0;
  let quoted = false;
  let escaped = false;
  for (let index = start; index < html.length; index += 1) {
    const character = html[index];
    if (quoted) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === '"') quoted = false;
      continue;
    }
    if (character === '"') quoted = true;
    else if (character === "[") depth += 1;
    else if (character === "]" && --depth === 0) return JSON.parse(html.slice(start, index + 1)) as unknown[];
  }
  throw new Error("SoundCloud hydration data is incomplete");
}

export function parseSoundCloudBootstrap(html: string): SoundCloudBootstrap {
  const hydration = hydrationArray(html);
  const entry = hydration.find((value) => value && typeof value === "object"
    && (value as { hydratable?: unknown }).hydratable === "apiClient") as { data?: { id?: unknown } } | undefined;
  const clientId = string(entry?.data?.id);
  if (!clientId) throw new Error("SoundCloud homepage did not expose a public API client ID");
  const appVersionMatch = html.match(/\\?"appVersion\\?"\s*:\s*\\?"(\d+)\\?"/);
  return { clientId, ...(appVersionMatch?.[1] ? { appVersion: appVersionMatch[1] } : {}) };
}

export function parseSoundCloudAuthorization(input: string): string {
  const matches = [...input.matchAll(/(?:^|\s)(?:-H|--header)\s+(?:'([^']*)'|"((?:\\.|[^"])*)")/g)]
    .map((match) => (match[1] ?? match[2] ?? "").replace(/\\"/g, '"'));
  const rawLines = input.split(/\r?\n/).map((line) => line.trim());
  const authorization = [...matches, ...rawLines]
    .find((header) => /^authorization\s*:/i.test(header));
  const value = authorization?.replace(/^authorization\s*:\s*/i, "").trim() ?? "";
  const token = value.replace(/^oauth\s+/i, "").trim();
  if (!token || /[\r\n]/.test(token)) throw new Error("The pasted request does not contain an Authorization: OAuth header");
  return token;
}

export function setSoundCloudAccessToken(token: string | null): void {
  accessToken = token?.trim() ?? "";
}

export function soundCloudLinked(): boolean {
  return Boolean(accessToken);
}

async function discover(force = false): Promise<SoundCloudBootstrap> {
  if (!force && bootstrapCache && Date.now() - bootstrapCache.discoveredAt < DISCOVERY_TTL_MS) return bootstrapCache;
  const response = await fetch(WEB_ORIGIN, { headers: { accept: "text/html" } });
  if (!response.ok) throw new Error(`SoundCloud discovery returned HTTP ${response.status}`);
  const bootstrap = parseSoundCloudBootstrap(await response.text());
  bootstrapCache = { ...bootstrap, discoveredAt: Date.now() };
  return bootstrap;
}

function apiUrl(pathOrUrl: string, bootstrap: SoundCloudBootstrap, query: Record<string, unknown> = {}): URL {
  const url = /^https?:\/\//.test(pathOrUrl) ? new URL(pathOrUrl) : new URL(pathOrUrl.replace(/^\//, ""), `${API_ORIGIN}/`);
  url.searchParams.set("client_id", bootstrap.clientId);
  if (bootstrap.appVersion) url.searchParams.set("app_version", bootstrap.appVersion);
  url.searchParams.set("app_locale", "en");
  for (const [key, value] of Object.entries(query)) {
    if (value !== undefined && value !== null && value !== "") url.searchParams.set(key, String(value));
  }
  return url;
}

async function api<T>(pathOrUrl: string, query: Record<string, unknown> = {}, retry = true): Promise<T> {
  const bootstrap = await discover();
  const response = await fetch(apiUrl(pathOrUrl, bootstrap, query), { headers: {
    accept: "application/json",
    ...(accessToken ? { authorization: `OAuth ${accessToken}` } : {}),
  } });
  if (response.status === 401 && accessToken) throw new Error("The stored SoundCloud session has expired; reconnect it in Settings");
  if ((response.status === 401 || response.status === 403) && retry) {
    await discover(true);
    return api<T>(pathOrUrl, query, false);
  }
  if (!response.ok) {
    const detail = (await response.text().catch(() => "")).slice(0, 240);
    throw new Error(`SoundCloud returned HTTP ${response.status}${detail ? `: ${detail}` : ""}`);
  }
  return response.json() as Promise<T>;
}

function trackFromActivity(value: unknown): SoundCloudTrack | null {
  const item = value && typeof value === "object" ? value as Record<string, unknown> : {};
  if (item.kind === "track") return item as SoundCloudTrack;
  return item.track && typeof item.track === "object" ? item.track as SoundCloudTrack : null;
}

function playlistFromActivity(value: unknown): SoundCloudPlaylist | null {
  const item = value && typeof value === "object" ? value as Record<string, unknown> : {};
  if (item.kind === "playlist") return item as SoundCloudPlaylist;
  return item.playlist && typeof item.playlist === "object" ? item.playlist as SoundCloudPlaylist : null;
}

export async function soundCloudAccount(): Promise<Record<string, unknown>> {
  if (!accessToken) throw new Error("Connect your SoundCloud account first");
  const user = await api<SoundCloudUser & Record<string, unknown>>("me");
  const artist = mapSoundCloudArtist(user);
  if (!artist) throw new Error("SoundCloud did not return an account profile");
  return {
    id: artist.id,
    username: artist.name,
    avatarUrl: artist.pictureUrl,
    permalinkUrl: string(user.permalink_url),
  };
}

export async function soundCloudCollection(): Promise<UserCollectionPage> {
  if (!accessToken) throw new Error("Connect your SoundCloud account first");
  const [trackResult, playlistResult, ownPlaylistResult, followingResult] = await Promise.allSettled([
    api<SoundCloudCollection>("me/likes/tracks", { limit: 50, offset: 0, linked_partitioning: 1 }),
    api<SoundCloudCollection>("me/likes/playlists", { limit: 50, offset: 0, linked_partitioning: 1 }),
    api<SoundCloudCollection>("me/playlists", { limit: 50, offset: 0, linked_partitioning: 1, show_tracks: false }),
    api<SoundCloudCollection>("me/followings", { limit: 50, offset: 0, linked_partitioning: 1 }),
  ]);
  if (trackResult.status === "rejected" && playlistResult.status === "rejected"
      && ownPlaylistResult.status === "rejected" && followingResult.status === "rejected") {
    throw trackResult.reason;
  }
  const trackPage = trackResult.status === "fulfilled" ? trackResult.value : {};
  const playlistPage = playlistResult.status === "fulfilled" ? playlistResult.value : {};
  const ownPlaylistPage = ownPlaylistResult.status === "fulfilled" ? ownPlaylistResult.value : {};
  const followingPage = followingResult.status === "fulfilled" ? followingResult.value : {};
  const tracks = array(trackPage.collection).map(trackFromActivity).filter((value): value is SoundCloudTrack => Boolean(value))
    .map(mapSoundCloudTrack).filter((value): value is TrackSummary => Boolean(value));
  const albums = [...new Map([...array(playlistPage.collection), ...array(ownPlaylistPage.collection)]
    .map(playlistFromActivity).filter((value): value is SoundCloudPlaylist => Boolean(value))
    .map(mapSoundCloudPlaylist).filter((value): value is AlbumSummary => Boolean(value))
    .map((album) => [album.id, album])).values()];
  const artists = array(followingPage.collection).map((value) => mapSoundCloudArtist(value as SoundCloudUser))
    .filter((value): value is ArtistSummary => Boolean(value));
  return {
    tracks,
    albums,
    artists,
    playlists: albums.map((album): PlaylistSummary => ({
      id: album.id,
      name: album.title,
      description: null,
      coverUrl: album.coverUrl,
      durationMs: album.durationMs,
      numberOfItems: album.numberOfTracks,
      playlistType: album.albumType,
      createdAt: album.releaseDate,
      lastModifiedAt: null,
    })),
    mixes: [],
    cursors: {
      ...(nextCursor(trackPage) ? { tracks: nextCursor(trackPage)! } : {}),
      ...(nextCursor(playlistPage) ? { playlists: nextCursor(playlistPage)! } : {}),
      ...(nextCursor(followingPage) ? { artists: nextCursor(followingPage)! } : {}),
    },
  };
}

function nextCursor(document: SoundCloudCollection): string | undefined {
  const href = string(document.next_href);
  return href || undefined;
}

async function hydratedTracks(values: unknown[]): Promise<TrackSummary[]> {
  const embedded = values.filter((value): value is SoundCloudTrack => Boolean(value) && typeof value === "object");
  const ids = embedded.map((track) => identifier(track.id)).filter(Boolean);
  if (!ids.length) return [];
  const chunks: string[][] = [];
  for (let index = 0; index < ids.length; index += 50) chunks.push(ids.slice(index, index + 50));
  const fetched = await Promise.all(chunks.map((chunk) => api<unknown[]>("tracks", { ids: chunk.join(",") })))
    .then((pages) => pages.flat()).catch(() => embedded);
  const byId = new Map(fetched.map((value) => [identifier((value as SoundCloudTrack).id), value as SoundCloudTrack]));
  return ids.map((id, index) => byId.get(id) ?? embedded[index])
    .map((value) => value ? mapSoundCloudTrack(value) : null)
    .filter((value): value is TrackSummary => Boolean(value));
}

export async function soundCloudSearch(query: string, limit = 20): Promise<{
  tracks: TrackSummary[]; albums: AlbumSummary[]; artists: ArtistSummary[]; cursor?: string;
}> {
  const response = await api<SoundCloudCollection>("search", {
    q: query, facet: "model", limit, offset: 0, linked_partitioning: 1, user_id: anonymousUserId,
  });
  const values = array(response.collection);
  const cursor = nextCursor(response);
  return {
    tracks: values.filter((value) => (value as SoundCloudTrack)?.kind === "track")
      .map((value) => mapSoundCloudTrack(value as SoundCloudTrack)).filter((value): value is TrackSummary => Boolean(value)),
    albums: values.filter((value) => (value as SoundCloudPlaylist)?.kind === "playlist")
      .map((value) => mapSoundCloudPlaylist(value as SoundCloudPlaylist)).filter((value): value is AlbumSummary => Boolean(value)),
    artists: values.filter((value) => (value as SoundCloudUser & { kind?: unknown })?.kind === "user")
      .map((value) => mapSoundCloudArtist(value as SoundCloudUser)).filter((value): value is ArtistSummary => Boolean(value)),
    ...(cursor ? { cursor } : {}),
  };
}

export async function soundCloudSearchMore(cursor: string): Promise<{
  tracks: TrackSummary[]; albums: AlbumSummary[]; artists: ArtistSummary[]; cursor?: string;
}> {
  const response = await api<SoundCloudCollection>(cursor);
  const values = array(response.collection);
  const next = nextCursor(response);
  return {
    tracks: values.map(trackFromActivity).filter((value): value is SoundCloudTrack => Boolean(value))
      .map(mapSoundCloudTrack).filter((value): value is TrackSummary => Boolean(value)),
    albums: values.map(playlistFromActivity).filter((value): value is SoundCloudPlaylist => Boolean(value))
      .map(mapSoundCloudPlaylist).filter((value): value is AlbumSummary => Boolean(value)),
    artists: values.filter((value) => (value as SoundCloudUser & { kind?: unknown })?.kind === "user")
      .map((value) => mapSoundCloudArtist(value as SoundCloudUser)).filter((value): value is ArtistSummary => Boolean(value)),
    ...(next ? { cursor: next } : {}),
  };
}

export async function soundCloudTrackPage(id: string) {
  const track = mapSoundCloudTrack(await api<SoundCloudTrack>(`tracks/${id}`));
  if (!track) throw new Error("SoundCloud track could not be resolved");
  const related = await soundCloudRelated(id, 20).catch(() => []);
  return { kind: "track" as const, provider: "soundcloud" as const, track, relatedTracks: related };
}

export async function soundCloudPlaylistPage(id: string) {
  const raw = await api<SoundCloudPlaylist>(`playlists/${id}`, { representation: "full" });
  const album = mapSoundCloudPlaylist(raw);
  if (!album) throw new Error("SoundCloud playlist could not be resolved");
  return { kind: "album" as const, provider: "soundcloud" as const, album,
    tracks: await hydratedTracks(array(raw.tracks)) };
}

export async function soundCloudArtistPage(id: string) {
  const [rawArtist, rawTracks, rawPlaylists] = await Promise.all([
    api<SoundCloudUser>(`users/${id}`),
    api<SoundCloudCollection>(`users/${id}/tracks`, { limit: 20, offset: 0, linked_partitioning: 1 }),
    api<SoundCloudCollection>(`users/${id}/playlists_without_albums`, { limit: 20, offset: 0, linked_partitioning: 1 }),
  ]);
  const artist = mapSoundCloudArtist(rawArtist);
  if (!artist) throw new Error("SoundCloud profile could not be resolved");
  return {
    kind: "artist" as const,
    provider: "soundcloud" as const,
    artist,
    topTracks: array(rawTracks.collection).map((value) => mapSoundCloudTrack(value as SoundCloudTrack)).filter((value): value is TrackSummary => Boolean(value)),
    albums: array(rawPlaylists.collection).map((value) => mapSoundCloudPlaylist(value as SoundCloudPlaylist)).filter((value): value is AlbumSummary => Boolean(value)),
    trackCursor: nextCursor(rawTracks),
    albumCursor: nextCursor(rawPlaylists),
  };
}

export async function soundCloudMore(section: string, cursor: string) {
  const response = await api<SoundCloudCollection>(cursor);
  if (section === "albums") return { section, albums: array(response.collection)
    .map((value) => mapSoundCloudPlaylist(value as SoundCloudPlaylist)).filter((value): value is AlbumSummary => Boolean(value)), cursor: nextCursor(response) };
  return { section: "tracks", tracks: array(response.collection)
    .map((value) => mapSoundCloudTrack(value as SoundCloudTrack)).filter((value): value is TrackSummary => Boolean(value)), cursor: nextCursor(response) };
}

export async function soundCloudRelated(id: string, limit = 20): Promise<TrackSummary[]> {
  const response = await api<SoundCloudCollection>(`tracks/${id}/related`, {
    limit: Math.max(1, Math.min(50, Math.floor(limit))), offset: 0, linked_partitioning: 1, user_id: anonymousUserId,
  });
  return array(response.collection).map((value) => mapSoundCloudTrack(value as SoundCloudTrack))
    .filter((value): value is TrackSummary => Boolean(value));
}

export async function soundCloudSource(id: string): Promise<Record<string, unknown>> {
  const track = await api<SoundCloudTrack>(`tracks/${id}`);
  if (track.streamable === false) throw new Error("This SoundCloud track is not streamable");
  const transcodings = array(track.media?.transcodings).filter((value): value is SoundCloudTranscoding => Boolean(value) && typeof value === "object");
  const score = (transcoding: SoundCloudTranscoding) => {
    const protocol = string(transcoding.format?.protocol);
    const mime = string(transcoding.format?.mime_type);
    const preset = string(transcoding.preset);
    return (protocol === "progressive" ? 100 : protocol === "hls" ? 50 : 0)
      + (mime.includes("opus") ? 20 : mime.includes("mpeg") ? 15 : 0)
      + (preset.includes("hq") ? 10 : 0);
  };
  const selected = transcodings.filter((value) => string(value.url)).sort((left, right) => score(right) - score(left))[0];
  if (!selected) throw new Error("SoundCloud did not expose a playable transcoding");
  const resolved = await api<{ url?: unknown }>(string(selected.url), {
    track_authorization: string(track.track_authorization),
  });
  const uri = string(resolved.url);
  if (!uri) throw new Error("SoundCloud returned an empty playback URL");
  return { uri, referrer: `${WEB_ORIGIN}/`, webpageUrl: string(track.permalink_url) || `${WEB_ORIGIN}/` };
}
