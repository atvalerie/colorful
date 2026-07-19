import { describe, expect, test } from "bun:test";
import { buildPlaybackManifestUrl, formatsForQuality, parseAudioNormalization, requiresEntitlementRefresh } from "../src/manifest";

describe("TIDAL manifest entitlement handling", () => {
  test("refreshes a subscription-gated preview", () => {
    expect(requiresEntitlementRefresh({
      trackPresentation: "PREVIEW",
      previewReason: "FULL_REQUIRES_SUBSCRIPTION",
    })).toBe(true);
  });

  test("does not refresh a full manifest", () => {
    expect(requiresEntitlementRefresh({ trackPresentation: "FULL" })).toBe(false);
  });

  test("does not retry unrelated preview restrictions", () => {
    expect(requiresEntitlementRefresh({
      trackPresentation: "PREVIEW",
      previewReason: "FULL_REQUIRES_PURCHASE",
    })).toBe(false);
  });
});

describe("TIDAL playback manifest request", () => {
  test("keeps finite ReplayGain and peak values from the manifest", () => {
    expect(parseAudioNormalization({ replayGain: -10.1, peakAmplitude: 0.901468 })).toEqual({
      replayGain: -10.1,
      peakAmplitude: 0.901468,
    });
    expect(parseAudioNormalization({ replayGain: "nope", peakAmplitude: 1 })).toBeNull();
    expect(parseAudioNormalization({ replayGain: null, peakAmplitude: 1 })).toBeNull();
    expect(parseAudioNormalization({ replayGain: -8, peakAmplitude: 0 })).toEqual({
      replayGain: -8,
      peakAmplitude: null,
    });
  });

  test("requests one seekable representation instead of an adaptive audio master", () => {
    const url = buildPlaybackManifestUrl("https://openapi.tidal.com/v2", "track/id");

    expect(url.pathname).toBe("/v2/trackManifests/track%2Fid");
    expect(url.searchParams.get("manifestType")).toBe("HLS");
    expect(url.searchParams.getAll("formats")).toEqual(["FLAC_HIRES", "FLAC", "AACLC"]);
    expect(url.searchParams.get("usage")).toBe("PLAYBACK");
    expect(url.searchParams.get("adaptive")).toBe("false");
  });

  test("lets the desktop request a DASH timeline", () => {
    const url = buildPlaybackManifestUrl("https://openapi.tidal.com/v2", "123", "MPEG_DASH");
    expect(url.searchParams.get("manifestType")).toBe("MPEG_DASH");
    expect(url.searchParams.get("adaptive")).toBe("false");
  });

  test("maps quality choices to manifest formats", () => {
    expect(formatsForQuality("best")).toEqual(["FLAC_HIRES", "FLAC", "AACLC"]);
    expect(formatsForQuality("lossless")).toEqual(["FLAC", "AACLC"]);
    expect(formatsForQuality("high")).toEqual(["AACLC"]);
  });
});
