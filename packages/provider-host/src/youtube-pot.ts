import { BotGuardClient } from "bgutils-js/botguard";
import { WebPoMinter } from "bgutils-js/webpo";
import { buildURL, getHeaders, USER_AGENT } from "bgutils-js/utils";
import type { IntegrityTokenData, WebPoSignalOutput } from "bgutils-js/shared-types";
import { JSDOM, VirtualConsole } from "jsdom";
import { debugLog } from "./debug";
import { parseYouTubeMusicBootstrap } from "./youtube-music";

type JsonObject = Record<string, unknown>;
type MinterState = {
  client: BotGuardClient;
  minter: WebPoMinter;
  expiresAt: number;
  contextKey: string;
};

const PLAYER_ORIGIN = "https://www.youtube.com";
const INTEGRITY_REQUEST_KEY = "O43z0dpjhgX20SCx4KAo";
const REQUEST_TIMEOUT_MS = 15_000;
const TOKEN_CACHE_MS = 6 * 60 * 60 * 1_000;

let domInitialized = false;
let minterState: MinterState | null = null;
let minterPromise: Promise<MinterState> | null = null;
let attestationContextPromise: Promise<JsonObject> | null = null;
const tokenCache = new Map<string, { token: string; expiresAt: number }>();

function object(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonObject : {};
}

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function ensureDom(): void {
  if (domInitialized) return;
  const virtualConsole = new VirtualConsole();
  const dom = new JSDOM("<!doctype html><html lang=\"en\"><head></head><body></body></html>", {
    url: `${PLAYER_ORIGIN}/`,
    referrer: `${PLAYER_ORIGIN}/`,
    virtualConsole,
  });
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    location: dom.window.location,
    origin: dom.window.origin,
  });
  if (!Reflect.has(globalThis, "navigator")) {
    Object.defineProperty(globalThis, "navigator", { value: dom.window.navigator });
  }
  domInitialized = true;
}

async function responseJson(response: Response, operation: string): Promise<unknown> {
  const document: unknown = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = text(object(object(document).error).message);
    throw new Error(`${operation} returned HTTP ${response.status}${message ? `: ${message}` : ""}`);
  }
  return document;
}

async function nativeAttestationContext(refresh: boolean): Promise<JsonObject> {
  if (refresh) attestationContextPromise = null;
  if (!attestationContextPromise) {
    attestationContextPromise = (async () => {
      const response = await fetch(`${PLAYER_ORIGIN}/`, {
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        headers: { "User-Agent": USER_AGENT },
      });
      if (!response.ok) throw new Error(`YouTube WEB bootstrap returned HTTP ${response.status}`);
      const config = parseYouTubeMusicBootstrap(await response.text());
      const client = object(object(config.INNERTUBE_CONTEXT).client);
      const clientName = text(client.clientName);
      const clientVersion = text(client.clientVersion) || text(config.INNERTUBE_CLIENT_VERSION);
      if (clientName !== "WEB" || !clientVersion) {
        throw new Error("YouTube WEB bootstrap did not contain a native attestation client version");
      }
      // Browser EACR challenges are bound to that page's browser environment.
      // Native clients use the maintained unbound challenge flow with only the
      // current WEB client identity, then bind the resulting GVS POT separately.
      return { client: { clientName, clientVersion } };
    })().catch((error) => {
      attestationContextPromise = null;
      throw error;
    });
  }
  return attestationContextPromise;
}

