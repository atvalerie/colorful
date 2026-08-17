import Foundation
import Security

enum ColorfulKeychainError: LocalizedError, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed (status \(status))."
        case .invalidData:
            return "The Keychain returned invalid credential data."
        }
    }
}

struct ColorfulKeychain {
    private let service = "sh.valerie.colorful.provider"

    func readString(forKey key: String) throws -> String? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else {
            throw ColorfulKeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw ColorfulKeychainError.invalidData
        }
        return value
    }

    func writeString(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(forKey: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw ColorfulKeychainError.unexpectedStatus(updateStatus)
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ColorfulKeychainError.unexpectedStatus(addStatus)
        }
    }

    func deleteValue(forKey key: String) throws {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ColorfulKeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

struct TidalConfiguration: Sendable {
    let browseClientID: String
    let browseClientSecret: String
    let deviceClientID: String
    let deviceClientSecret: String
    let browseScope: String
    let deviceScope: String
    let authBaseURL: String
    let apiBaseURL: String
    let countryCode: String

    static let bundled = TidalConfiguration(
        browseClientID: "lw3vR6GE1vtNBsjv",
        browseClientSecret: "Y8tIpqKJxs9BEIwYr0I9bSbMWDsogXJx9LaN3mCHwD4=",
        deviceClientID: "fX2JxdmntZWK0ixT",
        deviceClientSecret: "1Nm5AfDAjxrgJFJbKNWLeAyKGVGmINuXPPLHVXAvxAg=",
        browseScope: "r_usr w_usr w_sub",
        deviceScope: "r_usr+w_usr+w_sub",
        authBaseURL: "https://auth.tidal.com",
        apiBaseURL: "https://openapi.tidal.com/v2/",
        countryCode: (Locale.current.regionCode ?? "US").uppercased()
    )
}

enum TidalClientError: LocalizedError, Sendable {
    case invalidResponse(String)
    case http(status: Int, message: String)
    case missingValue(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message):
            return message
        case .http(let status, let message):
            return "TIDAL request failed (HTTP \(status)): \(message)"
        case .missingValue(let value):
            return "TIDAL returned no \(value)."
        }
    }
}

struct TidalDeviceAuthorization: Codable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let expiresAtMs: Int64
    let intervalSeconds: Int64

    enum CodingKeys: String, CodingKey {
        case deviceCode
        case userCode
        case verificationURL = "verificationUrl"
        case expiresAtMs
        case intervalSeconds
    }
}

struct TidalUserToken: Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAtMs: Int64
}

struct TidalAccountInfo: Sendable {
    let userID: String
    let countryCode: String
    let email: String?
}

struct TidalAlbumPage: Sendable {
    let id: String
    let title: String
    let artistLabel: String
    let artworkURL: String?
    let tracksDocument: String
}

struct TidalAlbumCollection: Sendable {
    let id: String
    let title: String
    let artistLabel: String
    let artworkURL: String?
    let tracks: [CoreTrack]
}

struct TidalArtistPage: Sendable {
    let id: String
    let name: String
    let artworkURL: String?
    let tracksDocument: String
    let albums: [TidalAlbumSummary]
}

struct TidalArtistCollection: Sendable {
    let id: String
    let name: String
    let artworkURL: String?
    let topTracks: [CoreTrack]
    let albums: [TidalAlbumSummary]
}

struct TidalAlbumSummary: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artistLabel: String
    let artworkURL: String?
}

struct TidalArtistSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let artworkURL: String?
}

struct TidalPlaylistSummary: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String?
    let artworkURL: String?
}

struct TidalRecommendationPage: Sendable {
    let dailyMixes: [TidalPlaylistSummary]
    let discoveryMixes: [TidalPlaylistSummary]
    let newReleaseMixes: [TidalPlaylistSummary]

    var isEmpty: Bool {
        dailyMixes.isEmpty && discoveryMixes.isEmpty && newReleaseMixes.isEmpty
    }
}

struct TidalPlaylistPage: Sendable {
    let id: String
    let title: String
    let description: String?
    let artworkURL: String?
    let tracksDocument: String
}

struct TidalPlaylistCollection: Sendable {
    let id: String
    let title: String
    let description: String?
    let artworkURL: String?
    let tracks: [CoreTrack]
}

struct TidalUserCatalogResolution<Value: Sendable>: Sendable {
    let value: Value
    let refreshToken: String
}

struct TidalCatalogSearchResults: Sendable {
    let tracks: [CoreTrack]
    let albums: [TidalAlbumSummary]
    let artists: [TidalArtistSummary]

    var isEmpty: Bool {
        tracks.isEmpty && albums.isEmpty && artists.isEmpty
    }
}

struct TidalCatalogSearchPage: Sendable {
    let tracksDocument: String
    let albums: [TidalAlbumSummary]
    let artists: [TidalArtistSummary]
}

struct TidalPlaybackSource: Sendable {
    let uri: String
    let manifestType: String
    let formats: [String]
    let presentation: String?
    let previewReason: String?
}

struct TidalPlaybackResolution: Sendable {
    let source: TidalPlaybackSource
    let refreshToken: String
}

struct TidalLyricLine: Identifiable, Hashable, Sendable {
    let id: Int
    let startMs: UInt64?
    let text: String
}

struct TidalLyricsDocument: Sendable {
    let sourceLabel: String
    let synced: Bool
    let lines: [TidalLyricLine]
}

