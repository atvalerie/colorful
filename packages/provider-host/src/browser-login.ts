import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { basename, join, posix, resolve, win32 } from "node:path";
import { debugLog } from "./debug";

export type BrowserLoginProvider = "youtube" | "soundcloud";

export type BrowserLoginCapture = {
  provider: "youtube";
  headers: Record<string, string>;
} | {
  provider: "soundcloud";
  token: string;
};

type CdpMessage = {
  id?: number;
  method?: string;
  params?: Record<string, unknown>;
  result?: unknown;
  error?: { message?: unknown };
};

type CdpTarget = {
  type?: unknown;
  url?: unknown;
  webSocketDebuggerUrl?: unknown;
};

const LOGIN_TIMEOUT_MS = 10 * 60 * 1_000;
const START_TIMEOUT_MS = 20_000;

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function object(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : {};
}

function normalizedHeaders(value: unknown): Record<string, string> {
  return Object.fromEntries(Object.entries(object(value))
    .map(([name, header]) => [name.toLowerCase(), typeof header === "string" ? header.trim() : String(header ?? "").trim()])
    .filter(([, header]) => Boolean(header)));
}

export function browserLoginCapture(
  provider: BrowserLoginProvider,
  requestUrl: string,
  headers: Record<string, string>,
): BrowserLoginCapture | null {
  let url: URL;
  try { url = new URL(requestUrl); } catch { return null; }
  const values = normalizedHeaders(headers);
  if (provider === "youtube") {
    if (url.hostname !== "music.youtube.com" || !url.pathname.startsWith("/youtubei/v1/browse")) return null;
    const cookie = values.cookie ?? "";
    if (!values["x-goog-authuser"] || !/(?:^|;\s*)__Secure-3PAPISID=/.test(cookie)) return null;
    const retained = new Set([
      "cookie", "user-agent", "accept-language", "x-goog-authuser", "x-goog-pageid",
      "x-goog-visitor-id", "x-youtube-client-name", "x-youtube-client-version",
      "x-youtube-bootstrap-logged-in", "x-youtube-identity-token",
    ]);
    return {
      provider,
      headers: Object.fromEntries(Object.entries(values).filter(([name]) => retained.has(name))),
    };
  }

  if ((url.hostname !== "api-v2.soundcloud.com" && url.hostname !== "api.soundcloud.com")
      || !/^\/me(?:\/|$)/.test(url.pathname)) return null;
  const authorization = values.authorization ?? "";
  const token = authorization.replace(/^oauth\s+/i, "").trim();
  return /^oauth\s+/i.test(authorization) && token ? { provider, token } : null;
}

export type BrowserPlatform = "win32" | "darwin" | "linux" | string;

