import { describe, expect, test } from "bun:test";
import { mapYouTubePlayerTrack } from "../src/youtube";
import { buildYouTubePlayerRequest, parseYouTubePlayerResponse, selectYouTubeAudioFormat,
  selectYouTubeCipheredAudioFormat, youtubeBrowserIdentity } from "../src/youtube-player";

describe("YouTube Music mapping", () => {
  test("maps native player metadata into a provider-aware track", () => {
    expect(mapYouTubePlayerTrack({ videoDetails: {
      videoId: "abcdefghijk",
      title: "A colorful song",
      lengthSeconds: "123.456",
      author: "An Artist - Topic",
      channelId: "channel-one",
      thumbnail: { thumbnails: [
        { url: "https://img.test/small.jpg", width: 120, height: 90 },
        { url: "https://img.test/large.jpg", width: 720, height: 720 },
      ] },
    } })).toEqual({
      provider: "youtube",
      id: "abcdefghijk",
      title: "A colorful song",
      version: null,
      artists: ["An Artist - Topic"],
      artistCredits: [{ id: "channel-one", name: "An Artist - Topic" }],
      uploader: { id: "channel-one", name: "An Artist - Topic" },
      albumId: null,
      albumTitle: null,
      durationMs: 123_456,
      isrc: null,
      coverUrl: "https://img.test/large.jpg",
    });
  });

  test("rejects player documents without usable video metadata", () => {
    expect(mapYouTubePlayerTrack({ videoDetails: { title: "Missing ID" } })).toBeNull();
    expect(mapYouTubePlayerTrack({ videoDetails: { videoId: "abcdefghijk" } })).toBeNull();
    expect(mapYouTubePlayerTrack({ videoDetails: { videoId: "too-short", title: "Invalid" } })).toBeNull();
  });

  test("selects the best direct audio-only player format", () => {
    const document = {
      playabilityStatus: { status: "OK" },
      streamingData: {
        adaptiveFormats: [
          { itag: 136, url: "https://media.test/video", mimeType: "video/mp4", bitrate: 1_000_000 },
          { itag: 140, url: "https://media.test/aac", mimeType: "audio/mp4; codecs=\"mp4a.40.2\"",
            bitrate: 130_612, audioQuality: "AUDIO_QUALITY_MEDIUM", contentLength: "1992515" },
          { itag: 251, url: "https://media.test/opus", mimeType: "audio/webm; codecs=\"opus\"",
            bitrate: 142_971, audioQuality: "AUDIO_QUALITY_MEDIUM", audioSampleRate: "48000",
            audioChannels: 2, approxDurationMs: "123021" },
        ],
      },
    };
    expect(selectYouTubeAudioFormat(document)).toEqual({
      itag: 251,
      uri: "https://media.test/opus",
      mimeType: "audio/webm; codecs=\"opus\"",
      bitrate: 142_971,
      audioQuality: "AUDIO_QUALITY_MEDIUM",
      sampleRate: 48_000,
      channels: 2,
      contentLength: null,
      durationMs: 123_021,
    });
    expect(parseYouTubePlayerResponse(document, "abcdefghijk", "colorful-test")).toEqual({
      uri: "https://media.test/opus",
      httpHeaders: { "User-Agent": "colorful-test" },
      userAgent: "colorful-test",
      referrer: "",
      webpageUrl: "https://music.youtube.com/watch?v=abcdefghijk",
      mimeType: "audio/webm; codecs=\"opus\"",
      bitrate: 142_971,
      itag: 251,
      contentLength: null,
      durationMs: 123_021,
    });
  });

  test("builds the typed Android VR player request without browser tracking fields", () => {
    const plan = buildYouTubePlayerRequest("abcdefghijk", "public-visitor", 20653);
    expect(plan.url).toBe("https://www.youtube.com/youtubei/v1/player?prettyPrint=false");
    expect(plan.headers).toEqual(expect.objectContaining({
      "X-Youtube-Client-Name": "28",
      "X-Youtube-Client-Version": "1.65.10",
      "X-Goog-Visitor-Id": "public-visitor",
    }));
    expect(plan.body).toEqual(expect.objectContaining({
      videoId: "abcdefghijk",
      contentCheckOk: true,
      racyCheckOk: true,
      playbackContext: { contentPlaybackContext: {
        html5Preference: "HTML5_PREF_WANTS",
        signatureTimestamp: 20653,
      } },
    }));
    expect(plan.body.context.client).toEqual(expect.objectContaining({
      clientName: "ANDROID_VR",
      clientVersion: "1.65.10",
      visitorData: "public-visitor",
    }));
  });

  test("reports player availability and cipher failures clearly", () => {
    expect(() => selectYouTubeAudioFormat({
      playabilityStatus: { status: "LOGIN_REQUIRED", reason: "Sign in to confirm your age" },
    })).toThrow("YouTube Music playback is login_required: Sign in to confirm your age");
    expect(() => selectYouTubeAudioFormat({
      playabilityStatus: { status: "OK" },
      streamingData: { adaptiveFormats: [{
        itag: 251,
        mimeType: "audio/webm; codecs=\"opus\"",
        signatureCipher: "url=https%3A%2F%2Fmedia.test&sp=sig&s=encrypted",
      }] },
    })).toThrow("only ciphered audio formats");
  });

  test("selects a ciphered authenticated audio format for player transformation", () => {
    const selected = selectYouTubeCipheredAudioFormat({
      playabilityStatus: { status: "OK" },
      streamingData: { adaptiveFormats: [
        { itag: 140, mimeType: "audio/mp4; codecs=\"mp4a.40.2\"", bitrate: 130_000,
          signatureCipher: "url=https%3A%2F%2Fmedia.test%2Faac&sp=sig&s=aac" },
        { itag: 251, mimeType: "audio/webm; codecs=\"opus\"", bitrate: 145_000,
          signatureCipher: "url=https%3A%2F%2Fmedia.test%2Fopus&sp=sig&s=opus" },
      ] },
    });
    expect(selected.format.itag).toBe(251);
    expect(selected.signatureCipher).toContain("s=opus");
  });

  test("keeps only required browser identity headers for authenticated playback", () => {
    expect(youtubeBrowserIdentity({
      cookie: "SID=one; __Secure-3PAPISID=two",
      "user-agent": "colorful-browser",
      "x-goog-authuser": "1",
      "x-goog-visitor-id": "browser-visitor",
      "x-goog-pageid": "channel-page",
      "x-youtube-client-version": "1.2.3",
      authorization: "must-not-be-retained",
    }, "public-visitor")).toEqual({
      cookie: "SID=one; __Secure-3PAPISID=two",
      authUser: "1",
      visitorData: "browser-visitor",
      userAgent: "colorful-browser",
      acceptLanguage: "",
      clientVersion: "1.2.3",
      retainedHeaders: { "x-goog-pageid": "channel-page" },
    });
  });

});
