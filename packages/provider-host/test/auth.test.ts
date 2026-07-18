import { describe, expect, test } from "bun:test";
import { basicAuthorization, nextDevicePollDelay, normalizeVerificationUrl } from "../src/auth";
import { readTidalConfig } from "../src/config";

describe("TIDAL auth helpers", () => {
  test("uses HTTP Basic for the exact client pair", () => {
    expect(basicAuthorization("client", "secret")).toBe("Basic Y2xpZW50OnNlY3JldA==");
  });

  test("RFC 8628 slow_down adds five seconds", () => {
    expect(nextDevicePollDelay("slow_down", 5_000)).toBe(10_000);
    expect(nextDevicePollDelay("authorization_pending", 5_000)).toBe(5_000);
  });

  test("refresh client defaults to browse client", () => {
    const config = readTidalConfig({ TIDAL_CLIENT_ID: "browse", TIDAL_CLIENT_SECRET: "secret" });
    expect(config.refreshClientId).toBe("browse");
    expect(config.refreshClientSecret).toBe("secret");
  });

  test("normalizes TIDAL's scheme-less verification links", () => {
    expect(normalizeVerificationUrl("link.tidal.com/ABCDE")).toBe("https://link.tidal.com/ABCDE");
    expect(normalizeVerificationUrl("https://link.tidal.com/ABCDE")).toBe("https://link.tidal.com/ABCDE");
  });
});
