import { chmodSync, existsSync, mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join, posix, resolve, win32 } from "node:path";
import {
  availableLoopbackPort,
  browserExecutableCandidates,
  CdpClient,
  pageTarget,
  selectChromiumExecutable,
} from "./browser-login";
import { debugLog } from "./debug";

const SPOTIFY_ORIGIN = "https://open.spotify.com";
const SPOTIFY_START_URL = `${SPOTIFY_ORIGIN}/`;
const SPOTIFY_LOGIN_URL = `https://accounts.spotify.com/en/login?continue=${encodeURIComponent(SPOTIFY_START_URL)}`;
const SPOTIFY_TOKEN_PATH = "/api/token";
const CLIENT_TOKEN_HOST = "clienttoken.spotify.com";
const CLIENT_TOKEN_PATH = "/v1/clienttoken";
const TOKEN_REFRESH_MARGIN_MS = 60_000;
const CLIENT_TOKEN_REFRESH_MARGIN_MS = 5 * 60_000;
const START_TIMEOUT_MS = 20_000;
const LOGIN_TIMEOUT_MS = 10 * 60_000;
const SEARCH_TIMEOUT_MS = 20_000;
const PATHFINDER_HOST = "api-partner.spotify.com";
const PATHFINDER_PATHS = new Set(["/pathfinder/v1/query", "/pathfinder/v2/query"]);
const SPOTIFY_TRACK_ID = /^[A-Za-z0-9]{22}$/;

type JsonObject = Record<string, unknown>;

export type SpotifyApiToken = {
  accessToken: string;
  expiresAtMs: number;
  isAnonymous: boolean;
};

export type SpotifyClientToken = {
  clientToken: string;
  expiresAtMs: number | null;
};

/**
 * The two values Spotify's web player uses for its first-party requests.
 * These values intentionally live only in this provider-host process. The
 * durable account state is the isolated Chromium profile, whose cookie store
 * is managed by the browser rather than being copied to config or logs.
 */
export type SpotifyCredentials = {
  accessToken: string;
  clientToken: string;
  expiresAtMs: number;
  clientTokenExpiresAtMs: number | null;
};

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function object(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as JsonObject : {};
}

function normalizedHeaders(value: unknown): Record<string, string> {
  return Object.fromEntries(Object.entries(object(value))
    .map(([name, header]) => [name.toLowerCase(), typeof header === "string" ? header.trim() : String(header ?? "").trim()])
    .filter(([, header]) => Boolean(header)));
}

/** Return true only for Spotify's Web Player Pathfinder search endpoint. */
export function isSpotifyPathfinderUrl(rawUrl: string): boolean {
  try {
    const url = new URL(rawUrl);
    return url.protocol === "https:" && url.hostname === PATHFINDER_HOST && PATHFINDER_PATHS.has(url.pathname);
  } catch {
    return false;
  }
}

/**
 * Extract track IDs from a Pathfinder response without retaining the response.
 * Search results have changed shape several times, so this intentionally walks
 * nested arrays/objects and accepts only explicit Spotify track URIs or IDs.
 */
export function collectSpotifyTrackIds(value: unknown): string[] {
  const found = new Set<string>();
  const seen = new Set<object>();
  const visit = (item: unknown): void => {
    if (typeof item === "string") {
      const match = item.match(/spotify:track:([A-Za-z0-9]{22})/i);
      if (match?.[1]) found.add(match[1]);
      return;
    }
    if (!item || typeof item !== "object" || seen.has(item)) return;
    seen.add(item);
    if (Array.isArray(item)) {
      for (const child of item) visit(child);
      return;
    }
    const candidate = item as JsonObject;
    const uri = text(candidate.uri) || text(candidate.track_uri) || text(candidate.trackUri);
    const uriMatch = uri.match(/^spotify:track:([A-Za-z0-9]{22})$/i);
    if (uriMatch?.[1]) found.add(uriMatch[1]);
    const id = text(candidate.id);
    // Current Pathfinder search nodes may expose only a bare 22-character ID.
    // Keep it as a candidate: resolveSeed() hydrates every candidate through
    // track metadata and verifies the exact ISRC before trusting it, so album
    // or artist IDs collected from the same envelope are safely discarded.
    if (id && SPOTIFY_TRACK_ID.test(id)) found.add(id);
    for (const child of Object.values(candidate)) visit(child);
  };
  visit(value);
  return [...found];
}

