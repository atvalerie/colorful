import {
  MAX_ALLOCATIONS_PER_MINUTE,
  MAX_RELAY_BYTES_PER_SECOND,
  MAX_RELAY_CONNECTIONS,
  MAX_RELAY_FRAME_BYTES,
  MAX_RELAY_FRAMES_PER_SECOND,
  MAX_RELAY_PEERS,
  MAX_MESSAGE_BYTES,
  MAX_JOIN_TICKET_BOOTSTRAP_BYTES,
  MAX_JOIN_TICKET_ISSUANCES_PER_MINUTE,
  MAX_JOIN_TICKET_REDEMPTIONS_IN_FLIGHT,
  MAX_JOIN_TICKET_REDEMPTIONS_PER_MINUTE,
  PROTOCOL_VERSION,
  bearerToken,
} from "./protocol";
import type { PartyRole } from "./protocol";
import { OpaqueRelayStore, StoreError } from "./store";

export interface RelaySocketData {
  sessionId: string;
  role: PartyRole;
  expiresAtMs: number;
  rateWindowMs: number;
  rateFrames: number;
  rateBytes: number;
}

type RelaySocket = Bun.ServerWebSocket<RelaySocketData>;

const jsonHeaders = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: jsonHeaders });
}

function errorResponse(status: number, code: string): Response {
  return json({ ok: false, error: code, protocolVersion: PROTOCOL_VERSION }, status);
}

