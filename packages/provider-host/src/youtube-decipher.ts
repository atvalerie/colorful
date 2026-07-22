import { Log, Platform, Player, type Types } from "youtubei.js";
import { debugLog } from "./debug";

// YouTube.js statically extracts a small dependency-closed transform program
// from base.js before this evaluator is called. It rejects side-effectful
// initializers; the full remote player script is never evaluated here.
Log.setLevel(Log.Level.NONE);
Platform.shim.eval = async (data: Types.BuildScriptResult): Promise<unknown> =>
  new Function(`"use strict";\n${data.output}`)();

const players = new Map<string, Promise<Player>>();
const nsigCache = new Map<string, string>();

export function clearYouTubeDecipherCache(): void {
  players.clear();
  nsigCache.clear();
}

async function player(playerId: string): Promise<Player> {
  let pending = players.get(playerId);
  if (!pending) {
    pending = Player.create(undefined, fetch, undefined, playerId).catch((error) => {
      players.delete(playerId);
      throw error;
    });
    players.set(playerId, pending);
  }
  return pending;
}

export async function decipherYouTubeFormat(
  playerId: string,
  url: string,
  signatureCipher: string,
  cipher: string,
): Promise<string> {
  if (!/^[A-Za-z0-9_-]+$/.test(playerId)) throw new Error("Invalid YouTube player ID");
  const startedAt = Date.now();
  const resolved = await (await player(playerId)).decipher(url, signatureCipher, cipher, nsigCache);
  if (!resolved.startsWith("https://")) throw new Error("YouTube player decipher returned an invalid media URL");
  debugLog("youtube.decipher", "completed", { playerId, elapsedMs: Date.now() - startedAt });
  return resolved;
}
