export const RECOMMENDATION_MODES = ["tidal", "spotify", "fallback"] as const;
export type RecommendationMode = typeof RECOMMENDATION_MODES[number];

export function recommendationMode(value: unknown): RecommendationMode {
  return typeof value === "string" && RECOMMENDATION_MODES.includes(value as RecommendationMode)
    ? value as RecommendationMode
    : "fallback";
}

export async function selectRecommendations<T>(
  mode: RecommendationMode,
  tidal: () => Promise<T[]>,
  spotify: () => Promise<T[]>,
): Promise<{ source: "tidal" | "spotify"; tracks: T[] }> {
  if (mode === "tidal") return { source: "tidal", tracks: await tidal() };
  if (mode === "spotify") return { source: "spotify", tracks: await spotify() };
  try {
    const tracks = await tidal();
    if (tracks.length > 0) return { source: "tidal", tracks };
  } catch {
    // Fallback mode deliberately treats a missing/failed TIDAL radio alike.
  }
  return { source: "spotify", tracks: await spotify() };
}
