import Foundation

struct ColorfulCoreResponse<Value: Decodable>: Decodable {
    let abiVersion: UInt32
    let ok: Bool
    let value: Value?
    let error: String?
}

struct CoreMediaID: Codable, Hashable, Sendable {
    let provider: String
    let providerID: String

    enum CodingKeys: String, CodingKey {
        case provider
        case providerID = "providerId"
    }
}

struct CoreArtistCredit: Codable, Hashable, Sendable {
    let id: CoreMediaID?
    let name: String
}

struct CoreArtwork: Codable, Hashable, Sendable {
    let url: String?
    let localKey: String?
    let width: UInt32?
    let height: UInt32?
}

struct CoreTrack: Codable, Identifiable, Hashable, Sendable {
    let id: CoreMediaID
    let title: String
    let version: String?
    let artists: [CoreArtistCredit]
    let albumID: CoreMediaID?
    let albumTitle: String?
    let artwork: CoreArtwork?
    let durationMs: UInt64?
    let isrc: String?
    let explicit: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case version
        case artists
        case albumID = "albumId"
        case albumTitle
        case artwork
        case durationMs
        case isrc
        case explicit
    }

    var artistLabel: String {
        let names = artists.map { $0.name }.filter { !$0.isEmpty }
        return names.isEmpty ? "Unknown artist" : names.joined(separator: ", ")
    }

    var albumLabel: String {
        albumTitle?.isEmpty == false ? albumTitle! : "Single"
    }

    var durationLabel: String {
        guard let durationMs = durationMs else { return "—" }
        let totalSeconds = Int(durationMs / 1_000)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    var accent: UInt32 {
        switch id.provider.lowercased() {
        case "tidal": return 0xFF5C9A
        case "soundcloud": return 0xFFC857
        case "youtube": return 0xA18CFF
        default: return 0x7DE2D1
        }
    }
}

struct CoreQueueEntry: Codable, Hashable, Sendable {
    let id: UInt64
    let mediaID: CoreMediaID

    enum CodingKeys: String, CodingKey {
        case id
        case mediaID = "mediaId"
    }
}

struct CoreQueueSnapshot: Codable, Sendable {
    let entries: [CoreQueueEntry]
    let playOrder: [UInt64]
    let current: UInt64?
    let shuffle: Bool
    let shuffleSeed: UInt64
    let nextEntryID: UInt64

    enum CodingKeys: String, CodingKey {
        case entries
        case playOrder
        case current
        case shuffle
        case shuffleSeed
        case nextEntryID = "nextEntryId"
    }
}

struct CorePlaybackState: Codable, Sendable {
    let current: CoreMediaID?
    let positionMs: UInt64
    let playing: Bool
    let repeatMode: String
    let shuffle: Bool

    enum CodingKeys: String, CodingKey {
        case current
        case positionMs
        case playing
        case repeatMode = "repeat"
        case shuffle
    }
}

struct ColorfulCoreSnapshot: Codable, Sendable {
    let abiVersion: UInt32
    let queue: CoreQueueSnapshot
    let queueTracks: [CoreTrack]
    let playback: CorePlaybackState
    let library: [CoreTrack]
}

struct CoreSimpleCommand: Encodable, Sendable {
    let command: String
}

struct CorePositionCommand: Encodable, Sendable {
    let command: String
    let positionMs: UInt64
}

struct CorePlayTracksCommand: Encodable, Sendable {
    let command = "play_tracks"
    let tracks: [CoreTrack]
}

struct CoreEnqueueCommand: Encodable, Sendable {
    let command = "enqueue"
    let track: CoreTrack
}
