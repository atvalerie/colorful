import { OpaqueRelayStore } from "./store";
import { createRelayApp } from "./server";

const port = Number(process.env.COLORFUL_RELAY_PORT ?? 8787);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("COLORFUL_RELAY_PORT must be a valid TCP port");

const store = new OpaqueRelayStore();
const server = Bun.serve({
  ...createRelayApp(store),
  hostname: process.env.COLORFUL_RELAY_HOST ?? "127.0.0.1",
  port,
});

const cleanupTimer = setInterval(() => store.cleanup(), 60_000);
cleanupTimer.unref?.();

console.log(`colorful relay listening on ${server.hostname}:${server.port}`);
