import { chmodSync, existsSync, mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join, posix, resolve, win32 } from "node:path";
import {
  availableLoopbackPort,
  type BrowserCdpTransport,
  browserExecutableCandidates,
  captureBrowserRequest,
  CdpClient,
  pageTarget,
  selectBrowserExecutable,
} from "./browser-login";
import { debugLog } from "./debug";
import { clearProviderSecret, loadProviderSecret, saveProviderSecret } from "./secret-store";

const CODE_URL = "https://www.youtube.com/o/oauth2/device/code";
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const SCOPE = "https://www.googleapis.com/auth/youtube";
const USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/140 Safari/537.36 Cobalt/Version";
const YOUTUBE_MUSIC_ORIGIN = "https://music.youtube.com";
const YOUTUBE_MUSIC_LIBRARY_URL = `${YOUTUBE_MUSIC_ORIGIN}/library`;
const BROWSER_START_TIMEOUT_MS = 20_000;
const BROWSER_LOGIN_TIMEOUT_MS = 10 * 60_000;
const BROWSER_REFRESH_INTERVAL_MS = 15 * 60_000;

export type YouTubeCredentials = {
  clientId: string;
  clientSecret: string;
  refreshToken: string;
};

export type YouTubeToken = YouTubeCredentials & {
  accessToken: string;
  expiresAt: number;
};

export type YouTubeBrowserSession = {
  mode: "browser";
  headers: Record<string, string>;
  profileBacked?: boolean;
  refreshedAt?: number;
};

export type YouTubeDeviceCode = {
  deviceCode: string;
  userCode: string;
  verificationUri: string;
  expiresIn: number;
  interval: number;
};

let token: YouTubeToken | null = null;
let browserSession: YouTubeBrowserSession | null = null;
let refreshInFlight: Promise<string> | null = null;

type YouTubeBrowserProcess = {
  exited: Promise<number>;
  exitCode: number | null;
  kill: () => void;
};

export type YouTubeBrowserProfileOptions = {
  profileDirectory?: string;
  browserExecutable?: string;
  browserCandidates?: string[];
  now?: () => number;
  refreshIntervalMs?: number;
  selectBrowser?: (candidates: string[]) => string;
  reservePort?: (signal: AbortSignal) => Promise<number>;
  connect?: (url: string, signal: AbortSignal) => Promise<BrowserCdpTransport>;
  findPage?: (port: number, expectedHost: string, signal: AbortSignal) => Promise<string>;
  spawn?: (browser: string, args: string[]) => YouTubeBrowserProcess;
  capture?: (client: BrowserCdpTransport, signal: AbortSignal, reload: boolean) => Promise<Record<string, string>>;
};

export function youtubeProfileDirectory(
  platform: string = process.platform,
  environment: Record<string, string | undefined> = process.env,
  home = homedir(),
): string {
  const pathApi = platform === "win32" ? win32 : posix;
  const configured = environment.COLORFUL_YOUTUBE_PROFILE_DIR?.trim();
  if (configured) return pathApi.resolve(configured);
  const dataRoot = environment.COLORFUL_DATA_DIR?.trim();
  if (dataRoot) return pathApi.resolve(dataRoot, "youtube-browser");
  const root = platform === "win32"
    ? pathApi.join(environment.LOCALAPPDATA || environment.APPDATA || pathApi.join(home, "AppData", "Local"), "colorful")
    : platform === "darwin"
      ? pathApi.join(home, "Library", "Application Support", "colorful")
      : pathApi.join(environment.XDG_DATA_HOME || pathApi.join(home, ".local", "share"), "colorful");
  return pathApi.resolve(root, "youtube-browser");
}

export function ensureYouTubeProfileDirectory(directory: string): string {
  const profile = resolve(directory);
  mkdirSync(profile, { recursive: true, mode: 0o700 });
  if (process.platform !== "win32") {
    try { chmodSync(profile, 0o700); } catch { /* browser reports actionable failures */ }
  }
  return profile;
}

function spawnYouTubeBrowser(browser: string, args: string[]): YouTubeBrowserProcess {
  return Bun.spawn({
    cmd: [browser, ...args],
    stdin: "ignore",
    stdout: "ignore",
    stderr: "ignore",
    windowsHide: args.includes("--headless=new"),
  });
}

