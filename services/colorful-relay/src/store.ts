import {
  DEFAULT_MAILBOX_TTL_SECONDS,
  DEFAULT_PARTY_TTL_SECONDS,
  MAX_MAILBOX_BYTES,
  MAX_MAILBOXES,
  MAX_MAILBOX_MESSAGES,
  MAX_MESSAGE_BYTES,
  MAX_JOIN_TICKETS_PER_PARTY,
  MAX_JOIN_HANDLE_TICKETS_PER_HANDLE,
  MAX_JOIN_TICKET_TTL_MS,
  MIN_JOIN_TICKET_TTL_MS,
  MAX_TOTAL_JOIN_TICKET_BYTES,
  MAX_PARTY_TTL_SECONDS,
  MAX_PARTY_SESSIONS,
  MAX_TOTAL_MAILBOX_BYTES,
  bytesToBase64,
  clampTtl,
  randomToken,
  sha256,
  validJoinTicketLookup,
  validJoinHandleLookup,
  validJoinTicketBootstrap,
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
  joinTicketDigests: Set<string>;
  stableJoinHandleDigest?: string;
}

interface StableJoinHandle {
  handleDigest: string;
  sessionId: string;
  // Invite generation is opaque to the relay. It is retained only to make a
  // host refresh idempotent and to prevent an older refresh racing a newer
  // invite into replacing it.
  inviteGeneration?: string | number;
  expiresAtMs: number;
  bootstrapCiphertext: string;
  bootstrapBytes: number;
  ticketDigests: Set<string>;
}

interface JoinTicket {
  ticketDigest: string;
  sessionId: string;
  expiresAtMs: number;
  bootstrapCiphertext: string;
  bootstrapBytes: number;
  stableHandleDigest?: string;
}

