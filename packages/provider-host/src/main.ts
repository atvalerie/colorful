import { normalizeVerificationUrl, pollDeviceAuth, refreshUserToken, startDeviceAuth, type UserToken } from "./auth";
import { BrowseClient } from "./browse";
import { readTidalConfig } from "./config";
import { UserSession, type ManifestType, type PlaybackQuality } from "./manifest";
import { clearProviderSecret, clearRefreshToken, loadProviderSecret, loadRefreshToken, saveProviderSecret, saveRefreshToken } from "./secret-store";
import { loadAccountIdentity, loadSubscriptionStatus, type SubscriptionStatus } from "./subscription";
import { parseSoundCloudAuthorization, setSoundCloudAccessToken, soundCloudAccount, soundCloudArtistPage, soundCloudCollection, soundCloudCollectionMore, soundCloudLinked, soundCloudMore, soundCloudPlaylistPage, soundCloudRelated, soundCloudSearch, soundCloudSearchMore, soundCloudSource, soundCloudTrackPage } from "./soundcloud";
import { clearYouTubeAuth, connectYouTubeBrowser, pollYouTubeDeviceAuth, restoreYouTubeAuth, startYouTubeDeviceAuth, youtubeAccessToken, youtubeBrowserHeaders, youtubeLinked } from "./youtube-auth";
import { searchYouTubeVideos, youtubeAutomix, youtubeAvailable, youtubeChannelVideos, youtubeSource, youtubeTrack } from "./youtube";
import { searchYouTubeMusicCatalog, setYouTubeMusicAccessTokenProvider, setYouTubeMusicBrowserHeadersProvider, youtubeMusicAccount, youtubeMusicAlbum, youtubeMusicArtist, youtubeMusicAutomix, youtubeMusicCollection, youtubeMusicPlaylist, youtubeMusicPlaylistMore, youtubeMusicShuffledPlaylist, youtubeMusicTrackMetadata } from "./youtube-music";

type RequestMessage = { id: number; type: string; payload?: Record<string, unknown> };
type ResponseMessage = { id?: number; event?: string; ok: boolean; data?: unknown; error?: string };

const config = readTidalConfig();
const browse = new BrowseClient(config);
let session: UserSession | null = null;
let account: SubscriptionStatus | null = null;
let accountLoad: Promise<SubscriptionStatus> | null = null;
let userBrowse: BrowseClient | null = null;
let authAbort: AbortController | null = null;
let youtubeAuthAbort: AbortController | null = null;