async function captureYouTubeHeaders(
  client: BrowserCdpTransport,
  signal: AbortSignal,
  reload: boolean,
): Promise<Record<string, string>> {
  const capture = await captureBrowserRequest(client, "youtube", signal, reload);
  if (capture.provider !== "youtube") throw new Error("YouTube Music browser returned the wrong account capture");
  return capture.headers;
}

function browserAbortError(): Error {
  return new Error("YouTube Music browser session cancelled");
}

/**
 * Own the durable YouTube Music Chromium profile. Requests still run natively;
 * this hidden page exists only to rotate the cookie-backed browser session.
 */
export class YouTubeBrowserProfileSession {
  readonly profileDirectory: string;
  private readonly linkedMarker: string;
  private readonly options: YouTubeBrowserProfileOptions;
  private readonly now: () => number;
  private readonly refreshIntervalMs: number;
  private browser: YouTubeBrowserProcess | null = null;
  private client: BrowserCdpTransport | null = null;
  private clientHeadless = false;
  private cachedHeaders: Record<string, string> | null = null;
  private refreshedAt = 0;
  private lastRefreshAttempt = 0;
  private lastRefreshFailedAt = 0;
  private refreshJob: Promise<Record<string, string>> | null = null;
  private generation = 0;
  private readonly exitHandler = (): void => {
    if (this.browser && this.browser.exitCode === null) this.browser.kill();
  };

  constructor(options: YouTubeBrowserProfileOptions = {}) {
    this.options = options;
    this.now = options.now ?? (() => Date.now());
    this.refreshIntervalMs = options.refreshIntervalMs ?? BROWSER_REFRESH_INTERVAL_MS;
    this.profileDirectory = ensureYouTubeProfileDirectory(
      options.profileDirectory ?? youtubeProfileDirectory(),
    );
    this.linkedMarker = join(this.profileDirectory, ".colorful-linked");
    process.once("exit", this.exitHandler);
  }

  get linked(): boolean {
    return existsSync(this.linkedMarker) && this.cachedHeaders !== null;
  }

  hydrate(headers: Record<string, string>, refreshedAt = 0): void {
    this.cachedHeaders = { ...headers };
    this.refreshedAt = refreshedAt;
    this.lastRefreshAttempt = 0;
    this.lastRefreshFailedAt = 0;
  }

  async headers(
    force = false,
    signal: AbortSignal = new AbortController().signal,
  ): Promise<Record<string, string>> {
    if (!existsSync(this.linkedMarker)) throw new Error("Reconnect your YouTube Music browser session");
    if (this.refreshJob) return this.refreshJob;
    if (this.cachedHeaders && this.lastRefreshFailedAt > 0
        && this.lastRefreshFailedAt + this.refreshIntervalMs > this.now()) {
      return { ...this.cachedHeaders };
    }
    if (!force && this.cachedHeaders
        && Math.max(this.refreshedAt, this.lastRefreshAttempt) + this.refreshIntervalMs > this.now()) {
      return { ...this.cachedHeaders };
    }
    const generation = this.generation;
    this.lastRefreshAttempt = this.now();
    this.refreshJob = this.refreshFromBrowser(signal).then((headers) => {
      if (generation !== this.generation) throw browserAbortError();
      this.cachedHeaders = { ...headers };
      this.refreshedAt = this.now();
      this.lastRefreshFailedAt = 0;
      return { ...headers };
    }).catch((error) => {
      if (generation === this.generation) this.lastRefreshFailedAt = this.now();
      throw error;
    }).finally(() => {
      this.refreshJob = null;
    });
    return this.refreshJob;
  }

  async authenticate(
    signal: AbortSignal,
    progress: (status: string) => void = () => undefined,
  ): Promise<Record<string, string>> {
    this.generation += 1;
    this.cachedHeaders = null;
    this.refreshedAt = 0;
    this.lastRefreshAttempt = 0;
    this.lastRefreshFailedAt = 0;
    try {
      const client = await this.ensureBrowser(false, signal);
      progress("Sign in to YouTube Music, choose your profile, then open Library.");
      const timeout = AbortSignal.timeout(BROWSER_LOGIN_TIMEOUT_MS);
      const headers = await (this.options.capture ?? captureYouTubeHeaders)(
        client, AbortSignal.any([signal, timeout]), true,
      );
      this.cachedHeaders = { ...headers };
      this.refreshedAt = this.now();
      this.lastRefreshAttempt = this.refreshedAt;
      writeFileSync(this.linkedMarker, "1\n", { mode: 0o600 });
      await this.closeBrowser();
      await this.ensureBrowser(true, signal);
      progress("YouTube Music account connected. Background session refresh is ready.");
      return { ...headers };
    } finally {
      if (!this.cachedHeaders && !this.clientHeadless) await this.closeBrowser();
    }
  }