export class OpaqueRelayStore {
  private readonly mailboxes = new Map<string, Mailbox>();
  private readonly parties = new Map<string, PartySession>();
  private mailboxesCreated = 0;
  private partiesCreated = 0;
  private queuedMessages = 0;
  private queuedBytes = 0;
  private readonly joinTicketsByDigest = new Map<string, JoinTicket>();
  private readonly stableJoinHandlesByDigest = new Map<string, StableJoinHandle>();
  private joinTicketBytes = 0;

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
      joinTicketDigests: new Set(),
    });
    this.partiesCreated += 1;
    return { sessionId, hostCapability, guestCapability, expiresAtMs };
  }

  /**
   * Register the long-lived opaque lookup used by a Discord button. The
   * encrypted bootstrap is retained as ciphertext only. A new lookup replaces
   * the prior lookup for this party and revokes all tickets minted from it.
   *
   * `inviteGeneration` is optional for compatibility with older hosts. When
   * supplied as a number, an older generation cannot overwrite a newer one.
   */
  public async registerJoinHandle(
    sessionId: string,
    capability: string,
    handleLookup: unknown,
    bootstrapCiphertext: unknown,
    inviteGeneration?: unknown,
  ): Promise<{ handleLookup: string; publicHandle: string; expiresAtMs: number; inviteGeneration?: string | number }> {
    const party = this.parties.get(sessionId);
    if (!party) throw new StoreError("not_found");
    const now = Date.now();
    if (party.expiresAtMs <= now) {
      this.deleteParty(sessionId);
      throw new StoreError("expired");
    }
    if (await sha256(capability) !== party.hostCapabilityDigest) throw new StoreError("not_found");
    if (!validJoinHandleLookup(handleLookup) || !validJoinTicketBootstrap(bootstrapCiphertext))
      throw new StoreError("invalid");
    const generation = normalizeInviteGeneration(inviteGeneration);
    let previous = party.stableJoinHandleDigest
      ? this.stableJoinHandlesByDigest.get(party.stableJoinHandleDigest)
      : undefined;
    if (previous && generation !== undefined && typeof previous.inviteGeneration === "number"
        && typeof generation === "number" && generation < previous.inviteGeneration)
      throw new StoreError("conflict");

    const handleDigest = await sha256(handleLookup);
    // Hashing yields to the event loop. Re-read the current generation before
    // committing so a slower, older registration cannot overwrite a newer
    // invite that completed while this request was hashing.
    const current = party.stableJoinHandleDigest
      ? this.stableJoinHandlesByDigest.get(party.stableJoinHandleDigest)
      : undefined;
    if (current !== previous) {
      if (current && generation !== undefined && typeof current.inviteGeneration === "number"
          && typeof generation === "number" && generation < current.inviteGeneration)
        throw new StoreError("conflict");
      previous = current;
    }
    if (party.expiresAtMs <= Date.now()) {
      this.deleteParty(sessionId);
      throw new StoreError("expired");
    }
    const collision = this.stableJoinHandlesByDigest.get(handleDigest);
    if (collision && collision.sessionId !== sessionId) throw new StoreError("conflict");
    // Refreshing a handle also replaces its encrypted bootstrap and revokes
    // any tickets minted from the previous record, even when a host retries
    // with the same lookup.
    if (previous) this.removeStableJoinHandle(previous);
    if (collision) this.removeStableJoinHandle(collision);

    const bootstrapBytes = new TextEncoder().encode(bootstrapCiphertext).byteLength;
    const entry: StableJoinHandle = {
      handleDigest,
      sessionId,
      ...(generation === undefined ? {} : { inviteGeneration: generation }),
      expiresAtMs: party.expiresAtMs,
      bootstrapCiphertext,
      bootstrapBytes,
      ticketDigests: new Set(),
    };
    this.stableJoinHandlesByDigest.set(handleDigest, entry);
    party.stableJoinHandleDigest = handleDigest;
    return {
      handleLookup,
      publicHandle: handleLookup,
      expiresAtMs: entry.expiresAtMs,
      ...(generation === undefined ? {} : { inviteGeneration: generation }),
    };
  }

  /** Revoke the current Discord handle and every derived one-use ticket. */
  public async revokeJoinHandle(
    sessionId: string,
    capability: string,
    expectedHandleLookup?: unknown,
  ): Promise<boolean> {
    const party = this.parties.get(sessionId);
    if (!party) throw new StoreError("not_found");
    if (await sha256(capability) !== party.hostCapabilityDigest) throw new StoreError("not_found");
    const handle = party.stableJoinHandleDigest
      ? this.stableJoinHandlesByDigest.get(party.stableJoinHandleDigest)
      : undefined;
    if (!handle) return false;
    if (expectedHandleLookup !== undefined) {
      if (!validJoinHandleLookup(expectedHandleLookup)) throw new StoreError("invalid");
      if (await sha256(expectedHandleLookup) !== handle.handleDigest) return false;
    }
    // The digest check above yields while hashing. A refresh may have replaced
    // the handle during that yield; never let this stale revoke clear the new
    // generation.
    if (party.stableJoinHandleDigest !== handle.handleDigest
        || this.stableJoinHandlesByDigest.get(handle.handleDigest) !== handle)
      return false;
    this.removeStableJoinHandle(handle);
    return true;
  }

  /**
   * Mint a fresh one-use ticket at click time. The handle itself is never
   * consumed, so concurrent clicks receive independent ticket lookups.
   */
  public async mintJoinTicketFromHandle(
    handleLookup: unknown,
  ): Promise<{ ticketLookup: string; expiresAtMs: number }> {
    if (!validJoinHandleLookup(handleLookup)) throw new StoreError("invalid");
    const handleDigest = await sha256(handleLookup);
    const handle = this.stableJoinHandlesByDigest.get(handleDigest);
    const now = Date.now();
    if (!handle) throw new StoreError("not_found");
    const party = this.parties.get(handle.sessionId);
    if (!party || party.expiresAtMs <= now || handle.expiresAtMs <= now) {
      if (party && party.expiresAtMs <= now) this.deleteParty(handle.sessionId);
      else this.removeStableJoinHandle(handle);
      throw new StoreError("not_found");
    }
    this.removeExpiredJoinTickets(party, now);
    if (handle.ticketDigests.size >= MAX_JOIN_HANDLE_TICKETS_PER_HANDLE)
      throw new StoreError("quota");
    const ticketLookup = randomToken();
    const ticketDigest = await sha256(ticketLookup);
    // A refresh/revoke can run while the digest is being computed. Do not
    // commit a ticket for a handle that stopped being current meanwhile.
    if (this.stableJoinHandlesByDigest.get(handleDigest) !== handle
        || party.stableJoinHandleDigest !== handleDigest)
      throw new StoreError("not_found");
    const expiresAtMs = Math.min(now + MAX_JOIN_TICKET_TTL_MS, handle.expiresAtMs, party.expiresAtMs);
    if (expiresAtMs <= now) throw new StoreError("expired");
    const bootstrapBytes = new TextEncoder().encode(handle.bootstrapCiphertext).byteLength;
    if (this.joinTicketBytes + bootstrapBytes > MAX_TOTAL_JOIN_TICKET_BYTES)
      throw new StoreError("quota");
    const entry: JoinTicket = {
      ticketDigest,
      sessionId: handle.sessionId,
      expiresAtMs,
      bootstrapCiphertext: handle.bootstrapCiphertext,
      bootstrapBytes,
      stableHandleDigest: handleDigest,
    };
    this.joinTicketsByDigest.set(ticketDigest, entry);
    party.joinTicketDigests.add(ticketDigest);
    handle.ticketDigests.add(ticketDigest);
    this.joinTicketBytes += bootstrapBytes;
    return { ticketLookup, expiresAtMs };
  }

  public async issueJoinTicket(
    sessionId: string,
    capability: string,
    ticketLookup: unknown,
    expiresAtMs: unknown,
    bootstrapCiphertext: unknown,
  ): Promise<{ expiresAtMs: number }> {
    const party = this.parties.get(sessionId);
    if (!party) throw new StoreError("not_found");
    if (party.expiresAtMs <= Date.now()) {
      this.deleteParty(sessionId);
      throw new StoreError("expired");
    }
    const digest = await sha256(capability);
    if (digest !== party.hostCapabilityDigest) throw new StoreError("not_found");
    if (!validJoinTicketLookup(ticketLookup) || !validJoinTicketBootstrap(bootstrapCiphertext))
      throw new StoreError("invalid");
    if (typeof expiresAtMs !== "number" || !Number.isSafeInteger(expiresAtMs))
      throw new StoreError("invalid");
    const now = Date.now();
    const minimumExpiry = Math.min(now + MIN_JOIN_TICKET_TTL_MS, party.expiresAtMs);
    const maximumExpiry = Math.min(now + MAX_JOIN_TICKET_TTL_MS, party.expiresAtMs);
    if (expiresAtMs < minimumExpiry || expiresAtMs > maximumExpiry)
      throw new StoreError("invalid");
    this.removeExpiredJoinTickets(party, now);
    if (party.joinTicketDigests.size >= MAX_JOIN_TICKETS_PER_PARTY) throw new StoreError("quota");
    const bootstrapBytes = new TextEncoder().encode(bootstrapCiphertext).byteLength;
    if (this.joinTicketBytes + bootstrapBytes > MAX_TOTAL_JOIN_TICKET_BYTES) throw new StoreError("quota");
    const ticketDigest = await sha256(ticketLookup);
    if (this.joinTicketsByDigest.has(ticketDigest))
      throw new StoreError("conflict");
    const entry = {
      ticketDigest,
      sessionId,
      expiresAtMs,
      bootstrapCiphertext,
      bootstrapBytes,
    } satisfies JoinTicket;
    party.joinTicketDigests.add(ticketDigest);
    this.joinTicketsByDigest.set(ticketDigest, entry);
    this.joinTicketBytes += bootstrapBytes;
    return { expiresAtMs };
  }

  public async redeemJoinTicket(
    ticketLookup: unknown,
  ): Promise<{ sessionId: string; bootstrapCiphertext: string }> {
    if (!validJoinTicketLookup(ticketLookup))
      throw new StoreError("invalid");
    const ticketDigest = await sha256(ticketLookup);
    const now = Date.now();
    const entry = this.joinTicketsByDigest.get(ticketDigest);
    if (!entry) throw new StoreError("not_found");
    const party = this.parties.get(entry.sessionId);
    if (!party || party.expiresAtMs <= now || entry.expiresAtMs <= now) {
      if (party && party.expiresAtMs <= now) this.deleteParty(entry.sessionId);
      else this.removeJoinTicket(entry);
      throw new StoreError("not_found");
    }
    // Delete before returning so concurrent redemption attempts cannot reuse it.
    this.removeJoinTicket(entry);
    return { sessionId: entry.sessionId, bootstrapCiphertext: entry.bootstrapCiphertext };
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
    if (this.queuedBytes + ciphertext.byteLength > MAX_TOTAL_MAILBOX_BYTES) throw new StoreError("quota");
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
    this.queuedMessages += 1;
    this.queuedBytes += ciphertext.byteLength;
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
    this.queuedMessages -= 1;
    this.queuedBytes -= message.ciphertext.byteLength;
    return true;
  }

  public async authorizeParty(sessionId: string, capability: string): Promise<PartyRole> {
    const party = this.parties.get(sessionId);
    if (!party) throw new StoreError("not_found");
    if (party.expiresAtMs <= Date.now()) {
      this.deleteParty(sessionId);
      throw new StoreError("expired");
    }
    const digest = await sha256(capability);
    if (digest === party.hostCapabilityDigest) return "host";
    if (digest === party.guestCapabilityDigest) return "guest";
    throw new StoreError("not_found");
  }

  public partyExpiresAt(sessionId: string): number | undefined {
    return this.parties.get(sessionId)?.expiresAtMs;
  }

  public cleanup(now = Date.now()): void {
    for (const [id, mailbox] of this.mailboxes) {
      if (mailbox.expiresAtMs <= now) {
        this.queuedMessages -= mailbox.messages.size;
        this.queuedBytes -= mailbox.bytes;
        this.mailboxes.delete(id);
        continue;
      }
      this.removeExpiredMessages(mailbox, now);
    }
    for (const [id, party] of this.parties)
      if (party.expiresAtMs <= now) this.deleteParty(id);
      else this.removeExpiredJoinTickets(party, now);
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
    return {
      activeMailboxes: this.mailboxes.size,
      queuedMessages: this.queuedMessages,
      queuedBytes: this.queuedBytes,
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
        this.queuedMessages -= 1;
        this.queuedBytes -= message.ciphertext.byteLength;
      }
    }
  }

  private removeExpiredJoinTickets(party: PartySession, now: number): void {
    for (const digest of party.joinTicketDigests) {
      const ticket = this.joinTicketsByDigest.get(digest);
      if (ticket && ticket.expiresAtMs <= now) this.removeJoinTicket(ticket);
      else if (!ticket) party.joinTicketDigests.delete(digest);
    }
  }

  private deleteParty(sessionId: string): void {
    const party = this.parties.get(sessionId);
    if (party) {
      for (const digest of [...party.joinTicketDigests]) {
        const ticket = this.joinTicketsByDigest.get(digest);
        if (ticket) this.removeJoinTicket(ticket);
        else party.joinTicketDigests.delete(digest);
      }
      if (party.stableJoinHandleDigest) {
        const handle = this.stableJoinHandlesByDigest.get(party.stableJoinHandleDigest);
        if (handle) this.removeStableJoinHandle(handle);
      }
    }
    this.parties.delete(sessionId);
  }

  private removeJoinTicket(ticket: JoinTicket): void {
    if (!this.joinTicketsByDigest.delete(ticket.ticketDigest)) return;
    const party = this.parties.get(ticket.sessionId);
    party?.joinTicketDigests.delete(ticket.ticketDigest);
    if (ticket.stableHandleDigest) {
      this.stableJoinHandlesByDigest.get(ticket.stableHandleDigest)?.ticketDigests.delete(ticket.ticketDigest);
    }
    this.joinTicketBytes -= ticket.bootstrapBytes;
  }

  private removeStableJoinHandle(handle: StableJoinHandle): void {
    if (!this.stableJoinHandlesByDigest.delete(handle.handleDigest)) return;
    const party = this.parties.get(handle.sessionId);
    if (party?.stableJoinHandleDigest === handle.handleDigest)
      delete party.stableJoinHandleDigest;
    for (const digest of [...handle.ticketDigests]) {
      const ticket = this.joinTicketsByDigest.get(digest);
      if (ticket) this.removeJoinTicket(ticket);
      else handle.ticketDigests.delete(digest);
    }
  }
}

function normalizeInviteGeneration(value: unknown): string | number | undefined {
  if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) return value;
  if (typeof value === "string" && /^[A-Za-z0-9._~-]{1,128}$/.test(value)) return value;
  if (value === undefined || value === null) return undefined;
  throw new StoreError("invalid");
}
