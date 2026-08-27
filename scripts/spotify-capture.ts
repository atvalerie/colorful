/**
 * Local-only Spotify Web Player request capture helper.
 *
 * This is intentionally a development aid, not part of the provider host.
 * It records Pathfinder/API request shapes and JSON responses while a user
 * operates an isolated visible Spotify browser profile. Authorization,
 * cookies, and client-token values are never written to the capture file.
 *
 * Run with:
 *   bun scripts/spotify-capture.ts
 *
 * Set COLORFUL_SPOTIFY_CAPTURE_PROFILE/FILE to choose persistent paths.
 */
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  availableLoopbackPort,
  browserExecutableCandidates,
  CdpClient,
  pageTarget,
  selectChromiumExecutable,
} from "../packages/provider-host/src/browser-login";

const spotifyOrigin = "https://open.spotify.com";
const captureRoot = process.env.COLORFUL_DATA_DIR?.trim()
  || join(process.env.LOCALAPPDATA?.trim() || join(homedir(), "AppData", "Local"), "colorful");
const profileDirectory = resolve(process.env.COLORFUL_SPOTIFY_CAPTURE_PROFILE?.trim()
  || join(captureRoot, "spotify-capture"));
const outputPath = resolve(process.env.COLORFUL_SPOTIFY_CAPTURE_FILE?.trim()
  || join(captureRoot, "spotify-capture.jsonl"));
const startUrl = process.env.COLORFUL_SPOTIFY_CAPTURE_URL?.trim() || spotifyOrigin;
const durationMs = Number(process.env.COLORFUL_SPOTIFY_CAPTURE_DURATION_MS || 0);

type Json = Record<string, unknown>;

function object(value: unknown): Json {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Json : {};
}

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function interesting(rawUrl: string): boolean {
  try {
    const url = new URL(rawUrl);
    if (url.protocol !== "https:") return false;
    if (url.hostname === "api-partner.spotify.com") return url.pathname.startsWith("/pathfinder/");
    if (url.hostname === "api.spotify.com") return url.pathname.startsWith("/v1/");
    return url.hostname.endsWith(".spotify.com")
      && /(?:^|\.)spclient\./i.test(url.hostname);
  } catch {
    return false;
  }
}

function safeUrl(rawUrl: string): string {
  try {
    const url = new URL(rawUrl);
    // Query strings can contain search text and operation hashes, which are
    // useful for reproducing requests; never preserve token-like parameters.
    for (const key of [...url.searchParams.keys()]) {
      if (/token|auth|cookie|secret/i.test(key)) url.searchParams.set(key, "[redacted]");
    }
    return url.toString();
  } catch {
    return "[invalid-url]";
  }
}

function safeHeaders(value: unknown): Json {
  const headers = object(value);
  const result: Json = {};
  for (const [name, raw] of Object.entries(headers)) {
    const normalized = name.toLowerCase();
    if (["authorization", "cookie", "set-cookie", "client-token", "x-client-token"].includes(normalized)) {
      result[normalized] = "[redacted]";
      continue;
    }
    if (typeof raw === "string") result[normalized] = raw;
  }
  return result;
}

function safeBody(value: string): string {
  return value
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, "Bearer [redacted]")
    .replace(/(["'](?:access[_-]?token|client[_-]?token|cookie|secret)["']\s*:\s*["'])[^"']+/gi, "$1[redacted]")
    .slice(0, 200_000);
}

function writeRecord(record: Json): void {
  appendFileSync(outputPath, `${JSON.stringify({ at: new Date().toISOString(), ...record })}\n`, { mode: 0o600 });
}

async function main(): Promise<void> {
  mkdirSync(profileDirectory, { recursive: true, mode: 0o700 });
  mkdirSync(resolve(outputPath, ".."), { recursive: true, mode: 0o700 });
  const browser = selectChromiumExecutable(browserExecutableCandidates());
  const controller = new AbortController();
  const port = await availableLoopbackPort(controller.signal);
  const browserProcess = Bun.spawn({
    cmd: [
      browser,
      `--user-data-dir=${profileDirectory}`,
      "--remote-debugging-address=127.0.0.1",
      `--remote-debugging-port=${port}`,
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-background-mode",
      "--disable-sync",
      "--disable-extensions",
      "--new-window",
      startUrl,
    ],
    stdin: "ignore",
    stdout: "ignore",
    stderr: "ignore",
    windowsHide: false,
  });
  let client: CdpClient | null = null;
  const requests = new Map<string, { url: string; method: string; postData: string }>();
  const jsonResponses = new Set<string>();
  try {
    const target = await pageTarget(port, "open.spotify.com", controller.signal);
    client = await CdpClient.connect(target, controller.signal);
    client.onMessage((message) => {
      const params = object(message.params);
      const requestId = text(params.requestId);
      if (!requestId) return;
      if (message.method === "Network.requestWillBeSent") {
        const request = object(params.request);
        const url = text(request.url);
        if (!interesting(url)) return;
        const postData = safeBody(text(request.postData));
        requests.set(requestId, { url, method: text(request.method) || "GET", postData });
        writeRecord({
          kind: "request",
          url: safeUrl(url),
          method: text(request.method) || "GET",
          headers: safeHeaders(request.headers),
          postData: postData || undefined,
        });
      } else if (message.method === "Network.responseReceived") {
        const response = object(params.response);
        const url = text(response.url);
        if (!interesting(url)) return;
        const mimeType = text(response.mimeType).toLowerCase();
        if (mimeType.includes("json") || url.includes("pathfinder")) jsonResponses.add(requestId);
        writeRecord({
          kind: "response",
          url: safeUrl(url),
          status: Number(response.status) || 0,
          mimeType: mimeType || undefined,
        });
      } else if (message.method === "Network.loadingFinished" && jsonResponses.delete(requestId)) {
        void client?.command("Network.getResponseBody", { requestId }).then((value) => {
          const body = object(value);
          const textBody = safeBody(text(body.body));
          if (textBody) writeRecord({
            kind: "response-body",
            request: requests.get(requestId)?.url ? safeUrl(requests.get(requestId)!.url) : undefined,
            base64Encoded: body.base64Encoded === true,
            body: textBody,
          });
        }).catch(() => undefined);
      }
    });
    await client.command("Network.enable", { maxTotalBufferSize: 16_777_216, maxResourceBufferSize: 8_388_608 });
    await client.command("Page.enable");
    if (startUrl !== spotifyOrigin) {
      await client.command("Page.navigate", { url: startUrl });
    }
    console.log(`Spotify capture browser is ready. Sign in and perform Search, Library, album, and playlist actions.`);
    console.log(`Capture file: ${outputPath}`);
      await new Promise<void>((resolveWait) => {
        const stop = () => { controller.abort(); resolveWait(); };
        process.once("SIGINT", stop);
        process.once("SIGTERM", stop);
        void browserProcess.exited.then(stop);
        if (durationMs > 0) setTimeout(stop, durationMs);
      });
  } finally {
    controller.abort();
    if (client) {
      await client.command("Browser.close").catch(() => undefined);
      client.close();
    }
    await Promise.race([browserProcess.exited, new Promise<void>((resolveWait) => setTimeout(resolveWait, 1_000))]);
    if (browserProcess.exitCode === null) browserProcess.kill();
  }
}

void main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
