export const PROTOCOL_VERSION = 2;
export const DEFAULT_MAILBOX_TTL_SECONDS = 7 * 24 * 60 * 60;
export const MAX_MAILBOX_TTL_SECONDS = DEFAULT_MAILBOX_TTL_SECONDS;
export const DEFAULT_PARTY_TTL_SECONDS = 2 * 60 * 60;
export const MAX_PARTY_TTL_SECONDS = 24 * 60 * 60;
export const MAX_MAILBOX_MESSAGES = 256;
export const MAX_MAILBOX_BYTES = 8 * 1024 * 1024;
export const MAX_MESSAGE_BYTES = 256 * 1024;
export const MAX_RELAY_PEERS = 64;
export const MAX_RELAY_FRAME_BYTES = 512 * 1024;
export const MAX_MAILBOXES = 10_000;
export const MAX_PARTY_SESSIONS = 2_000;

const tokenBytes = 32;

export type PartyRole = "host" | "guest";

export interface MailboxDescriptor {
  mailboxId: string;
  capability: string;
  expiresAtMs: number;
}

export interface PartyDescriptor {
  sessionId: string;
  hostCapability: string;
  guestCapability: string;
  expiresAtMs: number;
}

export interface MailboxMessageView {
  messageId: string;
  ciphertext: string;
  createdAtMs: number;
  expiresAtMs: number;
}

export function randomToken(): string {
  const bytes = new Uint8Array(tokenBytes);
  crypto.getRandomValues(bytes);
  return Buffer.from(bytes).toString("base64url");
}

export async function sha256(value: string | Uint8Array): Promise<string> {
  const input = typeof value === "string" ? new TextEncoder().encode(value) : value;
  const digest = await crypto.subtle.digest("SHA-256", input);
  return Buffer.from(digest).toString("hex");
}

export function bytesToBase64(value: Uint8Array): string {
  return Buffer.from(value).toString("base64");
}

export function clampTtl(value: unknown, defaultSeconds: number, maximumSeconds: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return defaultSeconds;
  return Math.max(60, Math.min(maximumSeconds, Math.floor(value)));
}

export function validMessageId(value: string): boolean {
  return /^[A-Za-z0-9][A-Za-z0-9._~-]{0,199}$/.test(value);
}

export function bearerToken(request: Request): string | null {
  const header = request.headers.get("authorization");
  if (!header?.startsWith("Bearer ")) return null;
  const value = header.slice("Bearer ".length).trim();
  return value.length > 0 && value.length <= 256 ? value : null;
}
