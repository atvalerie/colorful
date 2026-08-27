import Foundation
import JavaScriptCore
import OSLog

private let colorfulYouTubeLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "sh.valerie.colorful",
    category: "YouTube"
)

private func colorfulYouTubeInfo(_ message: String) {
    colorfulYouTubeLogger.info("\(message, privacy: .public)")
    ColorfulDiagnostics.shared.append(category: "YouTube", message: message)
}

private func colorfulYouTubeDebug(_ message: String) {
    colorfulYouTubeLogger.debug("\(message, privacy: .public)")
    ColorfulDiagnostics.shared.append(category: "YouTube", message: message)
}

private func colorfulYouTubeError(_ message: String) {
    colorfulYouTubeLogger.error("\(message, privacy: .public)")
    ColorfulDiagnostics.shared.append(category: "YouTube", message: message)
}

enum YouTubePlayerScriptError: LocalizedError, Sendable {
    case transformNotFound
    case runtimeUnavailable(String)
    case invalidCipher(String)

    var errorDescription: String? {
        switch self {
        case .transformNotFound:
            return "The current YouTube player script did not expose its media transform."
        case .runtimeUnavailable(let detail):
            return "The YouTube player transform could not run\(detail.isEmpty ? "." : ": \(detail)")"
        case .invalidCipher(let detail):
            return "YouTube returned an invalid protected audio URL\(detail.isEmpty ? "." : ": \(detail)")"
        }
    }
}

private struct YouTubePlayerTransform: Decodable {
    let signature: String?
    let n: String?
}

/// Evaluates YouTube's current player script in an isolated JavaScriptCore VM
/// and exposes only its URL transform. The context receives no native objects,
/// network bridge, DOM, or app state.
final class YouTubePlayerScriptRuntime: @unchecked Sendable {
    private let instrumentedSource: String
    private let queue = DispatchQueue(label: "app.colorful.youtube-player-script")
    private var context: JSContext?

    init(source: String) throws {
        instrumentedSource = try Self.instrument(source)
    }

