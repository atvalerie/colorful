import { describe, expect, test } from "bun:test";
import { recommendationMode, selectRecommendations } from "../src/recommendation-policy";

describe("recommendation policy", () => {
  test("defaults unknown values to Spotify fallback", () => {
    expect(recommendationMode(undefined)).toBe("fallback");
    expect(recommendationMode("something-else")).toBe("fallback");
  });

  test("uses only the explicitly selected provider", async () => {
    let tidalCalls = 0;
    let spotifyCalls = 0;
    expect(await selectRecommendations("tidal", async () => { tidalCalls += 1; return ["t"]; }, async () => {
      spotifyCalls += 1; return ["s"];
    })).toEqual({ source: "tidal", tracks: ["t"] });
    expect(tidalCalls).toBe(1);
    expect(spotifyCalls).toBe(0);
  });

  test("uses Spotify only when TIDAL is empty or unavailable in fallback mode", async () => {
    let spotifyCalls = 0;
    const spotify = async () => { spotifyCalls += 1; return ["s"]; };
    expect(await selectRecommendations("fallback", async () => ["t"], spotify)).toEqual({
      source: "tidal", tracks: ["t"],
    });
    expect(await selectRecommendations("fallback", async () => [], spotify)).toEqual({
      source: "spotify", tracks: ["s"],
    });
    expect(await selectRecommendations("fallback", async () => { throw new Error("missing"); }, spotify)).toEqual({
      source: "spotify", tracks: ["s"],
    });
    expect(spotifyCalls).toBe(2);
  });
});
