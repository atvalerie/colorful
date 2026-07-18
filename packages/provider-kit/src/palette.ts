export type Rgb = Readonly<{ r: number; g: number; b: number }>;

export type ArtworkPalette = Readonly<{
  primary: Rgb;
  secondary: Rgb;
}>;

type Bucket = { r: number; g: number; b: number; count: number; score: number };

function lightness({ r, g, b }: Rgb): number {
  return (Math.max(r, g, b) + Math.min(r, g, b)) / (2 * 255);
}

function saturation(color: Rgb): number {
  const max = Math.max(color.r, color.g, color.b) / 255;
  const min = Math.min(color.r, color.g, color.b) / 255;
  const delta = max - min;
  if (delta === 0) return 0;
  return delta / (1 - Math.abs(max + min - 1));
}

function distance(a: Rgb, b: Rgb): number {
  return Math.hypot(a.r - b.r, a.g - b.g, a.b - b.b);
}

function normalized(bucket: Bucket): Rgb {
  return {
    r: Math.round(bucket.r / bucket.count),
    g: Math.round(bucket.g / bucket.count),
    b: Math.round(bucket.b / bucket.count),
  };
}

/**
 * Scores already-decoded RGB pixels. Native image decoders can feed this
 * function a small sample without ffmpeg, temporary files, or network access.
 */
export function extractPalette(rgb: Uint8Array): ArtworkPalette {
  if (rgb.length < 3) throw new Error("artwork sample is empty");

  const buckets = new Map<string, Bucket>();
  for (let index = 0; index + 2 < rgb.length; index += 3) {
    const color = { r: rgb[index]!, g: rgb[index + 1]!, b: rgb[index + 2]! };
    const key = `${color.r >> 4},${color.g >> 4},${color.b >> 4}`;
    const l = lightness(color);
    const usefulLightness = l < 0.06 || l > 0.97 ? 0.08 : 1;
    const score = usefulLightness * (0.2 + saturation(color) * 2.8);
    const bucket = buckets.get(key);
    if (bucket) {
      bucket.r += color.r;
      bucket.g += color.g;
      bucket.b += color.b;
      bucket.count += 1;
      bucket.score += score;
    } else {
      buckets.set(key, { ...color, count: 1, score });
    }
  }

  const ranked = [...buckets.values()].sort((a, b) => b.score - a.score);
  const primary = normalized(ranked[0]!);
  const secondaryBucket = ranked.find((candidate) => distance(primary, normalized(candidate)) >= 72)
    ?? ranked[1]
    ?? ranked[0]!;

  return { primary, secondary: normalized(secondaryBucket) };
}

export function toCss({ r, g, b }: Rgb): string {
  return `rgb(${r} ${g} ${b})`;
}