export function browserExecutableCandidates(
  platform: BrowserPlatform = process.platform,
  environment: Record<string, string | undefined> = process.env,
  which: (command: string) => string | null = (command) => Bun.which(command),
): string[] {
  const candidatePath = platform === "win32" ? win32 : posix;
  const configured = environment.COLORFUL_BROWSER_EXECUTABLE?.trim();
  const values: string[] = configured ? [configured] : [];
  if (platform === "win32") {
    const programFiles = environment.ProgramFiles ?? "C:\\Program Files";
    const programFilesX86 = environment["ProgramFiles(x86)"] ?? "C:\\Program Files (x86)";
    const localAppData = environment.LOCALAPPDATA ?? "";
    values.push(
      ...(localAppData ? [
        candidatePath.join(localAppData, "imput", "Helium", "Application", "chrome.exe"),
        candidatePath.join(localAppData, "Helium", "Application", "chrome.exe"),
      ] : []),
      candidatePath.join(programFiles, "Google", "Chrome", "Application", "chrome.exe"),
      candidatePath.join(programFilesX86, "Google", "Chrome", "Application", "chrome.exe"),
      candidatePath.join(programFiles, "Microsoft", "Edge", "Application", "msedge.exe"),
      candidatePath.join(programFilesX86, "Microsoft", "Edge", "Application", "msedge.exe"),
      candidatePath.join(programFiles, "BraveSoftware", "Brave-Browser", "Application", "brave.exe"),
      candidatePath.join(programFilesX86, "BraveSoftware", "Brave-Browser", "Application", "brave.exe"),
      candidatePath.join(programFiles, "Vivaldi", "Application", "vivaldi.exe"),
      candidatePath.join(programFilesX86, "Vivaldi", "Application", "vivaldi.exe"),
      ...(localAppData ? [
        candidatePath.join(localAppData, "Google", "Chrome", "Application", "chrome.exe"),
        candidatePath.join(localAppData, "Microsoft", "Edge", "Application", "msedge.exe"),
        candidatePath.join(localAppData, "BraveSoftware", "Brave-Browser", "Application", "brave.exe"),
        candidatePath.join(localAppData, "Vivaldi", "Application", "vivaldi.exe"),
        candidatePath.join(localAppData, "Chromium", "Application", "chrome.exe"),
        candidatePath.join(localAppData, "Programs", "Opera", "opera.exe"),
        candidatePath.join(localAppData, "Programs", "Opera GX", "opera.exe"),
      ] : []),
    );
  } else if (platform === "darwin") {
    values.push(
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
      "/Applications/Chromium.app/Contents/MacOS/Chromium",
      "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
      "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi",
      "/Applications/Opera.app/Contents/MacOS/Opera",
      "/Applications/Helium.app/Contents/MacOS/Helium",
    );
  }
  const commands = platform === "win32" ? [
    "chrome.exe", "msedge.exe", "brave.exe", "vivaldi.exe", "chromium.exe",
  ] : [
    "google-chrome-stable", "google-chrome", "microsoft-edge-stable", "microsoft-edge",
    "chromium", "chromium-browser", "brave-browser", "brave-browser-stable",
    "vivaldi", "vivaldi-stable", "opera", "helium", "helium-browser",
  ];
  for (const command of commands) {
    const found = which(command);
    if (found) values.push(found);
  }
  return [...new Set(values.map((value) => candidatePath.resolve(value)))];
}

/** Select the first installed Chromium-family browser from a candidate list. */
export function selectChromiumExecutable(
  candidates: string[],
  exists: (path: string) => boolean = existsSync,
): string {
  const browser = candidates.find(exists);
  if (!browser) {
    throw new Error("Could not find a Chromium-based browser. Install Chrome, Edge, Chromium, Brave, Vivaldi, or Opera; set COLORFUL_BROWSER_EXECUTABLE; or use the manual session field.");
  }
  return browser;
}

function isHeliumBrowser(browser: string): boolean {
  return /[\\/]Helium[\\/]/i.test(browser) || /^helium(?:-browser)?(?:\.exe)?$/i.test(basename(browser));
}

export function selectBrowserExecutable(
  provider: BrowserLoginProvider,
  candidates: string[],
  exists: (path: string) => boolean = existsSync,
): string {
  const installed = candidates.filter(exists);
  const browser = provider === "youtube"
    ? installed.find((candidate) => !isHeliumBrowser(candidate))
    : installed[0];
  if (!browser) {
    if (provider === "youtube" && installed.some(isHeliumBrowser)) {
      throw new Error("Google sign-in is currently blocked in Helium. Install or select another Chromium-based browser, or use the manual session field.");
    }
    throw new Error("Could not find a Chromium-based browser. Install Chrome, Edge, Chromium, Brave, Vivaldi, or Opera; set COLORFUL_BROWSER_EXECUTABLE; or use the manual session field.");
  }
  return browser;
}

function findBrowser(provider: BrowserLoginProvider): string {
  return selectBrowserExecutable(provider, browserExecutableCandidates());
}

function abortError(): Error {
  return new Error("Browser sign-in cancelled");
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

export async function availableLoopbackPort(signal: AbortSignal): Promise<number> {
  if (signal.aborted) throw abortError();
  const server = createServer();
  await new Promise<void>((resolveListen, reject) => {
    const aborted = () => {
      server.close();
      reject(abortError());
    };
    const failed = (error: Error) => {
      signal.removeEventListener("abort", aborted);
      reject(error);
    };
    server.once("error", failed);
    signal.addEventListener("abort", aborted, { once: true });
    server.listen(0, "127.0.0.1", () => {
      server.removeListener("error", failed);
      signal.removeEventListener("abort", aborted);
      resolveListen();
    });
  });
  const address = server.address();
  if (!address || typeof address === "string") {
    server.close();
    throw new Error("Could not reserve a local browser sign-in connection");
  }
  const port = address.port;
  await new Promise<void>((resolveClose, reject) => {
    server.close((error) => error ? reject(error) : resolveClose());
  });
  return port;
}

export async function pageTarget(port: number, expectedHost: string, signal: AbortSignal): Promise<string> {
  const deadline = Date.now() + START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const response = await fetch(`http://127.0.0.1:${port}/json/list`, {
      signal: AbortSignal.timeout(2_000),
    }).catch(() => null);
    if (response?.ok) {
      const targets = await response.json().catch(() => []) as CdpTarget[];
      const pages = targets.filter((target) => target.type === "page" && text(target.webSocketDebuggerUrl));
      const page = pages.find((target) => {
        try { return new URL(text(target.url)).hostname === expectedHost; } catch { return false; }
      }) ?? (pages.length === 1 ? pages[0] : undefined);
      if (page) return text(page.webSocketDebuggerUrl);
    }
    await delay(100, signal);
  }
  throw new Error("The browser sign-in tab did not become available");
}

