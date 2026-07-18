import { refreshUserToken, type UserToken } from "./auth";
import type { TidalConfig } from "./config";

export type PlaybackSource = {
  uri: string;
  manifestType: "HLS" | "MPEG_DASH";
  formats: string[];
  presentation: string | null;
  previewReason: string | null;
};

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
    const base = this.config.apiBaseUrl.endsWith("/") ? this.config.apiBaseUrl : `${this.config.apiBaseUrl}/`;
    const url = new URL(`trackManifests/${encodeURIComponent(trackId)}`, base);
    url.searchParams.append("manifestType", "HLS");
    for (const format of ["FLAC_HIRES", "FLAC", "AACLC"]) url.searchParams.append("formats", format);
    url.searchParams.set("uriScheme", "HTTPS");
    url.searchParams.set("usage", "PLAYBACK");
    url.searchParams.set("adaptive", "true");
    const request = async (force: boolean) => fetch(url, {
      headers: { Authorization: `Bearer ${await this.accessToken(force)}`, Accept: "application/vnd.api+json" },
    });
    let response = await request(false);
    if (response.status === 401) response = await request(true);
    if (!response.ok) throw new Error(`TIDAL playback source failed (${response.status}): ${await response.text()}`);
    const document = await response.json() as any;
    const attributes = document.data?.attributes ?? {};
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

