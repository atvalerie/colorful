import { afterEach, describe, expect, test } from "bun:test";
import { createRelayApp } from "./server";
import type { RelaySocketData } from "./server";
import { OpaqueRelayStore } from "./store";
import { randomToken } from "./protocol";

const servers: Bun.Server<RelaySocketData>[] = [];

afterEach(() => {
  for (const server of servers.splice(0)) server.stop(true);
});

async function startTestServer(): Promise<Bun.Server<RelaySocketData>> {
  const server = Bun.serve<RelaySocketData>(createRelayApp(new OpaqueRelayStore(), {
    hostname: "127.0.0.1",
    port: 0,
  }));
  servers.push(server);
  return server;
}

describe("relay HTTP API", () => {
  test("creates an expiring mailbox and stores opaque binary data", async () => {
    const server = await startTestServer();
    const origin = `http://${server.hostname}:${server.port}`;
    const created = await fetch(`${origin}/v1/mailboxes`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ttlSeconds: 60 }),
    });
    expect(created.status).toBe(201);
    const descriptor = (await created.json() as { mailbox: { mailboxId: string; capability: string } }).mailbox;

    const payload = new Uint8Array([0, 255, 12, 99]);
    const stored = await fetch(`${origin}/v1/mailboxes/${descriptor.mailboxId}/messages/event-1`, {
      method: "PUT",
      headers: { authorization: `Bearer ${descriptor.capability}`, "content-type": "application/octet-stream" },
      body: payload,
    });
    expect(stored.status).toBe(201);

    const listed = await fetch(`${origin}/v1/mailboxes/${descriptor.mailboxId}/messages`, {
      headers: { authorization: `Bearer ${descriptor.capability}` },
    });
    expect(listed.status).toBe(200);
    expect(await listed.json()).toMatchObject({
      messages: [{ messageId: "event-1", ciphertext: Buffer.from(payload).toString("base64") }],
    });
  });

  test("does not reveal mailbox existence without its capability", async () => {
    const server = await startTestServer();
    const origin = `http://${server.hostname}:${server.port}`;
    const created = await fetch(`${origin}/v1/mailboxes`, { method: "POST", body: "{}" });
    const descriptor = (await created.json() as { mailbox: { mailboxId: string } }).mailbox;
    const response = await fetch(`${origin}/v1/mailboxes/${descriptor.mailboxId}/messages`);
    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({ error: "not_found" });
  });

  test("party creation returns separate short-lived capabilities", async () => {
    const server = await startTestServer();
    const origin = `http://${server.hostname}:${server.port}`;
    const response = await fetch(`${origin}/v1/party-sessions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ttlSeconds: 60 }),
    });
    expect(response.status).toBe(201);
    const party = (await response.json() as { party: { hostCapability: string; guestCapability: string } }).party;
    expect(party.hostCapability).not.toBe(party.guestCapability);
  });

  test("publishes aggregate stats without identifiers or capabilities", async () => {
    const server = await startTestServer();
    const origin = `http://${server.hostname}:${server.port}`;
    await fetch(`${origin}/v1/mailboxes`, { method: "POST", body: "{}" });
    await fetch(`${origin}/v1/party-sessions`, { method: "POST", body: "{}" });
    const response = await fetch(`${origin}/stats`);
    expect(response.status).toBe(200);
    const stats = await response.json() as Record<string, unknown>;
    expect(stats).toMatchObject({
      protocolVersion: 2,
      activeMailboxes: 1,
      activePartySessions: 1,
      mailboxesCreated: 1,
      partySessionsCreated: 1,
      activeRelayConnections: 0,
    });
    const serialized = JSON.stringify(stats).toLowerCase();
    expect(serialized).not.toContain("capability");
    expect(serialized).not.toContain("sessionid");
    expect(serialized).not.toContain("mailboxid");
    expect(serialized).not.toContain("ip");
  });

  test("serves a private-fragment-preserving party landing page", async () => {
    const server = await startTestServer();
    const origin = `http://${server.hostname}:${server.port}`;
    const response = await fetch(`${origin}/party/session_123`);
    expect(response.status).toBe(200);
    const html = await response.text();
    expect(html).toContain("colorful://party/");
    expect(html).toContain("https://github.com/atvalerie/colorful");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
  });

  test("serves a hardened Discord join landing page that preserves its fragment client-side", async () => {
    const server = await startTestServer();
    const origin = `http://${server.hostname}:${server.port}`;
    const response = await fetch(`${origin}/discord/join`);
    expect(response.status).toBe(200);
    const html = await response.text();
    expect(html).toContain("/v1/party-join-handles/mint");
    expect(html).toContain("colorful://discord/join'+original");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
    expect(response.headers.get("content-security-policy")).toContain("default-src 'none'");
    expect(response.headers.get("content-security-policy")).toContain("connect-src 'self'");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
  });

  test("issues and redeems host-authenticated one-use join tickets", async () => {
    const server = await startTestServer();
    const origin = `http://${server.hostname}:${server.port}`;
    const created = await fetch(`${origin}/v1/party-sessions`, { method: "POST", body: "{}" });
    const party = (await created.json() as {
      party: { sessionId: string; hostCapability: string; guestCapability: string; expiresAtMs: number };
    }).party;
    const ticket = randomToken();
    const issueBody = {
      ticketLookup: ticket,
      expiresAtMs: Date.now() + 30_000,
      bootstrapCiphertext: "sealed-bootstrap",
    };
    const guestAttempt = await fetch(`${origin}/v1/party-sessions/${party.sessionId}/join-tickets`, {
      method: "POST",
      headers: { authorization: `Bearer ${party.guestCapability}`, "content-type": "application/json" },
      body: JSON.stringify(issueBody),
    });
    expect(guestAttempt.status).toBe(404);
    const issued = await fetch(`${origin}/v1/party-sessions/${party.sessionId}/join-tickets`, {
      method: "POST",
      headers: { authorization: `Bearer ${party.hostCapability}`, "content-type": "application/json" },
      body: JSON.stringify(issueBody),
    });
    expect(issued.status).toBe(201);
    const issuedBody = await issued.json() as Record<string, unknown>;
    expect(issuedBody).toMatchObject({ joinTicket: { expiresAtMs: issueBody.expiresAtMs }, expiresAtMs: issueBody.expiresAtMs });
    expect(JSON.stringify(issuedBody)).not.toContain(ticket);

    const unknown = await fetch(`${origin}/v1/party-join-tickets/redeem`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ ticketLookup: randomToken() }),
    });
    expect(unknown.status).toBe(404);
    const redeemed = await fetch(`${origin}/v1/party-join-tickets/redeem`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ ticketLookup: ticket }),
    });
    expect(redeemed.status).toBe(200);
    expect(await redeemed.json()).toMatchObject({ sessionId: party.sessionId, bootstrapCiphertext: "sealed-bootstrap" });
    const replay = await fetch(`${origin}/v1/party-join-tickets/redeem`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ ticketLookup: ticket }),
    });
    expect(replay.status).toBe(404);
  });

  test("mints click-time tickets from a stable handle and revokes stale handles", async () => {
    const server = await startTestServer();
    const origin = `http://${server.hostname}:${server.port}`;
    const created = await fetch(`${origin}/v1/party-sessions`, { method: "POST", body: "{}" });
    const party = (await created.json() as { party: { sessionId: string; hostCapability: string } }).party;
    const handle = randomToken();
    const registered = await fetch(`${origin}/v1/party-sessions/${party.sessionId}/join-handles`, {
      method: "POST",
      headers: { authorization: `Bearer ${party.hostCapability}`, "content-type": "application/json" },
      body: JSON.stringify({ handleLookup: handle, inviteGeneration: 1, bootstrapCiphertext: "sealed" }),
    });
    expect(registered.status).toBe(201);
    const [first, second] = await Promise.all([
      fetch(`${origin}/v1/party-join-handles/mint`, {
        method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ handleLookup: handle }),
      }),
      fetch(`${origin}/v1/party-join-handles/mint`, {
        method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ handleLookup: handle }),
      }),
    ]);
    expect(first.status).toBe(201);
    expect(second.status).toBe(201);
    const firstLookup = (await first.json() as { ticketLookup: string }).ticketLookup;
    const secondLookup = (await second.json() as { ticketLookup: string }).ticketLookup;
    expect(firstLookup).not.toBe(secondLookup);
    const redeemed = await fetch(`${origin}/v1/party-join-tickets/redeem`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ ticketLookup: firstLookup }),
    });
    expect(redeemed.status).toBe(200);
    expect(await redeemed.json()).toMatchObject({ sessionId: party.sessionId, bootstrapCiphertext: "sealed" });
    const replay = await fetch(`${origin}/v1/party-join-tickets/redeem`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ ticketLookup: firstLookup }),
    });
    expect(replay.status).toBe(404);

    const revoked = await fetch(`${origin}/v1/party-sessions/${party.sessionId}/join-handles/revoke`, {
      method: "POST",
      headers: { authorization: `Bearer ${party.hostCapability}`, "content-type": "application/json" },
      body: JSON.stringify({ handleLookup: handle }),
    });
    expect(revoked.status).toBe(200);
    const stale = await fetch(`${origin}/v1/party-join-handles/mint`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ handleLookup: handle }),
    });
    expect(stale.status).toBe(404);
  });

  test("rate-limits global join-ticket issuance", async () => {
    const server = await startTestServer();
    const origin = `http://${server.hostname}:${server.port}`;
    const unauthorizedPartyResponse = await fetch(`${origin}/v1/party-sessions`, { method: "POST", body: "{}" });
    const unauthorizedParty = (await unauthorizedPartyResponse.json() as { party: { sessionId: string } }).party;
    for (let index = 0; index < 3; index++) {
      const unauthorized = await fetch(`${origin}/v1/party-sessions/${unauthorizedParty.sessionId}/join-tickets`, {
        method: "POST", body: JSON.stringify({ ticketLookup: randomToken(), expiresAtMs: Date.now() + 30_000, bootstrapCiphertext: "x" }),
      });
      expect(unauthorized.status).toBe(404);
    }
    let lastStatus = 0;
    for (let index = 0; index < 121; index++) {
      const created = await fetch(`${origin}/v1/party-sessions`, { method: "POST", body: "{}" });
      const party = (await created.json() as { party: { sessionId: string; hostCapability: string } }).party;
      const response = await fetch(`${origin}/v1/party-sessions/${party.sessionId}/join-tickets`, {
        method: "POST",
        headers: { authorization: `Bearer ${party.hostCapability}`, "content-type": "application/json" },
        body: JSON.stringify({
          ticketLookup: randomToken(),
          expiresAtMs: Date.now() + 30_000,
          bootstrapCiphertext: "bootstrap",
        }),
      });
      lastStatus = response.status;
    }
    expect(lastStatus).toBe(429);
  });

  test("rate-limits unauthenticated join-ticket redemption", async () => {
    const server = await startTestServer();
    const origin = `http://${server.hostname}:${server.port}`;
    let lastStatus = 0;
    for (let index = 0; index < 241; index++) {
      const response = await fetch(`${origin}/v1/party-join-tickets/redeem`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ ticketLookup: randomToken() }),
      });
      lastStatus = response.status;
    }
    expect(lastStatus).toBe(429);
  });

  test("relay forwards binary frames without echoing to the sender", async () => {
    const server = await startTestServer();
    const origin = `http://${server.hostname}:${server.port}`;
    const created = await fetch(`${origin}/v1/party-sessions`, { method: "POST", body: "{}" });
    const party = (await created.json() as {
      party: { sessionId: string; hostCapability: string; guestCapability: string };
    }).party;
    const relayUrl = `ws://${server.hostname}:${server.port}/v1/party-sessions/${party.sessionId}/relay?protocolVersion=2`;
    const host = new WebSocket(relayUrl, { headers: { authorization: `Bearer ${party.hostCapability}` } } as never);
    const guest = new WebSocket(relayUrl, { headers: { authorization: `Bearer ${party.guestCapability}` } } as never);
    const opened = (socket: WebSocket) => new Promise<void>((resolve, reject) => {
      socket.addEventListener("open", () => resolve(), { once: true });
      socket.addEventListener("error", () => reject(new Error("websocket failed")), { once: true });
    });
    await Promise.all([opened(host), opened(guest)]);

    const received = new Promise<Uint8Array>((resolve) => {
      guest.addEventListener("message", (event) => {
        const value = event.data instanceof ArrayBuffer ? new Uint8Array(event.data) : new Uint8Array(event.data);
        resolve(value);
      }, { once: true });
    });
    const payload = new Uint8Array([9, 8, 7, 6]);
    host.send(payload);
    expect([...await received]).toEqual([...payload]);
    host.close();
    guest.close();
  });

  test("rejects incompatible party protocol versions before WebSocket upgrade", async () => {
    const server = await startTestServer();
    const origin = `http://${server.hostname}:${server.port}`;
    const created = await fetch(`${origin}/v1/party-sessions`, { method: "POST", body: "{}" });
    const party = (await created.json() as { party: { sessionId: string; guestCapability: string } }).party;
    const response = await fetch(
      `${origin}/v1/party-sessions/${party.sessionId}/relay?protocolVersion=1`,
      { headers: { upgrade: "websocket", authorization: `Bearer ${party.guestCapability}` } },
    );
    expect(response.status).toBe(426);
    expect(await response.json()).toMatchObject({ error: "protocol_version_mismatch", protocolVersion: 2 });
  });
});