export class CdpClient {
  private readonly socket: WebSocket;
  private nextId = 1;
  private readonly pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();
  private readonly listeners = new Set<(message: CdpMessage) => void>();
  private readonly closeListeners = new Set<() => void>();

  private constructor(socket: WebSocket) {
    this.socket = socket;
    socket.addEventListener("message", (event) => {
      let message: CdpMessage;
      try { message = JSON.parse(String(event.data)) as CdpMessage; } catch { return; }
      if (message.id !== undefined) {
        const pending = this.pending.get(message.id);
        if (pending) {
          this.pending.delete(message.id);
          if (message.error) pending.reject(new Error(text(message.error.message) || "Browser command failed"));
          else pending.resolve(message.result);
        }
      }
      for (const listener of this.listeners) listener(message);
    });
    socket.addEventListener("close", () => {
      for (const pending of this.pending.values()) pending.reject(new Error("Browser sign-in connection closed"));
      this.pending.clear();
      for (const listener of this.closeListeners) listener();
      this.closeListeners.clear();
    });
  }

  static async connect(url: string, signal: AbortSignal): Promise<CdpClient> {
    if (signal.aborted) throw abortError();
    const socket = new WebSocket(url);
    await new Promise<void>((resolveOpen, reject) => {
      const opened = () => { cleanup(); resolveOpen(); };
      const failed = () => { cleanup(); reject(new Error("Could not connect to the isolated browser")); };
      const aborted = () => { cleanup(); socket.close(); reject(abortError()); };
      const cleanup = () => {
        socket.removeEventListener("open", opened);
        socket.removeEventListener("error", failed);
        signal.removeEventListener("abort", aborted);
      };
      socket.addEventListener("open", opened, { once: true });
      socket.addEventListener("error", failed, { once: true });
      signal.addEventListener("abort", aborted, { once: true });
    });
    return new CdpClient(socket);
  }