  async restore(signal: AbortSignal = new AbortController().signal): Promise<Record<string, string> | null> {
    if (!existsSync(this.linkedMarker)) return null;
    try {
      return await this.headers(true, signal);
    } catch (error) {
      debugLog("youtube.auth", "hidden_restore_failed", {
        error: error instanceof Error ? error.message : String(error),
      });
      await this.closeBrowser();
      return null;
    }
  }

  async clear(): Promise<void> {
    this.generation += 1;
    this.cachedHeaders = null;
    this.refreshedAt = 0;
    this.lastRefreshAttempt = 0;
    this.lastRefreshFailedAt = 0;
    const hadBrowserState = existsSync(this.linkedMarker) || this.client !== null || this.browser !== null;
    try { unlinkSync(this.linkedMarker); } catch { /* already disconnected */ }
    try {
      if (!hadBrowserState) return;
      const client = this.client ?? await this.ensureBrowser(true, AbortSignal.timeout(BROWSER_START_TIMEOUT_MS));
      await client.command("Network.clearBrowserCookies").catch(() => undefined);
      for (const origin of [YOUTUBE_MUSIC_ORIGIN, "https://www.youtube.com", "https://accounts.google.com"]) {
        await client.command("Storage.clearDataForOrigin", { origin, storageTypes: "all" }).catch(() => undefined);
      }
    } catch { /* profile may be unavailable; the marker still prevents restore */ }
    finally { await this.closeBrowser(); }
  }

  async suspend(): Promise<void> {
    this.generation += 1;
    this.cachedHeaders = null;
    this.refreshedAt = 0;
    this.lastRefreshAttempt = 0;
    this.lastRefreshFailedAt = 0;
    await this.closeBrowser();
  }

  async close(): Promise<void> {
    await this.closeBrowser();
    process.removeListener("exit", this.exitHandler);
  }

  private selectBrowser(): string {
    if (this.options.browserExecutable?.trim()) return resolve(this.options.browserExecutable);
    const candidates = this.options.browserCandidates ?? browserExecutableCandidates();
    return (this.options.selectBrowser ?? ((values) => selectBrowserExecutable("youtube", values)))(candidates);
  }

  private async ensureBrowser(headless: boolean, signal: AbortSignal): Promise<BrowserCdpTransport> {
    if (this.client && this.clientHeadless === headless) return this.client;
    if (this.browser || this.client) await this.closeBrowser();
    if (signal.aborted) throw browserAbortError();
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
    args.push(YOUTUBE_MUSIC_LIBRARY_URL);
    const process = (this.options.spawn ?? spawnYouTubeBrowser)(browser, args);
    this.browser = process;
    this.clientHeadless = headless;
    void process.exited.then(() => {
      if (this.browser === process) this.browser = null;
    });
    debugLog("youtube.auth", "browser_started", {
      browser: basename(browser),
      headless,
      profile: basename(this.profileDirectory),
    });
    const target = await (this.options.findPage ?? pageTarget)(
      port, new URL(YOUTUBE_MUSIC_LIBRARY_URL).hostname, signal,
    );
    const client = await (this.options.connect ?? CdpClient.connect)(target, signal);
    client.onClose(() => {
      if (this.client === client) this.client = null;
    });
    this.client = client;
    return client;
  }

  private async refreshFromBrowser(signal: AbortSignal): Promise<Record<string, string>> {
    const client = await this.ensureBrowser(true, signal);
    const timeout = AbortSignal.timeout(BROWSER_START_TIMEOUT_MS);
    return (this.options.capture ?? captureYouTubeHeaders)(
      client, AbortSignal.any([signal, timeout]), true,
    );
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

const youtubeBrowserProfile = new YouTubeBrowserProfileSession();

function form(values: Record<string, string>): URLSearchParams {
  return new URLSearchParams(values);
}

async function oauthPost(url: string, values: Record<string, string>): Promise<Record<string, unknown>> {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", "User-Agent": USER_AGENT },
    body: form(values),
  });
  const document = await response.json().catch(() => ({})) as Record<string, unknown>;
  if (!response.ok && !document.error) throw new Error(`Google OAuth returned HTTP ${response.status}`);
  return document;
}