actor TidalClient {
    private let configuration: TidalConfiguration
    private var browseAccessToken: String?
    private var browseTokenExpiresAtMs: Int64 = 0
    private var userToken: TidalUserToken?

    init(configuration: TidalConfiguration = .bundled) {
        self.configuration = configuration
    }

    func startDeviceAuthorization() async throws -> TidalDeviceAuthorization {
        let url = try makeURL(base: configuration.authBaseURL, path: "/v1/oauth2/device_authorization")
        let data = try await request(
            url,
            method: "POST",
            body: formBody([
                "client_id": configuration.deviceClientID,
                "scope": configuration.deviceScope,
            ])
        )
        let value = try object(from: data)
        let deviceCode = string(value, key: "deviceCode")
        let userCode = string(value, key: "userCode")
        let verification = string(value, key: "verificationUriComplete")
            .ifBlank { string(value, key: "verificationUri") }
        let expiresIn = int64(value, key: "expiresIn", fallback: 300)
        let interval = max(1, int64(value, key: "interval", fallback: 5))
        guard !deviceCode.isEmpty, !userCode.isEmpty, !verification.isEmpty else {
            throw TidalClientError.invalidResponse("TIDAL returned an incomplete device authorization.")
        }

        return TidalDeviceAuthorization(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: normalizeVerificationURL(verification),
            expiresAtMs: nowMs + expiresIn * 1_000,
            intervalSeconds: interval
        )
    }

    func pollDeviceAuthorization(_ authorization: TidalDeviceAuthorization) async throws -> TidalUserToken {
        var delaySeconds = authorization.intervalSeconds
        while nowMs < authorization.expiresAtMs {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)

            let url = try makeURL(base: configuration.authBaseURL, path: "/v1/oauth2/token")
            let (status, data) = try await perform(
                url,
                method: "POST",
                headers: ["Authorization": basicAuthorization(configuration.deviceClientID, configuration.deviceClientSecret)],
                body: formBody([
                    "client_id": configuration.deviceClientID,
                    "scope": configuration.deviceScope,
                    "device_code": authorization.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ])
            )

            if (200..<300).contains(status) {
                let value = try object(from: data)
                let accessToken = string(value, key: "access_token")
                let refreshToken = string(value, key: "refresh_token")
                guard !accessToken.isEmpty, !refreshToken.isEmpty else {
                    throw TidalClientError.missingValue("refresh token")
                }
                return TidalUserToken(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    expiresAtMs: nowMs + int64(value, key: "expires_in", fallback: 3_600) * 1_000
                )
            }

            let error = string((try? object(from: data)) ?? [:], key: "error")
            switch error {
            case "authorization_pending":
                continue
            case "slow_down":
                delaySeconds += 5
            default:
                throw TidalClientError.http(status: status, message: error.ifBlank { "device authorization failed" })
            }
        }
        throw TidalClientError.invalidResponse("TIDAL device authorization expired.")
    }

    func accountInfo(accessToken: String) async throws -> TidalAccountInfo {
        let url = try makeURL(base: "https://login.tidal.com", path: "/oauth2/me")
        let value = try object(from: await request(url, headers: ["Authorization": "Bearer \(accessToken)"]))
        let userID = string(value, key: "userId")
        let country = string(value, key: "countryCode").uppercased()
        let email = string(value, key: "email")
        guard !userID.isEmpty else { throw TidalClientError.missingValue("user ID") }
        guard country.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else {
            throw TidalClientError.missingValue("account country")
        }
        return TidalAccountInfo(
            userID: userID,
            countryCode: country,
            email: email.isEmpty ? nil : email
        )
    }

    func refreshUserToken(_ refreshToken: String) async throws -> TidalUserToken {
        let url = try makeURL(base: configuration.authBaseURL, path: "/v1/oauth2/token")
        let data = try await request(
            url,
            method: "POST",
            headers: ["Authorization": basicAuthorization(configuration.browseClientID, configuration.browseClientSecret)],
            body: formBody([
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": configuration.browseClientID,
                "scope": configuration.browseScope,
            ])
        )
        let value = try object(from: data)
        let accessToken = string(value, key: "access_token")
        guard !accessToken.isEmpty else { throw TidalClientError.missingValue("access token") }
        return TidalUserToken(
            accessToken: accessToken,
            refreshToken: string(value, key: "refresh_token").ifBlank { refreshToken },
            expiresAtMs: nowMs + int64(value, key: "expires_in", fallback: 3_600) * 1_000
        )
    }

    func clearUserSession() {
        userToken = nil
    }

    func searchCatalog(query: String, countryCode: String) async throws -> TidalCatalogSearchPage {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return TidalCatalogSearchPage(tracksDocument: "{\"data\":[]}", albums: [], artists: [])
        }

        do {
            let token = try await browseAccessToken(force: false)
            return try await searchCatalogPage(query: cleaned, countryCode: countryCode, token: token)
        } catch let error as TidalClientError {
            if case .http(let status, _) = error, status == 401 {
                let token = try await browseAccessToken(force: true)
                return try await searchCatalogPage(query: cleaned, countryCode: countryCode, token: token)
            }
            throw error
        }
    }

    func albumPage(albumID: String, countryCode: String) async throws -> TidalAlbumPage {
        let cleaned = albumID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw TidalClientError.missingValue("album ID") }

        do {
            let token = try await browseAccessToken(force: false)
            return try await fetchAlbumPage(albumID: cleaned, countryCode: countryCode, token: token)
        } catch let error as TidalClientError {
            if case .http(let status, _) = error, status == 401 {
                let token = try await browseAccessToken(force: true)
                return try await fetchAlbumPage(albumID: cleaned, countryCode: countryCode, token: token)
            }
            throw error
        }
    }

    func artistPage(artistID: String, countryCode: String) async throws -> TidalArtistPage {
        let cleaned = artistID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw TidalClientError.missingValue("artist ID") }

        do {
            let token = try await browseAccessToken(force: false)
            return try await fetchArtistPage(artistID: cleaned, countryCode: countryCode, token: token)
        } catch let error as TidalClientError {
            if case .http(let status, _) = error, status == 401 {
                let token = try await browseAccessToken(force: true)
                return try await fetchArtistPage(artistID: cleaned, countryCode: countryCode, token: token)
            }
            throw error
        }
    }

    func lyrics(
        trackID: String,
        countryCode: String,
        refreshToken: String
    ) async throws -> TidalUserCatalogResolution<TidalLyricsDocument?> {
        let cleaned = trackID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return TidalUserCatalogResolution(value: nil, refreshToken: refreshToken)
        }
        var currentRefreshToken = refreshToken
        if let userResolution = try? await withUserCatalog(refreshToken: refreshToken, operation: { token in
            try await self.fetchLyrics(trackID: cleaned, countryCode: countryCode, token: token)
        }) {
            currentRefreshToken = userResolution.refreshToken
            if userResolution.value != nil {
                return userResolution
            }
        }
        let browseToken = try await browseAccessToken(force: false)
        let catalogLyrics = try await fetchLyrics(
            trackID: cleaned,
            countryCode: countryCode,
            token: browseToken
        )
        return TidalUserCatalogResolution(value: catalogLyrics, refreshToken: currentRefreshToken)
    }

    func lrclibLyrics(for track: CoreTrack) async -> TidalLyricsDocument? {
        guard !track.title.isEmpty,
              let primaryArtist = track.artists.first?.name,
              !primaryArtist.isEmpty else { return nil }
        var exactQuery = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artistLabel),
        ]
        if let albumTitle = track.albumTitle, !albumTitle.isEmpty,
           let durationMs = track.durationMs {
            exactQuery.append(URLQueryItem(name: "album_name", value: albumTitle))
            exactQuery.append(URLQueryItem(name: "duration", value: String((durationMs + 500) / 1_000)))
        }

        var candidates = [[String: Any]]()
        if let exactURL = try? makeURL(base: "https://lrclib.net/api/", path: "get", query: exactQuery),
           let response = try? await perform(exactURL),
           (200..<300).contains(response.0),
           let record = try? JSONSerialization.jsonObject(with: response.1) as? [String: Any] {
            candidates.append(record)
        }
        let exactHasSyncedLyrics = candidates.contains {
            firstNonblankString($0, keys: ["syncedLyrics"]) != nil
        }
        if !exactHasSyncedLyrics,
           let searchURL = try? makeURL(
               base: "https://lrclib.net/api/",
               path: "search",
               query: [
                   URLQueryItem(name: "track_name", value: track.title),
                   URLQueryItem(name: "artist_name", value: primaryArtist),
               ]
           ),
           let response = try? await perform(searchURL),
           (200..<300).contains(response.0),
           let records = try? JSONSerialization.jsonObject(with: response.1) as? [[String: Any]] {
            candidates.append(contentsOf: records)
        }

        let durationSeconds = track.durationMs.map { Double($0) / 1_000 }
        let matchingDuration = candidates.filter { record in
            guard let durationSeconds else { return true }
            guard let candidateDuration = (record["duration"] as? NSNumber)?.doubleValue else { return false }
            return abs(candidateDuration - durationSeconds) <= 3
        }
        let ranked = matchingDuration.isEmpty ? candidates : matchingDuration
        guard let candidate = ranked.first(where: {
            firstNonblankString($0, keys: ["syncedLyrics"]) != nil
        }) ?? ranked.first else { return nil }
        let syncedLines = firstNonblankString(candidate, keys: ["syncedLyrics"])
            .map(parseSyncedLyrics) ?? []
        let lines = syncedLines.isEmpty
            ? plainLyricsLines(firstNonblankString(candidate, keys: ["plainLyrics"]))
            : syncedLines
        guard !lines.isEmpty else { return nil }
        return TidalLyricsDocument(
            sourceLabel: "LRCLIB",
            synced: !syncedLines.isEmpty,
            lines: lines
        )
    }

    func playbackSource(
        trackID: String,
        countryCode: String,
        refreshToken: String
    ) async throws -> TidalPlaybackResolution {
        let token = try await userAccessToken(refreshToken: refreshToken, force: false)
        do {
            let source = try await fetchPlaybackSource(
                trackID: trackID,
                countryCode: countryCode,
                accessToken: token.accessToken
            )
            if source.presentation == "PREVIEW", source.previewReason == "FULL_REQUIRES_SUBSCRIPTION" {
                let refreshed = try await userAccessToken(refreshToken: token.refreshToken, force: true)
                let entitled = try await fetchPlaybackSource(
                    trackID: trackID,
                    countryCode: countryCode,
                    accessToken: refreshed.accessToken
                )
                return try entitledResolution(source: entitled, refreshToken: refreshed.refreshToken)
            }
            return try entitledResolution(source: source, refreshToken: token.refreshToken)
        } catch let error as TidalClientError {
            guard case .http(let status, _) = error, status == 401 else { throw error }
            let refreshed = try await userAccessToken(refreshToken: token.refreshToken, force: true)
            let source = try await fetchPlaybackSource(
                trackID: trackID,
                countryCode: countryCode,
                accessToken: refreshed.accessToken
            )
            return try entitledResolution(source: source, refreshToken: refreshed.refreshToken)
        }
    }

    func recommendations(
        countryCode: String,
        refreshToken: String
    ) async throws -> TidalUserCatalogResolution<TidalRecommendationPage> {
        try await withUserCatalog(refreshToken: refreshToken) { token in
            try await self.fetchRecommendations(countryCode: countryCode, accessToken: token)
        }
    }

    func playlistPage(
        playlistID: String,
        countryCode: String,
        refreshToken: String
    ) async throws -> TidalUserCatalogResolution<TidalPlaylistPage> {
        let cleaned = playlistID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw TidalClientError.missingValue("playlist ID") }
        return try await withUserCatalog(refreshToken: refreshToken) { token in
            try await self.fetchPlaylistPage(
                playlistID: cleaned,
                countryCode: countryCode,
                accessToken: token
            )
        }
    }

    private func withUserCatalog<Value: Sendable>(
        refreshToken: String,
        operation: (String) async throws -> Value
    ) async throws -> TidalUserCatalogResolution<Value> {
        let token = try await userAccessToken(refreshToken: refreshToken, force: false)
        do {
            return TidalUserCatalogResolution(
                value: try await operation(token.accessToken),
                refreshToken: token.refreshToken
            )
        } catch let error as TidalClientError {
            guard case .http(let status, _) = error, status == 401 else { throw error }
            let refreshed = try await userAccessToken(refreshToken: token.refreshToken, force: true)
            return TidalUserCatalogResolution(
                value: try await operation(refreshed.accessToken),
                refreshToken: refreshed.refreshToken
            )
        }
    }

    private func browseAccessToken(force: Bool) async throws -> String {
        if !force, let browseAccessToken, nowMs < browseTokenExpiresAtMs - 30_000 {
            return browseAccessToken
        }
        let url = try makeURL(base: configuration.authBaseURL, path: "/v1/oauth2/token")
        let data = try await request(
            url,
            method: "POST",
            headers: ["Authorization": basicAuthorization(configuration.browseClientID, configuration.browseClientSecret)],
            body: formBody([
                "grant_type": "client_credentials",
                "scope": configuration.browseScope,
            ])
        )
        let value = try object(from: data)
        let token = string(value, key: "access_token")
        guard !token.isEmpty else { throw TidalClientError.missingValue("catalog access token") }
        browseAccessToken = token
        browseTokenExpiresAtMs = nowMs + int64(value, key: "expires_in", fallback: 3_600) * 1_000
        return token
    }

    private func searchCatalogPage(
        query: String,
        countryCode: String,
        token: String
    ) async throws -> TidalCatalogSearchPage {
        let country = countryCode.uppercased().range(of: "^[A-Z]{2}$", options: .regularExpression) != nil
            ? countryCode.uppercased() : configuration.countryCode
        let searchURL = try makeURL(
            base: configuration.apiBaseURL,
            path: "searchResults",
            query: [
                URLQueryItem(name: "filter[query]", value: query),
                URLQueryItem(name: "page[limit]", value: "1"),
                URLQueryItem(name: "countryCode", value: country),
            ]
        )
        let searchValue = try object(from: await request(searchURL, headers: [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.api+json",
        ]))
        guard let data = searchValue["data"] as? [[String: Any]],
              let searchID = data.first?["id"] as? String,
              !searchID.isEmpty else {
            throw TidalClientError.missingValue("search resource")
        }

        let tracksURL = try makeURL(
            base: configuration.apiBaseURL,
            path: "searchResults/\(searchID)/relationships/tracks",
            query: [
                URLQueryItem(name: "include", value: "tracks.albums,tracks.artists,tracks.albums.coverArt"),
                URLQueryItem(name: "collapseBy", value: "FINGERPRINT"),
                URLQueryItem(name: "page[limit]", value: "20"),
                URLQueryItem(name: "countryCode", value: country),
            ]
        )
        let albumsURL = try makeURL(
            base: configuration.apiBaseURL,
            path: "searchResults/\(searchID)/relationships/albums",
            query: [
                URLQueryItem(name: "include", value: "albums,albums.coverArt,albums.artists"),
                URLQueryItem(name: "page[limit]", value: "20"),
                URLQueryItem(name: "countryCode", value: country),
            ]
        )
        let artistsURL = try makeURL(
            base: configuration.apiBaseURL,
            path: "searchResults/\(searchID)/relationships/artists",
            query: [
                URLQueryItem(name: "include", value: "artists,artists.profileArt"),
                URLQueryItem(name: "page[limit]", value: "20"),
                URLQueryItem(name: "countryCode", value: country),
            ]
        )
        let headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.api+json",
        ]
        async let tracksData = optionalRequest(tracksURL, headers: headers)
        async let albumsData = optionalRequest(albumsURL, headers: headers)
        async let artistsData = optionalRequest(artistsURL, headers: headers)
        let responses = await (tracksData, albumsData, artistsData)
        guard responses.0 != nil || responses.1 != nil || responses.2 != nil else {
            throw TidalClientError.invalidResponse("TIDAL search did not return any catalog section.")
        }
        let tracksDocument = responses.0.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"data\":[]}"
        let albums = responses.1.flatMap { try? albumSummaries(from: $0) } ?? []
        let artists = responses.2.flatMap { try? artistSummaries(from: $0) } ?? []
        return TidalCatalogSearchPage(
            tracksDocument: tracksDocument,
            albums: albums,
            artists: artists
        )
    }

    private func fetchAlbumPage(albumID: String, countryCode: String, token: String) async throws -> TidalAlbumPage {
        let country = countryCode.uppercased().range(of: "^[A-Z]{2}$", options: .regularExpression) != nil
            ? countryCode.uppercased() : configuration.countryCode
        let encodedID = albumID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? albumID
        let headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.api+json",
        ]
        let albumURL = try makeURL(
            base: configuration.apiBaseURL,
            path: "albums/\(encodedID)",
            query: [
                URLQueryItem(name: "include", value: "artists,coverArt"),
                URLQueryItem(name: "countryCode", value: country),
            ]
        )
        let tracksURL = try makeURL(
            base: configuration.apiBaseURL,
            path: "albums/\(encodedID)/relationships/items",
            query: [
                URLQueryItem(name: "include", value: "items,items.albums,items.artists,items.albums.coverArt"),
                URLQueryItem(name: "page[limit]", value: "20"),
                URLQueryItem(name: "countryCode", value: country),
            ]
        )
        let albumValue = try object(from: await request(albumURL, headers: headers))
        let tracksData = try await request(tracksURL, headers: headers)
        guard let album = albumValue["data"] as? [String: Any],
              let returnedID = album["id"] as? String,
              let attributes = album["attributes"] as? [String: Any] else {
            throw TidalClientError.invalidResponse("TIDAL returned an incomplete album.")
        }

        let included = (albumValue["included"] as? [[String: Any]]) ?? []
        var resources = [String: [String: Any]]()
        for resource in included {
            guard let type = resource["type"] as? String,
                  let id = resource["id"] as? String else { continue }
            resources["\(type):\(id)"] = resource
        }
        let artistNames = relationshipIDs(album, name: "artists").compactMap { id in
            resources["artists:\(id)"]?["attributes"] as? [String: Any]
        }.map { string($0, key: "name") }.filter { !$0.isEmpty }
        let coverURL = relationshipIDs(album, name: "coverArt").compactMap { id in
            resources["artworks:\(id)"]
        }.compactMap(artworkURL).first
            ?? imageLinkURL(attributes)
        let title = string(attributes, key: "title").ifBlank { "Unknown album" }
        let document = String(data: tracksData, encoding: .utf8)
            ?? "{\"data\":[]}"

        return TidalAlbumPage(
            id: returnedID,
            title: title,
            artistLabel: artistNames.isEmpty ? "Unknown artist" : artistNames.joined(separator: ", "),
            artworkURL: coverURL,
            tracksDocument: document
        )
    }

    private func fetchArtistPage(artistID: String, countryCode: String, token: String) async throws -> TidalArtistPage {
        let country = countryCode.uppercased().range(of: "^[A-Z]{2}$", options: .regularExpression) != nil
            ? countryCode.uppercased() : configuration.countryCode
        let encodedID = artistID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artistID
        let headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.api+json",
        ]
        let artistURL = try makeURL(
            base: configuration.apiBaseURL,
            path: "artists/\(encodedID)",
            query: [
                URLQueryItem(name: "include", value: "profileArt"),
                URLQueryItem(name: "countryCode", value: country),
            ]
        )
        let tracksURL = try makeURL(
            base: configuration.apiBaseURL,
            path: "artists/\(encodedID)/relationships/tracks",
            query: [
                URLQueryItem(name: "include", value: "tracks,tracks.albums,tracks.artists,tracks.albums.coverArt"),
                URLQueryItem(name: "collapseBy", value: "FINGERPRINT"),
                URLQueryItem(name: "page[limit]", value: "20"),
                URLQueryItem(name: "countryCode", value: country),
            ]
        )
        let albumsURL = try makeURL(
            base: configuration.apiBaseURL,
            path: "artists/\(encodedID)/relationships/albums",
            query: [
                URLQueryItem(name: "include", value: "albums,albums.coverArt,albums.artists"),
                URLQueryItem(name: "page[limit]", value: "20"),
                URLQueryItem(name: "countryCode", value: country),
            ]
        )
        let artistValue = try object(from: await request(artistURL, headers: headers))
        let tracksData = try await request(tracksURL, headers: headers)
        let albums: [TidalAlbumSummary]
        do {
            albums = try albumSummaries(from: await request(albumsURL, headers: headers))
        } catch {
            albums = []
        }
        guard let artist = artistValue["data"] as? [String: Any],
              let returnedID = artist["id"] as? String,
              let attributes = artist["attributes"] as? [String: Any] else {
            throw TidalClientError.invalidResponse("TIDAL returned an incomplete artist.")
        }

        let included = (artistValue["included"] as? [[String: Any]]) ?? []
        var resources = [String: [String: Any]]()
        for resource in included {
            guard let type = resource["type"] as? String,
                  let id = resource["id"] as? String else { continue }
            resources["\(type):\(id)"] = resource
        }
        let artwork = relationshipIDs(artist, name: "profileArt").compactMap { id in
            resources["artworks:\(id)"]
        }.compactMap(artworkURL).first ?? imageLinkURL(attributes)
        let document = String(data: tracksData, encoding: .utf8) ?? "{\"data\":[]}"
        return TidalArtistPage(
            id: returnedID,
            name: string(attributes, key: "name").ifBlank { "Unknown artist" },
            artworkURL: artwork,
            tracksDocument: document,
            albums: albums
        )
    }

    private func fetchLyrics(
        trackID: String,
        countryCode: String,
        token: String
    ) async throws -> TidalLyricsDocument? {
        let country = countryCode.uppercased().range(of: "^[A-Z]{2}$", options: .regularExpression) != nil
            ? countryCode.uppercased() : configuration.countryCode
        let encodedID = trackID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trackID
        let url = try makeURL(
            base: configuration.apiBaseURL,
            path: "tracks/\(encodedID)/relationships/lyrics",
            query: [
                URLQueryItem(name: "include", value: "lyrics"),
                URLQueryItem(name: "countryCode", value: country),
            ]
        )
        let document = try object(from: await request(url, headers: [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.api+json",
        ]))
        let primaryObject = document["data"] as? [String: Any]
        let primary = (document["data"] as? [[String: Any]]) ?? primaryObject.map { [$0] } ?? []
        let included = document["included"] as? [[String: Any]] ?? []
        guard let resource = (primary + included).first(where: { ($0["type"] as? String) == "lyrics" }),
              let attributes = resource["attributes"] as? [String: Any] else { return nil }
        let syncedText = firstNonblankString(
            attributes,
            keys: ["subtitles", "syncLyrics", "lrc", "lrcText"]
        )
        let plainText = firstNonblankString(
            attributes,
            keys: ["text", "lyrics", "body", "content"]
        )
        let syncedLines = syncedText.map(parseSyncedLyrics) ?? []
        let lines = syncedLines.isEmpty ? plainLyricsLines(plainText) : syncedLines
        guard !lines.isEmpty else { return nil }
        return TidalLyricsDocument(sourceLabel: "TIDAL", synced: !syncedLines.isEmpty, lines: lines)
    }

    private func firstNonblankString(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func parseSyncedLyrics(_ value: String) -> [TidalLyricLine] {
        let pattern = #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        var parsed = [(UInt64, String)]()
        for rawLine in value.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = expression.matches(in: rawLine, range: range)
            guard !matches.isEmpty else { continue }
            let text = expression.stringByReplacingMatches(in: rawLine, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: rawLine),
                      let secondRange = Range(match.range(at: 2), in: rawLine),
                      let minutes = UInt64(rawLine[minuteRange]),
                      let seconds = UInt64(rawLine[secondRange]),
                      seconds < 60 else { continue }
                var milliseconds: UInt64 = 0
                if let fractionRange = Range(match.range(at: 3), in: rawLine),
                   let fraction = UInt64(rawLine[fractionRange]) {
                    switch rawLine[fractionRange].count {
                    case 1: milliseconds = fraction * 100
                    case 2: milliseconds = fraction * 10
                    default: milliseconds = fraction
                    }
                }
                parsed.append(((minutes * 60 + seconds) * 1_000 + milliseconds, text))
            }
        }
        return parsed.sorted { $0.0 < $1.0 }.enumerated().map { index, item in
            TidalLyricLine(id: index, startMs: item.0, text: item.1)
        }
    }

    private func plainLyricsLines(_ value: String?) -> [TidalLyricLine] {
        guard let value else { return [] }
        return value.components(separatedBy: .newlines).enumerated().map { index, text in
            TidalLyricLine(id: index, startMs: nil, text: text.trimmingCharacters(in: .whitespaces))
        }
    }

    private func fetchRecommendations(
        countryCode: String,
        accessToken: String
    ) async throws -> TidalRecommendationPage {
        let country = countryCode.uppercased().range(of: "^[A-Z]{2}$", options: .regularExpression) != nil
            ? countryCode.uppercased() : configuration.countryCode
        let headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/vnd.api+json",
        ]
        func relationshipURL(_ relationship: String) throws -> URL {
            try makeURL(
                base: configuration.apiBaseURL,
                path: "userRecommendations/me/relationships/\(relationship)",
                query: [
                    URLQueryItem(name: "include", value: relationship),
                    URLQueryItem(name: "locale", value: "en-US"),
                    URLQueryItem(name: "page[limit]", value: "20"),
                    URLQueryItem(name: "countryCode", value: country),
                ]
            )
        }
        let dailyURL = try relationshipURL("myMixes")
        let discoveryURL = try relationshipURL("discoveryMixes")
        let releasesURL = try relationshipURL("newArrivalMixes")
        async let dailyData = optionalRequest(dailyURL, headers: headers)
        async let discoveryData = optionalRequest(discoveryURL, headers: headers)
        async let releasesData = optionalRequest(releasesURL, headers: headers)
        let responses = await (dailyData, discoveryData, releasesData)
        guard responses.0 != nil || responses.1 != nil || responses.2 != nil else {
            throw TidalClientError.invalidResponse("TIDAL did not return personalized recommendations.")
        }
        let daily = responses.0.flatMap { try? playlistSummaries(from: $0) } ?? []
        let discovery = responses.1.flatMap { try? playlistSummaries(from: $0) } ?? []
        let releases = responses.2.flatMap { try? playlistSummaries(from: $0) } ?? []
        async let hydratedDaily = hydratePlaylists(daily, countryCode: country, headers: headers)
        async let hydratedDiscovery = hydratePlaylists(discovery, countryCode: country, headers: headers)
        async let hydratedReleases = hydratePlaylists(releases, countryCode: country, headers: headers)
        let hydrated = await (hydratedDaily, hydratedDiscovery, hydratedReleases)
        return TidalRecommendationPage(
            dailyMixes: hydrated.0,
            discoveryMixes: hydrated.1,
            newReleaseMixes: hydrated.2
        )
    }

    private func hydratePlaylists(
        _ playlists: [TidalPlaylistSummary],
        countryCode: String,
        headers: [String: String]
    ) async -> [TidalPlaylistSummary] {
        guard !playlists.isEmpty else { return [] }
        do {
            let url = try makeURL(
                base: configuration.apiBaseURL,
                path: "playlists",
                query: [
                    URLQueryItem(name: "filter[id]", value: playlists.prefix(20).map(\.id).joined(separator: ",")),
                    URLQueryItem(name: "include", value: "coverArt"),
                    URLQueryItem(name: "countryCode", value: countryCode),
                ]
            )
            let hydrated = try playlistSummaries(from: await request(url, headers: headers))
            let byID = Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, $0) })
            return playlists.map { original in
                guard let replacement = byID[original.id] else { return original }
                return TidalPlaylistSummary(
                    id: original.id,
                    title: replacement.title,
                    description: replacement.description ?? original.description,
                    artworkURL: replacement.artworkURL ?? original.artworkURL
                )
            }
        } catch {
            return playlists
        }
    }

    private func fetchPlaylistPage(
        playlistID: String,
        countryCode: String,
        accessToken: String
    ) async throws -> TidalPlaylistPage {
        let country = countryCode.uppercased().range(of: "^[A-Z]{2}$", options: .regularExpression) != nil
            ? countryCode.uppercased() : configuration.countryCode
        let encodedID = playlistID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? playlistID
        let headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/vnd.api+json",
        ]
        let metadataURL = try makeURL(
            base: configuration.apiBaseURL,
            path: "playlists/\(encodedID)",
            query: [
                URLQueryItem(name: "include", value: "coverArt"),
                URLQueryItem(name: "countryCode", value: country),
            ]
        )
        let tracksURL = try makeURL(
            base: configuration.apiBaseURL,
            path: "playlists/\(encodedID)/relationships/items",
            query: [
                URLQueryItem(name: "include", value: "items,items.albums,items.artists,items.albums.coverArt"),
                URLQueryItem(name: "page[limit]", value: "50"),
                URLQueryItem(name: "countryCode", value: country),
            ]
        )
        async let metadataData = request(metadataURL, headers: headers)
        async let tracksData = request(tracksURL, headers: headers)
        let (metadata, tracks) = try await (metadataData, tracksData)
        let summaries = try playlistSummaries(from: metadata)
        guard let playlist = summaries.first else {
            throw TidalClientError.invalidResponse("TIDAL returned an incomplete playlist.")
        }
        return TidalPlaylistPage(
            id: playlist.id,
            title: playlist.title,
            description: playlist.description,
            artworkURL: playlist.artworkURL,
            tracksDocument: String(data: tracks, encoding: .utf8) ?? "{\"data\":[]}"
        )
    }

    private func albumSummaries(from data: Data) throws -> [TidalAlbumSummary] {
        let document = try object(from: data)
        let primary = document["data"] as? [[String: Any]] ?? []
        let included = document["included"] as? [[String: Any]] ?? []
        var resources = [String: [String: Any]]()
        for resource in primary + included {
            guard let type = resource["type"] as? String,
                  let id = resource["id"] as? String else { continue }
            resources["\(type):\(id)"] = resource
        }

        var seen = Set<String>()
        return primary.compactMap { reference in
            guard let id = reference["id"] as? String,
                  seen.insert(id).inserted else { return nil }
            let album = (reference["attributes"] as? [String: Any]) == nil
                ? resources["albums:\(id)"]
                : reference
            guard let album,
                  let attributes = album["attributes"] as? [String: Any] else { return nil }
            let artistNames = relationshipIDs(album, name: "artists").compactMap { artistID in
                resources["artists:\(artistID)"]?["attributes"] as? [String: Any]
            }.map { string($0, key: "name") }.filter { !$0.isEmpty }
            let cover = relationshipIDs(album, name: "coverArt").compactMap { artworkID in
                resources["artworks:\(artworkID)"]
            }.compactMap(artworkURL).first ?? imageLinkURL(attributes)
            return TidalAlbumSummary(
                id: id,
                title: string(attributes, key: "title").ifBlank { "Unknown album" },
                artistLabel: artistNames.isEmpty ? "Unknown artist" : artistNames.joined(separator: ", "),
                artworkURL: cover
            )
        }
    }

    private func artistSummaries(from data: Data) throws -> [TidalArtistSummary] {
        let document = try object(from: data)
        let primary = document["data"] as? [[String: Any]] ?? []
        let included = document["included"] as? [[String: Any]] ?? []
        var resources = [String: [String: Any]]()
        for resource in primary + included {
            guard let type = resource["type"] as? String,
                  let id = resource["id"] as? String else { continue }
            resources["\(type):\(id)"] = resource
        }

        var seen = Set<String>()
        return primary.compactMap { reference in
            guard let id = reference["id"] as? String,
                  seen.insert(id).inserted else { return nil }
            let artist = (reference["attributes"] as? [String: Any]) == nil
                ? resources["artists:\(id)"]
                : reference
            guard let artist,
                  let attributes = artist["attributes"] as? [String: Any] else { return nil }
            let profileArt = relationshipIDs(artist, name: "profileArt").compactMap { artworkID in
                resources["artworks:\(artworkID)"]
            }.compactMap(artworkURL).first ?? imageLinkURL(attributes)
            return TidalArtistSummary(
                id: id,
                name: string(attributes, key: "name").ifBlank { "Unknown artist" },
                artworkURL: profileArt
            )
        }
    }

    private func playlistSummaries(from data: Data) throws -> [TidalPlaylistSummary] {
        let document = try object(from: data)
        let primaryObject = document["data"] as? [String: Any]
        let primary = (document["data"] as? [[String: Any]]) ?? primaryObject.map { [$0] } ?? []
        let included = document["included"] as? [[String: Any]] ?? []
        var resources = [String: [String: Any]]()
        for resource in primary + included {
            guard let type = resource["type"] as? String,
                  let id = resource["id"] as? String else { continue }
            resources["\(type):\(id)"] = resource
        }
        var seen = Set<String>()
        return primary.compactMap { reference in
            guard let id = reference["id"] as? String,
                  seen.insert(id).inserted else { return nil }
            let playlist = (reference["attributes"] as? [String: Any]) == nil
                ? resources["playlists:\(id)"]
                : reference
            guard let playlist,
                  let attributes = playlist["attributes"] as? [String: Any] else { return nil }
            let cover = relationshipIDs(playlist, name: "coverArt").compactMap { artworkID in
                resources["artworks:\(artworkID)"]
            }.compactMap(artworkURL).first ?? imageLinkURL(attributes)
            let description = string(attributes, key: "description").ifBlankOptional
            return TidalPlaylistSummary(
                id: id,
                title: string(attributes, key: "name").ifBlank {
                    string(attributes, key: "title").ifBlank { "TIDAL mix" }
                },
                description: description,
                artworkURL: cover
            )
        }
    }

    private func fetchPlaybackSource(
        trackID: String,
        countryCode: String,
        accessToken: String
    ) async throws -> TidalPlaybackSource {
        let country = countryCode.uppercased().range(of: "^[A-Z]{2}$", options: .regularExpression) != nil
            ? countryCode.uppercased() : configuration.countryCode
        let encodedID = trackID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trackID
        let url = try makeURL(
            base: configuration.apiBaseURL,
            path: "trackManifests/\(encodedID)",
            query: [
                URLQueryItem(name: "manifestType", value: "HLS"),
                URLQueryItem(name: "formats", value: "FLAC_HIRES"),
                URLQueryItem(name: "formats", value: "FLAC"),
                URLQueryItem(name: "formats", value: "AACLC"),
                URLQueryItem(name: "uriScheme", value: "HTTPS"),
                URLQueryItem(name: "usage", value: "PLAYBACK"),
                URLQueryItem(name: "adaptive", value: "false"),
                URLQueryItem(name: "countryCode", value: country),
            ]
        )
        let value = try object(from: await request(url, headers: [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/vnd.api+json",
        ]))
        guard let data = value["data"] as? [String: Any],
              let attributes = data["attributes"] as? [String: Any] else {
            throw TidalClientError.invalidResponse("TIDAL returned no playback attributes.")
        }
        let uri = string(attributes, key: "uri")
        guard uri.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil else {
            throw TidalClientError.invalidResponse("TIDAL returned an unsupported playback URL.")
        }
        let formats = (attributes["formats"] as? [Any])?.compactMap { $0 as? String } ?? []
        return TidalPlaybackSource(
            uri: uri,
            manifestType: string(attributes, key: "manifestType").ifBlank { "HLS" },
            formats: formats,
            presentation: string(attributes, key: "trackPresentation").ifBlankOptional,
            previewReason: string(attributes, key: "previewReason").ifBlankOptional
        )
    }

    private func userAccessToken(refreshToken: String, force: Bool) async throws -> TidalUserToken {
        if !force, let userToken, userToken.refreshToken == refreshToken, nowMs < userToken.expiresAtMs - 30_000 {
            return userToken
        }
        let token = try await refreshUserToken(refreshToken)
        userToken = token
        return token
    }

    private func entitledResolution(
        source: TidalPlaybackSource,
        refreshToken: String
    ) throws -> TidalPlaybackResolution {
        if source.presentation == "PREVIEW" {
            let reason = source.previewReason ?? "unknown reason"
            throw TidalClientError.invalidResponse("TIDAL only returned a preview (\(reason)).")
        }
        return TidalPlaybackResolution(source: source, refreshToken: refreshToken)
    }

    private func relationshipIDs(_ resource: [String: Any], name: String) -> [String] {
        guard let relationships = resource["relationships"] as? [String: Any],
              let relationship = relationships[name] as? [String: Any],
              let data = relationship["data"] as? [[String: Any]] else {
            return []
        }
        return data.compactMap { $0["id"] as? String }
    }

    private func artworkURL(_ resource: [String: Any]) -> String? {
        guard let attributes = resource["attributes"] as? [String: Any],
              let files = attributes["files"] as? [[String: Any]],
              let href = files.first?["href"] as? String,
              !href.isEmpty else {
            return nil
        }
        return href
    }

    private func imageLinkURL(_ attributes: [String: Any]) -> String? {
        guard let links = attributes["imageLinks"] as? [[String: Any]],
              let href = links.first?["href"] as? String,
              !href.isEmpty else {
            return nil
        }
        return href
    }

    private func request(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> Data {
        let (_, data) = try await perform(url, method: method, headers: headers, body: body, requireSuccess: true)
        return data
    }

    private func optionalRequest(_ url: URL, headers: [String: String]) async -> Data? {
        try? await request(url, headers: headers)
    }

    private func perform(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        requireSuccess: Bool = false
    ) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("colorful/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw TidalClientError.invalidResponse("TIDAL returned no HTTP response.")
        }
        if requireSuccess, !(200..<300).contains(response.statusCode) {
            let value = try? object(from: data)
            let message = string(value ?? [:], key: "error_description")
                .ifBlank { string(value ?? [:], key: "error") }
                .ifBlank { String(data: data, encoding: .utf8) ?? "request failed" }
            throw TidalClientError.http(status: response.statusCode, message: message)
        }
        return (response.statusCode, data)
    }

    private func makeURL(
        base: String,
        path: String,
        query: [URLQueryItem] = []
    ) throws -> URL {
        guard var components = URLComponents(string: base + path) else {
            throw TidalClientError.invalidResponse("Invalid TIDAL URL.")
        }
        components.queryItems = query
        guard let url = components.url else {
            throw TidalClientError.invalidResponse("Invalid TIDAL query.")
        }
        return url
    }

    private func object(from data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TidalClientError.invalidResponse("TIDAL returned invalid JSON.")
        }
        return value
    }

    private func formBody(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private func basicAuthorization(_ clientID: String, _ clientSecret: String) -> String {
        let value = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        return "Basic \(value)"
    }

    private func string(_ object: [String: Any], key: String) -> String {
        if let value = object[key] as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = object[key] as? NSNumber { return value.stringValue }
        return ""
    }

    private func int64(_ object: [String: Any], key: String, fallback: Int64) -> Int64 {
        (object[key] as? NSNumber)?.int64Value ?? fallback
    }

    private var nowMs: Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private func normalizeVerificationURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil {
            return trimmed
        }
        return "https://\(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    }
}