function partyLandingPage(sessionId: string): Response {
  const safeSession = JSON.stringify(sessionId);
  const html = `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>Listen together in Colorful</title><style>body{margin:0;background:#0d0d10;color:#f5f5f5;font:16px system-ui;display:grid;min-height:100vh;place-items:center}.card{width:min(420px,calc(100% - 40px));padding:28px;border:1px solid #303038;background:#17171c}h1{font-size:24px;margin:0 0 8px}p{color:#aaaab3;line-height:1.5}a{display:block;margin-top:12px;padding:12px;text-align:center;text-decoration:none;color:#111;background:#f5f5f5}a.secondary{color:#ddd;background:#24242b}</style><main class="card"><h1>Listen together</h1><p>This private invite opens in Colorful. The relay never receives the secret after the # in this URL.</p><a id="open" href="#">Open in Colorful</a><a class="secondary" href="https://github.com/atvalerie/colorful">Get Colorful</a></main><script>const session=${safeSession};document.getElementById('open').href='colorful://party/'+encodeURIComponent(session)+location.hash;</script></html>`;
  return new Response(html, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}

function discordJoinLandingPage(): Response {
  const html = `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>Join in Colorful</title><style>body{margin:0;background:#0d0d10;color:#f5f5f5;font:16px system-ui;display:grid;min-height:100vh;place-items:center}.card{width:min(420px,calc(100% - 40px));padding:28px;border:1px solid #303038;background:#17171c}h1{font-size:24px;margin:0 0 8px}p{color:#aaaab3;line-height:1.5}a{display:block;margin-top:12px;padding:12px;text-align:center;text-decoration:none;color:#111;background:#f5f5f5}</style><main class="card"><h1>Join in Colorful</h1><p>This invite opens in Colorful. The relay never receives the secret after the # in this URL.</p><a id="open" href="#">Open in Colorful</a></main><script>document.getElementById('open').href='colorful://discord/join'+location.hash;</script></html>`;
  return new Response(html, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}

function storeStatus(error: unknown): number {
  if (!(error instanceof StoreError)) return 500;
  return error.code === "not_found" || error.code === "expired" ? 404
    : error.code === "quota" ? 413
    : error.code === "conflict" ? 409 : 400;
}

async function requestJson(request: Request, maxBodyCharacters = 4096): Promise<Record<string, unknown>> {
  const body = await request.text();
  if (body.length > maxBodyCharacters) throw new StoreError("invalid");
  let value: unknown;
  try {
    value = JSON.parse(body);
  } catch {
    throw new StoreError("invalid");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new StoreError("invalid");
  return value as Record<string, unknown>;
}

function pathParts(request: Request): string[] {
  try {
    return new URL(request.url).pathname.split("/").filter(Boolean).map((part) => decodeURIComponent(part));
  } catch {
    return [];
  }
}

export function createRelayApp(
  store: OpaqueRelayStore = new OpaqueRelayStore(),
  listen: { hostname?: string; port?: number } = {},
): Bun.Serve.Options<RelaySocketData> {
  const sockets = new Map<string, Set<RelaySocket>>();
  const startedAtMs = Date.now();
  let allocationWindowMs = startedAtMs;
  let allocationsThisMinute = 0;
  let joinTicketWindowMs = startedAtMs;
  let joinTicketsIssuedThisMinute = 0;
  let joinTicketsInFlight = 0;
  let joinTicketRedemptionWindowMs = startedAtMs;
  let joinTicketRedemptionsThisMinute = 0;
  let joinTicketRedemptionsInFlight = 0;
  let activeRelayConnections = 0;
  let relayConnectionsAccepted = 0;
  let framesForwarded = 0;
  let bytesForwarded = 0;

  return {
    ...listen,
    async fetch(request, server) {
      const url = new URL(request.url);
      const parts = pathParts(request);

      if (request.method === "GET" && url.pathname === "/healthz")
        return json({ ok: true, service: "colorful-relay", protocolVersion: PROTOCOL_VERSION });

      if (request.method === "GET" && url.pathname === "/stats") {
        const storeStats = store.publicStats();
        return json({
          ok: true,
          service: "colorful-relay",
          protocolVersion: PROTOCOL_VERSION,
          startedAtMs,
          uptimeSeconds: Math.floor((Date.now() - startedAtMs) / 1000),
          ...storeStats,
          activeRelayConnections,
          relayConnectionsAccepted,
          framesForwarded,
          bytesForwarded,
        });
      }

      if (request.method === "GET" && parts[0] === "party" && parts.length === 2
          && /^[A-Za-z0-9_-]{8,64}$/.test(parts[1]!))
        return partyLandingPage(parts[1]!);

      if (request.method === "GET" && url.pathname === "/discord/join")
        return discordJoinLandingPage();

      if (request.method === "POST" && url.pathname === "/v1/mailboxes") {
        const now = Date.now();
        if (now - allocationWindowMs >= 60_000) {
          allocationWindowMs = now;
          allocationsThisMinute = 0;
        }
        if (++allocationsThisMinute > MAX_ALLOCATIONS_PER_MINUTE) return errorResponse(429, "rate_limited");
        try {
          const body = await requestJson(request);
          return json({ ok: true, protocolVersion: PROTOCOL_VERSION, mailbox: await store.createMailbox(body.ttlSeconds) }, 201);
        } catch (error) {
          return errorResponse(storeStatus(error), error instanceof StoreError ? error.code : "invalid");
        }
      }

      if (request.method === "POST" && url.pathname === "/v1/party-sessions") {
        const now = Date.now();
        if (now - allocationWindowMs >= 60_000) {
          allocationWindowMs = now;
          allocationsThisMinute = 0;
        }
        if (++allocationsThisMinute > MAX_ALLOCATIONS_PER_MINUTE) return errorResponse(429, "rate_limited");
        try {
          const body = await requestJson(request);
          return json({ ok: true, protocolVersion: PROTOCOL_VERSION, party: await store.createParty(body.ttlSeconds) }, 201);
        } catch (error) {
          return errorResponse(storeStatus(error), error instanceof StoreError ? error.code : "invalid");
        }
      }

      if (request.method === "POST" && parts[0] === "v1" && parts[1] === "party-sessions"
          && parts[2] && parts[3] === "join-tickets" && parts.length === 4) {
        const capability = bearerToken(request);
        if (!capability) return errorResponse(404, "not_found");
        let reserved = false;
        try {
          // Authenticate before consulting or reserving the global issuance
          // budget so unauthenticated callers cannot exhaust it.
          if (await store.authorizeParty(parts[2], capability) !== "host")
            return errorResponse(404, "not_found");
          const body = await requestJson(request, MAX_JOIN_TICKET_BOOTSTRAP_BYTES + 4096);
          const now = Date.now();
          if (now - joinTicketWindowMs >= 60_000) {
            joinTicketWindowMs = now;
            joinTicketsIssuedThisMinute = 0;
          }
          if (joinTicketsIssuedThisMinute + joinTicketsInFlight >= MAX_JOIN_TICKET_ISSUANCES_PER_MINUTE)
            return errorResponse(429, "rate_limited");
          joinTicketsInFlight += 1;
          reserved = true;
          const result = await store.issueJoinTicket(
            parts[2], capability, body.ticketLookup, body.expiresAtMs,
            body.bootstrapCiphertext,
          );
          joinTicketsIssuedThisMinute += 1;
          joinTicketsInFlight -= 1;
          reserved = false;
          return json({ ok: true, protocolVersion: PROTOCOL_VERSION, ...result, joinTicket: result }, 201);
        } catch (error) {
          if (reserved) joinTicketsInFlight = Math.max(0, joinTicketsInFlight - 1);
          return errorResponse(storeStatus(error), error instanceof StoreError ? error.code : "invalid");
        }
      }

      if (request.method === "POST" && url.pathname === "/v1/party-join-tickets/redeem") {
        const now = Date.now();
        if (now - joinTicketRedemptionWindowMs >= 60_000) {
          joinTicketRedemptionWindowMs = now;
          joinTicketRedemptionsThisMinute = 0;
        }
        if (joinTicketRedemptionsThisMinute >= MAX_JOIN_TICKET_REDEMPTIONS_PER_MINUTE
            || joinTicketRedemptionsInFlight >= MAX_JOIN_TICKET_REDEMPTIONS_IN_FLIGHT)
          return errorResponse(429, "rate_limited");
        joinTicketRedemptionsThisMinute += 1;
        joinTicketRedemptionsInFlight += 1;
        try {
          const body = await requestJson(request, MAX_JOIN_TICKET_BOOTSTRAP_BYTES + 4096);
          const result = await store.redeemJoinTicket(body.ticketLookup);
          return json({ ok: true, protocolVersion: PROTOCOL_VERSION, ...result });
        } catch (error) {
          return errorResponse(storeStatus(error), error instanceof StoreError ? error.code : "invalid");
        } finally {
          joinTicketRedemptionsInFlight = Math.max(0, joinTicketRedemptionsInFlight - 1);
        }
      }

      if (parts[0] === "v1" && parts[1] === "mailboxes" && parts[2] && parts[3] === "messages") {
        const mailboxId = parts[2];
        const capability = bearerToken(request);
        if (!capability) return errorResponse(404, "not_found");
        try {
          if (request.method === "GET" && parts.length === 4) {
            const limit = Number(url.searchParams.get("limit") ?? 100);
            if (!Number.isInteger(limit) || limit < 1 || limit > 100)
              return errorResponse(400, "invalid_limit");
            const after = url.searchParams.get("after") ?? undefined;
            return json({ ok: true, protocolVersion: PROTOCOL_VERSION, messages: await store.listMessages(mailboxId, capability, after, limit) });
          }
          if (request.method === "PUT" && parts[4]) {
            const lengthHeader = request.headers.get("content-length");
            if (lengthHeader !== null) {
              const contentLength = Number(lengthHeader);
              if (!Number.isInteger(contentLength) || contentLength < 0 || contentLength > MAX_MESSAGE_BYTES)
                return errorResponse(413, "message_too_large");
            }
            const body = new Uint8Array(await request.arrayBuffer());
            const result = await store.putMessage(mailboxId, capability, parts[4], body);
            return json({ ok: true, protocolVersion: PROTOCOL_VERSION, ...result }, result.created ? 201 : 200);
          }
          if (request.method === "DELETE" && parts[4])
            return json({ ok: true, protocolVersion: PROTOCOL_VERSION, deleted: await store.acknowledgeMessage(mailboxId, capability, parts[4]) });
        } catch (error) {
          return errorResponse(storeStatus(error), error instanceof StoreError ? error.code : "internal");
        }
      }

      if (request.method === "GET" && request.headers.get("upgrade")?.toLowerCase() === "websocket"
          && parts[0] === "v1" && parts[1] === "party-sessions" && parts[2] && parts[3] === "relay") {
        if (Number(url.searchParams.get("protocolVersion")) !== PROTOCOL_VERSION)
          return errorResponse(426, "protocol_version_mismatch");
        const capability = bearerToken(request);
        if (!capability) return errorResponse(404, "not_found");
        try {
          const role = await store.authorizeParty(parts[2], capability);
          const existing = sockets.get(parts[2]) ?? new Set<RelaySocket>();
          if (existing.size >= MAX_RELAY_PEERS) return errorResponse(429, "too_many_peers");
          if (activeRelayConnections >= MAX_RELAY_CONNECTIONS) return errorResponse(503, "relay_capacity");
          const expiresAtMs = store.partyExpiresAt(parts[2]);
          if (!expiresAtMs) return errorResponse(404, "not_found");
          if (server.upgrade(request, { data: {
            sessionId: parts[2], role, expiresAtMs,
            rateWindowMs: Date.now(), rateFrames: 0, rateBytes: 0,
          } })) return undefined;
          return errorResponse(400, "upgrade_failed");
        } catch (error) {
          return errorResponse(storeStatus(error), error instanceof StoreError ? error.code : "internal");
        }
      }

      return errorResponse(404, "not_found");
    },
    websocket: {
      maxPayloadLength: MAX_RELAY_FRAME_BYTES,
      open(socket) {
        const peers = sockets.get(socket.data.sessionId) ?? new Set<RelaySocket>();
        peers.add(socket);
        sockets.set(socket.data.sessionId, peers);
        activeRelayConnections += 1;
        relayConnectionsAccepted += 1;
      },
      message(socket, message) {
        const now = Date.now();
        if (now >= socket.data.expiresAtMs) {
          socket.close(1008, "party session expired");
          return;
        }
        if (typeof message === "string") {
          socket.close(1003, "binary frames required");
          return;
        }
        const frame = message instanceof ArrayBuffer ? new Uint8Array(message) : new Uint8Array(message);
        if (frame.byteLength > MAX_RELAY_FRAME_BYTES) {
          socket.close(1009, "frame too large");
          return;
        }
        if (now - socket.data.rateWindowMs >= 1000) {
          socket.data.rateWindowMs = now;
          socket.data.rateFrames = 0;
          socket.data.rateBytes = 0;
        }
        socket.data.rateFrames += 1;
        socket.data.rateBytes += frame.byteLength;
        if (socket.data.rateFrames > MAX_RELAY_FRAMES_PER_SECOND
            || socket.data.rateBytes > MAX_RELAY_BYTES_PER_SECOND) {
          socket.close(1008, "relay rate exceeded");
          return;
        }
        for (const peer of sockets.get(socket.data.sessionId) ?? [])
          if (peer !== socket) {
            if (peer.send(frame) <= 0) {
              peer.close(1013, "relay peer is too slow");
              continue;
            }
            framesForwarded += 1;
            bytesForwarded += frame.byteLength;
          }
      },
      close(socket) {
        activeRelayConnections = Math.max(0, activeRelayConnections - 1);
        const peers = sockets.get(socket.data.sessionId);
        peers?.delete(socket);
        if (peers?.size === 0) sockets.delete(socket.data.sessionId);
      },
    },
    maxRequestBodySize: MAX_MESSAGE_BYTES,
    idleTimeout: 120,
  };
}
