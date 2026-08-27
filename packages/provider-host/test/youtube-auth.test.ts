import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { BrowserCdpTransport } from "../src/browser-login";
import { YouTubeBrowserProfileSession, youtubeProfileDirectory } from "../src/youtube-auth";

const profiles: string[] = [];

afterEach(() => {
  for (const profile of profiles.splice(0)) rmSync(profile, { recursive: true, force: true });
});

function profileDirectory(): string {
  const directory = mkdtempSync(join(tmpdir(), "colorful-youtube-auth-test-"));
  profiles.push(directory);
  return directory;
}

function fakeClient(): BrowserCdpTransport {
  return {
    command: async () => ({}),
    onMessage: () => () => undefined,
    onClose: () => () => undefined,
    close: () => undefined,
  };
}

function browserProcess() {
  return { exited: Promise.resolve(0), exitCode: 0, kill: () => undefined };
}

const capturedHeaders = (cookie: string) => ({
  cookie: `SID=session; __Secure-3PAPISID=${cookie}`,
  "x-goog-authuser": "0",
  "x-goog-pageid": "UC_selected",
  "x-youtube-client-version": "1.20260827.01.00",
});

describe("YouTube Music persistent browser profile", () => {
  test("uses the app data root and supports an explicit profile override", () => {
    expect(youtubeProfileDirectory("win32", {
      COLORFUL_DATA_DIR: "C:\\Users\\listener\\AppData\\Local\\colorful",
    }, "C:\\Users\\listener")).toBe("C:\\Users\\listener\\AppData\\Local\\colorful\\youtube-browser");
    expect(youtubeProfileDirectory("linux", {
      COLORFUL_YOUTUBE_PROFILE_DIR: "/srv/colorful/youtube-session",
    }, "/home/listener")).toBe("/srv/colorful/youtube-session");
  });

  test("hands one persistent profile from visible login to a hidden session", async () => {
    const launches: string[][] = [];
    const captureReloads: boolean[] = [];
    const session = new YouTubeBrowserProfileSession({
      profileDirectory: profileDirectory(),
      browserExecutable: "test-browser",
      reservePort: async () => 39001,
      findPage: async () => "ws://youtube.test/page",
      connect: async () => fakeClient(),
      spawn: (_browser, args) => { launches.push(args); return browserProcess(); },
      capture: async (_client, _signal, reload) => {
        captureReloads.push(reload);
        return capturedHeaders("initial-cookie");
      },
    });

    const headers = await session.authenticate(new AbortController().signal);
    expect(headers.cookie).toContain("initial-cookie");
    expect(session.linked).toBe(true);
    expect(launches).toHaveLength(2);
    expect(launches[0]).toContain("--new-window");
    expect(launches[0]).not.toContain("--headless=new");
    expect(launches[1]).toContain("--headless=new");
    expect(launches[1]).not.toContain("--new-window");
    expect(captureReloads).toEqual([true]);
    const profileArgs = launches.map((args) => args.find((arg) => arg.startsWith("--user-data-dir=")));
    expect(profileArgs[0]).toBe(profileArgs[1]);
    await session.close();
  });

  test("reuses one hidden browser and single-flights rotated cookie capture", async () => {
    let now = 1_000;
    let captures = 0;
    const launches: string[][] = [];
    const captureReloads: boolean[] = [];
    const session = new YouTubeBrowserProfileSession({
      profileDirectory: profileDirectory(),
      browserExecutable: "test-browser",
      now: () => now,
      refreshIntervalMs: 1_000,
      reservePort: async () => 39002,
      findPage: async () => "ws://youtube.test/page",
      connect: async () => fakeClient(),
      spawn: (_browser, args) => { launches.push(args); return browserProcess(); },
      capture: async (_client, _signal, reload) => {
        captureReloads.push(reload);
        return capturedHeaders(`cookie-${++captures}`);
      },
    });

    await session.authenticate(new AbortController().signal);
    expect((await session.headers()).cookie).toContain("cookie-1");
    now += 1_001;
    const [first, second] = await Promise.all([session.headers(), session.headers()]);
    expect(first.cookie).toContain("cookie-2");
    expect(second).toEqual(first);
    expect(captures).toBe(2);
    expect(captureReloads).toEqual([true, true]);
    expect(launches).toHaveLength(2);
    expect(launches.filter((args) => args.includes("--new-window"))).toHaveLength(1);
    await session.close();
  });

  test("does not launch a browser when no linked marker exists", async () => {
    let launches = 0;
    const session = new YouTubeBrowserProfileSession({
      profileDirectory: profileDirectory(),
      browserExecutable: "test-browser",
      spawn: () => { launches += 1; return browserProcess(); },
    });
    expect(await session.restore()).toBeNull();
    expect(launches).toBe(0);
    await session.close();
  });

  test("backs off after a failed hidden refresh instead of relaunching for every forced request", async () => {
    let now = 1_000;
    let captures = 0;
    const session = new YouTubeBrowserProfileSession({
      profileDirectory: profileDirectory(),
      browserExecutable: "test-browser",
      now: () => now,
      refreshIntervalMs: 1_000,
      reservePort: async () => 39004,
      findPage: async () => "ws://youtube.test/page",
      connect: async () => fakeClient(),
      spawn: () => browserProcess(),
      capture: async () => {
        captures += 1;
        if (captures === 1) return capturedHeaders("verified");
        throw new Error("headless capture failed");
      },
    });

    await session.authenticate(new AbortController().signal);
    await expect(session.headers(true)).rejects.toThrow("headless capture failed");
    expect((await session.headers(true)).cookie).toContain("verified");
    expect(captures).toBe(2);
    now += 1_001;
    await expect(session.headers(true)).rejects.toThrow("headless capture failed");
    expect(captures).toBe(3);
    await session.close();
  });

  test("unlink wins a race with an in-flight hidden refresh", async () => {
    let captureNumber = 0;
    let markRefreshStarted: () => void = () => undefined;
    const refreshStarted = new Promise<void>((resolve) => { markRefreshStarted = resolve; });
    let finishRefresh: (headers: Record<string, string>) => void = () => {
      throw new Error("refresh did not start");
    };
    const session = new YouTubeBrowserProfileSession({
      profileDirectory: profileDirectory(),
      browserExecutable: "test-browser",
      reservePort: async () => 39003,
      findPage: async () => "ws://youtube.test/page",
      connect: async () => fakeClient(),
      spawn: () => browserProcess(),
      capture: async () => {
        captureNumber += 1;
        if (captureNumber === 1) return capturedHeaders("initial");
        return new Promise<Record<string, string>>((resolve) => {
          finishRefresh = resolve;
          markRefreshStarted();
        });
      },
    });

    await session.authenticate(new AbortController().signal);
    const refreshing = session.headers(true);
    await refreshStarted;
    const clearing = session.clear();
    finishRefresh(capturedHeaders("must-not-survive"));
    await expect(refreshing).rejects.toThrow("cancelled");
    await clearing;
    expect(session.linked).toBe(false);
    await session.close();
  });
});