function oauthError(document: Record<string, unknown>): string {
  return String(document.error_description ?? document.error ?? "Google OAuth rejected the request");
}

export async function startYouTubeDeviceAuth(clientId: string, clientSecret: string): Promise<YouTubeDeviceCode> {
  const id = clientId.trim();
  const secret = clientSecret.trim();
  if (!id || !secret) throw new Error("Enter your Google OAuth client ID and client secret");
  const document = await oauthPost(CODE_URL, { client_id: id, scope: SCOPE });
  if (document.error) throw new Error(oauthError(document));
  const deviceCode = String(document.device_code ?? "");
  const userCode = String(document.user_code ?? "");
  const verificationUri = String(document.verification_url ?? document.verification_uri ?? "");
  if (!deviceCode || !userCode || !verificationUri) throw new Error("Google returned an incomplete device authorization challenge");
  pendingCredentials = { clientId: id, clientSecret: secret };
  return {
    deviceCode,
    userCode,
    verificationUri,
    expiresIn: Number(document.expires_in ?? 900),
    interval: Number(document.interval ?? 5),
  };
}

let pendingCredentials: Pick<YouTubeCredentials, "clientId" | "clientSecret"> | null = null;

export async function pollYouTubeDeviceAuth(code: YouTubeDeviceCode, signal: AbortSignal): Promise<YouTubeToken> {
  if (!pendingCredentials) throw new Error("YouTube Music OAuth credentials were not initialized");
  const credentials = pendingCredentials;
  const deadline = Date.now() + code.expiresIn * 1000;
  let delay = Math.max(1, code.interval) * 1000;
  while (Date.now() < deadline) {
    if (signal.aborted) throw new Error("YouTube Music authorization cancelled");
    await new Promise<void>((resolve, reject) => {
      const aborted = () => {
        clearTimeout(timer);
        reject(new Error("YouTube Music authorization cancelled"));
      };
      const timer = setTimeout(() => {
        signal.removeEventListener("abort", aborted);
        resolve();
      }, delay);
      signal.addEventListener("abort", aborted, { once: true });
    });
    const document = await oauthPost(TOKEN_URL, {
      client_id: credentials.clientId,
      client_secret: credentials.clientSecret,
      code: code.deviceCode,
      grant_type: "http://oauth.net/grant_type/device/1.0",
    });
    const error = String(document.error ?? "");
    if (error === "authorization_pending") continue;
    if (error === "slow_down") { delay += 5_000; continue; }
    if (error) throw new Error(oauthError(document));
    const accessToken = String(document.access_token ?? "");
    const refreshToken = String(document.refresh_token ?? "");
    if (!accessToken || !refreshToken) throw new Error("Google did not return a refreshable YouTube token");
    token = {
      ...credentials,
      accessToken,
      refreshToken,
      expiresAt: Date.now() + Number(document.expires_in ?? 3600) * 1000,
    };
    pendingCredentials = null;
    if (!await persistYouTubeCredentials(token)) throw new Error("Could not store the YouTube Music account in Secret Service");
    return token;
  }
  throw new Error("YouTube Music authorization expired");
}

async function persistYouTubeCredentials(credentials: YouTubeCredentials): Promise<boolean> {
  return saveProviderSecret("youtube", "colorful YouTube Music account", JSON.stringify({
    clientId: credentials.clientId,
    clientSecret: credentials.clientSecret,
    refreshToken: credentials.refreshToken,
  }));
}

