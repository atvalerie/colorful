import { normalizeVerificationUrl, pollDeviceAuth, refreshUserToken, startDeviceAuth, type UserToken } from "./auth";
import { BrowseClient } from "./browse";
import { readTidalConfig } from "./config";
import { UserSession } from "./manifest";
import { clearRefreshToken, loadRefreshToken, saveRefreshToken } from "./secret-store";
import { loadSubscriptionStatus } from "./subscription";

type RequestMessage = { id: number; type: string; payload?: Record<string, unknown> };
type ResponseMessage = { id?: number; event?: string; ok: boolean; data?: unknown; error?: string };

const config = readTidalConfig();
const browse = new BrowseClient(config);
let session: UserSession | null = null;
let authAbort: AbortController | null = null;

function send(message: ResponseMessage): void {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function publicError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function installSession(token: UserToken): Promise<void> {
  session = new UserSession(config, token, async (refreshToken) => {
    if (!await saveRefreshToken(refreshToken)) send({ event: "warning", ok: false, error: "Could not persist refreshed TIDAL login in Secret Service" });
  });
}

async function publishSubscriptionStatus(): Promise<void> {
  if (!session) return;
  try {
    send({ event: "subscription.status", ok: true, data: await loadSubscriptionStatus(await session.accessToken()) });
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
      await clearRefreshToken();
      send({ id: request.id, ok: true, data: { linked: false } });
      return;
    case "search": {
      const query = String(request.payload?.query ?? "").trim();
      if (!query) throw new Error("Search query is empty");
      const tracks = await browse.searchTracks(query);
      send({ id: request.id, ok: true, data: { tracks } });
      return;
    }
    case "related": {
      const provider = String(request.payload?.provider ?? "tidal");
      if (provider !== "tidal") throw new Error(`Related tracks are not implemented for ${provider}`);
      const trackId = String(request.payload?.trackId ?? "").trim();
      if (!trackId) throw new Error("Track ID is empty");
      const requestedLimit = Number(request.payload?.limit ?? 20);
      const limit = Number.isFinite(requestedLimit) ? requestedLimit : 20;
      send({ id: request.id, ok: true, data: { tracks: await browse.relatedTracks(trackId, limit) } });
      return;
    }
    case "source": {
      if (!session) throw new Error("Connect your TIDAL account before playing music");
      const provider = String(request.payload?.provider ?? "tidal");
      if (provider !== "tidal") throw new Error(`Playback is not implemented for ${provider}`);
      const trackId = String(request.payload?.trackId ?? "").trim();
      if (!trackId) throw new Error("Track ID is empty");
      send({ id: request.id, ok: true, data: await session.sourceFor(trackId) });
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