function positiveNumber(value: unknown): number | null {
  const number = typeof value === "number" ? value : Number(value);
  return Number.isFinite(number) && number > 0 ? number : null;
}

function expirationMs(value: unknown): number | null {
  const number = positiveNumber(value);
  if (number === null) return null;
  // Spotify has returned both millisecond timestamps and second durations in
  // this family of responses. Values in the billions are timestamps in ms;
  // smaller values are durations and are handled by the caller.
  return number >= 100_000_000_000 ? number : null;
}

function durationMs(value: unknown): number | null {
  const number = positiveNumber(value);
  return number === null ? null : number * 1_000;
}

/** Parse an open.spotify.com/api/token response without retaining the raw document. */
export function parseSpotifyApiTokenResponse(
  value: unknown,
  now = Date.now(),
): SpotifyApiToken | null {
  const document = object(value);
  const accessToken = text(document.accessToken) || text(document.access_token);
  if (!accessToken) return null;
  const absoluteExpiry = expirationMs(
    document.accessTokenExpirationTimestampMs
      ?? document.access_token_expiration_timestamp_ms
      ?? document.expiresAtMs,
  );
  const duration = durationMs(document.expiresIn ?? document.expires_in);
  const expiresAtMs = absoluteExpiry ?? (duration === null ? now + 60 * 60_000 : now + duration);
  return {
    accessToken,
    expiresAtMs,
    isAnonymous: document.isAnonymous === true || document.isAnonymous === "true"
      || document.is_anonymous === true || document.is_anonymous === "true",
  };
}

/** Parse the clienttoken.spotify.com response emitted by Spotify's web player. */
export function parseSpotifyClientTokenResponse(
  value: unknown,
  now = Date.now(),
): SpotifyClientToken | null {
  const document = object(value);
  const granted = object(document.granted_token ?? document.grantedToken);
  const clientToken = text(granted.token)
    || text(document.clientToken)
    || text(document.client_token)
    || text(document.token);
  if (!clientToken) return null;
  const duration = durationMs(
    granted.expires_after_seconds
      ?? granted.expiresAfterSeconds
      ?? document.expires_after_seconds
      ?? document.expiresAfterSeconds,
  );
  const absoluteExpiry = expirationMs(
    granted.expiresAtMs ?? document.expiresAtMs,
  );
  return {
    clientToken,
    expiresAtMs: absoluteExpiry ?? (duration === null ? null : now + duration),
  };
}

/**
 * Resolve Colorful's app-owned profile location. COLORFUL_DATA_DIR mirrors
 * QStandardPaths::AppDataLocation when the native shell provides it; the
 * platform defaults keep the provider host useful when run directly.
 */
export function spotifyProfileDirectory(
  platform: string = process.platform,
  environment: Record<string, string | undefined> = process.env,
  home = homedir(),
): string {
  const pathApi = platform === "win32" ? win32 : posix;
  const configured = environment.COLORFUL_SPOTIFY_PROFILE_DIR?.trim();
  if (configured) return pathApi.resolve(configured);
  const dataRoot = environment.COLORFUL_DATA_DIR?.trim();
  if (dataRoot) return pathApi.resolve(dataRoot, "spotify-browser");
  const root = platform === "win32"
    ? pathApi.join(environment.LOCALAPPDATA || environment.APPDATA || pathApi.join(home, "AppData", "Local"), "colorful")
    : platform === "darwin"
      ? pathApi.join(home, "Library", "Application Support", "colorful")
      : pathApi.join(environment.XDG_DATA_HOME || pathApi.join(home, ".local", "share"), "colorful");
  return pathApi.resolve(root, "spotify-browser");
}

/** Keep the browser profile private when the platform supports Unix modes. */
export function ensureSpotifyProfileDirectory(directory: string): string {
  const profile = resolve(directory);
  mkdirSync(profile, { recursive: true, mode: 0o700 });
  if (process.platform !== "win32") {
    try { chmodSync(profile, 0o700); } catch { /* best effort; browser will report a real failure */ }
  }
  return profile;
}

export type SpotifyCredentialCacheOptions = {
  now?: () => number;
  refreshMarginMs?: number;
};

/** Small in-memory cache kept separate so expiry behavior remains testable. */
export class SpotifyCredentialCache {
  private value: SpotifyCredentials | null = null;
  private readonly now: () => number;
  private readonly refreshMarginMs: number;

