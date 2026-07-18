import type { TidalConfig } from "./config";
import { validateBrowseConfig, validateDeviceConfig } from "./config";

export type TokenResponse = {
  access_token: string;
  refresh_token?: string;
  expires_in: number;
  scope?: string;
  user?: { userId?: number };
};

export type DeviceAuthStart = {
  deviceCode: string;
  userCode: string;
  verificationUri: string;
  verificationUriComplete: string;
  expiresIn: number;
  interval: number;
};

export type UserToken = {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
  userId: number | null;
};

export type DevicePollError = "authorization_pending" | "slow_down" | "access_denied" | "expired_token" | string;

export function basicAuthorization(clientId: string, clientSecret: string): string {
  return `Basic ${Buffer.from(`${clientId}:${clientSecret}`).toString("base64")}`;
}

async function tokenRequest(
  config: TidalConfig,
  body: URLSearchParams,
  clientId: string,
  clientSecret: string,
): Promise<Response> {
  return fetch(`${config.authBaseUrl}/v1/oauth2/token`, {
    method: "POST",
    headers: {
      Authorization: basicAuthorization(clientId, clientSecret),
      "Content-Type": "application/x-www-form-urlencoded",
      "User-Agent": config.userAgent,
      Accept: "application/json",
    },
    body,
  });
}

export class BrowseAuth {
  private accessToken: string | null = null;
  private expiresAt = 0;
  private refreshing: Promise<string> | null = null;

  constructor(private readonly config: TidalConfig) {}

  async getAccessToken(force = false): Promise<string> {
    validateBrowseConfig(this.config);
    if (!force && this.accessToken && Date.now() < this.expiresAt - 30_000) return this.accessToken;
    this.refreshing ??= this.fetchToken().finally(() => { this.refreshing = null; });
    return this.refreshing;
  }

  private async fetchToken(): Promise<string> {
    const response = await tokenRequest(
      this.config,
      new URLSearchParams({ grant_type: "client_credentials", scope: this.config.browseScope }),
      this.config.browseClientId,
      this.config.browseClientSecret,
    );
    if (!response.ok) throw new Error(`TIDAL browse token failed (${response.status}): ${await response.text()}`);
    const token = await response.json() as TokenResponse;
    this.accessToken = token.access_token;
    this.expiresAt = Date.now() + token.expires_in * 1000;
    return token.access_token;
  }
}

export async function startDeviceAuth(config: TidalConfig): Promise<DeviceAuthStart> {
  validateDeviceConfig(config);
  const response = await fetch(`${config.authBaseUrl}/v1/oauth2/device_authorization`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "User-Agent": config.userAgent,
      Accept: "application/json",
    },
    body: new URLSearchParams({ client_id: config.deviceClientId, scope: config.deviceScope }),
  });
  if (!response.ok) throw new Error(`TIDAL device login failed to start (${response.status}): ${await response.text()}`);
  const value = await response.json() as Record<string, unknown>;
  return {
    deviceCode: String(value.deviceCode ?? ""),
    userCode: String(value.userCode ?? ""),
    verificationUri: String(value.verificationUri ?? ""),
    verificationUriComplete: String(value.verificationUriComplete ?? value.verificationUri ?? ""),
    expiresIn: Number(value.expiresIn ?? 0),
    interval: Math.max(1, Number(value.interval ?? 5)),
  };
}

export function nextDevicePollDelay(error: DevicePollError, currentDelayMs: number): number {
  return error === "slow_down" ? currentDelayMs + 5_000 : currentDelayMs;
}

export function normalizeVerificationUrl(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) return "";
  return /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
}

export async function pollDeviceAuth(
  config: TidalConfig,
  start: DeviceAuthStart,
  signal?: AbortSignal,
): Promise<UserToken> {
  const deadline = Date.now() + start.expiresIn * 1000;
  let delayMs = start.interval * 1000;
  while (Date.now() < deadline) {
    if (signal?.aborted) throw new Error("TIDAL device login cancelled");
    const response = await tokenRequest(
      config,
      new URLSearchParams({
        client_id: config.deviceClientId,
        scope: config.deviceScope,
        device_code: start.deviceCode,
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
      }),
      config.deviceClientId,
      config.deviceClientSecret,
    );
    if (response.ok) {
      const token = await response.json() as TokenResponse;
      if (!token.refresh_token) throw new Error("TIDAL login returned no refresh token");
      return {
        accessToken: token.access_token,
        refreshToken: token.refresh_token,
        expiresAt: Date.now() + token.expires_in * 1000,
        userId: token.user?.userId ?? null,
      };
    }
    const payload = await response.json().catch(() => ({})) as { error?: string };
    const error = payload.error ?? `http_${response.status}`;
    if (error !== "authorization_pending" && error !== "slow_down") {
      throw new Error(`TIDAL device login failed: ${error}`);
    }
    delayMs = nextDevicePollDelay(error, delayMs);
    await Bun.sleep(delayMs);
  }
  throw new Error("TIDAL device login expired");
}

export async function refreshUserToken(config: TidalConfig, refreshToken: string): Promise<UserToken> {
  validateBrowseConfig(config);
  const response = await tokenRequest(
    config,
    new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: config.refreshClientId,
      scope: config.refreshScope,
    }),
    config.refreshClientId,
    config.refreshClientSecret,
  );
  if (!response.ok) throw new Error(`TIDAL token refresh failed (${response.status}): ${await response.text()}`);
  const token = await response.json() as TokenResponse;
  return {
    accessToken: token.access_token,
    refreshToken: token.refresh_token ?? refreshToken,
    expiresAt: Date.now() + token.expires_in * 1000,
    userId: token.user?.userId ?? null,
  };
}