@MainActor
final class TidalAccountStore: ObservableObject {
    struct PendingAuthorization: Codable, Sendable {
        let authorization: TidalDeviceAuthorization
    }

    @Published private(set) var isLinked: Bool
    @Published private(set) var countryCode: String
    @Published private(set) var email: String?
    @Published private(set) var pendingAuthorization: PendingAuthorization?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?

    let client: TidalClient
    private let keychain = ColorfulKeychain()
    private let defaults = UserDefaults.standard
    private var authorizationTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var accountRefreshTask: Task<Void, Never>?
    private var pollingID: UUID?
    private var isAppActive = true

    init(client: TidalClient = TidalClient()) {
        self.client = client
        isLinked = (try? keychain.readString(forKey: Self.refreshTokenKey)) != nil
        countryCode = defaults.string(forKey: Self.countryCodeKey) ?? TidalConfiguration.bundled.countryCode
        email = defaults.string(forKey: Self.emailKey)
        pendingAuthorization = Self.readPending(from: defaults)
    }

    func appBecameActive() {
        isAppActive = true
        resumeIfNeeded()
        refreshLinkedAccountIfNeeded()
    }

    func appBecameInactive() {
        isAppActive = false
        pollingTask?.cancel()
        pollingTask = nil
        pollingID = nil
    }

