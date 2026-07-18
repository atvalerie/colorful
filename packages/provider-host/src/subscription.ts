export type SubscriptionStatus = {
  canStreamFull: boolean;
  status: string | null;
  validUntil: string | null;
  highestSoundQuality: string | null;
  paymentOverdue: boolean;
};

type SubscriptionDocument = {
  status?: unknown;
  validUntil?: unknown;
  highestSoundQuality?: unknown;
  premiumAccess?: unknown;
  paymentOverdue?: unknown;
};

export function hasPremiumPlayback(subscription: SubscriptionDocument): boolean {
  return subscription.status === "ACTIVE"
    && subscription.premiumAccess === true
    && subscription.paymentOverdue !== true;
}

export async function loadSubscriptionStatus(accessToken: string): Promise<SubscriptionStatus> {
  const headers = { Authorization: `Bearer ${accessToken}`, Accept: "application/json" };
  const meResponse = await fetch("https://login.tidal.com/oauth2/me", { headers });
  if (!meResponse.ok) throw new Error(`TIDAL account lookup failed (${meResponse.status})`);
  const me = await meResponse.json() as { userId?: unknown; countryCode?: unknown };
  const userId = String(me.userId ?? "").trim();
  const countryCode = String(me.countryCode ?? "").trim().toUpperCase();
  if (!userId || !countryCode) throw new Error("TIDAL account lookup returned no user or country");

  const url = new URL(`https://tidal.com/v1/users/${encodeURIComponent(userId)}/subscription`);
  url.searchParams.set("countryCode", countryCode);
  url.searchParams.set("locale", "en_US");
  url.searchParams.set("deviceType", "BROWSER");
  const subscriptionResponse = await fetch(url, { headers });
  if (!subscriptionResponse.ok) throw new Error(`TIDAL subscription lookup failed (${subscriptionResponse.status})`);
  const subscription = await subscriptionResponse.json() as SubscriptionDocument;

  return {
    canStreamFull: hasPremiumPlayback(subscription),
    status: typeof subscription.status === "string" ? subscription.status : null,
    validUntil: typeof subscription.validUntil === "string" ? subscription.validUntil : null,
    highestSoundQuality: typeof subscription.highestSoundQuality === "string" ? subscription.highestSoundQuality : null,
    paymentOverdue: subscription.paymentOverdue === true,
  };
}