  constructor(options: SpotifyCredentialCacheOptions = {}) {
    this.now = options.now ?? (() => Date.now());
    this.refreshMarginMs = options.refreshMarginMs ?? TOKEN_REFRESH_MARGIN_MS;
  }

  get(force = false): SpotifyCredentials | null {
    if (!this.value || force || this.value.expiresAtMs <= this.now() + this.refreshMarginMs) return null;
    if (this.value.clientTokenExpiresAtMs !== null
        && this.value.clientTokenExpiresAtMs <= this.now() + CLIENT_TOKEN_REFRESH_MARGIN_MS) return null;
    return { ...this.value };
  }

  peek(): SpotifyCredentials | null {
    return this.value ? { ...this.value } : null;
  }

  set(value: SpotifyCredentials): void {
    this.value = { ...value };
  }

  clear(): void {
    this.value = null;
  }
}

type CdpTransport = Pick<CdpClient, "command" | "onMessage" | "onClose" | "close">;
export type SpotifyCdpTransport = CdpTransport;

type SpotifyBrowserProcess = {
  exited: Promise<number>;
  exitCode: number | null;
  kill: () => void;
};

export type SpotifyBrowserSessionOptions = {
  profileDirectory?: string;
  browserExecutable?: string;
  now?: () => number;
  /** Injectable only for tests and alternative desktop launchers. */
  browserCandidates?: string[];
  selectBrowser?: (candidates: string[]) => string;
  reservePort?: (signal: AbortSignal) => Promise<number>;
  connect?: (url: string, signal: AbortSignal) => Promise<CdpTransport>;
  findPage?: (port: number, expectedHost: string, signal: AbortSignal) => Promise<string>;
  spawn?: (browser: string, args: string[]) => SpotifyBrowserProcess;
};

type NetworkCapture = {
  clientToken: SpotifyClientToken | null;
  headerClientToken: string;
};

function abortError(): Error {
  return new Error("Spotify browser sign-in cancelled");
}

async function delay(milliseconds: number, signal: AbortSignal): Promise<void> {
  if (signal.aborted) throw abortError();
  await new Promise<void>((resolveDelay, reject) => {
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", aborted);
      resolveDelay();
    }, milliseconds);
    const aborted = () => {
      clearTimeout(timer);
      reject(abortError());
    };
    signal.addEventListener("abort", aborted, { once: true });
  });
}

function defaultSpawn(browser: string, args: string[]): SpotifyBrowserProcess {
  const process = Bun.spawn({
    cmd: [browser, ...args],
    stdin: "ignore",
    stdout: "ignore",
    stderr: "ignore",
  });
  return process;
}

function responseBody(value: unknown): string {
  return text(object(value).body);
}

function isClientTokenUrl(rawUrl: string): boolean {
  try {
    const url = new URL(rawUrl);
    return url.hostname === CLIENT_TOKEN_HOST && url.pathname === CLIENT_TOKEN_PATH;
  } catch {
    return false;
  }
}

function isSpotifyTokenUrl(rawUrl: string): boolean {
  try {
    const url = new URL(rawUrl);
    return url.hostname === "open.spotify.com" && url.pathname === SPOTIFY_TOKEN_PATH;
  } catch {
    return false;
  }
}

class SpotifySessionExpiredError extends Error {
  constructor(message = "Spotify browser session is no longer authenticated") {
    super(message);
    this.name = "SpotifySessionExpiredError";
  }
}

type SessionCapture = {
  apiToken: SpotifyApiToken | null;
  clientToken: SpotifyClientToken | null;
  headerClientToken: string;
};

type SessionCaptureOptions = {
  /** Visible login must stay passive; hidden refresh may reload the Web Player. */
  reload: boolean;
  failAnonymous: boolean;
  timeoutMs: number;
};

/**
 * Observe the Web Player's own credential requests. Spotify signs `/api/token`
 * requests with a short-lived page parameter, so native fetch/Runtime.evaluate
 * is intentionally not used here. The only way to refresh is to let the page
 * generate a fresh request (a reload is permitted only for a hidden session).
 */
