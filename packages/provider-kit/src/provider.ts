import type { MediaRef, ProviderName, Track } from "./media";

export type CatalogPage = {
  nextCursor?: string;
};

export type SearchOptions = {
  countryCode?: string;
  explicit?: boolean;
  limit?: number;
  cursor?: string;
};

export type SearchResult = {
  tracks: Track[];
  page?: CatalogPage;
};

export type StreamQuality = "low" | "high" | "lossless" | "hires";

export type SourcePlan = {
  kind: "progressive" | "hls" | "dash";
  uri: string;
  mimeType?: string;
  codec?: string;
  quality?: StreamQuality;
  requestHeaders?: Readonly<Record<string, string>>;
  expiresAtMs?: number;
};

export interface ProviderAdapter {
  readonly provider: ProviderName;
  search(query: string, options?: SearchOptions): Promise<SearchResult>;
  getTrack(ref: MediaRef): Promise<Track>;
  getStreamSource(ref: MediaRef, quality: StreamQuality): Promise<SourcePlan>;
  getDownloadSource?(ref: MediaRef, quality: StreamQuality): Promise<SourcePlan>;
}

