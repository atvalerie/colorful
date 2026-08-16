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

    var compactArtistLabel: String {
        let names = artists.map { $0.name }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return "Unknown artist" }
        guard names.count > 1 else { return names[0] }
        return "\(names[0]) + \(names.count - 1) more"
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

struct CoreQueueItem: Identifiable, Hashable, Sendable {
    let entry: CoreQueueEntry
    let track: CoreTrack

    var id: UInt64 { entry.id }
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
    let playlists: [CoreLocalPlaylist]
    let listenStats: CoreListenStats
}

struct CoreTopTrack: Codable, Identifiable, Hashable, Sendable {
    let track: CoreTrack
    let listenedMs: UInt64
    let playCount: UInt64

    var id: CoreMediaID { track.id }
}

struct CoreTopArtist: Codable, Identifiable, Hashable, Sendable {
    let id: CoreMediaID?
    let name: String
    let listenedMs: UInt64
    let playCount: UInt64

    var stableID: String {
        id.map { "\($0.provider):\($0.providerID)" } ?? "name:\(name)"
    }

    var accent: UInt32 {
        providerAccent(id?.provider)
    }
}

struct CoreTopAlbum: Codable, Identifiable, Hashable, Sendable {
    let id: CoreMediaID
    let title: String
    let artists: [CoreArtistCredit]
    let artwork: CoreArtwork?
    let listenedMs: UInt64
    let playCount: UInt64

    var artistLabel: String {
        let names = artists.map(\.name).filter { !$0.isEmpty }
        return names.isEmpty ? "Unknown artist" : names.joined(separator: ", ")
    }

    var accent: UInt32 {
        providerAccent(id.provider)
    }
}

private func providerAccent(_ provider: String?) -> UInt32 {
    switch provider?.lowercased() {
    case "tidal": return 0xFF5C9A
    case "soundcloud": return 0xFFC857
    case "youtube": return 0xA18CFF
    default: return 0x7DE2D1
    }
}

struct CoreProviderListenStats: Codable, Hashable, Sendable {
    let provider: String
    let listenedMs: UInt64
    let playCount: UInt64
}

struct CoreListenStats: Codable, Hashable, Sendable {
    let totalListenedMs: UInt64
    let playCount: UInt64
    let providerStats: [CoreProviderListenStats]
    let topTracks: [CoreTopTrack]
    let topArtists: [CoreTopArtist]
    let topAlbums: [CoreTopAlbum]
}

struct CoreLocalPlaylist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let createdAtMs: Int64
    let updatedAtMs: Int64
    let tracks: [CoreTrack]
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

struct CorePlayNextCommand: Encodable, Sendable {
    let command = "play_next"
    let track: CoreTrack
}

struct CoreAddToLibraryCommand: Encodable, Sendable {
    let command = "add_to_library"
    let track: CoreTrack
}

struct CoreRemoveFromLibraryCommand: Encodable, Sendable {
    let command = "remove_from_library"
    let id: CoreMediaID
}

struct CoreCreatePlaylistCommand: Encodable, Sendable {
    let command = "create_playlist"
    let name: String
    let tracks: [CoreTrack]
}

struct CorePlaylistCommand: Encodable, Sendable {
    let command: String
    let id: String
}

struct CoreRenamePlaylistCommand: Encodable, Sendable {
    let command = "rename_playlist"
    let id: String
    let name: String
}

struct CoreAddPlaylistTrackCommand: Encodable, Sendable {
    let command = "add_playlist_track"
    let id: String
    let track: CoreTrack
}

struct CorePlaylistItemCommand: Encodable, Sendable {
    let command: String
    let id: String
    let position: Int
}

struct CoreMovePlaylistItemCommand: Encodable, Sendable {
    let command = "move_playlist_item"
    let id: String
    let position: Int
    let target: Int
}

enum CoreRepeatMode: String, CaseIterable, Encodable, Sendable {
    case off
    case all
    case one

    var label: String {
        switch self {
        case .off: return "Repeat off"
        case .all: return "Repeat queue"
        case .one: return "Repeat track"
        }
    }

    var symbol: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

struct CoreQueueEntryCommand: Encodable, Sendable {
    let command: String
    let entryID: UInt64

    enum CodingKeys: String, CodingKey {
        case command
        case entryID = "entryId"
    }
}

struct CoreMoveQueueEntryCommand: Encodable, Sendable {
    let command = "move"
    let entryID: UInt64
    let targetIndex: Int

    enum CodingKeys: String, CodingKey {
        case command
        case entryID = "entryId"
        case targetIndex
    }
}

struct CoreSetRepeatCommand: Encodable, Sendable {
    let command = "set_repeat"
    let repeatMode: CoreRepeatMode

    enum CodingKeys: String, CodingKey {
        case command
        case repeatMode = "repeat"
    }
}

struct CoreSetShuffleCommand: Encodable, Sendable {
    let command = "set_shuffle"
    let enabled: Bool
    let seed: UInt64
}

struct CoreListenEvent: Encodable, Sendable {
    let eventID: String
    let deviceID: String
    let mediaID: CoreMediaID
    let startedAtMs: Int64
    let endedAtMs: Int64
    let listenedMs: UInt64
    let trackDurationMs: UInt64?

    enum CodingKeys: String, CodingKey {
        case eventID = "eventId"
        case deviceID = "deviceId"
        case mediaID = "mediaId"
        case startedAtMs
        case endedAtMs
        case listenedMs
        case trackDurationMs
    }
}

struct CoreRecordListenCommand: Encodable, Sendable {
    let command = "record_listen"
    let track: CoreTrack
    let event: CoreListenEvent
}