async function captureSpotifySession(
  client: CdpTransport,
  signal: AbortSignal,
  now: () => number,
  options: SessionCaptureOptions,
): Promise<SessionCapture> {
  let apiToken: SpotifyApiToken | null = null;
  let clientCapture: SpotifyClientToken | null = null;
  let headerClientToken = "";
  const requestState = new Map<string, { url: string; headers: Record<string, string> }>();
  const tokenResponses = new Set<string>();
  const clientResponses = new Set<string>();
  const bodyJobs = new Set<Promise<void>>();
  let settled = false;
  let resolveCapture: (value: SessionCapture) => void = () => undefined;
  let rejectCapture: (error: Error) => void = () => undefined;
  const captured = new Promise<SessionCapture>((resolveValue, rejectValue) => {
    resolveCapture = resolveValue;
    rejectCapture = rejectValue;
  });
  const finish = (): void => {
    if (settled || !apiToken || apiToken.isAnonymous) return;
    const clientToken = clientCapture?.clientToken || headerClientToken;
    if (!clientToken) return;
    settled = true;
    resolveCapture({ apiToken, clientToken: clientCapture, headerClientToken });
  };
  const captureBody = async (requestId: string, kind: "api" | "client"): Promise<void> => {
    const body = responseBody(await client.command("Network.getResponseBody", { requestId }).catch(() => ({})));
    if (!body) return;
    let document: unknown;
    try { document = JSON.parse(body); } catch { return; }
    if (kind === "api") {
      const parsed = parseSpotifyApiTokenResponse(document, now());
      if (parsed?.isAnonymous && options.failAnonymous) {
        settled = true;
        rejectCapture(new SpotifySessionExpiredError());
        return;
      }
      if (parsed) apiToken = parsed;
    } else {
      const parsed = parseSpotifyClientTokenResponse(document, now());
      if (parsed) clientCapture = parsed;
    }
    finish();
  };
  const removeListener = client.onMessage((message) => {
    const params = object(message.params);
    const requestId = text(params.requestId);
    if (!requestId) return;
    if (message.method === "Network.requestWillBeSent") {
      const request = object(params.request);
      const url = text(request.url);
      const state = requestState.get(requestId) ?? { url, headers: {} };
      state.url = url || state.url;
      state.headers = { ...state.headers, ...normalizedHeaders(request.headers) };
      requestState.set(requestId, state);
      headerClientToken = state.headers["client-token"] ?? state.headers["x-client-token"] ?? headerClientToken;
      finish();
    } else if (message.method === "Network.requestWillBeSentExtraInfo") {
      const state = requestState.get(requestId) ?? { url: "", headers: {} };
      state.headers = { ...state.headers, ...normalizedHeaders(params.headers) };
      requestState.set(requestId, state);
      headerClientToken = state.headers["client-token"] ?? state.headers["x-client-token"] ?? headerClientToken;
      finish();
    } else if (message.method === "Network.responseReceived") {
      const response = object(params.response);
      const url = text(response.url);
      const status = Number(response.status);
      if (isSpotifyTokenUrl(url)) {
        if (status === 200) tokenResponses.add(requestId);
        else if (options.failAnonymous && (status === 401 || status === 403)) {
          settled = true;
          rejectCapture(new SpotifySessionExpiredError(`Spotify token endpoint returned HTTP ${status}`));
        }
      }
      if (isClientTokenUrl(url) && status === 200) clientResponses.add(requestId);
    } else if (message.method === "Network.loadingFinished") {
      const api = tokenResponses.delete(requestId);
      const clientToken = clientResponses.delete(requestId);
      if (api) {
        const job = captureBody(requestId, "api").catch(() => undefined);
        bodyJobs.add(job);
        void job.finally(() => bodyJobs.delete(job));
      }
      if (clientToken) {
        const job = captureBody(requestId, "client").catch(() => undefined);
        bodyJobs.add(job);
        void job.finally(() => bodyJobs.delete(job));
      }
    }
  });
  const removeCloseListener = client.onClose(() => {
    if (!settled) rejectCapture(new Error("The Spotify browser closed before its session could be captured"));
  });
  const aborted = () => rejectCapture(new Error("Spotify browser session capture cancelled"));
  const timer = setTimeout(() => rejectCapture(new Error("Spotify browser session did not produce an authenticated token")), options.timeoutMs);
  signal.addEventListener("abort", aborted, { once: true });
  try {
    await client.command("Network.enable", { maxTotalBufferSize: 1_048_576, maxPostDataSize: 65_536 });
    await client.command("Page.enable");
    if (options.reload) await client.command("Page.reload", { ignoreCache: true });
    return await captured;
  } finally {
    clearTimeout(timer);
    signal.removeEventListener("abort", aborted);
    removeListener();
    removeCloseListener();
    bodyJobs.clear();
  }
}

