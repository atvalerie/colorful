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
  // These are public web/device application clients, not user credentials.
  // Environment values remain available as an escape hatch when TIDAL rotates
  // a client or a developer needs to exercise another first-party profile.
  const browseClientId = env.TIDAL_CLIENT_ID ?? "lw3vR6GE1vtNBsjv";
  const browseClientSecret = env.TIDAL_CLIENT_SECRET ?? "Y8tIpqKJxs9BEIwYr0I9bSbMWDsogXJx9LaN3mCHwD4=";
  return {
    browseClientId,
    browseClientSecret,
    browseScope: env.TIDAL_CLIENT_SCOPE ?? "r_usr w_usr w_sub",
    deviceClientId: env.TIDAL_DEVICE_CLIENT_ID ?? "fX2JxdmntZWK0ixT",
    deviceClientSecret: env.TIDAL_DEVICE_CLIENT_SECRET ?? "1Nm5AfDAjxrgJFJbKNWLeAyKGVGmINuXPPLHVXAvxAg=",
    deviceScope: env.TIDAL_DEVICE_SCOPE ?? "r_usr+w_usr+w_sub",
    refreshClientId: env.TIDAL_REFRESH_CLIENT_ID ?? browseClientId,
    refreshClientSecret: env.TIDAL_REFRESH_CLIENT_SECRET ?? browseClientSecret,
    refreshScope: env.TIDAL_REFRESH_SCOPE ?? "r_usr w_usr w_sub",
    authBaseUrl: env.TIDAL_AUTH_BASE_URL ?? "https://auth.tidal.com",
    apiBaseUrl: env.TIDAL_API_BASE_URL ?? "https://openapi.tidal.com/v2/",
    countryCode: env.TIDAL_COUNTRY_CODE ?? env.COUNTRY_CODE ?? "US",
    userAgent: env.TIDAL_USER_AGENT ?? "colorful/0.1 (Desktop)",
  };
}

export function validateBrowseConfig(config: TidalConfig): void {
  if (!config.browseClientId || !config.browseClientSecret) {
    throw new Error("TIDAL browse client configuration is missing");
  }
}

export function validateDeviceConfig(config: TidalConfig): void {
  if (!config.deviceClientId || !config.deviceClientSecret) {
    throw new Error("TIDAL device client configuration is missing");
  }
}
