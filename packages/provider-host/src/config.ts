export type TidalConfig = Readonly<{
  browseClientId: string;
  browseClientSecret: string;
  browseScope: string;
  deviceClientId: string;
  deviceClientSecret: string;
  deviceScope: string;
  refreshClientId: string;
  refreshClientSecret: string;
  refreshScope: string;
  authBaseUrl: string;
  apiBaseUrl: string;
  countryCode: string;
  userAgent: string;
}>;

export function readTidalConfig(env: NodeJS.ProcessEnv = process.env): TidalConfig {
  const browseClientId = env.TIDAL_CLIENT_ID ?? "";
  const browseClientSecret = env.TIDAL_CLIENT_SECRET ?? "";
  return {
    browseClientId,
    browseClientSecret,
    browseScope: env.TIDAL_CLIENT_SCOPE ?? "r_usr w_usr w_sub",
    deviceClientId: env.TIDAL_DEVICE_CLIENT_ID ?? "",
    deviceClientSecret: env.TIDAL_DEVICE_CLIENT_SECRET ?? "",
    deviceScope: env.TIDAL_DEVICE_SCOPE ?? "r_usr+w_usr+w_sub",
    refreshClientId: env.TIDAL_REFRESH_CLIENT_ID ?? browseClientId,
    refreshClientSecret: env.TIDAL_REFRESH_CLIENT_SECRET ?? browseClientSecret,
    refreshScope: env.TIDAL_REFRESH_SCOPE ?? "r_usr w_usr w_sub",
    authBaseUrl: env.TIDAL_AUTH_BASE_URL ?? "https://auth.tidal.com",
    apiBaseUrl: env.TIDAL_API_BASE_URL ?? "https://openapi.tidal.com/v2/",
    countryCode: env.TIDAL_COUNTRY_CODE ?? env.COUNTRY_CODE ?? "US",
    userAgent: env.TIDAL_USER_AGENT ?? "colorful/0.1 (Linux)",
  };
}

export function validateBrowseConfig(config: TidalConfig): void {
  if (!config.browseClientId || !config.browseClientSecret) {
    throw new Error("TIDAL browse credentials are missing; run through scripts/run-linux.sh or set TIDAL_CLIENT_ID and TIDAL_CLIENT_SECRET");
  }
}

export function validateDeviceConfig(config: TidalConfig): void {
  if (!config.deviceClientId || !config.deviceClientSecret) {
    throw new Error("TIDAL device credentials are missing; set TIDAL_DEVICE_CLIENT_ID and TIDAL_DEVICE_CLIENT_SECRET");
  }
}

