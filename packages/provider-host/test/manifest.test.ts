import { describe, expect, test } from "bun:test";
import { requiresEntitlementRefresh } from "../src/manifest";

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