export class SpotifyBrowserSession {
  readonly profileDirectory: string;
  readonly cache: SpotifyCredentialCache;
  private readonly linkedMarker: string;
  private readonly options: SpotifyBrowserSessionOptions;
  private readonly now: () => number;
  private browser: SpotifyBrowserProcess | null = null;
  private client: CdpTransport | null = null;
  private clientHeadless = false;
  private clientToken: SpotifyClientToken | null = null;
  private refreshInFlight: Promise<SpotifyCredentials> | null = null;
  private readonly exitHandler = (): void => {
    // The process-exit path cannot await Browser.close. Killing the child is
    // still preferable to leaving a persistent profile locked by a stale
    // hidden Chromium process after the provider host terminates.
    if (this.browser && this.browser.exitCode === null) this.browser.kill();
  };

  constructor(options: SpotifyBrowserSessionOptions = {}) {
    this.options = options;
    this.now = options.now ?? (() => Date.now());
    this.profileDirectory = ensureSpotifyProfileDirectory(
      options.profileDirectory ?? spotifyProfileDirectory(),
    );
    this.linkedMarker = join(this.profileDirectory, ".colorful-linked");
    this.cache = new SpotifyCredentialCache({ now: this.now });
    process.once("exit", this.exitHandler);
  }

  get linked(): boolean {
    return this.cache.peek() !== null;
  }

  /**
   * Return a bearer/client-token pair, refreshing in the existing headless
   * browser session only when either value is near expiry.
   */
  async credentials(force = false, signal: AbortSignal = new AbortController().signal): Promise<SpotifyCredentials> {
    const cached = this.cache.get(force);
    if (cached) return cached;
    if (this.refreshInFlight) return this.refreshInFlight;
    this.refreshInFlight = this.refreshFromBrowser(signal).then((credentials) => {
      this.cache.set(credentials);
      return credentials;
    }).finally(() => {
      this.refreshInFlight = null;
    });
    return this.refreshInFlight;
  }

  /**
   * Open Spotify's own login page in the isolated profile. Once authenticated,
   * the visible process is replaced by a headless process using that same
   * profile, so later recommendation/catalog requests never open a browser.
   */
  async authenticate(
    signal: AbortSignal,
    progress: (status: string) => void = () => undefined,
  ): Promise<SpotifyCredentials> {
    this.cache.clear();
    this.clientToken = null;
    try {
      const client = await this.ensureBrowser(false, signal);
      progress("Sign in to Spotify in the isolated browser window.");
      // Attach once and wait for the Web Player's own authenticated requests.
      // Polling /api/token here would reload/touch accounts.spotify.com every
      // second and can interrupt an in-progress login or MFA challenge.
      const credentials = await this.captureVisibleSession(client, signal);
      this.cache.set(credentials);
      writeFileSync(this.linkedMarker, "1\n", { mode: 0o600 });
      // Do not leave the user's login window running after authentication.
      // The profile remains durable; only the process changes to a hidden
      // headless instance used for token refreshes.
      await this.closeBrowser();
      await this.ensureBrowser(true, signal);
      progress("Spotify account connected.");
      return credentials;
    } finally {
      // A cancelled/timed-out login must not leave a visible Chromium process
      // running. Successful auth has a cached token and a headless process.
      if (!this.cache.peek() && !this.clientHeadless) await this.closeBrowser();
    }
  }

  /** Attempt a silent restore from the persistent profile. */
  async restore(signal: AbortSignal = new AbortController().signal): Promise<SpotifyCredentials | null> {
    if (!existsSync(this.linkedMarker)) return null;
    try {
      return await this.credentials(false, signal);
    } catch (error) {
      debugLog("spotify.auth", "restore_failed", {
        error: error instanceof Error ? error.message : String(error),
      });
      this.cache.clear();
      this.clientToken = null;
      // Keep the marker for transient browser/network failures so the next
      // startup retries the durable profile. Remove it only when Spotify
      // explicitly says the cookie-backed session is no longer authenticated;
      // that is the case that needs visible re-authentication.
      if (error instanceof SpotifySessionExpiredError) {
        try { unlinkSync(this.linkedMarker); } catch { /* missing marker is already unlinked */ }
      }
      await this.closeBrowser();
      return null;
    }
  }

