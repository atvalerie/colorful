import { describe, expect, test } from "bun:test";
import { resolve } from "node:path";
import { browserExecutableCandidates, browserLoginCapture, selectBrowserExecutable } from "../src/browser-login";

describe("isolated browser authentication capture", () => {
  test("keeps only the YouTube Music identity required by native requests", () => {
    const capture = browserLoginCapture("youtube",
      "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false", {
        Cookie: "SID=one; __Secure-3PAPISID=private; PREF=music",
        "X-Goog-AuthUser": "0",
        "X-Goog-PageId": "UC_selected",
        "X-Youtube-Client-Version": "1.20260820.01.00",
        "User-Agent": "browser-test",
        Authorization: "SAPISIDHASH secret-that-must-not-be-retained",
        "Sec-Ch-Ua": "telemetry-that-must-not-be-retained",
      });
    expect(capture).toEqual({
      provider: "youtube",
      headers: {
        cookie: "SID=one; __Secure-3PAPISID=private; PREF=music",
        "x-goog-authuser": "0",
        "x-goog-pageid": "UC_selected",
        "x-youtube-client-version": "1.20260820.01.00",
        "user-agent": "browser-test",
      },
    });
  });

  test("ignores unrelated YouTube requests and anonymous sessions", () => {
    expect(browserLoginCapture("youtube", "https://music.youtube.com/youtubei/v1/player", {
      cookie: "__Secure-3PAPISID=private", "x-goog-authuser": "0",
    })).toBeNull();
    expect(browserLoginCapture("youtube", "https://music.youtube.com/youtubei/v1/browse", {
      cookie: "PREF=music", "x-goog-authuser": "0",
    })).toBeNull();
  });

  test("extracts only SoundCloud's OAuth token from an authenticated account request", () => {
    expect(browserLoginCapture("soundcloud", "https://api-v2.soundcloud.com/me?client_id=public", {
      Authorization: "OAuth account-token",
      Cookie: "unrelated-browser-cookie",
    })).toEqual({ provider: "soundcloud", token: "account-token" });
    expect(browserLoginCapture("soundcloud", "https://api-v2.soundcloud.com/tracks/1", {
      Authorization: "OAuth account-token",
    })).toBeNull();
  });

  test("discovers Chromium-family browsers across desktop platforms", () => {
    const windows = browserExecutableCandidates("win32", {
      ProgramFiles: "C:\\Programs",
      "ProgramFiles(x86)": "C:\\Programs32",
      LOCALAPPDATA: "C:\\Users\\tester\\AppData\\Local",
    }, () => null);
    expect(windows.some((path) => path.endsWith("Google\\Chrome\\Application\\chrome.exe"))).toBe(true);
    expect(windows.some((path) => path.endsWith("imput\\Helium\\Application\\chrome.exe"))).toBe(true);
    expect(windows.some((path) => path.endsWith("BraveSoftware\\Brave-Browser\\Application\\brave.exe"))).toBe(true);
    expect(windows.some((path) => path.endsWith("Vivaldi\\Application\\vivaldi.exe"))).toBe(true);

    const linux = browserExecutableCandidates("linux", {}, (command) =>
      command === "brave-browser" ? "/usr/bin/brave-browser" : null);
    expect(linux).toContain(resolve("/usr/bin/brave-browser"));

    const macOS = browserExecutableCandidates("darwin", {}, () => null);
    expect(macOS).toContain(resolve("/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"));
    expect(macOS).toContain(resolve("/Applications/Vivaldi.app/Contents/MacOS/Vivaldi"));
    expect(macOS).toContain(resolve("/Applications/Helium.app/Contents/MacOS/Helium"));
  });

  test("prefers an explicitly configured browser", () => {
    const candidates = browserExecutableCandidates("linux", {
      COLORFUL_BROWSER_EXECUTABLE: "/opt/my-browser/browser",
    }, () => null);
    expect(candidates[0]).toBe(resolve("/opt/my-browser/browser"));
  });

  test("uses Helium for ordinary providers but skips it for Google sign-in", () => {
    const helium = "C:\\Users\\tester\\AppData\\Local\\imput\\Helium\\Application\\chrome.exe";
    const edge = "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe";
    expect(selectBrowserExecutable("soundcloud", [helium, edge], () => true)).toBe(helium);
    expect(selectBrowserExecutable("youtube", [helium, edge], () => true)).toBe(edge);
    expect(() => selectBrowserExecutable("youtube", [helium], () => true))
      .toThrow("Google sign-in is currently blocked in Helium");
  });
});
