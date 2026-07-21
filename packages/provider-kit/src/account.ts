import type { ProviderName } from "./media";

/** Provider-neutral account state shared by native shells and provider adapters. */
export type ProviderAccountState = {
  provider: ProviderName;
  linked: boolean;
  displayName?: string;
  handle?: string;
  pictureUrl?: string;
};

/** A device-code challenge can be presented by every native UI. */
export type DeviceAuthorizationChallenge = {
  provider: ProviderName;
  userCode: string;
  verificationUri: string;
  verificationUriComplete?: string;
  expiresIn: number;
  interval: number;
};

/** Secrets remain platform-owned; the shared layer only refers to a handle. */
export type ProviderCredentialHandle = {
  provider: ProviderName;
  handle: string;
};