export function parseYouTubeBrowserHeaders(raw: string): Record<string, string> {
  const headers: Record<string, string> = {};
  // Chromium always exposes "Copy as cURL", even in builds that omit
  // "Copy request headers". Read its -H/--header and -b/--cookie arguments.
  const shellArgument = String.raw`(?:'([^']*)'|"((?:\\.|[^"])*)"|([^\s\\]+))`;
  const decodeArgument = (match: RegExpMatchArray): string =>
    (match[1] ?? match[2]?.replace(/\\"/g, '"').replace(/\\\\/g, "\\") ?? match[3] ?? "").trim();
  for (const match of raw.matchAll(new RegExp(String.raw`(?:^|\s)(?:-H|--header)\s+${shellArgument}`, "g"))) {
    const header = decodeArgument(match);
    const colon = header.indexOf(":");
    if (colon > 0) headers[header.slice(0, colon).trim().toLowerCase()] = header.slice(colon + 1).trim();
  }
  for (const match of raw.matchAll(new RegExp(String.raw`(?:^|\s)(?:-b|--cookie)\s+${shellArgument}`, "g"))) {
    const cookie = decodeArgument(match);
    if (cookie) headers.cookie = cookie;
  }
  if (Object.keys(headers).length > 0) return headers;

  const lines = raw.replace(/\r/g, "").split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]?.trim() ?? "";
    if (!line || line.startsWith(":")) continue;
    const colon = line.indexOf(":");
    if (colon > 0) {
      const value = line.slice(colon + 1).trim();
      if (value) headers[line.slice(0, colon).trim().toLowerCase()] = value;
      continue;
    }
    const next = lines[index + 1]?.trim() ?? "";
    if (next && !next.includes(":")) {
      headers[line.toLowerCase()] = next;
      index += 1;
    }
  }
  return headers;
}

export async function connectYouTubeBrowser(raw: string): Promise<void> {
  await connectYouTubeBrowserHeaders(parseYouTubeBrowserHeaders(raw.trim()));
}

function normalizedYouTubeBrowserHeaders(input: Record<string, string>): Record<string, string> {
  const parsed = Object.fromEntries(Object.entries(input)
    .map(([name, value]) => [name.trim().toLowerCase(), value.trim()])
    .filter(([name, value]) => Boolean(name && value)));
  if (!parsed.cookie) throw new Error("The copied request is missing its Cookie header");
  if (!parsed["x-goog-authuser"]) throw new Error("The copied request is missing X-Goog-AuthUser; copy a logged-in /browse request");
  if (!/(?:^|;\s*)__Secure-3PAPISID=/.test(parsed.cookie))
    throw new Error("The copied Cookie header is missing __Secure-3PAPISID");
  return selectYouTubeBrowserHeaders(parsed);
}

async function persistYouTubeBrowserSession(session: YouTubeBrowserSession): Promise<boolean> {
  return saveProviderSecret(
    "youtube",
    session.profileBacked
      ? "colorful YouTube Music refreshable browser session"
      : "colorful YouTube Music browser session",
    JSON.stringify(session),
  );
}

export async function connectYouTubeBrowserHeaders(input: Record<string, string>): Promise<void> {
  const headers = normalizedYouTubeBrowserHeaders(input);
  await youtubeBrowserProfile.clear();
  browserSession = { mode: "browser", headers, profileBacked: false, refreshedAt: Date.now() };
  token = null;
  if (!await persistYouTubeBrowserSession(browserSession)) {
    browserSession = null;
    throw new Error("Could not store the YouTube Music session in Secret Service");
  }
}

export async function connectYouTubeBrowserProfile(
  signal: AbortSignal,
  progress: (status: string) => void = () => undefined,
): Promise<void> {
  const headers = normalizedYouTubeBrowserHeaders(
    await youtubeBrowserProfile.authenticate(signal, progress),
  );
  browserSession = {
    mode: "browser",
    headers,
    profileBacked: true,
    refreshedAt: Date.now(),
  };
  youtubeBrowserProfile.hydrate(headers, browserSession.refreshedAt);
  token = null;
  if (!await persistYouTubeBrowserSession(browserSession)) {
    browserSession = null;
    await youtubeBrowserProfile.clear();
    throw new Error("Could not store the refreshable YouTube Music session in Secret Service");
  }
}

export function selectYouTubeBrowserHeaders(parsed: Record<string, string>): Record<string, string> {
  // X-Goog-PageId selects the active YouTube channel/brand account. Dropping it
  // leaves the cookies authenticated but silently changes private-library
  // requests to the Google account's default identity.
  const exact = new Set(["cookie", "user-agent", "accept-language"]);
  return Object.fromEntries(Object.entries(parsed).filter(([name, value]) =>
    Boolean(value) && (exact.has(name) || name.startsWith("x-goog-") || name.startsWith("x-youtube-"))));
}