  onMessage(listener: (message: CdpMessage) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  onClose(listener: () => void): () => void {
    this.closeListeners.add(listener);
    return () => this.closeListeners.delete(listener);
  }

  command(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
    const id = this.nextId++;
    return new Promise((resolveCommand, reject) => {
      this.pending.set(id, { resolve: resolveCommand, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  close(): void {
    this.socket.close();
  }
}

async function captureRequest(
  client: CdpClient,
  provider: BrowserLoginProvider,
  signal: AbortSignal,
): Promise<BrowserLoginCapture> {
  const urls = new Map<string, string>();
  const headers = new Map<string, Record<string, string>>();
  let resolveCapture: (capture: BrowserLoginCapture) => void = () => undefined;
  let rejectCapture: (error: Error) => void = () => undefined;
  const captured = new Promise<BrowserLoginCapture>((resolveValue, rejectValue) => {
    resolveCapture = resolveValue;
    rejectCapture = rejectValue;
  });
  const tryCapture = (requestId: string) => {
    const url = urls.get(requestId);
    const values = headers.get(requestId);
    if (!url || !values) return;
    const capture = browserLoginCapture(provider, url, values);
    if (capture) resolveCapture(capture);
  };
  const removeListener = client.onMessage((message) => {
    const params = object(message.params);
    const requestId = text(params.requestId);
    if (!requestId) return;
    if (message.method === "Network.requestWillBeSent") {
      const request = object(params.request);
      const url = text(request.url);
      if (url) urls.set(requestId, url);
      const visibleHeaders = normalizedHeaders(request.headers);
      if (Object.keys(visibleHeaders).length) {
        headers.set(requestId, { ...(headers.get(requestId) ?? {}), ...visibleHeaders });
      }
      tryCapture(requestId);
    } else if (message.method === "Network.requestWillBeSentExtraInfo") {
      headers.set(requestId, { ...(headers.get(requestId) ?? {}), ...normalizedHeaders(params.headers) });
      tryCapture(requestId);
    }
  });
  const aborted = () => rejectCapture(abortError());
  const removeCloseListener = client.onClose(() => {
    rejectCapture(new Error("The browser was closed before sign-in completed"));
  });
  signal.addEventListener("abort", aborted, { once: true });
  try {
    await client.command("Network.enable", { maxTotalBufferSize: 1_048_576 });
    await client.command("Page.enable");
    await client.command("Page.reload", { ignoreCache: true }).catch(() => undefined);
    return await captured;
  } finally {
    removeListener();
    removeCloseListener();
    signal.removeEventListener("abort", aborted);
  }
}

async function removeProfile(profileDirectory: string): Promise<void> {
  const expectedRoot = resolve(tmpdir());
  const target = resolve(profileDirectory);
  if (!target.startsWith(`${expectedRoot}\\`) && !target.startsWith(`${expectedRoot}/`)) return;
  if (!basename(target).startsWith("colorful-browser-login-")) return;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    try { rmSync(target, { recursive: true, force: true }); return; } catch {
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 250 * (attempt + 1)));
    }
  }
}

export async function captureBrowserLogin(
  provider: BrowserLoginProvider,
  signal: AbortSignal,
  progress: (status: string) => void = () => undefined,
): Promise<BrowserLoginCapture> {
  const browser = findBrowser(provider);
  const profileDirectory = mkdtempSync(join(tmpdir(), "colorful-browser-login-"));
  const startUrl = provider === "youtube"
    ? "https://music.youtube.com/library"
    : "https://soundcloud.com/you/library";
  const timeout = AbortSignal.timeout(LOGIN_TIMEOUT_MS);
  const combined = AbortSignal.any([signal, timeout]);
  const port = await availableLoopbackPort(combined);
  const process = Bun.spawn({
    cmd: [
      browser,
      `--user-data-dir=${profileDirectory}`,
      "--remote-debugging-address=127.0.0.1",
      `--remote-debugging-port=${port}`,
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-background-mode",
      "--new-window",
      startUrl,
    ],
    stdin: "ignore",
    stdout: "ignore",
    stderr: "ignore",
  });
  let client: CdpClient | null = null;
  debugLog("browser.auth", "browser_started", { provider, browser: basename(browser), pid: process.pid });
  try {
    progress("Waiting for the browser…");
    const target = await pageTarget(port, new URL(startUrl).hostname, combined);
    debugLog("browser.auth", "devtools_ready", { provider, port });
    client = await CdpClient.connect(target, combined);
    const evaluated = object(await client.command("Runtime.evaluate", {
      expression: "navigator.webdriver",
      returnByValue: true,
    }).catch(() => ({})));
    const webdriver = object(evaluated.result).value === true;
    debugLog("browser.auth", "automation_state", { provider, webdriver });
    if (provider === "youtube" && webdriver) {
      throw new Error("The selected browser exposed automation mode, which Google blocks for sign-in");
    }
    debugLog("browser.auth", "target_attached", { provider });
    progress(provider === "youtube"
      ? "Sign in to YouTube Music, choose the profile you want, then open Library."
      : "Sign in to SoundCloud, then open your Library.");
    const capture = await captureRequest(client, provider, combined);
    progress("Checking the captured account…");
    debugLog("browser.auth", "credential_captured", { provider });
    return capture;
  } catch (error) {
    const failure = timeout.aborted && !signal.aborted
      ? new Error("Browser sign-in timed out") : error;
    debugLog("browser.auth", "failed", {
      provider,
      error: failure instanceof Error ? failure.message : String(failure),
      launcherExitCode: process.exitCode,
      cancelled: signal.aborted,
    });
    throw failure;
  } finally {
    if (client) {
      await client.command("Browser.close").catch(() => undefined);
      client.close();
    }
    await Promise.race([
      process.exited,
      new Promise<void>((resolveDelay) => setTimeout(resolveDelay, 1_500)),
    ]);
    if (process.exitCode === null) process.kill();
    await removeProfile(profileDirectory);
    debugLog("browser.auth", "browser_cleaned", { provider });
  }
}
