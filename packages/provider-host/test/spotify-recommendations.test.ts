import { describe, expect, test } from "bun:test";
import {
  SpotifyRecommendationClient,
  SpotifyRecommendationError,
  collectNextPageUrls,
  collectTrackIds,
  decodeTrackMetadata,
  spotifyIdToHex,
  spotifyWebTrack,
} from "../src/spotify-recommendations";

function concat(...parts: Uint8Array[]): Uint8Array {
  const result = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

function varint(value: number): Uint8Array {
  const bytes: number[] = [];
  let remaining = value;
  do {
    const byte = remaining % 128;
    remaining = Math.floor(remaining / 128);
    bytes.push(byte | (remaining ? 0x80 : 0));
  } while (remaining);
  return Uint8Array.from(bytes);
}

function textField(number: number, value: string): Uint8Array {
  return messageField(number, new TextEncoder().encode(value));
}

function messageField(number: number, value: Uint8Array): Uint8Array {
  return concat(varint((number << 3) | 2), varint(value.length), value);
}

function metadata(id: string, isrc: string, title = "Track"): Uint8Array {
  const externalId = concat(textField(1, "isrc"), textField(2, isrc));
  return concat(textField(2, title), messageField(4, textField(2, "Artist")), messageField(10, externalId));
}

function jsonResponse(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function protobufResponse(value: Uint8Array, status = 200): Response {
  return new Response(value as unknown as BodyInit, { status, headers: { "content-type": "application/x-protobuf" } });
}

const seedId = "4uLU6hMCjMI75M1A2tKUQC";
const recommendationId = "7gf5ffmSqKQBDnkmSe2Dt7";
const secondRecommendationId = "00isIFJWVpXIQ8HkGICSQp";

describe("Spotify recommendation protocol primitives", () => {
  test("converts Spotify base62 IDs to metadata GIDs", () => {
    expect(spotifyIdToHex(recommendationId)).toBe("ee9b2a58162f4527b9a737e44c049139");
  });

  test("decodes track metadata and its ISRC external ID", () => {
    const externalId = concat(textField(1, "isrc"), textField(2, "GBARL9300136"));
    const payload = concat(
      textField(2, "Together Forever"),
      messageField(3, textField(2, "Whenever You Need Somebody")),
      messageField(4, textField(2, "Rick Astley")),
      concat(varint((7 << 3) | 0), varint(411066)),
      concat(varint((9 << 3) | 0), varint(1)),
      messageField(10, externalId),
    );
    expect(decodeTrackMetadata(payload, secondRecommendationId)).toEqual({
      spotifyId: secondRecommendationId,
      uri: `spotify:track:${secondRecommendationId}`,
      isrc: "GBARL9300136",
      title: "Together Forever",
      artists: ["Rick Astley"],
      album: "Whenever You Need Somebody",
      durationMs: 205533,
      explicit: true,
    });
  });

  test("normalizes nested tracks and hm continuation URLs", () => {
    const payload = {
      pages: [{ tracks: [{ uri: `spotify:track:${recommendationId}` }] }],
      next_page_url: "hm://radio-router/v3/tracks/spotify:station:track:seed?count=50",
    };
    expect(collectTrackIds(payload)).toEqual([recommendationId]);
    expect(collectNextPageUrls(payload)).toEqual([
      "hm://radio-router/v3/tracks/spotify:station:track:seed?count=50",
    ]);
    expect(spotifyWebTrack({ id: recommendationId, name: "Song", artists: ["Artist"] })?.title).toBe("Song");
  });
});

describe("Spotify recommendation client", () => {
  test("resolves dynamic spclient, follows hm pagination, and hydrates metadata", async () => {
    const calls: Array<{ url: string; init?: RequestInit | undefined }> = [];
    let sessionCalls = 0;
    const fetcher = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
      const url = String(input);
      calls.push(init ? { url, init } : { url });
      if (url.startsWith("https://apresolve.spotify.com/")) {
        return jsonResponse({ spclient: ["gae2-spclient.spotify.com:443"] });
      }
      if (url.endsWith(`/context-resolve/v1/spotify:station:track:${seedId}`)) {
        return jsonResponse({ tracks: [{ uri: `spotify:track:${seedId}` }, { uri: `spotify:track:${recommendationId}` }], next_page_url: "hm://radio-router/v3/next" });
      }
      if (url.endsWith("/radio-router/v3/next")) {
        return jsonResponse({ tracks: [{ uri: `spotify:track:${secondRecommendationId}` }] });
      }
      if (url.includes("/metadata/4/track/")) {
        const id = url.includes(spotifyIdToHex(recommendationId)) ? recommendationId : secondRecommendationId;
        return protobufResponse(metadata(id, id === recommendationId ? "GBARL9300135" : "GBARL9300136", id));
      }
      return jsonResponse({ error: "unexpected" }, 500);
    };
    const client = new SpotifyRecommendationClient({
      sessionProvider: async () => {
        sessionCalls += 1;
        return { accessToken: `token-${sessionCalls}`, clientToken: "client-token" };
      },
      fetch: fetcher,
    });

    const result = await client.recommendations({ spotifyId: seedId, uri: `spotify:track:${seedId}`, artists: [] }, 2);
    expect(result.recommendations.map((track) => track.spotifyId)).toEqual([recommendationId, secondRecommendationId]);
    expect(result.isrcBatch).toEqual(["GBARL9300135", "GBARL9300136"]);
    expect(result.diagnostics.hydration).toBe("complete");
    expect(sessionCalls).toBe(4);
    const apiCall = calls.find((call) => call.url.includes("context-resolve"));
    expect(apiCall?.init?.headers).toEqual({
      accept: "application/json",
      authorization: "Bearer token-1",
      "client-token": "client-token",
      "app-platform": "WebPlayer",
    });
  });

  test("uses the captured static Web Player host when AP resolution is unavailable", async () => {
    const calls: string[] = [];
    const fetcher = async (input: RequestInfo | URL): Promise<Response> => {
      const url = String(input);
      calls.push(url);
      if (url.startsWith("https://apresolve.spotify.com/")) throw new TypeError("Failed to fetch");
      if (url.includes("/metadata/4/track/")) return protobufResponse(metadata(recommendationId, "GBARL9300135"));
      return jsonResponse({}, 500);
    };
    const client = new SpotifyRecommendationClient({ sessionProvider: { accessToken: "token" }, fetch: fetcher });
    const tracks = await client.trackMetadata([recommendationId]);
    expect(tracks[0]?.isrc).toBe("GBARL9300135");
    expect(calls[0]).toBe("https://apresolve.spotify.com/?type=spclient");
    expect(calls[1]).toContain("https://spclient.wg.spotify.com/metadata/4/track/");
  });

  test("verifies an ISRC against candidate metadata instead of trusting search", async () => {
    const fetcher = async (input: RequestInfo | URL): Promise<Response> => {
      const url = String(input);
      if (url.startsWith("https://apresolve.spotify.com/")) return jsonResponse({ spclient: ["spclient.test"] });
      if (url.includes("/metadata/4/track/")) {
        const id = url.includes(spotifyIdToHex(recommendationId)) ? recommendationId : secondRecommendationId;
        return protobufResponse(metadata(id, id === recommendationId ? "US0000000001" : "GBARL9300136"));
      }
      return jsonResponse({}, 500);
    };
    const client = new SpotifyRecommendationClient({ sessionProvider: { accessToken: "token" }, fetch: fetcher });
    const seed = await client.resolveSeed({ isrc: "gbarl9300136", candidateTrackIds: [recommendationId, secondRecommendationId] });
    expect(seed.spotifyId).toBe(secondRecommendationId);
    await expect(client.resolveSeed({ isrc: "GBARL9300137", candidateTrackIds: [recommendationId, secondRecommendationId] }))
      .rejects.toMatchObject({ code: "seed_not_found" });
  });

  test("returns ID-only recommendations when metadata hydration is restricted", async () => {
    const fetcher = async (input: RequestInfo | URL): Promise<Response> => {
      const url = String(input);
      if (url.startsWith("https://apresolve.spotify.com/")) return jsonResponse({ spclient: ["spclient.test"] });
      if (url.includes("context-resolve")) return jsonResponse({ tracks: [{ uri: `spotify:track:${recommendationId}` }] });
      if (url.includes("/metadata/4/track/")) return protobufResponse(new Uint8Array(), 403);
      return jsonResponse({}, 500);
    };
    const client = new SpotifyRecommendationClient({ sessionProvider: { accessToken: "token" }, fetch: fetcher });
    const result = await client.recommendations({ spotifyId: seedId, uri: `spotify:track:${seedId}`, artists: [] }, 1);
    expect(result.diagnostics.hydration).toBe("unavailable");
    expect(result.recommendations).toEqual([{ spotifyId: recommendationId, uri: `spotify:track:${recommendationId}`, artists: [] }]);
  });

  test("rejects unsupported continuation schemes", async () => {
    const fetcher = async (input: RequestInfo | URL): Promise<Response> => {
      const url = String(input);
      if (url.startsWith("https://apresolve.spotify.com/")) return jsonResponse({ spclient: ["spclient.test"] });
      if (url.includes("context-resolve")) return jsonResponse({ next_page_url: "http://not-spotify.test/next" });
      return jsonResponse({}, 500);
    };
    const client = new SpotifyRecommendationClient({ sessionProvider: { accessToken: "token" }, fetch: fetcher });
    await expect(client.recommendations({ spotifyId: seedId, uri: `spotify:track:${seedId}`, artists: [] }, 1))
      .rejects.toBeInstanceOf(SpotifyRecommendationError);
  });
});
