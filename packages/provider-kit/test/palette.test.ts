import { describe, expect, test } from "bun:test";
import { extractPalette, toCss } from "../src/palette";

describe("extractPalette", () => {
  test("prefers colorful pixels over black padding", () => {
    const palette = extractPalette(new Uint8Array([
      0, 0, 0,
      0, 0, 0,
      230, 40, 90,
      230, 40, 90,
      20, 150, 235,
    ]));

    expect(palette.primary).toEqual({ r: 230, g: 40, b: 90 });
    expect(palette.secondary).toEqual({ r: 20, g: 150, b: 235 });
  });

  test("formats a CSS color", () => {
    expect(toCss({ r: 12, g: 34, b: 56 })).toBe("rgb(12 34 56)");
  });

  test("rejects an empty sample", () => {
    expect(() => extractPalette(new Uint8Array())).toThrow("empty");
  });
});