async function createMinter(
  innertubeContext: JsonObject,
  contextKey: string,
): Promise<MinterState> {
  const startedAt = Date.now();
  ensureDom();
  const challengeResponse = await fetch(`${PLAYER_ORIGIN}/youtubei/v1/att/get?prettyPrint=false`, {
    method: "POST",
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    headers: {
      "Content-Type": "application/json",
      "User-Agent": USER_AGENT,
      Origin: PLAYER_ORIGIN,
    },
    body: JSON.stringify({
      context: innertubeContext,
      engagementType: "ENGAGEMENT_TYPE_UNBOUND",
    }),
  });
  const challengeDocument = object(await responseJson(challengeResponse, "YouTube attestation challenge"));
  const challenge = object(challengeDocument.bgChallenge);
  const program = text(challenge.program);
  const globalName = text(challenge.globalName);
  const interpreterPath = text(object(challenge.interpreterUrl)
    .privateDoNotAccessOrElseTrustedResourceUrlWrappedValue);
  const interpreterUrl = new URL(interpreterPath, PLAYER_ORIGIN);
  const trustedInterpreterHost = interpreterUrl.hostname === "youtube.com"
    || interpreterUrl.hostname.endsWith(".youtube.com")
    || interpreterUrl.hostname === "google.com"
    || interpreterUrl.hostname.endsWith(".google.com");
  if (!program || !globalName || interpreterUrl.protocol !== "https:"
      || !trustedInterpreterHost) {
    throw new Error("YouTube attestation returned an invalid BotGuard challenge");
  }

  const interpreterResponse = await fetch(interpreterUrl, {
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    headers: { "User-Agent": USER_AGENT },
  });
  if (!interpreterResponse.ok) {
    throw new Error(`YouTube BotGuard interpreter returned HTTP ${interpreterResponse.status}`);
  }
  const interpreter = await interpreterResponse.text();
  if (!interpreter.trim()) throw new Error("YouTube BotGuard interpreter was empty");
  new Function(interpreter)();

  const client = await BotGuardClient.create({ program, globalName, globalObject: globalThis });
  try {
    const webPoSignalOutput: WebPoSignalOutput = [];
    const snapshot = await client.snapshot({ webPoSignalOutput });
    const integrityResponse = await fetch(buildURL("GenerateIT"), {
      method: "POST",
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      headers: getHeaders(),
      body: JSON.stringify([INTEGRITY_REQUEST_KEY, snapshot]),
    });
    const values = await responseJson(integrityResponse, "YouTube integrity token");
    if (!Array.isArray(values)) throw new Error("YouTube integrity token response was invalid");
    const integrityToken = text(values[0]);
    const estimatedTtlSecs = Number(values[1]);
    const mintRefreshThreshold = Number(values[2]);
    const websafeFallbackToken = text(values[3]);
    if (!integrityToken || !Number.isFinite(estimatedTtlSecs) || estimatedTtlSecs <= 0) {
      throw new Error("YouTube integrity token response was incomplete");
    }
    const data: IntegrityTokenData = {
      integrityToken,
      estimatedTtlSecs,
      ...(Number.isFinite(mintRefreshThreshold) ? { mintRefreshThreshold } : {}),
      ...(websafeFallbackToken ? { websafeFallbackToken } : {}),
    };
    const state = {
      client,
      minter: await WebPoMinter.create(data, webPoSignalOutput),
      expiresAt: Date.now() + estimatedTtlSecs * 1_000,
      contextKey,
    };
    debugLog("youtube.pot", "minter_ready", {
      estimatedTtlSecs,
      elapsedMs: Date.now() - startedAt,
    });
    return state;
  } catch (error) {
    await client.shutdown().catch(() => undefined);
    throw error;
  }
}

async function minter(
  refresh: boolean,
): Promise<MinterState> {
  const innertubeContext = await nativeAttestationContext(refresh);
  const contextKey = JSON.stringify(innertubeContext);
  if (refresh) {
    tokenCache.clear();
    if (minterState) await minterState.client.shutdown().catch(() => undefined);
    minterState = null;
    minterPromise = null;
  }
  if (minterState && minterState.contextKey === contextKey
      && minterState.expiresAt > Date.now() + 60_000) return minterState;
  if (minterState && minterState.contextKey !== contextKey) {
    await minterState.client.shutdown().catch(() => undefined);
    minterState = null;
    minterPromise = null;
  }
  if (!minterPromise) {
    minterPromise = createMinter(innertubeContext, contextKey).then((state) => {
      minterState = state;
      return state;
    }).catch((error) => {
      minterPromise = null;
      throw error;
    });
  }
  return minterPromise;
}

export async function youtubePoToken(
  contentBinding: string,
  refresh = false,
): Promise<string> {
  if (!contentBinding.trim() || contentBinding.length > 2_048 || /[\u0000-\u001f\u007f]/.test(contentBinding)) {
    throw new Error("Invalid YouTube proof-of-origin content binding");
  }
  const tokenCacheKey = contentBinding;
  const cached = tokenCache.get(tokenCacheKey);
  if (!refresh && cached && cached.expiresAt > Date.now() + 60_000) return cached.token;
  const startedAt = Date.now();
  const state = await minter(refresh);
  const token = await state.minter.mintAsWebsafeString(contentBinding);
  if (!token) throw new Error("YouTube BotGuard returned an empty proof-of-origin token");
  tokenCache.set(tokenCacheKey, {
    token,
    expiresAt: Math.min(state.expiresAt, Date.now() + TOKEN_CACHE_MS),
  });
  debugLog("youtube.pot", "token_minted", {
    elapsedMs: Date.now() - startedAt,
  });
  return token;
}

export function applyYouTubePoToken(uri: string, poToken: string): string {
  const url = new URL(uri);
  if (url.protocol !== "https:") throw new Error("YouTube media URL must use HTTPS");
  url.searchParams.set("pot", poToken);
  return url.toString();
}
