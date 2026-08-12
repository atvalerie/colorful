import { describe, expect, test } from "bun:test";
import { OpaqueRelayStore, StoreError } from "./store";

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
});
