import { normalizeVerificationUrl, pollDeviceAuth, refreshUserToken, startDeviceAuth, type UserToken } from "./auth";
import { BrowseClient } from "./browse";
import { readTidalConfig } from "./config";
import { UserSession, type ManifestType, type PlaybackQuality } from "./manifest";
import { clearRefreshToken, loadRefreshToken, saveRefreshToken } from "./secret-store";
import { loadAccountIdentity, loadSubscriptionStatus, type SubscriptionStatus } from "./subscription";
import { youtubeAutomix, youtubeAvailable, youtubeSource, youtubeTrack } from "./youtube";
import { searchYouTubeMusicCatalog, youtubeMusicAlbum, youtubeMusicArtist, youtubeMusicAutomix, youtubeMusicTrackMetadata } from "./youtube-music";

type RequestMessage = { id: number; type: string; payload?: Record<string, unknown> };
type ResponseMessage = { id?: number; event?: string; ok: boolean; data?: unknown; error?: string };

const config = readTidalConfig();
const browse = new BrowseClient(config);
let session: UserSession | null = null;
let account: SubscriptionStatus | null = null;
let accountLoad: Promise<SubscriptionStatus> | null = null;
let userBrowse: BrowseClient | null = null;
let authAbort: AbortController | null = null;

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
      } });
      return;
    case "auth.start": {
      authAbort?.abort();
      authAbort = new AbortController();
      const start = await startDeviceAuth(config);
      send({ id: request.id, ok: true, data: {
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
      const [tidalResult, youtubeResult] = await Promise.allSettled([
        browse.searchCatalog(query),
        searchYouTubeMusicCatalog(query),
      ]);
      if (tidalResult.status === "rejected" && youtubeResult.status === "rejected") {
        throw new Error(`Search failed: ${publicError(tidalResult.reason)}; YouTube: ${publicError(youtubeResult.reason)}`);
      }
      const tidal = tidalResult.status === "fulfilled"
        ? tidalResult.value : { tracks: [], albums: [], artists: [] };
      const youtube = youtubeResult.status === "fulfilled"
        ? youtubeResult.value : { tracks: [], albums: [], artists: [] };
      send({ id: request.id, ok: true, data: {
        ...tidal,
        tracks: [...tidal.tracks, ...youtube.tracks.map((track) => ({ ...track, provider: "youtube" }))],
        albums: [...tidal.albums, ...youtube.albums.map((album) => ({ ...album, provider: "youtube" }))],
        artists: [...tidal.artists, ...youtube.artists.map((artist) => ({ ...artist, provider: "youtube" }))],
        warnings: [
          ...(tidalResult.status === "rejected" ? [`TIDAL: ${publicError(tidalResult.reason)}`] : []),
          ...(youtubeResult.status === "rejected" ? [`YouTube: ${publicError(youtubeResult.reason)}`] : []),
        ],
      } });
      return;
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
      if (provider !== "tidal") throw new Error(`Catalog pagination is not implemented for ${provider}`);
      const kind = String(request.payload?.kind ?? "");
      const resourceId = String(request.payload?.id ?? "").trim();
      const section = String(request.payload?.section ?? "");
      const cursor = String(request.payload?.cursor ?? "").trim();
      if (!resourceId || !cursor) throw new Error("Catalog pagination state is incomplete");
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

void restoreSession().finally(async () => {
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
