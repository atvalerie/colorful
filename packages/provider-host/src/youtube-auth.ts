import { clearProviderSecret, loadProviderSecret, saveProviderSecret } from "./secret-store";

const CODE_URL = "https://www.youtube.com/o/oauth2/device/code";
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const SCOPE = "https://www.googleapis.com/auth/youtube";
const USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/140 Safari/537.36 Cobalt/Version";

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

function parseBrowserHeaders(raw: string): Record<string, string> {
  const headers: Record<string, string> = {};
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
  const parsed = parseBrowserHeaders(raw.trim());
  if (!parsed.cookie) throw new Error("The copied request is missing its Cookie header");
  if (!parsed["x-goog-authuser"]) throw new Error("The copied request is missing X-Goog-AuthUser; copy a logged-in /browse request");
  if (!/(?:^|;\s*)__Secure-3PAPISID=/.test(parsed.cookie))
    throw new Error("The copied Cookie header is missing __Secure-3PAPISID");
  const allowed = ["cookie", "x-goog-authuser", "user-agent", "accept-language", "x-goog-visitor-id"];
  const headers = Object.fromEntries(allowed.flatMap((name) => parsed[name] ? [[name, parsed[name]]] : []));
  browserSession = { mode: "browser", headers };
  token = null;
  if (!await saveProviderSecret("youtube", "colorful YouTube Music browser session", JSON.stringify(browserSession))) {
    browserSession = null;
    throw new Error("Could not store the YouTube Music session in Secret Service");
  }
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
      browserSession = { mode: "browser", headers: stored.headers };
      token = null;
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

export async function youtubeBrowserHeaders(): Promise<Record<string, string>> {
  if (!browserSession) throw new Error("Connect your YouTube Music browser session first");
  return { ...browserSession.headers };
}

export async function clearYouTubeAuth(): Promise<void> {
  token = null;
  browserSession = null;
  pendingCredentials = null;
  await clearProviderSecret("youtube");
}
