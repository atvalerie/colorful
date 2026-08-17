import Foundation

enum SoundCloudClientError: LocalizedError, Sendable {
    case invalidResponse(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail):
            return detail
        case .http(let status, let detail):
            return "SoundCloud returned HTTP \(status)\(detail.isEmpty ? "" : ": \(detail)")"
        }
    }
}

actor SoundCloudClient {
    static let shared = SoundCloudClient()

    private struct Bootstrap: Sendable {
        let clientID: String
        let appVersion: String?
        let discoveredAt: Date
    }

    private let webOrigin = URL(string: "https://soundcloud.com")!
    private let apiOrigin = URL(string: "https://api-v2.soundcloud.com")!
    private let discoveryLifetime: TimeInterval = 6 * 60 * 60
    private let anonymousUserID = (0..<4)
        .map { _ in String(Int.random(in: 100_000...999_999)) }
        .joined(separator: "-")
    private var bootstrap: Bootstrap?

    func searchTracks(query: String, limit: Int = 30) async throws -> [CoreTrack] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        let document = try await apiObject(
            path: "search",
            query: [
                URLQueryItem(name: "q", value: cleaned),
                URLQueryItem(name: "facet", value: "model"),
                URLQueryItem(name: "limit", value: String(max(1, min(50, limit)))),
                URLQueryItem(name: "offset", value: "0"),
                URLQueryItem(name: "linked_partitioning", value: "1"),
                URLQueryItem(name: "user_id", value: anonymousUserID),
            ]
        )
        return array(document["collection"]).compactMap { value in
            guard let object = value as? [String: Any], string(object["kind"]) == "track" else { return nil }
            return mapTrack(object)
        }
    }

    func playbackURL(for track: CoreTrack) async throws -> URL {
        guard track.id.provider.lowercased() == "soundcloud", !track.id.providerID.isEmpty else {
            throw SoundCloudClientError.invalidResponse("This is not a SoundCloud track.")
        }
        let object = try await apiObject(path: "tracks/\(track.id.providerID)")
        if object["streamable"] as? Bool == false {
            throw SoundCloudClientError.invalidResponse("This SoundCloud track is not streamable.")
        }
        guard let media = object["media"] as? [String: Any] else {
            throw SoundCloudClientError.invalidResponse("SoundCloud did not expose playback media.")
        }
        let transcodings = array(media["transcodings"])
            .compactMap { $0 as? [String: Any] }
            .filter { !string($0["url"]).isEmpty }
            .sorted { transcodingScore($0) > transcodingScore($1) }
        guard !transcodings.isEmpty else {
            throw SoundCloudClientError.invalidResponse("SoundCloud did not expose a playable transcoding.")
        }

        var lastError: Error?
        for (index, transcoding) in transcodings.enumerated() {
            let attempts = index == 0 ? 3 : 1
            for _ in 0..<attempts {
                do {
                    let resolved = try await apiObject(
                        absoluteURL: string(transcoding["url"]),
                        query: [URLQueryItem(
                            name: "track_authorization",
                            value: string(object["track_authorization"])
                        )]
                    )
                    guard let url = URL(string: string(resolved["url"])) else {
                        throw SoundCloudClientError.invalidResponse("SoundCloud returned an empty playback URL.")
                    }
                    let format = transcoding["format"] as? [String: Any]
                    if string(format?["protocol"]) == "hls" {
                        try await validateManifest(url)
                    }
                    return url
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError ?? SoundCloudClientError.invalidResponse("SoundCloud could not resolve a playable stream.")
    }

    private func discover(force: Bool = false) async throws -> Bootstrap {
        if !force, let bootstrap,
           Date().timeIntervalSince(bootstrap.discoveredAt) < discoveryLifetime {
            return bootstrap
        }
        var request = URLRequest(url: webOrigin)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("colorful/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SoundCloudClientError.invalidResponse("SoundCloud discovery returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SoundCloudClientError.http(http.statusCode, "public client discovery failed")
        }
        guard let html = String(data: data, encoding: .utf8),
              let clientID = firstMatch(
                #"\"hydratable\"\s*:\s*\"apiClient\"[\s\S]{0,1000}?\"id\"\s*:\s*\"([^\"]+)\""#,
                in: html
              ) else {
            throw SoundCloudClientError.invalidResponse("SoundCloud did not expose its public API client.")
        }
        let value = Bootstrap(
            clientID: clientID,
            appVersion: firstMatch(#"\\?\"appVersion\\?\"\s*:\s*\\?\"(\d+)\\?\""#, in: html),
            discoveredAt: Date()
        )
        bootstrap = value
        return value
    }

    private func apiObject(
        path: String? = nil,
        absoluteURL: String? = nil,
        query: [URLQueryItem] = [],
        retryDiscovery: Bool = true
    ) async throws -> [String: Any] {
        let bootstrap = try await discover()
        let baseURL: URL
        if let absoluteURL, let parsed = URL(string: absoluteURL) {
            baseURL = parsed
        } else if let path {
            baseURL = apiOrigin.appendingPathComponent(path)
        } else {
            throw SoundCloudClientError.invalidResponse("SoundCloud request URL is invalid.")
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw SoundCloudClientError.invalidResponse("SoundCloud request URL is invalid.")
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "client_id" || $0.name == "app_version" || $0.name == "app_locale" }
        items.append(URLQueryItem(name: "client_id", value: bootstrap.clientID))
        if let appVersion = bootstrap.appVersion {
            items.append(URLQueryItem(name: "app_version", value: appVersion))
        }
        items.append(URLQueryItem(name: "app_locale", value: "en"))
        items.append(contentsOf: query.filter { $0.value?.isEmpty == false })
        components.queryItems = items
        guard let url = components.url else {
            throw SoundCloudClientError.invalidResponse("SoundCloud request URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("colorful/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SoundCloudClientError.invalidResponse("SoundCloud returned no HTTP response.")
        }
        if (http.statusCode == 401 || http.statusCode == 403), retryDiscovery {
            _ = try await discover(force: true)
            return try await apiObject(
                path: path,
                absoluteURL: absoluteURL,
                query: query,
                retryDiscovery: false
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data.prefix(240), encoding: .utf8) ?? ""
            throw SoundCloudClientError.http(http.statusCode, detail)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SoundCloudClientError.invalidResponse("SoundCloud returned invalid JSON.")
        }
        return object
    }

    private func validateManifest(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.apple.mpegurl, application/x-mpegURL, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://soundcloud.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let body = String(data: data, encoding: .utf8),
              body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            throw SoundCloudClientError.invalidResponse("SoundCloud returned an invalid HLS stream.")
        }
    }

    private func mapTrack(_ object: [String: Any]) -> CoreTrack? {
        let id = identifier(object["id"])
        let title = string(object["title"])
        guard !id.isEmpty, !title.isEmpty else { return nil }
        let user = object["user"] as? [String: Any]
        let artistID = identifier(user?["id"])
        let artistName = string(user?["username"]).isEmpty ? "SoundCloud" : string(user?["username"])
        let publisher = object["publisher_metadata"] as? [String: Any]
        let artworkURL = upgradedArtworkURL(string(object["artwork_url"]).isEmpty
            ? string(user?["avatar_url"])
            : string(object["artwork_url"]))
        let duration = number(object["full_duration"]) ?? number(object["duration"])
        return CoreTrack(
            id: CoreMediaID(provider: "soundcloud", providerID: id),
            title: title,
            version: nil,
            artists: [CoreArtistCredit(
                id: artistID.isEmpty ? nil : CoreMediaID(provider: "soundcloud", providerID: artistID),
                name: artistName
            )],
            albumID: nil,
            albumTitle: string(publisher?["album_title"]).nilIfEmpty,
            artwork: artworkURL.map { CoreArtwork(url: $0, localKey: nil, width: nil, height: nil) },
            durationMs: duration.map { UInt64(max(0, $0)) },
            isrc: string(publisher?["isrc"]).nilIfEmpty,
            explicit: publisher?["explicit"] as? Bool
        )
    }

    private func transcodingScore(_ value: [String: Any]) -> Int {
        let format = value["format"] as? [String: Any]
        let protocolName = string(format?["protocol"])
        let mime = string(format?["mime_type"])
        let preset = string(value["preset"])
        let quality = string(value["quality"])
        if preset.contains("aac_160") { return 600 }
        if preset == "abr_sq" { return 550 }
        if preset.contains("aac_96") { return 500 }
        return (quality == "sq" ? 200 : quality == "lq" ? 100 : 0)
            + (mime.contains("mp4a") || mime.contains("audio/mp4") ? 60
                : mime.contains("mpeg") ? 40 : mime.contains("opus") ? 30 : 0)
            + (protocolName == "hls" ? 10 : 0)
    }

    private func firstMatch(_ pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private func upgradedArtworkURL(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        guard let expression = try? NSRegularExpression(
            pattern: #"-(?:large|t\d+x\d+|original|crop)(\.(?:jpg|jpeg|png|webp)(?:\?.*)?)$"#,
            options: [.caseInsensitive]
        ) else { return value }
        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value),
            withTemplate: "-t500x500$1"
        )
    }

    private func string(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private func identifier(_ value: Any?) -> String { string(value) }

    private func number(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
