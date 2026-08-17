import Foundation

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

actor YouTubeMusicClient {
    static let shared = YouTubeMusicClient()

    private let musicOrigin = URL(string: "https://music.youtube.com")!
    private let playerOrigin = URL(string: "https://www.youtube.com")!
    private let webUserAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/140 Safari/537.36"
    private let androidVersion = "1.65.10"
    private let songsFilter = "EgWKAQIIAWoQEAUQBBADEAoQCRAVEBAQEQ%3D%3D"
    private let videosFilter = "EgWKAQIQAWoQEAUQBBADEAoQCRAVEBAQEQ%3D%3D"
    private var visitorData: String?
    private var signatureTimestamp: Int?
    private var playerScriptURL: URL?

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

    func playbackURL(for track: CoreTrack) async throws -> URL {
        let videoID = track.id.providerID
        guard track.id.provider.lowercased() == "youtube",
              videoID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else {
            throw YouTubeMusicClientError.invalidResponse("This is not a valid YouTube Music track.")
        }
        let bootstrap = try await playerBootstrap()
        let androidUserAgent = "com.google.android.apps.youtube.vr.oculus/\(androidVersion) (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
        let androidClient: [String: Any] = [
                "clientName": "ANDROID_VR", "clientVersion": androidVersion,
                "deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": 32,
                "userAgent": androidUserAgent, "osName": "Android", "osVersion": "12L",
                "hl": "en", "timeZone": "UTC", "utcOffsetMinutes": 0,
                "visitorData": bootstrap.visitor,
        ]
        var firstFailure: Error?
        do {
            let document = try await playerDocument(
                videoID: videoID, visitor: bootstrap.visitor, timestamp: bootstrap.timestamp,
                client: androidClient,
                headers: [
                "User-Agent": androidUserAgent,
                "X-Youtube-Client-Name": "28",
                "X-Youtube-Client-Version": androidVersion,
                ]
            )
            let url = try directAudioURL(document)
            try await validateSource(url, userAgent: androidUserAgent, expectsManifest: false)
            return url
        } catch {
            firstFailure = error
        }

        let safariVersion = "2.20260708.00.00"
        let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)"
        do {
            let document = try await playerDocument(
                videoID: videoID, visitor: bootstrap.visitor, timestamp: bootstrap.timestamp,
                client: [
                    "clientName": "WEB", "clientVersion": safariVersion, "userAgent": safariUserAgent,
                    "hl": "en", "gl": "US", "visitorData": bootstrap.visitor,
                ],
                headers: [
                    "User-Agent": safariUserAgent,
                    "X-Youtube-Client-Name": "1",
                    "X-Youtube-Client-Version": safariVersion,
                ]
            )
            let manifest = string(dictionary(document["streamingData"])["hlsManifestUrl"])
            guard let url = URL(string: manifest), url.scheme == "https" else {
                throw YouTubeMusicClientError.invalidResponse("YouTube web player returned no HLS stream.")
            }
            try await validateSource(url, userAgent: safariUserAgent, expectsManifest: true)
            return url
        } catch {
            // Continue to the TV client, which often exposes direct formats when
            // the Android VR response is restricted or incomplete.
        }

        let tvVersion = "5.20260707"
        let tvUserAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
        do {
            let document = try await playerDocument(
                videoID: videoID, visitor: bootstrap.visitor, timestamp: bootstrap.timestamp,
                client: [
                    "clientName": "TVHTML5", "clientVersion": tvVersion,
                    "hl": "en", "gl": "US", "visitorData": bootstrap.visitor,
                ],
                headers: [
                    "User-Agent": tvUserAgent,
                    "X-Youtube-Client-Name": "7",
                    "X-Youtube-Client-Version": tvVersion,
                ]
            )
            let url = try directAudioURL(document)
            try await validateSource(url, userAgent: tvUserAgent, expectsManifest: false)
            return url
        } catch {
            throw firstFailure ?? error
        }
    }

    private func playerDocument(
        videoID: String,
        visitor: String,
        timestamp: Int,
        client: [String: Any],
        headers: [String: String]
    ) async throws -> [String: Any] {
        try await requestJSON(
            url: playerOrigin.appending(path: "youtubei/v1/player").appending(queryItems: [URLQueryItem(name: "prettyPrint", value: "false")]),
            body: [
                "context": ["client": client], "videoId": videoID,
                "playbackContext": ["contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS", "signatureTimestamp": timestamp,
                ]],
                "contentCheckOk": true, "racyCheckOk": true,
            ],
            headers: headers.merging([
                "X-Goog-Visitor-Id": visitor,
                "Origin": playerOrigin.absoluteString,
            ]) { current, _ in current }
        )
    }

    private func directAudioURL(_ document: [String: Any]) throws -> URL {
        let playability = dictionary(document["playabilityStatus"])
        let status = string(playability["status"])
        if !status.isEmpty && status != "OK" {
            let reason = string(playability["reason"])
            throw YouTubeMusicClientError.invalidResponse(
                "YouTube Music playback is \(status.lowercased())\(reason.isEmpty ? "" : ": \(reason)")"
            )
        }
        let streaming = dictionary(document["streamingData"])
        let formats = (array(streaming["adaptiveFormats"]) + array(streaming["formats"]))
            .compactMap { $0 as? [String: Any] }
            .filter { isIOSPlayableAudio($0) && !string($0["url"]).isEmpty }
            .sorted { formatScore($0) > formatScore($1) }
        guard let selected = formats.first, let url = URL(string: string(selected["url"])) else {
            let ciphered = (array(streaming["adaptiveFormats"]) + array(streaming["formats"]))
                .compactMap { $0 as? [String: Any] }
                .contains { !string($0["signatureCipher"]).isEmpty || !string($0["cipher"]).isEmpty }
            throw YouTubeMusicClientError.invalidResponse(ciphered
                ? "YouTube Music returned only protected audio for this track."
                : "YouTube Music returned no directly playable audio.")
        }
        return url
    }

    private func validateSource(_ url: URL, userAgent: String, expectsManifest: Bool) async throws {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if !expectsManifest { request.setValue("bytes=0-1", forHTTPHeaderField: "Range") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw YouTubeMusicClientError.invalidResponse("YouTube Music returned an unusable audio source.")
        }
        if expectsManifest {
            let prefix = String(data: data.prefix(256), encoding: .utf8) ?? ""
            guard prefix.contains("#EXTM3U") else {
                throw YouTubeMusicClientError.invalidResponse("YouTube Music returned an invalid HLS stream.")
            }
        }
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

    private func playerBootstrap() async throws -> (visitor: String, timestamp: Int) {
        if let visitorData, let signatureTimestamp { return (visitorData, signatureTimestamp) }
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
        let visitor = string(dictionary(context["client"])["visitorData"])
        guard !visitor.isEmpty else {
            throw YouTubeMusicClientError.invalidResponse("YouTube Music bootstrap did not contain visitor data.")
        }
        let script = try playerScript(from: config)
        var scriptRequest = URLRequest(url: script)
        scriptRequest.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        let (scriptData, scriptResponse) = try await URLSession.shared.data(for: scriptRequest)
        guard let scriptHTTP = scriptResponse as? HTTPURLResponse, (200..<300).contains(scriptHTTP.statusCode),
              let source = String(data: scriptData, encoding: .utf8),
              let timestamp = firstCapture(#"signatureTimestamp\s*:\s*(\d{4,6})"#, in: source).flatMap(Int.init) else {
            throw YouTubeMusicClientError.invalidResponse("YouTube Music player metadata could not be read.")
        }
        visitorData = visitor
        signatureTimestamp = timestamp
        playerScriptURL = script
        return (visitor, timestamp)
    }

    private func playerScript(from config: [String: Any]) throws -> URL {
        if let playerScriptURL { return playerScriptURL }
        let contexts = dictionary(config["WEB_PLAYER_CONTEXT_CONFIGS"])
        for value in contexts.values {
            let path = string(dictionary(value)["jsUrl"])
            if !path.isEmpty, let url = URL(string: path, relativeTo: musicOrigin)?.absoluteURL { return url }
        }
        throw YouTubeMusicClientError.invalidResponse("YouTube Music bootstrap did not contain a player script.")
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
        guard (200..<300).contains(http.statusCode) else {
            let detail = string(dictionary(document["error"])["message"])
            throw YouTubeMusicClientError.http(http.statusCode, detail)
        }
        return document
    }

    private func mapTrack(_ renderer: [String: Any]) -> CoreTrack? {
        let titleRuns = columnRuns(renderer, index: 0)
        let metadataRuns = columnRuns(renderer, index: 1)
        let id = titleRuns.lazy.map(videoID).first(where: { !$0.isEmpty })
            ?? children(renderer, key: "watchEndpoint").lazy.map { string($0["videoId"]) }.first(where: { !$0.isEmpty })
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
        let candidates = children(root, key: "thumbnail").flatMap { array($0["thumbnails"]) }
            .compactMap { $0 as? [String: Any] }
            .filter { !string($0["url"]).isEmpty }
            .sorted { number($0["width"]) * number($0["height"]) > number($1["width"]) * number($1["height"]) }
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
}
