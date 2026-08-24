import { describe, expect, test } from "bun:test";
import { OpaqueRelayStore, StoreError } from "./store";
import { randomToken, sha256 } from "./protocol";

describe("opaque relay store", () => {
  test("stores and replays ciphertext without interpreting it", async () => {
    const store = new OpaqueRelayStore();
    const mailbox = await store.createMailbox();
    const ciphertext = new TextEncoder().encode(JSON.stringify({ playlist: "private" }));

    await expect(store.putMessage(mailbox.mailboxId, mailbox.capability, "op-1", ciphertext)).resolves.toMatchObject({ created: true });
    await expect(store.listMessages(mailbox.mailboxId, mailbox.capability)).resolves.toMatchObject([
      { messageId: "op-1", ciphertext: Buffer.from(ciphertext).toString("base64") },
    ]);
  });

  test("replaying the same message is idempotent and changing its ciphertext conflicts", async () => {
    const store = new OpaqueRelayStore();
    const mailbox = await store.createMailbox();
    const first = new Uint8Array([1, 2, 3]);
    await store.putMessage(mailbox.mailboxId, mailbox.capability, "event-1", first);
    await expect(store.putMessage(mailbox.mailboxId, mailbox.capability, "event-1", first)).resolves.toMatchObject({ created: false });
    await expect(store.putMessage(mailbox.mailboxId, mailbox.capability, "event-1", new Uint8Array([4])))
      .rejects.toMatchObject({ code: "conflict" });
  });

  test("wrong capabilities reveal no mailbox existence", async () => {
    const store = new OpaqueRelayStore();
    const mailbox = await store.createMailbox();
    await expect(store.listMessages(mailbox.mailboxId, "not-the-capability"))
      .rejects.toMatchObject({ code: "not_found" });
  });

  test("party capabilities are separated by role", async () => {
    const store = new OpaqueRelayStore();
    const party = await store.createParty();
    await expect(store.authorizeParty(party.sessionId, party.hostCapability)).resolves.toBe("host");
    await expect(store.authorizeParty(party.sessionId, party.guestCapability)).resolves.toBe("guest");
    await expect(store.authorizeParty(party.sessionId, "wrong"))
      .rejects.toBeInstanceOf(StoreError);
  });

  test("issues digest-only one-use public join tickets", async () => {
    const store = new OpaqueRelayStore();
    const party = await store.createParty();
    const ticket = randomToken();
    const expiresAtMs = Date.now() + 30_000;
    await expect(store.issueJoinTicket(
      party.sessionId, party.hostCapability, ticket, expiresAtMs, "opaque-bootstrap",
    )).resolves.toMatchObject({ expiresAtMs });
    const internals = store as unknown as {
      parties: Map<string, { joinTicketDigests: Set<string> }>;
      joinTicketsByDigest: Map<string, unknown>;
    };
    const session = internals.parties.get(party.sessionId)!;
    const serializedTickets = JSON.stringify([...internals.joinTicketsByDigest.values()]);
    expect(serializedTickets).not.toContain(ticket);
    expect([...session.joinTicketDigests]).toContain(await sha256(ticket));
    await expect(store.redeemJoinTicket(ticket)).resolves.toEqual({
      sessionId: party.sessionId,
      bootstrapCiphertext: "opaque-bootstrap",
    });
    await expect(store.redeemJoinTicket(ticket)).rejects.toMatchObject({ code: "not_found" });
  });

  test("enforces the outstanding cap and O(1) digest index", async () => {
    const store = new OpaqueRelayStore();
    const party = await store.createParty();
    const expiresAtMs = Date.now() + 30_000;
    for (let index = 0; index < 16; index++)
      await store.issueJoinTicket(party.sessionId, party.hostCapability, randomToken(), expiresAtMs, "bootstrap");
    await expect(store.issueJoinTicket(party.sessionId, party.hostCapability, randomToken(), expiresAtMs, "bootstrap"))
      .rejects.toMatchObject({ code: "quota" });
    const internals = store as unknown as { joinTicketsByDigest: Map<string, unknown> };
    expect(internals.joinTicketsByDigest.size).toBe(16);
  });

  test("accounts bootstrap bytes globally and releases them on redemption and party expiry", async () => {
    const store = new OpaqueRelayStore();
    const party = await store.createParty();
    const lookup = randomToken();
    await store.issueJoinTicket(party.sessionId, party.hostCapability, lookup, Date.now() + 30_000, "small");
    expect((store as unknown as { joinTicketBytes: number }).joinTicketBytes).toBe(5);
    await store.redeemJoinTicket(lookup);
    expect((store as unknown as { joinTicketBytes: number }).joinTicketBytes).toBe(0);

    const expiringLookup = randomToken();
    const expiringAt = Date.now() + 10_000;
    await store.issueJoinTicket(party.sessionId, party.hostCapability, expiringLookup, expiringAt, "expired");
    store.cleanup(expiringAt + 1);
    expect((store as unknown as { joinTicketBytes: number }).joinTicketBytes).toBe(0);
    expect((store as unknown as { joinTicketsByDigest: Map<string, unknown> }).joinTicketsByDigest.size).toBe(0);
  });

  test("rejects invalid or too-short join-ticket expiry", async () => {
    const store = new OpaqueRelayStore();
    const party = await store.createParty();
    await expect(store.issueJoinTicket(
      party.sessionId, party.hostCapability, randomToken(), Date.now() + 1_000, "bootstrap",
    )).rejects.toMatchObject({ code: "invalid" });
    await expect(store.issueJoinTicket(
      party.sessionId, party.guestCapability, randomToken(), Date.now() + 30_000, "bootstrap",
    )).rejects.toMatchObject({ code: "not_found" });
  });
});
