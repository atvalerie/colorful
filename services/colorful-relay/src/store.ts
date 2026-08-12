import {
  DEFAULT_MAILBOX_TTL_SECONDS,
  DEFAULT_PARTY_TTL_SECONDS,
  MAX_MAILBOX_BYTES,
  MAX_MAILBOXES,
  MAX_MAILBOX_MESSAGES,
  MAX_MESSAGE_BYTES,
  MAX_PARTY_TTL_SECONDS,
  MAX_PARTY_SESSIONS,
  bytesToBase64,
  clampTtl,
  randomToken,
  sha256,
  validMessageId,
} from "./protocol";
import type { MailboxDescriptor, MailboxMessageView, PartyDescriptor, PartyRole } from "./protocol";

export class StoreError extends Error {
  public constructor(public readonly code: "not_found" | "expired" | "invalid" | "quota" | "conflict") {
    super(code);
  }
}

interface MailboxMessage {
  messageId: string;
  ciphertext: Uint8Array;
  ciphertextDigest: string;
  createdAtMs: number;
  expiresAtMs: number;
}

interface Mailbox {
  mailboxId: string;
  capabilityDigest: string;
  createdAtMs: number;
  expiresAtMs: number;
  bytes: number;
  messages: Map<string, MailboxMessage>;
}

interface PartySession {
  sessionId: string;
  hostCapabilityDigest: string;
  guestCapabilityDigest: string;
  createdAtMs: number;
  expiresAtMs: number;
}

export class OpaqueRelayStore {
  private readonly mailboxes = new Map<string, Mailbox>();
  private readonly parties = new Map<string, PartySession>();
  private mailboxesCreated = 0;
  private partiesCreated = 0;

  public async createMailbox(ttlSeconds?: unknown): Promise<MailboxDescriptor> {
    this.cleanup();
    if (this.mailboxes.size >= MAX_MAILBOXES) throw new StoreError("quota");
    const now = Date.now();
    const capability = randomToken();
    const mailboxId = randomToken().slice(0, 24);
    const expiresAtMs = now + clampTtl(ttlSeconds, DEFAULT_MAILBOX_TTL_SECONDS, DEFAULT_MAILBOX_TTL_SECONDS) * 1000;
    this.mailboxes.set(mailboxId, {
      mailboxId,
      capabilityDigest: await sha256(capability),
      createdAtMs: now,
      expiresAtMs,
      bytes: 0,
      messages: new Map(),
    });
    this.mailboxesCreated += 1;
    return { mailboxId, capability, expiresAtMs };
  }

  public async createParty(ttlSeconds?: unknown): Promise<PartyDescriptor> {
    this.cleanup();
    if (this.parties.size >= MAX_PARTY_SESSIONS) throw new StoreError("quota");
    const now = Date.now();
    const hostCapability = randomToken();
    const guestCapability = randomToken();
    const sessionId = randomToken().slice(0, 24);
    const expiresAtMs = now + clampTtl(ttlSeconds, DEFAULT_PARTY_TTL_SECONDS, MAX_PARTY_TTL_SECONDS) * 1000;
    this.parties.set(sessionId, {
      sessionId,
      hostCapabilityDigest: await sha256(hostCapability),
      guestCapabilityDigest: await sha256(guestCapability),
      createdAtMs: now,
      expiresAtMs,
    });
    this.partiesCreated += 1;
    return { sessionId, hostCapability, guestCapability, expiresAtMs };
  }

  public async putMessage(
    mailboxId: string,
    capability: string,
    messageId: string,
    ciphertext: Uint8Array,
    ttlSeconds?: unknown,
  ): Promise<{ created: boolean; expiresAtMs: number }> {
    if (!validMessageId(messageId) || ciphertext.byteLength === 0 || ciphertext.byteLength > MAX_MESSAGE_BYTES)
      throw new StoreError("invalid");
    const mailbox = await this.authorizeMailbox(mailboxId, capability);
    this.removeExpiredMessages(mailbox, Date.now());
    const digest = await sha256(ciphertext);
    const existing = mailbox.messages.get(messageId);
    if (existing) {
      if (existing.ciphertextDigest !== digest) throw new StoreError("conflict");
      return { created: false, expiresAtMs: existing.expiresAtMs };
    }
    if (mailbox.messages.size >= MAX_MAILBOX_MESSAGES || mailbox.bytes + ciphertext.byteLength > MAX_MAILBOX_BYTES)
      throw new StoreError("quota");
    const now = Date.now();
    const expiresAtMs = Math.min(
      mailbox.expiresAtMs,
      now + clampTtl(ttlSeconds, DEFAULT_MAILBOX_TTL_SECONDS, DEFAULT_MAILBOX_TTL_SECONDS) * 1000,
    );
    mailbox.messages.set(messageId, {
      messageId,
      ciphertext: new Uint8Array(ciphertext),
      ciphertextDigest: digest,
      createdAtMs: now,
      expiresAtMs,
    });
    mailbox.bytes += ciphertext.byteLength;
    return { created: true, expiresAtMs };
  }

