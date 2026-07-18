import { describe, expect, test } from "bun:test";
import { hasPremiumPlayback } from "../src/subscription";

describe("TIDAL subscription entitlement", () => {
  test("accepts an active paid playback entitlement", () => {
    expect(hasPremiumPlayback({ status: "ACTIVE", premiumAccess: true, paymentOverdue: false })).toBe(true);
  });

  test("rejects an active introductory record without premium access", () => {
    expect(hasPremiumPlayback({ status: "ACTIVE", premiumAccess: false, paymentOverdue: false })).toBe(false);
  });

  test("rejects overdue playback", () => {
    expect(hasPremiumPlayback({ status: "ACTIVE", premiumAccess: true, paymentOverdue: true })).toBe(false);
  });
});