  /**
   * Search through the authenticated Web Player page and return candidate
   * track IDs for an ISRC/title query. Spotify's private Pathfinder request is
   * intentionally observed in the existing hidden CDP page rather than
   * replayed from native code: its body and client context are Web Player
   * implementation details and can change independently of the recommendation
   * protocol.
   */
  async searchTrackIds(
    query: string,
    signal: AbortSignal = new AbortController().signal,
  ): Promise<string[]> {
    const normalizedQuery = query.trim();
    if (!normalizedQuery) throw new Error("Spotify search query is empty");
    await this.credentials(false, signal);
    const client = await this.ensureBrowser(true, signal);
    const requests = new Map<string, { url: string; postData: string }>();
    const successfulResponses = new Set<string>();
    let observedRequests = 0;
    let successfulRequests = 0;
    let matchedRequests = 0;
    const pausedJobs = new Set<Promise<void>>();
    let settled = false;
    let resolveSearch: (ids: string[]) => void = () => undefined;
    let rejectSearch: (error: Error) => void = () => undefined;
    const found = new Promise<string[]>((resolveValue, rejectValue) => {
      resolveSearch = resolveValue;
      rejectSearch = rejectValue;
    });
    const queryNeedle = normalizedQuery.toLowerCase();
    const finish = (ids: string[]): void => {
      if (settled) return;
      settled = true;
      resolveSearch(ids);
    };
    const removeListener = client.onMessage((message) => {
      const params = object(message.params);
      const requestId = text(params.requestId);
      if (!requestId) return;
      if (message.method === "Fetch.requestPaused") {
        const request = object(params.request);
        const url = text(request.url);
        const status = Number(params.responseStatusCode) || 0;
        const job = (async () => {
          let ids: string[] = [];
          try {
            if (isSpotifyPathfinderUrl(url) && status === 200) {
              let requestText = text(request.postData);
              try { requestText += ` ${decodeURIComponent(new URL(url).search)}`; } catch { /* URL is diagnostic-only. */ }
              if (requestText.toLowerCase().includes(queryNeedle)) {
                const result = object(await client.command("Fetch.getResponseBody", { requestId }));
                const encoded = text(result.body);
                const body = result.base64Encoded === true
                  ? Buffer.from(encoded, "base64").toString("utf8") : encoded;
                if (body) ids = collectSpotifyTrackIds(JSON.parse(body));
                debugLog("spotify.search", "intercepted_candidates", { count: ids.length });
              }
            }
          } catch (error) {
            debugLog("spotify.search", "intercept_failed", {
              error: error instanceof Error ? error.message : String(error),
            });
          } finally {
            await client.command("Fetch.continueResponse", { requestId }).catch(async () => {
              await client.command("Fetch.continueRequest", { requestId }).catch(() => undefined);
            });
          }
          if (ids.length) finish(ids);
        })();
        pausedJobs.add(job);
        void job.finally(() => pausedJobs.delete(job));
        return;
      }
      if (message.method === "Network.requestWillBeSent") {
        const request = object(params.request);
        const url = text(request.url);
        if (!url || !isSpotifyPathfinderUrl(url)) return;
        observedRequests += 1;
        requests.set(requestId, { url, postData: text(request.postData) });
      } else if (message.method === "Network.responseReceived") {
        const response = object(params.response);
        const url = text(response.url);
        if (requests.has(requestId) && isSpotifyPathfinderUrl(url) && Number(response.status) === 200) {
          successfulRequests += 1;
          successfulResponses.add(requestId);
        } else if (requests.has(requestId) && isSpotifyPathfinderUrl(url)) {
          debugLog("spotify.search", "pathfinder_failed", { status: Number(response.status) || 0 });
        }
      } else if (message.method === "Network.loadingFinished" && successfulResponses.delete(requestId)) {
        void (async () => {
          const request = requests.get(requestId);
          requests.delete(requestId);
          if (!request || settled) return;
          const [result, postResult] = await Promise.all([
            client.command("Network.getResponseBody", { requestId }).catch(() => ({})),
            client.command("Network.getRequestPostData", { requestId }).catch(() => ({})),
          ]);
          const postData = text(object(postResult).postData);
          let requestText = `${request.postData} ${postData}`;
          try { requestText += ` ${decodeURIComponent(new URL(request.url).search)}`; } catch { /* URL is diagnostic-only. */ }
          if (!requestText.toLowerCase().includes(queryNeedle)) return;
          matchedRequests += 1;
          const body = text(object(result).body);
          if (!body) {
            debugLog("spotify.search", "empty_body", {});
            return;
          }
          let document: unknown;
          try { document = JSON.parse(body); } catch { return; }
          const ids = collectSpotifyTrackIds(document);
          debugLog("spotify.search", "candidates", { count: ids.length });
          if (ids.length) finish(ids);
        })();
      }
    });
    const timer = setTimeout(() => {
      debugLog("spotify.search", "timed_out", {
        observedRequests, successfulRequests, matchedRequests,
      });
      finish([]);
    }, SEARCH_TIMEOUT_MS);
    const aborted = () => rejectSearch(abortError());
    signal.addEventListener("abort", aborted, { once: true });
    try {
      await client.command("Network.enable", { maxTotalBufferSize: 1_048_576, maxPostDataSize: 65_536 });
      // A persistent Web Player profile can satisfy Pathfinder through its
      // service worker/cache, in which case CDP reports HTTP 200 but refuses
      // Network.getResponseBody. Force this hidden search navigation through
      // the network so the exact ISRC result can be verified and discarded.
      await client.command("Network.setCacheDisabled", { cacheDisabled: true });
      await client.command("Network.setBypassServiceWorker", { bypass: true });
      await client.command("Fetch.enable", { patterns: [{
        urlPattern: "*api-partner.spotify.com/pathfinder/*",
        requestStage: "Response",
      }] });
      await client.command("Page.enable");
      await client.command("Page.navigate", {
        url: `${SPOTIFY_ORIGIN}/search/${encodeURIComponent(normalizedQuery)}`,
      });
      return await found;
    } finally {
      clearTimeout(timer);
      signal.removeEventListener("abort", aborted);
      removeListener();
      await client.command("Fetch.disable").catch(() => undefined);
      await Promise.allSettled([...pausedJobs]);
      await client.command("Network.setBypassServiceWorker", { bypass: false }).catch(() => undefined);
      await client.command("Network.setCacheDisabled", { cacheDisabled: false }).catch(() => undefined);
    }
  }

