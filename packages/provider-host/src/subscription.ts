export type SubscriptionStatus = {
  canStreamFull: boolean;
  userId: string;
  countryCode: string;
  email: string | null;
  username: string | null;
  nickname: string | null;
  emailVerified: boolean;
  accountCreated: string | null;
  startDate: string | null;
  status: string | null;
  validUntil: string | null;
  subscriptionType: string | null;
  offlineGracePeriod: number | null;
  highestSoundQuality: string | null;
  premiumAccess: boolean;
  canGetTrial: boolean;
  paymentType: string | null;
  paymentOverdue: boolean;
};

export type AccountIdentity = Pick<SubscriptionStatus,
  "userId" | "countryCode" | "email" | "username" | "nickname" | "emailVerified" | "accountCreated">;

type SubscriptionDocument = {
  startDate?: unknown;
  status?: unknown;
  validUntil?: unknown;
  subscription?: { type?: unknown; offlineGracePeriod?: unknown };
  highestSoundQuality?: unknown;
  premiumAccess?: unknown;
  canGetTrial?: unknown;
  paymentType?: unknown;
  paymentOverdue?: unknown;
};

export function hasPremiumPlayback(subscription: SubscriptionDocument): boolean {
  return subscription.status === "ACTIVE"
    && subscription.premiumAccess === true
    && subscription.paymentOverdue !== true;
}

function nullableString(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function tidalTimestamp(value: unknown): string | null {
  if (typeof value === "number" && Number.isFinite(value)) return new Date(value).toISOString();
  return nullableString(value);
}

export async function loadAccountIdentity(accessToken: string): Promise<AccountIdentity> {
  const headers = { Authorization: `Bearer ${accessToken}`, Accept: "application/json" };
  const meResponse = await fetch("https://login.tidal.com/oauth2/me", { headers });
  if (!meResponse.ok) throw new Error(`TIDAL account lookup failed (${meResponse.status})`);
  const me = await meResponse.json() as Record<string, unknown>;
  const userId = String(me.userId ?? "").trim();
  const countryCode = String(me.countryCode ?? "").trim().toUpperCase();
  if (!userId || !countryCode) throw new Error("TIDAL account lookup returned no user or country");
  return {
    userId,
    countryCode,
    email: nullableString(me.email),
    username: nullableString(me.username),
    nickname: nullableString(me.nickname),
    emailVerified: me.emailVerified === true,
    accountCreated: tidalTimestamp(me.created),
  };
}

export async function loadSubscriptionStatus(accessToken: string, identity?: AccountIdentity): Promise<SubscriptionStatus> {
  const account = identity ?? await loadAccountIdentity(accessToken);
  const headers = { Authorization: `Bearer ${accessToken}`, Accept: "application/json" };
  const url = new URL(`https://tidal.com/v1/users/${encodeURIComponent(account.userId)}/subscription`);
  url.searchParams.set("countryCode", account.countryCode);
  url.searchParams.set("locale", "en_US");
  url.searchParams.set("deviceType", "BROWSER");
  const subscriptionResponse = await fetch(url, { headers });
  if (!subscriptionResponse.ok) throw new Error(`TIDAL subscription lookup failed (${subscriptionResponse.status})`);
  const subscription = await subscriptionResponse.json() as SubscriptionDocument;

  return {
    ...account,
    canStreamFull: hasPremiumPlayback(subscription),
    startDate: nullableString(subscription.startDate),
    status: nullableString(subscription.status),
    validUntil: nullableString(subscription.validUntil),
    subscriptionType: nullableString(subscription.subscription?.type),
    offlineGracePeriod: Number.isFinite(subscription.subscription?.offlineGracePeriod)
      ? Number(subscription.subscription?.offlineGracePeriod) : null,
    highestSoundQuality: nullableString(subscription.highestSoundQuality),
    premiumAccess: subscription.premiumAccess === true,
    canGetTrial: subscription.canGetTrial === true,
    paymentType: nullableString(subscription.paymentType),
    paymentOverdue: subscription.paymentOverdue === true,
  };
}