function send(message: ResponseMessage): void {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function publicError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function youtubeTracks(tracks: Awaited<ReturnType<typeof youtubeMusicAutomix>>): Array<(typeof tracks)[number] & { provider: "youtube" }> {
  return tracks.map((track) => ({ ...track, provider: "youtube" as const }));
}

async function installSession(token: UserToken): Promise<void> {
  session = new UserSession(config, token, async (refreshToken) => {
    if (!await saveRefreshToken(refreshToken)) send({ event: "warning", ok: false, error: "Could not persist refreshed TIDAL login in Secret Service" });
  });
  account = null;
  accountLoad = null;
  userBrowse = null;
}

async function accountStatus(force = false): Promise<SubscriptionStatus> {
  if (!session) throw new Error("Connect your TIDAL account first");
  if (!force && account) return account;
  if (!force && accountLoad) return accountLoad;
  accountLoad = (async () => {
    const token = await session!.accessToken(force);
    const identity = await loadAccountIdentity(token);
    const details = await loadSubscriptionStatus(token, identity);
    account = details;
    userBrowse = new BrowseClient({ ...config, countryCode: details.countryCode }, {
      getAccessToken: (refresh = false) => session!.accessToken(refresh),
    });
    return details;
  })().finally(() => { accountLoad = null; });
  return accountLoad;
}

async function publishSubscriptionStatus(): Promise<void> {
  try {
    const data = await accountStatus();
    send({ event: "subscription.status", ok: true, data });
    send({ event: "account.status", ok: true, data });
  } catch (error) {
    send({ event: "subscription.check_failed", ok: false, error: publicError(error) });
  }
}

async function restoreSession(): Promise<void> {
  const refreshToken = await loadRefreshToken();
  if (!refreshToken) return;
  try {
    await installSession(await refreshUserToken(config, refreshToken));
    send({ event: "auth.restored", ok: true, data: { linked: true } });
    void publishSubscriptionStatus();
  } catch (error) {
    send({ event: "warning", ok: false, error: `Stored TIDAL login could not be refreshed: ${publicError(error)}` });
  }
}

async function handle(request: RequestMessage): Promise<void> {
  switch (request.type) {
    case "status":
      send({ id: request.id, ok: true, data: {
        linked: session !== null,
        browseConfigured: Boolean(config.browseClientId && config.browseClientSecret),
        deviceConfigured: Boolean(config.deviceClientId && config.deviceClientSecret),
        youtubeAvailable: youtubeAvailable(),
        youtubeLinked: youtubeLinked(),
        soundcloudAvailable: true,
        soundcloudLinked: soundCloudLinked(),
      } });
      return;
    case "youtube.auth.status":
      send({ id: request.id, ok: true, data: {
        linked: youtubeLinked(),
        ...(youtubeLinked() ? { account: await youtubeMusicAccount() } : {}),
      } });
      return;
    case "youtube.auth.start": {
      youtubeAuthAbort?.abort();
      youtubeAuthAbort = new AbortController();
      const start = await startYouTubeDeviceAuth(
        String(request.payload?.clientId ?? ""), String(request.payload?.clientSecret ?? ""));
      send({ id: request.id, ok: true, data: {
        provider: "youtube",
        userCode: start.userCode,
        verificationUri: start.verificationUri,
        verificationUriComplete: `${start.verificationUri}?user_code=${encodeURIComponent(start.userCode)}`,
        expiresIn: start.expiresIn,
        interval: start.interval,
      } });
      void pollYouTubeDeviceAuth(start, youtubeAuthAbort.signal).then(async () => {
        setYouTubeMusicAccessTokenProvider(youtubeAccessToken);
        const account = await youtubeMusicAccount();
        send({ event: "youtube.auth.completed", ok: true, data: { linked: true, account } });
      }).catch((error) => {
        if (!youtubeAuthAbort?.signal.aborted)
          send({ event: "youtube.auth.failed", ok: false, error: publicError(error) });
      });
      return;
    }
    case "youtube.auth.browser": {
      await connectYouTubeBrowser(String(request.payload?.headers ?? ""));
      setYouTubeMusicAccessTokenProvider(null);
      setYouTubeMusicBrowserHeadersProvider(youtubeBrowserHeaders);
      let account;
      try {
        account = await youtubeMusicAccount();
      } catch (error) {
        await clearYouTubeAuth();
        setYouTubeMusicBrowserHeadersProvider(null);
        throw error;
      }
      send({ id: request.id, ok: true, data: { linked: true, account } });
      send({ event: "youtube.auth.completed", ok: true, data: { linked: true, account } });
      return;
    }
    case "youtube.auth.unlink":
      youtubeAuthAbort?.abort();
      youtubeAuthAbort = null;
      await clearYouTubeAuth();
      setYouTubeMusicAccessTokenProvider(null);
      setYouTubeMusicBrowserHeadersProvider(null);
      send({ id: request.id, ok: true, data: { linked: false } });
      return;
    case "youtube.auth.cancel":
      youtubeAuthAbort?.abort();
      youtubeAuthAbort = null;
      send({ id: request.id, ok: true, data: { cancelled: true } });
      return;
    case "youtube.account":
      send({ id: request.id, ok: true, data: await youtubeMusicAccount() });
      return;
    case "youtube.collection":
      send({ id: request.id, ok: true, data: await youtubeMusicCollection() });
      return;
    case "soundcloud.auth.browser": {
      const token = parseSoundCloudAuthorization(String(request.payload?.request ?? ""));
      setSoundCloudAccessToken(token);
      let account;
      try {
        account = await soundCloudAccount();
      } catch (error) {
        setSoundCloudAccessToken(null);
        throw error;
      }
      if (!await saveProviderSecret("soundcloud", "colorful SoundCloud account", token)) {
        setSoundCloudAccessToken(null);
        throw new Error("Could not persist the SoundCloud session in Secret Service");
      }
      send({ id: request.id, ok: true, data: { linked: true, account } });
      send({ event: "soundcloud.auth.completed", ok: true, data: { linked: true, account } });
      return;
    }
    case "soundcloud.auth.unlink":
      setSoundCloudAccessToken(null);
      await clearProviderSecret("soundcloud");
      send({ id: request.id, ok: true, data: { linked: false } });
      return;
    case "soundcloud.account":
      send({ id: request.id, ok: true, data: await soundCloudAccount() });
      return;
    case "soundcloud.collection":
      send({ id: request.id, ok: true, data: await soundCloudCollection() });
      return;
    case "soundcloud.collection.more": {
      const section = String(request.payload?.section ?? "");
      const cursor = String(request.payload?.cursor ?? "").trim();
      if (!cursor || !["tracks", "albums", "artists"].includes(section))
        throw new Error("SoundCloud library pagination state is incomplete");
      send({ id: request.id, ok: true, data: await soundCloudCollectionMore(section, cursor) });
      return;
    }
    case "auth.start": {
      authAbort?.abort();
      authAbort = new AbortController();
      const start = await startDeviceAuth(config);
      send({ id: request.id, ok: true, data: {
        provider: "tidal",
        userCode: start.userCode,
        verificationUri: normalizeVerificationUrl(start.verificationUri),
        verificationUriComplete: normalizeVerificationUrl(start.verificationUriComplete),
        expiresIn: start.expiresIn,
      } });
      void pollDeviceAuth(config, start, authAbort.signal).then(async (token) => {
        await installSession(token);
        const persisted = await saveRefreshToken(token.refreshToken);
        send({ event: "auth.completed", ok: true, data: { linked: true, persisted } });
        void publishSubscriptionStatus();
      }).catch((error) => {
        if (!authAbort?.signal.aborted) send({ event: "auth.failed", ok: false, error: publicError(error) });
      });
      return;
    }
    case "auth.unlink":
      authAbort?.abort();
      authAbort = null;
      session = null;
      account = null;
      accountLoad = null;
      userBrowse = null;
      await clearRefreshToken();
      send({ id: request.id, ok: true, data: { linked: false } });
      return;
    case "auth.cancel":
      authAbort?.abort();
      authAbort = null;
      send({ id: request.id, ok: true, data: { cancelled: true } });
      return;
    case "account":
      send({ id: request.id, ok: true, data: await accountStatus(Boolean(request.payload?.refresh)) });
      return;
    case "collection": {
      const details = await accountStatus();
      if (!userBrowse) throw new Error("TIDAL account catalog is not ready");
      send({ id: request.id, ok: true, data: await userBrowse.userCollection(details.userId) });
      return;
    }
    case "collection.more": {
      const details = await accountStatus();
      if (!userBrowse) throw new Error("TIDAL account catalog is not ready");
      const section = String(request.payload?.section ?? "");
      const cursor = String(request.payload?.cursor ?? "");
      if (!section || !cursor) throw new Error("Collection pagination state is incomplete");
      send({ id: request.id, ok: true, data: await userBrowse.userCollectionMore(details.userId, section, cursor) });
      return;
    }
    case "search": {
      const query = String(request.payload?.query ?? "").trim();
      if (!query) throw new Error("Search query is empty");
      const [tidalResult, youtubeResult, soundcloudResult] = await Promise.allSettled([
        browse.searchCatalog(query),
        searchYouTubeMusicCatalog(query),
        soundCloudSearch(query),
      ]);
      if (tidalResult.status === "rejected" && youtubeResult.status === "rejected" && soundcloudResult.status === "rejected") {
        throw new Error(`Search failed: ${publicError(tidalResult.reason)}; YouTube: ${publicError(youtubeResult.reason)}; SoundCloud: ${publicError(soundcloudResult.reason)}`);
      }
      const tidal = tidalResult.status === "fulfilled"
        ? tidalResult.value : { tracks: [], albums: [], artists: [], cursors: {} };
      const youtube = youtubeResult.status === "fulfilled"
        ? youtubeResult.value : { tracks: [], albums: [], artists: [], cursors: {} };
      const soundcloud = soundcloudResult.status === "fulfilled"
        ? soundcloudResult.value : { tracks: [], albums: [], artists: [] };
      send({ id: request.id, ok: true, data: {
        ...tidal,
        tracks: [...tidal.tracks, ...youtube.tracks.map((track) => ({ ...track, provider: "youtube" })), ...soundcloud.tracks],
        albums: [...tidal.albums, ...youtube.albums.map((album) => ({ ...album, provider: "youtube" })), ...soundcloud.albums],
        artists: [...tidal.artists, ...youtube.artists.map((artist) => ({ ...artist, provider: "youtube" })), ...soundcloud.artists],
        cursors: {
          tidal: tidalResult.status === "fulfilled" ? tidal.cursors : {},
          youtube: youtubeResult.status === "fulfilled"
            ? (Object.keys(youtube.cursors).length ? youtube.cursors : youtubeAvailable() ? { fallbackOffset: "1" } : {}) : {},
          soundcloud: soundcloudResult.status === "fulfilled" ? soundcloud.cursor ?? "" : "",
        },
        warnings: [
          ...(tidalResult.status === "rejected" ? [`TIDAL: ${publicError(tidalResult.reason)}`] : []),
          ...(youtubeResult.status === "rejected" ? [`YouTube: ${publicError(youtubeResult.reason)}`] : []),
          ...(soundcloudResult.status === "rejected" ? [`SoundCloud: ${publicError(soundcloudResult.reason)}`] : []),
        ],
      } });
      return;
    }
    case "search.more": {
      const provider = String(request.payload?.provider ?? "");
      const query = String(request.payload?.query ?? "").trim();
      const cursor = request.payload?.cursor;
      if (!query) throw new Error("Search query is empty");
      if (provider === "tidal") {
        const page = await browse.searchCatalog(query, 20,
          cursor && typeof cursor === "object" ? cursor as Record<string, string> : {});
        send({ id: request.id, ok: true, data: { provider, ...page, cursor: page.cursors } });
        return;
      }
      if (provider === "youtube") {
        const youtubeCursor = cursor && typeof cursor === "object" ? cursor as Record<string, string> : {};
        if (youtubeCursor.fallbackOffset) {
          const start = Number(youtubeCursor.fallbackOffset);
          if (!Number.isSafeInteger(start) || start < 1) throw new Error("Invalid YouTube search offset");
          const tracks = await searchYouTubeVideos(query, 20, start);
          send({ id: request.id, ok: true, data: { provider,
            tracks, albums: [], artists: [],
            cursor: tracks.length === 20 ? { fallbackOffset: String(start + tracks.length) } : {} } });
          return;
        }
        const page = await searchYouTubeMusicCatalog(query,
          youtubeCursor);
        send({ id: request.id, ok: true, data: { provider,
          tracks: page.tracks.map((track) => ({ ...track, provider })),
          albums: page.albums.map((album) => ({ ...album, provider })),
          artists: page.artists.map((artist) => ({ ...artist, provider })),
          cursor: page.cursors } });
        return;
      }
      if (provider === "soundcloud") {
        const value = String(cursor ?? "").trim();
        if (!value) throw new Error("SoundCloud search has no next page");
        const page = await soundCloudSearchMore(value);
        send({ id: request.id, ok: true, data: { provider, ...page, cursor: page.cursor ?? "" } });
        return;
      }
      throw new Error(`Search pagination is not implemented for ${provider}`);
    }
    case "detail": {
      const provider = String(request.payload?.provider ?? "tidal");
      const kind = String(request.payload?.kind ?? "");
      const resourceId = String(request.payload?.id ?? "").trim();
      if (!resourceId) throw new Error("Catalog resource ID is empty");
      if (provider === "youtube" && kind === "track") {
        const [resolvedTrack, musicTrack, relatedTracks] = await Promise.all([
          youtubeTrack(resourceId),
          youtubeMusicTrackMetadata(resourceId).catch(() => null),
          youtubeMusicAutomix(resourceId, 20).then((tracks) => tracks.length ? tracks : youtubeAutomix(resourceId, 20))
            .catch(() => youtubeAutomix(resourceId, 20)),
        ]);
        const trackDocument = musicTrack ? { ...resolvedTrack, ...musicTrack, provider, uploader: resolvedTrack.uploader } : resolvedTrack;
        send({ id: request.id, ok: true, data: {
          kind: "track", provider, track: trackDocument, relatedTracks: youtubeTracks(relatedTracks),
        } });
        return;
      }
      if (provider === "youtube" && kind === "artist") {
        send({ id: request.id, ok: true, data: { ...await youtubeMusicArtist(resourceId), provider } });
        return;
      }
      if (provider === "youtube" && kind === "album") {
        send({ id: request.id, ok: true, data: { ...await youtubeMusicAlbum(resourceId), provider } });
        return;
      }
      if (provider === "youtube" && kind === "playlist") {
        send({ id: request.id, ok: true, data: { ...await youtubeMusicPlaylist(resourceId), provider } });
        return;
      }
      if (provider === "soundcloud" && kind === "track") {
        send({ id: request.id, ok: true, data: await soundCloudTrackPage(resourceId) });
        return;
      }
      if (provider === "soundcloud" && (kind === "album" || kind === "playlist")) {
        send({ id: request.id, ok: true, data: await soundCloudPlaylistPage(resourceId) });
        return;
      }
      if (provider === "soundcloud" && kind === "artist") {
        send({ id: request.id, ok: true, data: await soundCloudArtistPage(resourceId) });
        return;
      }
      if (provider !== "tidal") throw new Error(`Catalog pages are not implemented for ${provider}`);
      if (kind === "track") send({ id: request.id, ok: true, data: await browse.trackPage(resourceId) });
      else if (kind === "album") send({ id: request.id, ok: true, data: await browse.albumPage(resourceId) });
      else if (kind === "artist") send({ id: request.id, ok: true, data: await browse.artistPage(resourceId) });
      else if (kind === "playlist") {
        await accountStatus();
        if (!userBrowse) throw new Error("TIDAL account catalog is not ready");
        send({ id: request.id, ok: true, data: await userBrowse.playlistPage(resourceId) });
      }
      else throw new Error(`Unsupported catalog page: ${kind}`);
      return;
    }
    case "detail.more": {
      const provider = String(request.payload?.provider ?? "tidal");
      const kind = String(request.payload?.kind ?? "");
      const resourceId = String(request.payload?.id ?? "").trim();
      const section = String(request.payload?.section ?? "");
      const cursor = String(request.payload?.cursor ?? "").trim();
      if (!resourceId || !cursor) throw new Error("Catalog pagination state is incomplete");
      if (provider === "youtube") {
        if (kind === "playlist" && section === "tracks" && cursor.startsWith("youtube-music-")) {
          send({ id: request.id, ok: true, data: { section: "tracks", ...await youtubeMusicPlaylistMore(cursor) } });
          return;
        }
        if (kind !== "artist" || section !== "tracks" || !cursor.startsWith("youtube-channel:"))
          throw new Error("That YouTube catalog section cannot be expanded");
        const start = Number(cursor.slice("youtube-channel:".length));
        if (!Number.isSafeInteger(start) || start < 1) throw new Error("Invalid YouTube channel cursor");
        const tracks = await youtubeChannelVideos(resourceId, start, 20);
        send({ id: request.id, ok: true, data: { section: "tracks", tracks,
          cursor: tracks.length === 20 ? `youtube-channel:${start + tracks.length}` : "" } });
        return;
      }
      if (provider === "soundcloud") {
        if (section !== "tracks" && section !== "albums") throw new Error("That SoundCloud section cannot be expanded");
        send({ id: request.id, ok: true, data: await soundCloudMore(section, cursor) });
        return;
      }
      if (provider !== "tidal") throw new Error(`Catalog pagination is not implemented for ${provider}`);
      if (kind === "playlist") {
        await accountStatus();
        if (!userBrowse) throw new Error("TIDAL account catalog is not ready");
        send({ id: request.id, ok: true, data: await userBrowse.catalogMore(kind, resourceId, section, cursor) });
      } else {
        send({ id: request.id, ok: true, data: await browse.catalogMore(kind, resourceId, section, cursor) });
      }
      return;
    }
    case "detail.albumTracks": {
      const resourceId = String(request.payload?.id ?? "").trim();
      if (!resourceId) throw new Error("Album ID is empty");
      send({ id: request.id, ok: true, data: { tracks: await browse.allAlbumTracks(resourceId) } });
      return;
    }
    case "detail.youtubePlaylistShuffle": {
      const resourceId = String(request.payload?.id ?? "").trim();
      if (!resourceId) throw new Error("Playlist ID is empty");
      send({ id: request.id, ok: true, data: await youtubeMusicShuffledPlaylist(resourceId) });
      return;
    }
    case "related": {
      const provider = String(request.payload?.provider ?? "tidal");
      const trackId = String(request.payload?.trackId ?? "").trim();
      if (!trackId) throw new Error("Track ID is empty");
      const requestedLimit = Number(request.payload?.limit ?? 20);
      const limit = Number.isFinite(requestedLimit) ? requestedLimit : 20;
      if (provider === "youtube") {
        const tracks = await youtubeMusicAutomix(trackId, limit)
          .then((items) => items.length ? items : youtubeAutomix(trackId, limit))
          .catch(() => youtubeAutomix(trackId, limit));
        send({ id: request.id, ok: true, data: { tracks: youtubeTracks(tracks) } });
      }
      else if (provider === "tidal")
        send({ id: request.id, ok: true, data: { tracks: await browse.relatedTracks(trackId, limit) } });
      else if (provider === "soundcloud")
        send({ id: request.id, ok: true, data: { tracks: await soundCloudRelated(trackId, limit) } });
      else throw new Error(`Related tracks are not implemented for ${provider}`);
      return;
    }
    case "source": {
      const provider = String(request.payload?.provider ?? "tidal");
      const trackId = String(request.payload?.trackId ?? "").trim();
      if (!trackId) throw new Error("Track ID is empty");
      if (provider === "youtube") {
        send({ id: request.id, ok: true, data: await youtubeSource(trackId) });
        return;
      }
      if (provider === "soundcloud") {
        send({ id: request.id, ok: true, data: await soundCloudSource(trackId) });
        return;
      }
      if (provider !== "tidal") throw new Error(`Playback is not implemented for ${provider}`);
      if (!session) throw new Error("Connect your TIDAL account before playing music");
      const requestedManifestType = String(request.payload?.manifestType ?? "HLS");
      if (requestedManifestType !== "HLS" && requestedManifestType !== "MPEG_DASH") {
        throw new Error(`Unsupported manifest type: ${requestedManifestType}`);
      }
      const requestedQuality = String(request.payload?.quality ?? "best");
      if (!["best", "lossless", "high"].includes(requestedQuality)) {
        throw new Error(`Unsupported playback quality: ${requestedQuality}`);
      }
      send({
        id: request.id,
        ok: true,
        data: await session.sourceFor(trackId, requestedManifestType as ManifestType, requestedQuality as PlaybackQuality),
      });
      return;
    }
    default:
      throw new Error(`Unknown provider request: ${request.type}`);
  }
}

async function restoreAccounts(): Promise<void> {
  await Promise.all([restoreSession(), (async () => {
    if (!await restoreYouTubeAuth()) return;
    setYouTubeMusicBrowserHeadersProvider(youtubeBrowserHeaders);
    try {
      const account = await youtubeMusicAccount();
      send({ event: "youtube.auth.restored", ok: true, data: { linked: true, account } });
    } catch (error) {
      await clearYouTubeAuth();
      setYouTubeMusicBrowserHeadersProvider(null);
      send({ event: "warning", ok: false, error: `Stored YouTube Music session expired: ${publicError(error)}` });
    }
  })(), (async () => {
    const token = await loadProviderSecret("soundcloud");
    if (!token) return;
    setSoundCloudAccessToken(token);
    try {
      const account = await soundCloudAccount();
      send({ event: "soundcloud.auth.restored", ok: true, data: { linked: true, account } });
    } catch (error) {
      setSoundCloudAccessToken(null);
      await clearProviderSecret("soundcloud");
      send({ event: "warning", ok: false, error: `Stored SoundCloud session expired: ${publicError(error)}` });
    }
  })()]);
}

void restoreAccounts().finally(async () => {
  const reader = Bun.stdin.stream().pipeThrough(new TextDecoderStream()).getReader();
  let buffered = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffered += value;
    for (;;) {
      const newline = buffered.indexOf("\n");
      if (newline < 0) break;
      const line = buffered.slice(0, newline).trim();
      buffered = buffered.slice(newline + 1);
      if (!line) continue;
      let requestId: number | undefined;
      try {
        const request = JSON.parse(line) as RequestMessage;
        requestId = request.id;
        await handle(request);
      } catch (error) {
        send({ ...(requestId === undefined ? {} : { id: requestId }), ok: false, error: publicError(error) });
      }
    }
  }
});