  /** Clear only the isolated Spotify profile's browser state, never app data. */
  async clear(): Promise<void> {
    this.cache.clear();
    this.clientToken = null;
    try { unlinkSync(this.linkedMarker); } catch { /* missing marker is already unlinked */ }
    if (this.client) {
      await this.client.command("Network.clearBrowserCookies").catch(() => undefined);
      await this.client.command("Storage.clearDataForOrigin", {
        origin: SPOTIFY_ORIGIN,
        storageTypes: "all",
      }).catch(() => undefined);
    }
    await this.closeBrowser();
  }

  async close(): Promise<void> {
    await this.closeBrowser();
    process.removeListener("exit", this.exitHandler);
  }

  private selectBrowser(): string {
    if (this.options.browserExecutable?.trim()) return resolve(this.options.browserExecutable);
    const candidates = this.options.browserCandidates ?? browserExecutableCandidates();
    return (this.options.selectBrowser ?? selectChromiumExecutable)(candidates);
  }

  private async ensureBrowser(headless: boolean, signal: AbortSignal): Promise<CdpTransport> {
    // Chrome's launcher process may exit after handing the profile to its real
    // browser process. The CDP socket, not the launcher handle, is the source
    // of truth for whether that browser session is still alive.
    if (this.client && this.clientHeadless === headless) {
      return this.client;
    }
    if (this.browser || this.client) await this.closeBrowser();
    if (signal.aborted) throw abortError();
    const browser = this.selectBrowser();
    const port = await (this.options.reservePort ?? availableLoopbackPort)(signal);
    const args = [
      `--user-data-dir=${this.profileDirectory}`,
      "--remote-debugging-address=127.0.0.1",
      `--remote-debugging-port=${port}`,
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-background-mode",
      "--disable-sync",
      "--disable-extensions",
    ];
    if (headless) args.push("--headless=new");
    else args.push("--new-window");
    const startUrl = headless ? SPOTIFY_START_URL : SPOTIFY_LOGIN_URL;
    args.push(startUrl);
    const process = (this.options.spawn ?? defaultSpawn)(browser, args);
    this.browser = process;
    this.clientHeadless = headless;
    void process.exited.then(() => {
      if (this.browser === process) {
        this.browser = null;
      }
    });
    debugLog("spotify.auth", "browser_started", {
      browser: basename(browser),
      headless,
      profile: basename(this.profileDirectory),
    });
    const findPage = this.options.findPage ?? pageTarget;
    const target = await findPage(port, new URL(startUrl).hostname, signal);
    const client = await (this.options.connect ?? CdpClient.connect)(target, signal);
    client.onClose(() => {
      if (this.client === client) this.client = null;
    });
    this.client = client;
    return client;
  }