    func decipher(
        url: URL,
        signature: String? = nil,
        signatureParameter: String? = nil
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try decipherSynchronously(
                        url: url,
                        signature: signature,
                        signatureParameter: signatureParameter
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Finds the same three-argument URL constructor used by youtubei.js's
    /// nsig matcher and exports it without evaluating a WebView player.
    static func instrument(_ source: String) throws -> String {
        let marker = try NSRegularExpression(
            pattern: #"\.set\(\s*["']alr["']\s*,\s*["']yes["']\s*\)"#
        )
        let declaration = try NSRegularExpression(
            pattern: #"([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(function\s*\(([^)]*)\)\s*\{)"#
        )
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        for markerMatch in marker.matches(in: source, range: fullRange) {
            guard let markerRange = Range(markerMatch.range, in: source) else { continue }
            let markerOffset = source.utf16.distance(
                from: source.utf16.startIndex,
                to: markerRange.lowerBound.samePosition(in: source.utf16)!
            )
            let searchStart = max(0, markerOffset - 4_096)
            let searchRange = NSRange(location: searchStart, length: markerOffset - searchStart)
            guard let match = declaration.matches(in: source, range: searchRange).last,
                  let paramsRange = Range(match.range(at: 3), in: source),
                  source[paramsRange].split(separator: ",", omittingEmptySubsequences: false).count >= 3,
                  let functionRange = Range(match.range(at: 2), in: source) else { continue }
            return String(source[..<functionRange.lowerBound])
                + "globalThis.__colorfulNsig="
                + String(source[functionRange.lowerBound...])
        }
        throw YouTubePlayerScriptError.transformNotFound
    }

    private func decipherSynchronously(
        url: URL,
        signature: String?,
        signatureParameter: String?
    ) throws -> URL {
        let context = try runtimeContext()
        context.exception = nil
        guard let transform = context.objectForKeyedSubscript("__colorfulApply"),
              !transform.isUndefined else {
            throw YouTubePlayerScriptError.runtimeUnavailable("transform wrapper is missing")
        }
        let result = transform.call(withArguments: [
            url.absoluteString,
            signatureParameter ?? "",
            signature ?? "",
        ])
        if let exception = context.exception, !exception.isUndefined {
            context.exception = nil
            throw YouTubePlayerScriptError.runtimeUnavailable(exception.toString() ?? "JavaScript exception")
        }
        guard let json = result?.toString(), let data = json.data(using: .utf8),
              let transformed = try? JSONDecoder().decode(YouTubePlayerTransform.self, from: data) else {
            throw YouTubePlayerScriptError.runtimeUnavailable("transform returned invalid data")
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        func set(_ name: String, _ value: String) {
            items.removeAll { $0.name == name }
            items.append(URLQueryItem(name: name, value: value))
        }
        if let signature, !signature.isEmpty {
            guard let transformedSignature = transformed.signature, !transformedSignature.isEmpty else {
                throw YouTubePlayerScriptError.invalidCipher("signature transform was empty")
            }
            set(signatureParameter.flatMap { $0.isEmpty ? nil : $0 } ?? "signature", transformedSignature)
        }
        if let originalN = items.first(where: { $0.name == "n" })?.value, !originalN.isEmpty {
            guard let transformedN = transformed.n, !transformedN.isEmpty,
                  !transformedN.hasPrefix("enhanced_except_") else {
                throw YouTubePlayerScriptError.invalidCipher("n transform failed")
            }
            set("n", transformedN)
        }
        components?.queryItems = items
        guard let resolved = components?.url, resolved.scheme == "https", resolved.host != nil else {
            throw YouTubePlayerScriptError.invalidCipher("transformed URL is not HTTPS")
        }
        return resolved
    }

    private func runtimeContext() throws -> JSContext {
        if let context { return context }
        guard let context = JSContext() else {
            throw YouTubePlayerScriptError.runtimeUnavailable("JavaScriptCore is unavailable")
        }
        context.evaluateScript(Self.sandboxPrelude)
        if let exception = context.exception, !exception.isUndefined {
            throw YouTubePlayerScriptError.runtimeUnavailable(exception.toString() ?? "sandbox setup failed")
        }

        context.exception = nil
        context.evaluateScript(instrumentedSource)
        let playerException = context.exception?.toString()
        context.exception = nil
        context.evaluateScript(Self.transformWrapper)
        if let exception = context.exception, !exception.isUndefined {
            throw YouTubePlayerScriptError.runtimeUnavailable(
                exception.toString() ?? playerException ?? "player script evaluation failed"
            )
        }
        guard let exported = context.objectForKeyedSubscript("__colorfulNsig"),
              !exported.isUndefined else {
            throw YouTubePlayerScriptError.runtimeUnavailable(
                playerException ?? "player transform was not exported"
            )
        }
        self.context = context
        return context
    }

    private static let sandboxPrelude = #"""
    (() => {
      const global = globalThis;
      let inert;
      const target = function() { return inert; };
      inert = new Proxy(target, {
        get(_target, key) {
          if (key === "then") return undefined;
          if (key === "prototype") return Object.create(null);
          if (key === Symbol.toPrimitive) return () => "";
          if (key === Symbol.iterator) return function*() {};
          return inert;
        },
        set() { return true; },
        apply() { return inert; },
        construct() { return inert; },
        has() { return false; },
        ownKeys() { return []; },
        getOwnPropertyDescriptor() { return { configurable: true }; }
      });
      global.window = global;
      global.self = global;
      const inertNames = [
        "XMLHttpRequest", "navigator", "document", "location", "history",
        "performance", "crypto", "URL", "URLSearchParams", "TextEncoder",
        "TextDecoder", "AbortController", "AbortSignal", "Event",
        "EventTarget", "CustomEvent", "HTMLElement", "Element", "Node",
        "NodeList", "MutationObserver", "IntersectionObserver", "ResizeObserver",
        "Image", "Audio", "MediaSource", "Blob", "File", "FileReader",
        "Request", "Response", "Headers", "FormData", "localStorage",
        "sessionStorage", "customElements", "fetch", "WebSocket"
      ];
      for (const name of inertNames) {
        if (typeof global[name] === "undefined") global[name] = inert;
      }
      global.setTimeout = global.setInterval = global.requestAnimationFrame = () => 0;
      global.clearTimeout = global.clearInterval = global.cancelAnimationFrame = () => {};
      global.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };
    })();
    """#

    private static let transformWrapper = #"""
    globalThis.__colorfulApply = function(rawURL, signatureName, signatureValue) {
      const transformed = globalThis.__colorfulNsig(rawURL, signatureName, signatureValue);
      const prototype = Object.getPrototypeOf(transformed);
      const ignored = new Set(["constructor", "clone", "set", "get"]);
      for (const name of Object.getOwnPropertyNames(prototype)) {
        if (!ignored.has(name) && typeof transformed[name] === "function") transformed[name]();
      }
      const decode = (value) => {
        if (!value) return null;
        try { return decodeURIComponent(value); } catch (_) { return String(value); }
      };
      return JSON.stringify({
        signature: decode(transformed.get(signatureName)),
        n: decode(transformed.get("n"))
      });
    };
    """#
}

enum YouTubeMusicClientError: LocalizedError, Sendable {
    case invalidResponse(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail): return detail
        case .http(let status, let detail):
            return "YouTube Music returned HTTP \(status)\(detail.isEmpty ? "" : ": \(detail)")"
        }
    }
}

struct YouTubeMusicSearchResults: Sendable {
    let tracks: [CoreTrack]
}

struct YouTubeMusicPlaybackSource: Sendable {
    let url: URL
    let httpHeaders: [String: String]
    let mimeType: String
    let contentLength: Int64?
}

private struct YouTubeDirectAudioSource {
    let url: URL
    let mimeType: String
    let contentLength: Int64?
}

private struct YouTubeCipheredAudioSource {
    let url: URL
    let signature: String
    let signatureParameter: String
    let mimeType: String
    let contentLength: Int64?
}

actor YouTubeMusicClient {
    static let shared = YouTubeMusicClient()

    private let musicOrigin = URL(string: "https://music.youtube.com")!
    private let playerOrigin = URL(string: "https://www.youtube.com")!
    private let webUserAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/140 Safari/537.36"
    private let androidVersion = "1.65.10"
    private let songsFilter = "EgWKAQIIAWoQEAUQBBADEAoQCRAVEBAQEQ%3D%3D"
    private let videosFilter = "EgWKAQIQAWoQEAUQBBADEAoQCRAVEBAQEQ%3D%3D"
    private var visitorData: String?
    private var musicClientVersion: String?
    private var signatureTimestamp: Int?
    private var playerScriptSource: String?
    private var playerScriptRuntime: YouTubePlayerScriptRuntime?

    func search(query: String) async throws -> YouTubeMusicSearchResults {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return YouTubeMusicSearchResults(tracks: []) }

        async let songs = searchPage(query: cleaned, params: songsFilter)
        async let videos = searchPage(query: cleaned, params: videosFilter)
        let (songPage, videoPage) = try await (songs, videos)
        let songTracks = responsiveItems(songPage).compactMap(mapTrack)
        let videoTracks = responsiveItems(videoPage).compactMap(mapTrack)
        var interleaved = [CoreTrack]()
        for index in 0..<max(songTracks.count, videoTracks.count) {
            if index < songTracks.count { interleaved.append(songTracks[index]) }
            if index < videoTracks.count { interleaved.append(videoTracks[index]) }
        }
        var seen = Set<CoreMediaID>()
        return YouTubeMusicSearchResults(tracks: interleaved.filter { seen.insert($0.id).inserted })
    }

    func playbackSource(for track: CoreTrack) async throws -> YouTubeMusicPlaybackSource {
        let videoID = track.id.providerID
        guard track.id.provider.lowercased() == "youtube",
              videoID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else {
            throw YouTubeMusicClientError.invalidResponse("This is not a valid YouTube Music track.")
        }
        colorfulYouTubeInfo("playback source start video=\(videoID)")
        let visitor = try await publicVisitorData()
        var lastFailure: Error?
        var proofFailure: Error?
        func record(_ error: Error, client: String) {
            lastFailure = error
            if error.localizedDescription.localizedCaseInsensitiveContains("proof-of-origin") {
                proofFailure = error
            }
            colorfulYouTubeError(
                "playback source failed client=\(client) video=\(videoID) error=\(error.localizedDescription)"
            )
        }

        let iosVersion = "21.26.4"
        let iosUserAgent = "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
        do {
            let document = try await playerDocument(
                videoID: videoID, visitor: visitor, timestamp: nil,
                client: [
                    "clientName": "IOS", "clientVersion": iosVersion,
                    "deviceMake": "Apple", "deviceModel": "iPhone16,2",
                    "userAgent": iosUserAgent, "osName": "iPhone", "osVersion": "18.3.2.22D82",
                    "hl": "en", "gl": "US", "visitorData": visitor,
                ],
                headers: [
                    "User-Agent": iosUserAgent,
                    "X-Youtube-Client-Name": "5",
                    "X-Youtube-Client-Version": iosVersion,
                ]
            )
            let manifest = string(dictionary(document["streamingData"])["hlsManifestUrl"])
            if let hls = URL(string: manifest), hls.scheme == "https" {
                do {
                    return try await hlsAudioSource(masterURL: hls, userAgent: iosUserAgent)
                } catch {
                    record(error, client: "IOS-HLS")
                }
            }
            return try await resolvedAudioSource(document, userAgent: iosUserAgent)
        } catch {
            record(error, client: "IOS")
        }

        // Resolve player-script metadata only after the native iOS HLS attempt.
        // Some fallback identities still use its signature timestamp, while the
        // normal iOS path remains independent of music.youtube.com bootstrap JS.
        let fallbackTimestamp = await resolveSignatureTimestamp()

        // Match the current first-party Music request captured in the HAR.
        // This identity normally returns ciphered AAC rather than HLS; the
        // player-script runtime resolves both signature and n before probing.
        let remixVersion = musicClientVersion ?? webClientVersion()
        do {
            let document = try await playerDocument(
                videoID: videoID, visitor: visitor, timestamp: fallbackTimestamp,
                client: [
                    "clientName": "WEB_REMIX", "clientVersion": remixVersion,
                    "userAgent": webUserAgent, "hl": "en", "gl": "US",
                    "visitorData": visitor,
                ],
                headers: [
                    "User-Agent": webUserAgent,
                    "X-Youtube-Client-Name": "67",
                    "X-Youtube-Client-Version": remixVersion,
                    "X-Origin": musicOrigin.absoluteString,
                ],
                origin: musicOrigin
            )
            return try await resolvedAudioSource(document, userAgent: webUserAgent)
        } catch {
            record(error, client: "WEB_REMIX")
        }

        let safariVersion = "2.20260708.00.00"
        let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)"
        do {
            let document = try await playerDocument(
                videoID: videoID, visitor: visitor, timestamp: fallbackTimestamp,
                client: [
                    "clientName": "WEB", "clientVersion": safariVersion, "userAgent": safariUserAgent,
                    "hl": "en", "gl": "US", "visitorData": visitor,
                ],
                headers: [
                    "User-Agent": safariUserAgent,
                    "X-Youtube-Client-Name": "1",
                    "X-Youtube-Client-Version": safariVersion,
                ]
            )
            let manifest = string(dictionary(document["streamingData"])["hlsManifestUrl"])
            if let url = URL(string: manifest), url.scheme == "https" {
                do {
                    return try await hlsAudioSource(masterURL: url, userAgent: safariUserAgent)
                } catch {
                    record(error, client: "WEB-HLS")
                }
            }
            return try await resolvedAudioSource(document, userAgent: safariUserAgent)
        } catch {
            record(error, client: "WEB")
        }

        let androidUserAgent = "com.google.android.apps.youtube.vr.oculus/\(androidVersion) (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        do {
            let document = try await playerDocument(
                videoID: videoID, visitor: visitor, timestamp: nil,
                client: [
                    "clientName": "ANDROID_VR", "clientVersion": androidVersion,
                    "deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": 32,
                    "userAgent": androidUserAgent, "osName": "Android", "osVersion": "12L",
                    "hl": "en", "timeZone": "UTC", "utcOffsetMinutes": 0,
                    "visitorData": visitor,
                ],
                headers: [
                    "User-Agent": androidUserAgent,
                    "X-Youtube-Client-Name": "28",
                    "X-Youtube-Client-Version": androidVersion,
                ]
            )
            return try await resolvedAudioSource(document, userAgent: androidUserAgent)
        } catch {
            record(error, client: "ANDROID_VR")
        }

        let tvVersion = "5.20260707"
        let tvUserAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
        do {
            let document = try await playerDocument(
                videoID: videoID, visitor: visitor, timestamp: fallbackTimestamp,
                client: [
                    "clientName": "TVHTML5", "clientVersion": tvVersion,
                    "hl": "en", "gl": "US", "visitorData": visitor,
                ],
                headers: [
                    "User-Agent": tvUserAgent,
                    "X-Youtube-Client-Name": "7",
                    "X-Youtube-Client-Version": tvVersion,
                ]
            )
            return try await resolvedAudioSource(document, userAgent: tvUserAgent)
        } catch {
            record(error, client: "TVHTML5")
            // Client-side fallback: follow the Music watch page in a mounted
            // WKWebView so its browser session can expose the same media path
            // used by the normal Music site.
            do {
                let resolution = try await YouTubeHLSWebViewResolver.shared.resolve(videoID: videoID)
                var headers = ["User-Agent": resolution.userAgent]
                if !resolution.cookies.isEmpty,
                   let cookieHeader = HTTPCookie.requestHeaderFields(with: resolution.cookies)["Cookie"] {
                    headers["Cookie"] = cookieHeader
                }
                // AVPlayer inherits cookies from the shared store, so inject
                // the WebView session cookies for googlevideo segment requests.
                for cookie in resolution.cookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
                return YouTubeMusicPlaybackSource(
                    url: resolution.mediaURL,
                    httpHeaders: headers,
                    mimeType: resolution.mimeType,
                    contentLength: nil
                )
            } catch {
                colorfulYouTubeError(
                    "webview fallback failed video=\(videoID) error=\(error.localizedDescription)"
                )
                throw proofFailure ?? lastFailure ?? error
            }
        }
    }

    private func playerDocument(
        videoID: String,
        visitor: String,
        timestamp: Int?,
        client: [String: Any],
        headers: [String: String],
        origin: URL? = nil
    ) async throws -> [String: Any] {
        let requestOrigin = origin ?? playerOrigin
        var body: [String: Any] = [
            "context": ["client": client], "videoId": videoID,
            "contentCheckOk": true, "racyCheckOk": true,
        ]
        if let timestamp {
            body["playbackContext"] = ["contentPlaybackContext": [
                "html5Preference": "HTML5_PREF_WANTS", "signatureTimestamp": timestamp,
            ]]
        }
        let document = try await requestJSON(
            url: requestOrigin.appending(path: "youtubei/v1/player").appending(queryItems: [URLQueryItem(name: "prettyPrint", value: "false")]),
            body: body,
            headers: headers.merging([
                "X-Goog-Visitor-Id": visitor,
                "Origin": requestOrigin.absoluteString,
            ]) { current, _ in current }
        )
        logPlayerResponse(clientName: string(client["clientName"]), document: document)
        return document
    }

    private func directAudioSource(_ document: [String: Any]) throws -> YouTubeDirectAudioSource {
        let formats = try audioFormats(document)
            .filter { self.isIOSPlayableAudio($0) && !self.string($0["url"]).isEmpty }
            .sorted { self.formatScore($0) > self.formatScore($1) }
        guard let selected = formats.first, let url = URL(string: string(selected["url"])) else {
            let ciphered = try audioFormats(document)
                .contains { !string($0["signatureCipher"]).isEmpty || !string($0["cipher"]).isEmpty }
            throw YouTubeMusicClientError.invalidResponse(ciphered
                ? "YouTube Music returned only protected audio for this track."
                : "YouTube Music returned no directly playable audio.")
        }
        let rawLength = number64(selected["contentLength"])
        return YouTubeDirectAudioSource(
            url: url,
            mimeType: string(selected["mimeType"]).components(separatedBy: ";").first ?? "audio/mp4",
            contentLength: rawLength > 0 ? rawLength : nil
        )
    }

    private func cipheredAudioSource(_ document: [String: Any]) throws -> YouTubeCipheredAudioSource {
        let formats = try audioFormats(document)
            .filter {
                self.isIOSPlayableAudio($0)
                    && (!self.string($0["signatureCipher"]).isEmpty || !self.string($0["cipher"]).isEmpty)
            }
            .sorted { self.formatScore($0) > self.formatScore($1) }
        guard let selected = formats.first else {
            throw YouTubeMusicClientError.invalidResponse("YouTube Music returned no protected AAC audio.")
        }
        let encoded = string(selected["signatureCipher"]).isEmpty
            ? string(selected["cipher"])
            : string(selected["signatureCipher"])
        guard let fields = URLComponents(string: "https://cipher.invalid/?\(encoded)")?.queryItems else {
            throw YouTubePlayerScriptError.invalidCipher("query fields are missing")
        }
        let values = Dictionary(fields.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { current, _ in current })
        guard let rawURL = values["url"], let url = URL(string: rawURL),
              url.scheme == "https", url.host != nil,
              let signature = ["s", "sig", "signature"].compactMap({ values[$0] })
                .first(where: { !$0.isEmpty }) else {
            throw YouTubePlayerScriptError.invalidCipher("URL or signature is missing")
        }
        let rawLength = number64(selected["contentLength"])
        return YouTubeCipheredAudioSource(
            url: url,
            signature: signature,
            signatureParameter: values["sp"].flatMap { $0.isEmpty ? nil : $0 } ?? "signature",
            mimeType: string(selected["mimeType"]).components(separatedBy: ";").first ?? "audio/mp4",
            contentLength: rawLength > 0 ? rawLength : nil
        )
    }

    private func resolvedAudioSource(
        _ document: [String: Any],
        userAgent: String
    ) async throws -> YouTubeMusicPlaybackSource {
        if let direct = try? directAudioSource(document) {
            let hasN = URLComponents(url: direct.url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: { $0.name == "n" && !($0.value ?? "").isEmpty }) == true
            let resolvedURL: URL
            if hasN {
                let runtime = try await currentPlayerScriptRuntime()
                resolvedURL = try await runtime.decipher(url: direct.url)
            } else {
                resolvedURL = direct.url
            }
            let probedLength = try await validateDirectSource(resolvedURL, userAgent: userAgent)
            logResolvedSource(kind: hasN ? "direct-deciphered" : "direct", url: resolvedURL, mimeType: direct.mimeType)
            return YouTubeMusicPlaybackSource(
                url: resolvedURL,
                httpHeaders: ["User-Agent": userAgent],
                mimeType: direct.mimeType,
                contentLength: probedLength ?? direct.contentLength
            )
        }

        let protected = try cipheredAudioSource(document)
        let runtime = try await currentPlayerScriptRuntime()
        let resolvedURL = try await runtime.decipher(
            url: protected.url,
            signature: protected.signature,
            signatureParameter: protected.signatureParameter
        )
        let probedLength = try await validateDirectSource(resolvedURL, userAgent: userAgent)
        logResolvedSource(kind: "cipher-deciphered", url: resolvedURL, mimeType: protected.mimeType)
        return YouTubeMusicPlaybackSource(
            url: resolvedURL,
            httpHeaders: ["User-Agent": userAgent],
            mimeType: protected.mimeType,
            contentLength: probedLength ?? protected.contentLength
        )
    }

    private func audioFormats(_ document: [String: Any]) throws -> [[String: Any]] {
        let playability = dictionary(document["playabilityStatus"])
        let status = string(playability["status"])
        if !status.isEmpty && status != "OK" {
            let reason = string(playability["reason"])
            throw YouTubeMusicClientError.invalidResponse(
                "YouTube Music playback is \(status.lowercased())\(reason.isEmpty ? "" : ": \(reason)")"
            )
        }
        let streaming = dictionary(document["streamingData"])
        return (array(streaming["adaptiveFormats"]) + array(streaming["formats"]))
            .compactMap { $0 as? [String: Any] }
    }

    private func hlsAudioSource(masterURL: URL, userAgent: String) async throws -> YouTubeMusicPlaybackSource {
        let master = try await hlsPlaylist(at: masterURL, userAgent: userAgent)
        let audioURL: URL
        if master.contains("#EXTINF") {
            audioURL = masterURL
        } else if let rendition = preferredAudioRendition(in: master, relativeTo: masterURL) {
            audioURL = rendition
        } else {
            throw YouTubeMusicClientError.invalidResponse("YouTube HLS did not contain an audio rendition.")
        }

        let audioPlaylist = audioURL == masterURL
            ? master
            : try await hlsPlaylist(at: audioURL, userAgent: userAgent)
        let hasSegment = audioPlaylist.components(separatedBy: .newlines).contains {
            let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !line.isEmpty && !line.hasPrefix("#")
        }
        guard audioPlaylist.contains("#EXTM3U"), audioPlaylist.contains("#EXTINF"), hasSegment else {
            throw YouTubeMusicClientError.invalidResponse("YouTube returned an invalid HLS audio playlist.")
        }
        return YouTubeMusicPlaybackSource(
            url: audioURL,
            httpHeaders: ["User-Agent": userAgent],
            mimeType: "application/vnd.apple.mpegurl",
            contentLength: nil
        )
    }

    private func hlsPlaylist(at url: URL, userAgent: String) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.apple.mpegurl,application/x-mpegURL,*/*", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        colorfulYouTubeInfo(
            "hls response url=\(self.sourceDescriptor(url)) status=\(status) bytes=\(data.count)"
        )
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let playlist = String(data: data, encoding: .utf8), playlist.contains("#EXTM3U") else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw YouTubeMusicClientError.invalidResponse("YouTube HLS returned HTTP \(status).")
        }
        return playlist
    }

    private func preferredAudioRendition(in master: String, relativeTo masterURL: URL) -> URL? {
        struct Rendition {
            let groupID: String
            let url: URL
            let isDefault: Bool
        }

        var groupScores = [String: Int]()
        var renditions = [Rendition]()
        for rawLine in master.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let values = hlsAttributes(in: String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                guard let groupID = values["AUDIO"] else { continue }
                let codecs = values["CODECS"]?.lowercased() ?? ""
                let compatibility = codecs.contains("mp4a.40.2") ? 3
                    : codecs.contains("mp4a") ? 2 : 0
                let bandwidth = Int(values["BANDWIDTH"] ?? "") ?? 0
                groupScores[groupID] = max(groupScores[groupID] ?? 0, compatibility * 1_000_000_000 + bandwidth)
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let values = hlsAttributes(in: String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard values["TYPE"] == "AUDIO",
                      let groupID = values["GROUP-ID"],
                      let rawURI = values["URI"],
                      let url = URL(string: rawURI, relativeTo: masterURL)?.absoluteURL,
                      url.scheme == "https" else { continue }
                renditions.append(Rendition(
                    groupID: groupID,
                    url: url,
                    isDefault: values["DEFAULT"] == "YES"
                ))
            }
        }
        return renditions.max {
            let left = (groupScores[$0.groupID] ?? 0) + ($0.isDefault ? 1 : 0)
            let right = (groupScores[$1.groupID] ?? 0) + ($1.isDefault ? 1 : 0)
            return left < right
        }?.url
    }

    private func hlsAttributes(in value: String) -> [String: String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?:^|,)([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)"#
        ) else { return [:] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        var attributes = [String: String]()
        for match in expression.matches(in: value, range: range) where match.numberOfRanges == 3 {
            guard let nameRange = Range(match.range(at: 1), in: value),
                  let valueRange = Range(match.range(at: 2), in: value) else { continue }
            let name = String(value[nameRange])
            let raw = String(value[valueRange])
            attributes[name] = raw.hasPrefix("\"") && raw.hasSuffix("\"")
                ? String(raw.dropFirst().dropLast())
                : raw
        }
        return attributes
    }

    private func validateDirectSource(_ url: URL, userAgent: String) async throws -> Int64? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Match AVPlayer's direct-file request shape. GVS can permit a tiny
        // prefix while rejecting the open-ended request when a POT is missing.
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        colorfulYouTubeInfo(
            "direct probe url=\(self.sourceDescriptor(url)) status=\(status) contentType=\(contentType)"
        )
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let hasPOT = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: { $0.name == "pot" && !($0.value ?? "").isEmpty }) == true
            if status == 403 && !hasPOT {
                throw YouTubeMusicClientError.invalidResponse(
                    "YouTube rejected the deciphered audio URL before AVPlayer (HTTP 403; no proof-of-origin token was bound)."
                )
            }
            throw YouTubeMusicClientError.invalidResponse(
                "YouTube Music returned an unusable audio source (HTTP \(status))."
            )
        }
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) }), total > 0 {
            return total
        }
        return response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }

    private func searchPage(query: String, params: String) async throws -> [String: Any] {
        try await requestJSON(
            url: musicOrigin.appending(path: "youtubei/v1/search").appending(queryItems: [URLQueryItem(name: "alt", value: "json")]),
            body: [
                "context": ["client": [
                    "clientName": "WEB_REMIX", "clientVersion": webClientVersion(), "hl": "en", "gl": "US",
                ], "user": [:]],
                "query": query,
                "params": params,
            ],
            headers: ["User-Agent": webUserAgent, "Origin": musicOrigin.absoluteString, "X-Origin": musicOrigin.absoluteString]
        )
    }

    private func publicVisitorData() async throws -> String {
        if let visitorData { return visitorData }
        var request = URLRequest(url: musicOrigin)
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeMusicClientError.invalidResponse("YouTube Music bootstrap returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode), let html = String(data: data, encoding: .utf8) else {
            throw YouTubeMusicClientError.http(http.statusCode, "bootstrap failed")
        }
        let config = mergedBootstrap(from: html)
        let context = dictionary(config["INNERTUBE_CONTEXT"])
        let client = dictionary(context["client"])
        let configuredVersion = string(client["clientVersion"])
        if !configuredVersion.isEmpty { musicClientVersion = configuredVersion }
        var visitor = string(client["visitorData"])
        if visitor.isEmpty { visitor = string(config["VISITOR_DATA"]) }
        if visitor.isEmpty {
            visitor = firstCapture(#"\"VISITOR_DATA\"\s*:\s*\"([^\"]+)\""#, in: html)
                ?? firstCapture(#"\"visitorData\"\s*:\s*\"([^\"]+)\""#, in: html)
                ?? ""
        }
        if visitor.isEmpty { visitor = try await requestVisitorData() }
        guard !visitor.isEmpty else {
            throw YouTubeMusicClientError.invalidResponse("YouTube Music bootstrap did not contain visitor data.")
        }
        visitorData = visitor
        return visitor
    }

    private func requestVisitorData() async throws -> String {
        let document = try await requestJSON(
            url: musicOrigin.appending(path: "youtubei/v1/visitor_id").appending(queryItems: [URLQueryItem(name: "prettyPrint", value: "false")]),
            body: ["context": ["client": [
                "clientName": "WEB", "clientVersion": webClientVersion(), "hl": "en", "gl": "US",
            ]]],
            headers: ["User-Agent": webUserAgent, "Origin": musicOrigin.absoluteString]
        )
        let visitor = string(dictionary(document["responseContext"])["visitorData"])
        guard !visitor.isEmpty else {
            throw YouTubeMusicClientError.invalidResponse("YouTube Music could not establish a public visitor session.")
        }
        return visitor
    }

    private func resolveSignatureTimestamp() async -> Int? {
        if let signatureTimestamp { return signatureTimestamp }
        do {
            var homepageRequest = URLRequest(url: musicOrigin, timeoutInterval: 15)
            homepageRequest.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
            let (homepageData, homepageResponse) = try await URLSession.shared.data(for: homepageRequest)
            guard let homepageHTTP = homepageResponse as? HTTPURLResponse,
                  (200..<300).contains(homepageHTTP.statusCode),
                  let html = String(data: homepageData, encoding: .utf8) else { return nil }

            let config = mergedBootstrap(from: html)
            var candidates = [URL]()
            for value in dictionary(config["WEB_PLAYER_CONTEXT_CONFIGS"]).values {
                let path = string(dictionary(value)["jsUrl"])
                if let url = normalizedPlayerURL(path) { candidates.append(url) }
            }
            for pattern in [#"\"jsUrl\"\s*:\s*\"([^\"]+)\""#, #"\"PLAYER_JS_URL\"\s*:\s*\"([^\"]+)\""#] {
                if let path = firstCapture(pattern, in: html), let url = normalizedPlayerURL(path) {
                    candidates.append(url)
                }
            }

            if candidates.isEmpty {
                var iframeRequest = URLRequest(url: playerOrigin.appending(path: "iframe_api"), timeoutInterval: 15)
                iframeRequest.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
                let (iframeData, iframeResponse) = try await URLSession.shared.data(for: iframeRequest)
                if let iframeHTTP = iframeResponse as? HTTPURLResponse,
                   (200..<300).contains(iframeHTTP.statusCode),
                   let iframe = String(data: iframeData, encoding: .utf8) {
                    let normalized = iframe.replacingOccurrences(of: #"\/"#, with: "/")
                    if let playerID = firstCapture(#"/s/player/([A-Za-z0-9_-]+)/"#, in: normalized) {
                        candidates.append(playerOrigin.appending(path: "s/player/\(playerID)/player_ias.vflset/en_US/base.js"))
                    }
                }
            }

            for script in candidates {
                var request = URLRequest(url: script, timeoutInterval: 20)
                request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let source = String(data: data, encoding: .utf8) else { continue }
                playerScriptSource = source
                guard let timestamp = firstCapture(
                    #"signatureTimestamp\s*:\s*(\d{4,6})"#,
                    in: source
                ).flatMap(Int.init) else { continue }
                signatureTimestamp = timestamp
                return timestamp
            }
        } catch {
            return nil
        }
        return nil
    }

    private func currentPlayerScriptRuntime() async throws -> YouTubePlayerScriptRuntime {
        if let playerScriptRuntime { return playerScriptRuntime }
        if playerScriptSource == nil { _ = await resolveSignatureTimestamp() }
        guard let source = playerScriptSource else {
            throw YouTubePlayerScriptError.runtimeUnavailable("the current base.js could not be downloaded")
        }
        let runtime = try YouTubePlayerScriptRuntime(source: source)
        playerScriptRuntime = runtime
        return runtime
    }

    private func normalizedPlayerURL(_ rawValue: String) -> URL? {
        let path = rawValue
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\u0026"#, with: "&")
        guard !path.isEmpty else { return nil }
        return URL(string: path, relativeTo: musicOrigin)?.absoluteURL
    }

    private func requestJSON(url: URL, body: [String: Any], headers: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeMusicClientError.invalidResponse("YouTube Music returned no HTTP response.")
        }
        let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = http.statusCode
        colorfulYouTubeDebug(
            "innertube response path=\(url.path) status=\(status) bytes=\(data.count)"
        )
        guard (200..<300).contains(http.statusCode) else {
            let detail = string(dictionary(document["error"])["message"])
            throw YouTubeMusicClientError.http(http.statusCode, detail)
        }
        return document
    }

    private func logPlayerResponse(clientName: String, document: [String: Any]) {
        let playability = dictionary(document["playabilityStatus"])
        let status = string(playability["status"])
        let reason = string(playability["reason"])
        let streaming = dictionary(document["streamingData"])
        let formats = (array(streaming["adaptiveFormats"]) + array(streaming["formats"]))
            .compactMap { $0 as? [String: Any] }
        let audio = formats.filter { isIOSPlayableAudio($0) }
        let direct = audio.filter { !string($0["url"]).isEmpty }.count
        let ciphered = audio.filter {
            !string($0["signatureCipher"]).isEmpty || !string($0["cipher"]).isEmpty
        }.count
        let proofTokens = audio.filter { hasQuery("pot", in: $0) }.count
        let umpFormats = audio.filter { isUMPFormat($0) }.count
        let hasHLS = !string(streaming["hlsManifestUrl"]).isEmpty
        colorfulYouTubeInfo(
            "player response client=\(clientName) status=\(status) reason=\(reason) hls=\(hasHLS) formats=\(formats.count) audio=\(audio.count) direct=\(direct) ciphered=\(ciphered) potFormats=\(proofTokens) umpFormats=\(umpFormats)"
        )
        for format in audio.prefix(8) {
            let itag = number(format["itag"])
            let mimeType = string(format["mimeType"]).components(separatedBy: ";").first ?? ""
            let isDirect = !string(format["url"]).isEmpty
            let isCiphered = !string(format["signatureCipher"]).isEmpty || !string(format["cipher"]).isEmpty
            let hasPOT = hasQuery("pot", in: format)
            let isUMP = isUMPFormat(format)
            colorfulYouTubeDebug(
                "audio format client=\(clientName) itag=\(itag) mime=\(mimeType) direct=\(isDirect) cipher=\(isCiphered) pot=\(hasPOT) ump=\(isUMP)"
            )
        }
    }

    private func logResolvedSource(kind: String, url: URL, mimeType: String) {
        colorfulYouTubeInfo(
            "resolved source kind=\(kind) mime=\(mimeType) url=\(self.sourceDescriptor(url))"
        )
    }

    private func sourceDescriptor(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let keys = Array(Set(items.map(\.name))).sorted().joined(separator: ",")
        let hasPOT = items.contains { $0.name == "pot" && !($0.value ?? "").isEmpty }
        let hasUMP = items.contains { $0.name == "ump" && !($0.value ?? "").isEmpty }
        let host = url.host ?? ""
        return "host=\(host) queryKeys=[\(keys)] pot=\(hasPOT) ump=\(hasUMP)"
    }

    private func hasQuery(_ name: String, in format: [String: Any]) -> Bool {
        if let url = URL(string: string(format["url"])),
           URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
               $0.name == name && !($0.value ?? "").isEmpty
           }) == true {
            return true
        }
        let encoded = string(format["signatureCipher"]).isEmpty
            ? string(format["cipher"])
            : string(format["signatureCipher"])
        guard let queryItems = URLComponents(string: "https://cipher.invalid/?\(encoded)")?.queryItems else {
            return false
        }
        if queryItems.contains(where: { $0.name == name && !($0.value ?? "").isEmpty }) {
            return true
        }
        guard let nestedURL = queryItems.first(where: { $0.name == "url" })?.value,
              let url = URL(string: nestedURL) else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
            $0.name == name && !($0.value ?? "").isEmpty
        }) == true
    }

    private func isUMPFormat(_ format: [String: Any]) -> Bool {
        string(format["mimeType"]).localizedCaseInsensitiveContains("vnd.yt-ump")
            || hasQuery("ump", in: format)
    }

    private func mapTrack(_ renderer: [String: Any]) -> CoreTrack? {
        let titleRuns = columnRuns(renderer, index: 0)
        let metadataRuns = columnRuns(renderer, index: 1)
        let id = titleRuns.lazy.map(self.videoID).first(where: { !$0.isEmpty })
            ?? children(renderer, key: "watchEndpoint").lazy.map { self.string($0["videoId"]) }.first(where: { !$0.isEmpty })
            ?? ""
        let title = titleRuns.map { string($0["text"]) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !title.isEmpty else { return nil }
        var credits = [CoreArtistCredit]()
        var seen = Set<String>()
        for run in metadataRuns {
            let artistID = browseID(run)
            let name = string(run["text"])
            guard !name.isEmpty, (artistID.hasPrefix("UC") || artistID.hasPrefix("MPLA")), seen.insert(artistID).inserted else { continue }
            credits.append(CoreArtistCredit(id: CoreMediaID(provider: "youtube", providerID: artistID), name: name))
        }
        if credits.isEmpty {
            let fallback = metadataRuns.map { string($0["text"]) }
                .first { !$0.isEmpty && $0 != "•" && $0.range(of: #"^\d+(?::\d+){1,2}$"#, options: .regularExpression) == nil }
            credits = [CoreArtistCredit(id: nil, name: fallback ?? "YouTube Music")]
        }
        let durationText = metadataRuns.reversed().map { string($0["text"]) }
            .first { $0.range(of: #"^\d+(?::\d+){1,2}$"#, options: .regularExpression) != nil }
        return CoreTrack(
            id: CoreMediaID(provider: "youtube", providerID: id), title: title, version: nil,
            artists: credits, albumID: nil, albumTitle: nil,
            artwork: thumbnail(renderer).map { CoreArtwork(url: $0, localKey: nil, width: nil, height: nil) },
            durationMs: durationText.flatMap(parseDuration), isrc: nil, explicit: isExplicit(renderer)
        )
    }

    private func mergedBootstrap(from html: String) -> [String: Any] {
        let marker = "ytcfg.set("
        var merged = [String: Any]()
        var searchStart = html.startIndex
        while let markerRange = html.range(of: marker, range: searchStart..<html.endIndex) {
            let start = markerRange.upperBound
            var depth = 0, quoted = false, escaped = false
            var index = start
            var end: String.Index?
            while index < html.endIndex {
                let character = html[index]
                if quoted {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { quoted = false }
                } else if character == "\"" { quoted = true }
                else if character == "{" { depth += 1 }
                else if character == "}" {
                    depth -= 1
                    if depth == 0 { end = html.index(after: index); break }
                }
                index = html.index(after: index)
            }
            guard let end else { break }
            if let data = String(html[start..<end]).data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                merged.merge(object) { _, new in new }
            }
            searchStart = end
        }
        return merged
    }

    private func responsiveItems(_ root: [String: Any]) -> [[String: Any]] { children(root, key: "musicResponsiveListItemRenderer") }
    private func columnRuns(_ renderer: [String: Any], index: Int) -> [[String: Any]] {
        let columns = array(renderer["flexColumns"])
        guard index < columns.count else { return [] }
        let column = dictionary(columns[index])
        let value = dictionary(dictionary(column["musicResponsiveListItemFlexColumnRenderer"])["text"])
        return array(value["runs"]).compactMap { $0 as? [String: Any] }
    }
    private func browseID(_ run: [String: Any]) -> String {
        string(dictionary(dictionary(run["navigationEndpoint"])["browseEndpoint"])["browseId"])
    }
    private func videoID(_ run: [String: Any]) -> String {
        string(dictionary(dictionary(run["navigationEndpoint"])["watchEndpoint"])["videoId"])
    }
    private func thumbnail(_ root: Any) -> String? {
        let candidates = children(root, key: "thumbnail").flatMap { self.array($0["thumbnails"]) }
            .compactMap { $0 as? [String: Any] }
            .filter { !string($0["url"]).isEmpty }
            .sorted { self.number($0["width"]) * self.number($0["height"]) > self.number($1["width"]) * self.number($1["height"]) }
        let value = candidates.first.map { string($0["url"]) } ?? ""
        return value.isEmpty ? nil : (value.hasPrefix("//") ? "https:\(value)" : value)
    }
    private func isExplicit(_ root: Any) -> Bool {
        children(root, key: "musicInlineBadgeRenderer").contains {
            string(dictionary($0["accessibilityData"])["label"]).lowercased().contains("explicit")
        }
    }
    private func children(_ root: Any, key: String) -> [[String: Any]] {
        var output = [[String: Any]]()
        func visit(_ value: Any) {
            if let values = value as? [Any] { values.forEach(visit) }
            else if let object = value as? [String: Any] {
                for (name, child) in object {
                    if name == key, let match = child as? [String: Any] { output.append(match) }
                    visit(child)
                }
            }
        }
        visit(root)
        return output
    }
    private func parseDuration(_ value: String) -> UInt64? {
        let parts = value.split(separator: ":").compactMap { UInt64($0) }
        guard parts.count == value.split(separator: ":").count, (2...3).contains(parts.count) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 } * 1_000
    }
    private func formatScore(_ format: [String: Any]) -> Int {
        let quality = string(format["audioQuality"])
        let named = quality.contains("HIGH") ? 3 : quality.contains("MEDIUM") ? 2 : quality.contains("LOW") ? 1 : 0
        let mime = string(format["mimeType"])
        return named * 1_000_000_000 + number(format["bitrate"]) * 10 + (mime.contains("mp4a") ? 2 : 1)
    }
    private func isIOSPlayableAudio(_ format: [String: Any]) -> Bool {
        let mime = string(format["mimeType"]).lowercased()
        return mime.hasPrefix("audio/mp4") || mime.hasPrefix("audio/aac") || mime.hasPrefix("audio/mpeg")
    }
    private func webClientVersion() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return "1.\(formatter.string(from: Date())).01.00"
    }
    private func firstCapture(_ pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
    private func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    private func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
    private func string(_ value: Any?) -> String { value as? String ?? "" }
    private func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? Int(value as? String ?? "") ?? 0 }
    private func number64(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? Int64(value as? String ?? "") ?? 0 }
}
