import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  parseSpotifyApiTokenResponse,
  parseSpotifyAccount,
  parseSpotifyClientTokenResponse,
  loadSpotifyAccount,
  collectSpotifyTrackIds,
  isSpotifyPathfinderUrl,
  spotifyProfileDirectory,
  SpotifyBrowserSession,
  SpotifyCredentialCache,
  type SpotifyCdpTransport,
  type SpotifyCredentials,
} from "../src/spotify-auth";

const NOW = 1_750_000_000_000;

function credentials(overrides: Partial<SpotifyCredentials> = {}): SpotifyCredentials {
  return {
    accessToken: "access-token",
    clientToken: "client-token",
    expiresAtMs: NOW + 300_000,
    clientTokenExpiresAtMs: null,
    ...overrides,
  };
}

type FakeMessage = { method?: string; params?: Record<string, unknown> };

function fakeSpotifyTransport(): { transport: SpotifyCdpTransport; commands: string[]; emit: (message: FakeMessage) => void } {
  const listeners = new Set<(message: FakeMessage) => void>();
  const closeListeners = new Set<() => void>();
  const commands: string[] = [];
  const emit = (message: FakeMessage): void => {
    for (const listener of listeners) listener(message);
  };
  const transport = {
    async command(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
      commands.push(method);
      if (method === "Network.getResponseBody") {
        const requestId = String(params.requestId ?? "");
        return requestId === "api-1"
          ? { body: JSON.stringify({ accessToken: "captured-bearer", accessTokenExpirationTimestampMs: NOW + 900_000 }) }
          : { body: JSON.stringify({ granted_token: { token: "captured-client", expires_after_seconds: 3_600 } }) };
      }
      return {};
    },
    onMessage(listener: (message: FakeMessage) => void): () => void {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    onClose(listener: () => void): () => void {
      closeListeners.add(listener);
      return () => closeListeners.delete(listener);
    },
    close(): void {
      for (const listener of closeListeners) listener();
      closeListeners.clear();
    },
  } as SpotifyCdpTransport;
  return { transport, commands, emit };
}

describe("Spotify cookie-backed session primitives", () => {
  test("parses the first-party bearer response and millisecond expiry", () => {
    expect(parseSpotifyApiTokenResponse({
      accessToken: "bearer",
      accessTokenExpirationTimestampMs: String(NOW + 900_000),
      isAnonymous: false,
    }, NOW)).toEqual({
      accessToken: "bearer",
      expiresAtMs: NOW + 900_000,
      isAnonymous: false,
    });
  });

  test("supports duration responses and rejects incomplete or anonymous sessions", () => {
    expect(parseSpotifyApiTokenResponse({ access_token: "bearer", expiresIn: 120 }, NOW))
      .toEqual({ accessToken: "bearer", expiresAtMs: NOW + 120_000, isAnonymous: false });
    expect(parseSpotifyApiTokenResponse({ accessToken: "anonymous", isAnonymous: true }, NOW))
      .toMatchObject({ accessToken: "anonymous", isAnonymous: true });
    expect(parseSpotifyApiTokenResponse({ expiresIn: 120 }, NOW)).toBeNull();
  });

  test("parses Spotify's granted client-token response without retaining the document", () => {
    expect(parseSpotifyClientTokenResponse({
      granted_token: { token: "client-token", expires_after_seconds: 3_600 },
    }, NOW)).toEqual({
      clientToken: "client-token",
      expiresAtMs: NOW + 3_600_000,
    });
    expect(parseSpotifyClientTokenResponse({ token: "fallback-client-token" }, NOW))
      .toEqual({ clientToken: "fallback-client-token", expiresAtMs: null });
    expect(parseSpotifyClientTokenResponse({ granted_token: {} }, NOW)).toBeNull();
  });

  test("keeps only useful non-secret Spotify profile fields", () => {
    expect(parseSpotifyAccount({
      id: "account-id",
      display_name: "Val",
      email: "never-retain@example.com",
      product: "PREMIUM",
      country: "pl",
      images: [{ url: "https://i.scdn.co/image/profile" }],
      external_urls: { spotify: "https://open.spotify.com/user/account-id" },
    })).toEqual({
      id: "account-id",
      displayName: "Val",
      product: "premium",
      country: "PL",
      imageUrl: "https://i.scdn.co/image/profile",
      profileUrl: "https://open.spotify.com/user/account-id",
    });
    expect(parseSpotifyAccount({ display_name: "No ID" })).toBeNull();
  });

  test("loads the current account with the in-memory bearer", async () => {
    let authorization = "";
    const account = await loadSpotifyAccount(credentials(), async (input, init) => {
      expect(String(input)).toBe("https://api.spotify.com/v1/me");
      authorization = String((init?.headers as Record<string, string>).Authorization);
      return new Response(JSON.stringify({ id: "account-id", display_name: "Val", product: "free" }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });
    expect(authorization).toBe("Bearer access-token");
    expect(account).toMatchObject({ id: "account-id", displayName: "Val", product: "free" });
  });

  test("recognizes Pathfinder search responses without accepting unrelated URLs", () => {
    expect(isSpotifyPathfinderUrl("https://api-partner.spotify.com/pathfinder/v1/query")).toBe(true);
    expect(isSpotifyPathfinderUrl("https://api-partner.spotify.com/pathfinder/v2/query")).toBe(true);
    expect(isSpotifyPathfinderUrl("https://api-partner.spotify.com/pathfinder/v3/query")).toBe(false);
    expect(isSpotifyPathfinderUrl("https://open.spotify.com/pathfinder/v1/query")).toBe(false);
    expect(collectSpotifyTrackIds({
      entities: [
        { type: "track", id: "4uLU6hMCjMI75M1A2tKUQC", uri: "spotify:track:4uLU6hMCjMI75M1A2tKUQC" },
        { type: "album", id: "4uLU6hMCjMI75M1A2tKUQC" },
        { id: "0gxyHStUsqpMadRV0Di1Qt" },
        { uri: "spotify:track:7gf5ffmSqKQBDnkmSe2Dt7" },
      ],
    })).toEqual(["4uLU6hMCjMI75M1A2tKUQC", "0gxyHStUsqpMadRV0Di1Qt", "7gf5ffmSqKQBDnkmSe2Dt7"]);
  });

  test("uses an app-owned, persistent profile location per desktop platform", () => {
    expect(spotifyProfileDirectory("win32", {
      LOCALAPPDATA: "C:\\Users\\tester\\AppData\\Local",
    }, "C:\\Users\\tester")).toBe(
      "C:\\Users\\tester\\AppData\\Local\\colorful\\spotify-browser",
    );
    expect(spotifyProfileDirectory("linux", {
      XDG_DATA_HOME: "/home/tester/.local/share",
    }, "/home/tester")).toBe("/home/tester/.local/share/colorful/spotify-browser");
    expect(spotifyProfileDirectory("darwin", {}, "/Users/tester")).toBe(
      "/Users/tester/Library/Application Support/colorful/spotify-browser",
    );
    expect(spotifyProfileDirectory("linux", {
      COLORFUL_DATA_DIR: "/srv/colorful-data",
    }, "/home/tester")).toBe("/srv/colorful-data/spotify-browser");
  });

  test("caches only in memory and refreshes near bearer or client-token expiry", () => {
    let now = NOW;
    const cache = new SpotifyCredentialCache({ now: () => now, refreshMarginMs: 60_000 });
    cache.set(credentials());
    expect(cache.get()).toMatchObject({ accessToken: "access-token" });
    now += 241_000;
    expect(cache.get()).toBeNull();
    cache.set(credentials({ expiresAtMs: now + 300_000, clientTokenExpiresAtMs: now + 240_000 }));
    expect(cache.get()).toBeNull();
    expect(cache.get(true)).toBeNull();
    expect(cache.peek()).toMatchObject({ accessToken: "access-token" });
    cache.clear();
    expect(cache.peek()).toBeNull();
  });

  test("does not launch a hidden browser before Spotify has been linked", async () => {
    const profileDirectory = mkdtempSync(join(tmpdir(), "colorful-spotify-auth-"));
    let spawned = false;
    const session = new SpotifyBrowserSession({
      profileDirectory,
      browserExecutable: "unused-browser",
      spawn: () => {
        spawned = true;
        throw new Error("browser should not start");
      },
    });
    try {
      expect(await session.restore()).toBeNull();
      expect(spawned).toBe(false);
    } finally {
      await session.close();
      rmSync(profileDirectory, { recursive: true, force: true });
    }
  });

  test("attaches one visible observer without reloading the Spotify login page", async () => {
    const profileDirectory = mkdtempSync(join(tmpdir(), "colorful-spotify-auth-"));
    const transports: Array<ReturnType<typeof fakeSpotifyTransport>> = [];
    const processes: Array<{ exitCode: number | null; exited: Promise<number>; kill: () => void }> = [];
    const session = new SpotifyBrowserSession({
      profileDirectory,
      browserExecutable: "unused-browser",
      now: () => NOW,
      reservePort: async () => 43111,
      findPage: async () => "ws://spotify-test",
      connect: async () => {
        const fake = fakeSpotifyTransport();
        transports.push(fake);
        if (transports.length === 1) {
          setTimeout(() => {
            transports[0]?.emit({ method: "Network.responseReceived", params: {
              requestId: "client-1", response: { url: "https://clienttoken.spotify.com/v1/clienttoken", status: 200 },
            } });
            transports[0]?.emit({ method: "Network.loadingFinished", params: { requestId: "client-1" } });
            transports[0]?.emit({ method: "Network.responseReceived", params: {
              requestId: "api-1", response: { url: "https://open.spotify.com/api/token", status: 200 },
            } });
            transports[0]?.emit({ method: "Network.loadingFinished", params: { requestId: "api-1" } });
          }, 0);
        }
        return fake.transport;
      },
      spawn: () => {
        let resolveExited: (code: number) => void = () => undefined;
        const process = {
          exitCode: null as number | null,
          exited: new Promise<number>((resolve) => { resolveExited = resolve; }),
          kill: () => { process.exitCode = 0; resolveExited(0); },
        };
        processes.push(process);
        return process;
      },
    });
    try {
      const result = await session.authenticate(new AbortController().signal);
      expect(result.accessToken).toBe("captured-bearer");
      expect(result.clientToken).toBe("captured-client");
      expect(processes).toHaveLength(2);
      expect(transports[0]?.commands).not.toContain("Page.reload");
      expect(transports[0]?.commands).not.toContain("Runtime.evaluate");
      expect(transports[0]?.commands).toContain("Network.enable");
      expect(transports[0]?.commands).toContain("Page.enable");
    } finally {
      await session.close();
      rmSync(profileDirectory, { recursive: true, force: true });
    }
  });

  test("refreshes a linked headless session through Web Player reload, never Runtime.evaluate", async () => {
    const profileDirectory = mkdtempSync(join(tmpdir(), "colorful-spotify-auth-"));
    writeFileSync(join(profileDirectory, ".colorful-linked"), "1\n");
    const fake = fakeSpotifyTransport();
    const commands = fake.commands;
    let resolveExited: (code: number) => void = () => undefined;
    const process = {
      exitCode: null as number | null,
      exited: new Promise<number>((resolve) => { resolveExited = resolve; }),
      kill: () => { process.exitCode = 0; resolveExited(0); },
    };
    const session = new SpotifyBrowserSession({
      profileDirectory,
      browserExecutable: "unused-browser",
      now: () => NOW,
      reservePort: async () => 43112,
      findPage: async () => "ws://spotify-test",
      connect: async () => {
        setTimeout(() => {
          fake.emit({ method: "Network.responseReceived", params: {
            requestId: "client-1", response: { url: "https://clienttoken.spotify.com/v1/clienttoken", status: 200 },
          } });
          fake.emit({ method: "Network.loadingFinished", params: { requestId: "client-1" } });
          fake.emit({ method: "Network.responseReceived", params: {
            requestId: "api-1", response: { url: "https://open.spotify.com/api/token", status: 200 },
          } });
          fake.emit({ method: "Network.loadingFinished", params: { requestId: "api-1" } });
        }, 0);
        return fake.transport;
      },
      spawn: () => process,
    });
    try {
      const result = await session.restore();
      expect(result).toMatchObject({ accessToken: "captured-bearer", clientToken: "captured-client" });
      expect(session.linked).toBe(true);
      expect(commands).toContain("Page.reload");
      expect(commands).not.toContain("Runtime.evaluate");
    } finally {
      await session.close();
      rmSync(profileDirectory, { recursive: true, force: true });
    }
  });
});