async function refresh(credentials: YouTubeCredentials): Promise<YouTubeToken> {
  const document = await oauthPost(TOKEN_URL, {
    client_id: credentials.clientId,
    client_secret: credentials.clientSecret,
    refresh_token: credentials.refreshToken,
    grant_type: "refresh_token",
  });
  if (document.error) throw new Error(oauthError(document));
  const accessToken = String(document.access_token ?? "");
  if (!accessToken) throw new Error("Google did not return a YouTube access token");
  return {
    ...credentials,
    accessToken,
    expiresAt: Date.now() + Number(document.expires_in ?? 3600) * 1000,
  };
}

export async function restoreYouTubeAuth(): Promise<boolean> {
  const raw = await loadProviderSecret("youtube");
  if (!raw) return false;
  try {
    const stored = JSON.parse(raw) as Partial<YouTubeCredentials & YouTubeBrowserSession>;
    if (stored.mode === "browser" && stored.headers?.cookie && stored.headers["x-goog-authuser"]) {
      const headers = normalizedYouTubeBrowserHeaders(stored.headers);
      browserSession = {
        mode: "browser",
        headers,
        profileBacked: stored.profileBacked === true,
        refreshedAt: Number(stored.refreshedAt) || 0,
      };
      token = null;
      if (browserSession.profileBacked) {
        youtubeBrowserProfile.hydrate(headers, browserSession.refreshedAt);
        const fresh = await youtubeBrowserProfile.restore();
        if (fresh) {
          browserSession = {
            mode: "browser",
            headers: normalizedYouTubeBrowserHeaders(fresh),
            profileBacked: true,
            refreshedAt: Date.now(),
          };
          youtubeBrowserProfile.hydrate(browserSession.headers, browserSession.refreshedAt);
          await persistYouTubeBrowserSession(browserSession);
        } else if (!youtubeBrowserProfile.linked) {
          // The credential record survived but its app-owned browser profile
          // did not. Keep the last captured headers as the legacy static
          // fallback and require a reconnect before promising silent refresh.
          browserSession.profileBacked = false;
          await persistYouTubeBrowserSession(browserSession);
        }
      }
      return true;
    }
    const credentials = stored;
    if (!credentials.clientId || !credentials.clientSecret || !credentials.refreshToken) return false;
    // Google still refreshes legacy OAuth tokens, but YouTube Music's private
    // Innertube endpoints reject them. Prompt for a browser session instead.
    token = null;
    return false;
  } catch {
    token = null;
    return false;
  }
}

export async function youtubeAccessToken(): Promise<string> {
  if (!token) throw new Error("Connect your YouTube Music account first");
  if (token.expiresAt - Date.now() >= 60_000) return token.accessToken;
  if (!refreshInFlight) {
    refreshInFlight = refresh(token).then(async (next) => {
      token = next;
      await persistYouTubeCredentials(next);
      return next.accessToken;
    }).finally(() => { refreshInFlight = null; });
  }
  return refreshInFlight;
}

export function youtubeLinked(): boolean { return browserSession !== null; }

export async function youtubeBrowserHeaders(force = false): Promise<Record<string, string>> {
  if (!browserSession) throw new Error("Connect your YouTube Music browser session first");
  if (browserSession.profileBacked) {
    try {
      const headers = normalizedYouTubeBrowserHeaders(await youtubeBrowserProfile.headers(force));
      if (headers.cookie !== browserSession.headers.cookie || force) {
        browserSession = {
          mode: "browser",
          headers,
          profileBacked: true,
          refreshedAt: Date.now(),
        };
        await persistYouTubeBrowserSession(browserSession);
      }
    } catch (error) {
      // A transient CDP/browser failure must not turn every catalog request
      // into another process launch. The profile manager backs off and the
      // last verified cookie header remains available for native requests.
      debugLog("youtube.auth", "hidden_refresh_failed", {
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
  return { ...browserSession.headers };
}

export async function clearYouTubeAuth(): Promise<void> {
  token = null;
  browserSession = null;
  pendingCredentials = null;
  await youtubeBrowserProfile.clear();
  await clearProviderSecret("youtube");
}

/** Drop runtime state after failed startup validation but retain the durable profile for retry. */
export async function suspendYouTubeAuth(): Promise<void> {
  token = null;
  browserSession = null;
  pendingCredentials = null;
  await youtubeBrowserProfile.suspend();
}

export async function closeYouTubeAuth(): Promise<void> {
  await youtubeBrowserProfile.close();
}
