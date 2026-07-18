import { refreshUserToken, type UserToken } from "./auth";
import type { TidalConfig } from "./config";

export type PlaybackSource = {
  uri: string;
  manifestType: "HLS" | "MPEG_DASH";
  formats: string[];
  presentation: string | null;
  previewReason: string | null;
};

type ManifestAttributes = {
  uri?: unknown;
  manifestType?: unknown;
  formats?: unknown;
  trackPresentation?: unknown;
  previewReason?: unknown;
};

export function requiresEntitlementRefresh(attributes: ManifestAttributes): boolean {
  return attributes.trackPresentation === "PREVIEW"
    && attributes.previewReason === "FULL_REQUIRES_SUBSCRIPTION";
}

export function buildPlaybackManifestUrl(apiBaseUrl: string, trackId: string): URL {
  const base = apiBaseUrl.endsWith("/") ? apiBaseUrl : `${apiBaseUrl}/`;
  const url = new URL(`trackManifests/${encodeURIComponent(trackId)}`, base);
  url.searchParams.append("manifestType", "HLS");
  for (const format of ["FLAC_HIRES", "FLAC", "AACLC"]) url.searchParams.append("formats", format);
  url.searchParams.set("uriScheme", "HTTPS");
  url.searchParams.set("usage", "PLAYBACK");
  // Qt/FFmpeg treats TIDAL's adaptive audio master as simultaneous programs.
  // The resulting timelines wrap independently, freezing position and making
  // seeks unreliable. TIDAL still chooses the best entitled format from the
  // preference list when adaptive playback is disabled.
  url.searchParams.set("adaptive", "false");
  return url;
}

export class UserSession {
  constructor(
    private readonly config: TidalConfig,
    private token: UserToken,
    private readonly onRefreshToken: (token: string) => Promise<void>,
  ) {}

  async accessToken(force = false): Promise<string> {
    if (!force && Date.now() < this.token.expiresAt - 30_000) return this.token.accessToken;
    const previousRefreshToken = this.token.refreshToken;
    this.token = await refreshUserToken(this.config, previousRefreshToken);
    if (this.token.refreshToken !== previousRefreshToken) await this.onRefreshToken(this.token.refreshToken);
    return this.token.accessToken;
  }

  async sourceFor(trackId: string): Promise<PlaybackSource> {
    const url = buildPlaybackManifestUrl(this.config.apiBaseUrl, trackId);
    const request = async (force: boolean) => fetch(url, {
      headers: { Authorization: `Bearer ${await this.accessToken(force)}`, Accept: "application/vnd.api+json" },
    });
    let response = await request(false);
    if (response.status === 401) response = await request(true);
    if (!response.ok) throw new Error(`TIDAL playback source failed (${response.status}): ${await response.text()}`);
    let document = await response.json() as { data?: { attributes?: ManifestAttributes } };
    let attributes = document.data?.attributes ?? {};
    if (requiresEntitlementRefresh(attributes)) {
      response = await request(true);
      if (!response.ok) throw new Error(`TIDAL playback entitlement refresh failed (${response.status}): ${await response.text()}`);
      document = await response.json() as { data?: { attributes?: ManifestAttributes } };
      attributes = document.data?.attributes ?? {};
    }
    if (attributes.trackPresentation === "PREVIEW") {
      const reason = typeof attributes.previewReason === "string" ? attributes.previewReason : "unknown reason";
      throw new Error(`TIDAL only returned a preview (${reason})`);
    }
    const uri = String(attributes.uri ?? "");
    if (!/^https?:\/\//i.test(uri)) throw new Error("TIDAL returned an unsupported non-HTTPS playback manifest");
    return {
      uri,
      manifestType: attributes.manifestType === "MPEG_DASH" ? "MPEG_DASH" : "HLS",
      formats: Array.isArray(attributes.formats) ? attributes.formats.map(String) : [],
      presentation: typeof attributes.trackPresentation === "string" ? attributes.trackPresentation : null,
      previewReason: typeof attributes.previewReason === "string" ? attributes.previewReason : null,
    };
  }
}