  private async refreshFromBrowser(
    signal: AbortSignal,
  ): Promise<SpotifyCredentials> {
    const client = await this.ensureBrowser(true, signal);
    const current = this.cache.peek();
    const captures = await this.captureNetwork(client, signal);
    const apiToken = captures.apiToken;
    if (!apiToken || apiToken.isAnonymous) {
      throw new Error("Spotify browser session is not authenticated");
    }
    const clientCapture = captures.clientToken;
    if (clientCapture) this.clientToken = clientCapture;
    const clientToken = clientCapture?.clientToken || captures.headerClientToken
      || current?.clientToken || this.clientToken?.clientToken || "";
    if (!clientCapture && captures.headerClientToken) {
      this.clientToken = { clientToken: captures.headerClientToken, expiresAtMs: null };
    }
    if (!clientToken) throw new Error("Spotify client token unavailable; retry sign-in");
    return {
      accessToken: apiToken.accessToken,
      clientToken,
      expiresAtMs: apiToken.expiresAtMs,
      clientTokenExpiresAtMs: clientCapture?.expiresAtMs
        ?? current?.clientTokenExpiresAtMs
        ?? this.clientToken?.expiresAtMs
        ?? null,
    };
  }

  /**
   * Observe one visible login session. This method deliberately never reloads
   * or evaluates the page: the user may be in an accounts.spotify.com login,
   * MFA, consent, or anti-abuse step when the observer is attached.
   */
  private async captureVisibleSession(
    client: CdpTransport,
    signal: AbortSignal,
  ): Promise<SpotifyCredentials> {
    const capture = await captureSpotifySession(client, signal, this.now, {
      reload: false,
      failAnonymous: false,
      timeoutMs: LOGIN_TIMEOUT_MS,
    });
    const clientToken = capture.clientToken?.clientToken || capture.headerClientToken;
    if (!capture.apiToken || capture.apiToken.isAnonymous || !clientToken) {
      throw new Error("Spotify browser session is not authenticated");
    }
    this.clientToken = capture.clientToken ?? { clientToken, expiresAtMs: null };
    return {
      accessToken: capture.apiToken.accessToken,
      clientToken,
      expiresAtMs: capture.apiToken.expiresAtMs,
      clientTokenExpiresAtMs: capture.clientToken?.expiresAtMs ?? null,
    };
  }

  private async captureNetwork(
    client: CdpTransport,
    signal: AbortSignal,
  ): Promise<NetworkCapture & { apiToken: SpotifyApiToken | null }> {
    const capture = await captureSpotifySession(client, signal, this.now, {
      // Every background refresh reloads the hidden Web Player page. This is
      // what causes Spotify to generate its current TOTP query parameters for
      // /api/token; a native fetch is rejected with HTTP 400.
      reload: true,
      failAnonymous: true,
      timeoutMs: START_TIMEOUT_MS,
    });
    return {
      apiToken: capture.apiToken,
      clientToken: capture.clientToken,
      headerClientToken: capture.headerClientToken,
    };
  }

  private async closeBrowser(): Promise<void> {
    const client = this.client;
    const process = this.browser;
    this.client = null;
    this.browser = null;
    if (client) {
      await client.command("Browser.close").catch(() => undefined);
      client.close();
    }
    if (process) {
      await Promise.race([
        process.exited.then(() => undefined),
        new Promise<void>((resolveDelay) => setTimeout(resolveDelay, 1_500)),
      ]);
      if (process.exitCode === null) process.kill();
    }
  }
}

export { CLIENT_TOKEN_HOST, CLIENT_TOKEN_PATH, SPOTIFY_LOGIN_URL, SPOTIFY_ORIGIN, SPOTIFY_TOKEN_PATH };