    func resumeIfNeeded() {
        guard !isLinked, let pendingAuthorization else { return }
        guard pendingAuthorization.authorization.expiresAtMs > nowMs else {
            clearPendingAuthorization()
            isBusy = false
            message = "The TIDAL authorization link expired. Start again to reconnect."
            return
        }
        startPollingIfNeeded()
    }

    func startLink() {
        authorizationTask?.cancel()
        pollingTask?.cancel()
        pollingTask = nil
        pollingID = nil
        clearPendingAuthorization()
        message = "Starting TIDAL device authorization…"
        isBusy = true
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let authorization = try await client.startDeviceAuthorization()
                pendingAuthorization = PendingAuthorization(authorization: authorization)
                savePendingAuthorization()
                message = "Approve this device in TIDAL, then return here."
                authorizationTask = nil
                startPollingIfNeeded()
            } catch is CancellationError {
                if isAppActive {
                    isBusy = false
                }
            } catch {
                authorizationTask = nil
                isBusy = false
                message = error.localizedDescription
            }
        }
    }

    func unlink() {
        authorizationTask?.cancel()
        pollingTask?.cancel()
        accountRefreshTask?.cancel()
        authorizationTask = nil
        pollingTask = nil
        accountRefreshTask = nil
        pollingID = nil
        Task { await client.clearUserSession() }
        try? keychain.deleteValue(forKey: Self.refreshTokenKey)
        clearPendingAuthorization()
        isLinked = false
        isBusy = false
        email = nil
        countryCode = TidalConfiguration.bundled.countryCode
        defaults.removeObject(forKey: Self.countryCodeKey)
        defaults.removeObject(forKey: Self.emailKey)
        message = "TIDAL disconnected from this device."
    }

    func searchCatalog(query: String, core: ColorfulCoreBridge) async throws -> TidalCatalogSearchResults {
        let page = try await client.searchCatalog(query: query, countryCode: countryCode)
        let tracks = try await core.mapTidalTracks(documentJSON: page.tracksDocument)
        return TidalCatalogSearchResults(
            tracks: tracks,
            albums: page.albums,
            artists: page.artists
        )
    }

    func loadAlbum(albumID: String, core: ColorfulCoreBridge) async throws -> TidalAlbumCollection {
        let page = try await client.albumPage(albumID: albumID, countryCode: countryCode)
        let albumMediaID = CoreMediaID(provider: "tidal", providerID: page.id)
        let albumArtwork = page.artworkURL.map {
            CoreArtwork(url: $0, localKey: nil, width: nil, height: nil)
        }
        let mappedTracks = try await core.mapTidalTracks(documentJSON: page.tracksDocument)
        let tracks = mappedTracks.map { track in
            CoreTrack(
                id: track.id,
                title: track.title,
                version: track.version,
                artists: track.artists,
                albumID: track.albumID ?? albumMediaID,
                albumTitle: track.albumTitle ?? page.title,
                artwork: track.artwork ?? albumArtwork,
                durationMs: track.durationMs,
                isrc: track.isrc,
                explicit: track.explicit
            )
        }
        return TidalAlbumCollection(
            id: page.id,
            title: page.title,
            artistLabel: page.artistLabel,
            artworkURL: page.artworkURL,
            tracks: tracks
        )
    }

    func loadArtist(artistID: String, core: ColorfulCoreBridge) async throws -> TidalArtistCollection {
        let page = try await client.artistPage(artistID: artistID, countryCode: countryCode)
        let tracks = try await core.mapTidalTracks(documentJSON: page.tracksDocument)
        return TidalArtistCollection(
            id: page.id,
            name: page.name,
            artworkURL: page.artworkURL,
            topTracks: tracks,
            albums: page.albums
        )
    }

    func loadRecommendations() async throws -> TidalRecommendationPage {
        guard let refreshToken = try? keychain.readString(forKey: Self.refreshTokenKey) else {
            throw TidalClientError.invalidResponse("Connect TIDAL to load recommendations.")
        }
        let resolution = try await client.recommendations(
            countryCode: countryCode,
            refreshToken: refreshToken
        )
        if resolution.refreshToken != refreshToken {
            try keychain.writeString(resolution.refreshToken, forKey: Self.refreshTokenKey)
        }
        return resolution.value
    }

    func loadPlaylist(playlistID: String, core: ColorfulCoreBridge) async throws -> TidalPlaylistCollection {
        guard let refreshToken = try? keychain.readString(forKey: Self.refreshTokenKey) else {
            throw TidalClientError.invalidResponse("Connect TIDAL to open this playlist.")
        }
        let resolution = try await client.playlistPage(
            playlistID: playlistID,
            countryCode: countryCode,
            refreshToken: refreshToken
        )
        if resolution.refreshToken != refreshToken {
            try keychain.writeString(resolution.refreshToken, forKey: Self.refreshTokenKey)
        }
        let page = resolution.value
        let playlistArtwork = page.artworkURL.map {
            CoreArtwork(url: $0, localKey: nil, width: nil, height: nil)
        }
        let mappedTracks = try await core.mapTidalTracks(documentJSON: page.tracksDocument)
        let tracks = mappedTracks.map { track in
            CoreTrack(
                id: track.id,
                title: track.title,
                version: track.version,
                artists: track.artists,
                albumID: track.albumID,
                albumTitle: track.albumTitle,
                artwork: track.artwork ?? playlistArtwork,
                durationMs: track.durationMs,
                isrc: track.isrc,
                explicit: track.explicit
            )
        }
        return TidalPlaylistCollection(
            id: page.id,
            title: page.title,
            description: page.description,
            artworkURL: page.artworkURL,
            tracks: tracks
        )
    }

    func loadLyrics(for track: CoreTrack) async throws -> TidalLyricsDocument? {
        guard track.id.provider.lowercased() == "tidal" else { return nil }
        guard let refreshToken = try? keychain.readString(forKey: Self.refreshTokenKey) else {
            throw TidalClientError.invalidResponse("Connect TIDAL to load lyrics.")
        }
        var nativeError: Error?
        do {
            let resolution = try await client.lyrics(
                trackID: track.id.providerID,
                countryCode: countryCode,
                refreshToken: refreshToken
            )
            if resolution.refreshToken != refreshToken {
                try keychain.writeString(resolution.refreshToken, forKey: Self.refreshTokenKey)
            }
            if let lyrics = resolution.value {
                return lyrics
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            nativeError = error
        }
        if let fallback = await client.lrclibLyrics(for: track) {
            return fallback
        }
        if let nativeError { throw nativeError }
        return nil
    }

    func playbackSource(for track: CoreTrack) async throws -> TidalPlaybackResolution {
        guard track.id.provider.lowercased() == "tidal" else {
            throw TidalClientError.invalidResponse("This iOS playback slice only supports TIDAL tracks.")
        }
        guard let refreshToken = try? keychain.readString(forKey: Self.refreshTokenKey) else {
            throw TidalClientError.invalidResponse("Connect TIDAL before starting playback.")
        }
        let resolution = try await client.playbackSource(
            trackID: track.id.providerID,
            countryCode: countryCode,
            refreshToken: refreshToken
        )
        if resolution.refreshToken != refreshToken {
            try keychain.writeString(resolution.refreshToken, forKey: Self.refreshTokenKey)
        }
        return resolution
    }

    private func startPollingIfNeeded() {
        guard isAppActive, !isLinked, pollingTask == nil,
              let pendingAuthorization else { return }
        guard pendingAuthorization.authorization.expiresAtMs > nowMs else {
            clearPendingAuthorization()
            isBusy = false
            message = "The TIDAL authorization link expired. Start again to reconnect."
            return
        }

        isBusy = true
        let id = UUID()
        pollingID = id
        let authorization = pendingAuthorization.authorization
        pollingTask = Task { [weak self] in
            await self?.completeDeviceAuthorization(authorization, pollingID: id)
        }
    }

    private func completeDeviceAuthorization(
        _ authorization: TidalDeviceAuthorization,
        pollingID: UUID
    ) async {
        do {
            let token = try await client.pollDeviceAuthorization(authorization)
            try keychain.writeString(token.refreshToken, forKey: Self.refreshTokenKey)
            let account = try? await client.accountInfo(accessToken: token.accessToken)
            countryCode = account?.countryCode ?? countryCode
            email = account?.email ?? email
            defaults.set(countryCode, forKey: Self.countryCodeKey)
            if let email {
                defaults.set(email, forKey: Self.emailKey)
            }
            clearPendingAuthorization()
            isLinked = true
            isBusy = false
            message = "TIDAL linked. The refresh token is stored in iOS Keychain."
            finishPolling(pollingID)
        } catch is CancellationError {
            if isAppActive {
                isBusy = false
            }
            finishPolling(pollingID)
        } catch {
            finishPolling(pollingID)
            if isAppActive {
                isBusy = false
                message = error.localizedDescription
            }
        }
    }

    private func finishPolling(_ id: UUID) {
        guard pollingID == id else { return }
        pollingID = nil
        pollingTask = nil
    }

    private func refreshLinkedAccountIfNeeded() {
        guard isLinked, email == nil, accountRefreshTask == nil else { return }
        accountRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { accountRefreshTask = nil }
            guard let refreshToken = try? keychain.readString(forKey: Self.refreshTokenKey) else { return }
            do {
                let token = try await client.refreshUserToken(refreshToken)
                try keychain.writeString(token.refreshToken, forKey: Self.refreshTokenKey)
                let account = try await client.accountInfo(accessToken: token.accessToken)
                countryCode = account.countryCode
                email = account.email
                defaults.set(countryCode, forKey: Self.countryCodeKey)
                if let email {
                    defaults.set(email, forKey: Self.emailKey)
                }
            } catch {
                // Account metadata is supplementary; keep the linked state if it cannot refresh.
            }
        }
    }

    private func savePendingAuthorization() {
        guard let pendingAuthorization,
              let data = try? JSONEncoder().encode(pendingAuthorization) else { return }
        defaults.set(data, forKey: Self.pendingAuthorizationKey)
    }

    private func clearPendingAuthorization() {
        pendingAuthorization = nil
        defaults.removeObject(forKey: Self.pendingAuthorizationKey)
    }

    private static func readPending(from defaults: UserDefaults) -> PendingAuthorization? {
        guard let data = defaults.data(forKey: pendingAuthorizationKey),
              let value = try? JSONDecoder().decode(PendingAuthorization.self, from: data) else {
            return nil
        }
        return value
    }

    private var nowMs: Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private static let refreshTokenKey = "tidal.refresh-token"
    private static let countryCodeKey = "tidal.country-code"
    private static let emailKey = "tidal.email"
    private static let pendingAuthorizationKey = "tidal.pending-authorization"
}

private extension String {
    func ifBlank(_ fallback: () -> String) -> String {
        isEmpty ? fallback() : self
    }

    var ifBlankOptional: String? {
        isEmpty ? nil : self
    }
}