  public async listMessages(
    mailboxId: string,
    capability: string,
    afterMessageId?: string,
    limit = 100,
  ): Promise<MailboxMessageView[]> {
    const mailbox = await this.authorizeMailbox(mailboxId, capability);
    this.removeExpiredMessages(mailbox, Date.now());
    const messages = [...mailbox.messages.values()].sort((left, right) =>
      left.createdAtMs - right.createdAtMs || left.messageId.localeCompare(right.messageId));
    const afterIndex = afterMessageId ? messages.findIndex((message) => message.messageId === afterMessageId) : -1;
    return messages.slice(afterIndex + 1, afterIndex + 1 + Math.max(1, Math.min(100, Math.floor(limit))))
      .map((message) => ({
        messageId: message.messageId,
        ciphertext: bytesToBase64(message.ciphertext),
        createdAtMs: message.createdAtMs,
        expiresAtMs: message.expiresAtMs,
      }));
  }

  public async acknowledgeMessage(mailboxId: string, capability: string, messageId: string): Promise<boolean> {
    const mailbox = await this.authorizeMailbox(mailboxId, capability);
    const message = mailbox.messages.get(messageId);
    if (!message) return false;
    mailbox.messages.delete(messageId);
    mailbox.bytes -= message.ciphertext.byteLength;
    return true;
  }

  public async authorizeParty(sessionId: string, capability: string): Promise<PartyRole> {
    const party = this.parties.get(sessionId);
    if (!party) throw new StoreError("not_found");
    if (party.expiresAtMs <= Date.now()) {
      this.parties.delete(sessionId);
      throw new StoreError("expired");
    }
    const digest = await sha256(capability);
    if (digest === party.hostCapabilityDigest) return "host";
    if (digest === party.guestCapabilityDigest) return "guest";
    throw new StoreError("not_found");
  }

  public cleanup(now = Date.now()): void {
    for (const [id, mailbox] of this.mailboxes) {
      if (mailbox.expiresAtMs <= now) {
        this.mailboxes.delete(id);
        continue;
      }
      this.removeExpiredMessages(mailbox, now);
    }
    for (const [id, party] of this.parties)
      if (party.expiresAtMs <= now) this.parties.delete(id);
  }

  public publicStats(): {
    activeMailboxes: number;
    queuedMessages: number;
    queuedBytes: number;
    activePartySessions: number;
    mailboxesCreated: number;
    partySessionsCreated: number;
  } {
    this.cleanup();
    let queuedMessages = 0;
    let queuedBytes = 0;
    for (const mailbox of this.mailboxes.values()) {
      queuedMessages += mailbox.messages.size;
      queuedBytes += mailbox.bytes;
    }
    return {
      activeMailboxes: this.mailboxes.size,
      queuedMessages,
      queuedBytes,
      activePartySessions: this.parties.size,
      mailboxesCreated: this.mailboxesCreated,
      partySessionsCreated: this.partiesCreated,
    };
  }

  private async authorizeMailbox(mailboxId: string, capability: string): Promise<Mailbox> {
    const mailbox = this.mailboxes.get(mailboxId);
    if (!mailbox) throw new StoreError("not_found");
    if (mailbox.expiresAtMs <= Date.now()) {
      this.mailboxes.delete(mailboxId);
      throw new StoreError("expired");
    }
    if (await sha256(capability) !== mailbox.capabilityDigest) throw new StoreError("not_found");
    return mailbox;
  }

  private removeExpiredMessages(mailbox: Mailbox, now: number): void {
    for (const [id, message] of mailbox.messages) {
      if (message.expiresAtMs <= now) {
        mailbox.messages.delete(id);
        mailbox.bytes -= message.ciphertext.byteLength;
      }
    }
  }
}
