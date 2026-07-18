export const PROVIDERS = ["tidal", "soundcloud", "youtube", "local"] as const;
export type ProviderName = (typeof PROVIDERS)[number];

export type MediaRef = {
  provider: ProviderName;
  id: string;
  url?: string;
};

export type ImageRef = {
  url?: string;
  localKey?: string;
  width?: number;
  height?: number;
};

export type ArtistCredit = {
  ref?: MediaRef;
  name: string;
};

export type Track = {
  ref: MediaRef;
  title: string;
  version?: string;
  artists: ArtistCredit[];
  albumRef?: MediaRef;
  albumTitle?: string;
  image?: ImageRef;
  durationMs?: number;
  isrc?: string;
  explicit?: boolean;
};
