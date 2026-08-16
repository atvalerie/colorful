import SwiftUI

enum ColorfulTab: String, CaseIterable, Hashable {
    case home
    case library
    case offline
    case settings

    var title: String {
        rawValue.capitalized
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "books.vertical.fill"
        case .offline: return "arrow.down.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

@MainActor
final class PlaybackStore: ObservableObject {
    @Published var selectedTab: ColorfulTab = .home
    @Published var currentTrack: CoreTrack?
    @Published var isPlaying = false
    @Published private(set) var coreSnapshot: ColorfulCoreSnapshot?
    @Published private(set) var coreError: String?

    let core: ColorfulCoreBridge

    var libraryTracks: [CoreTrack] {
        coreSnapshot?.library ?? []
    }

    var queueTracks: [CoreTrack] {
        guard let snapshot = coreSnapshot,
              snapshot.queue.entries.count == snapshot.queueTracks.count else {
            return []
        }

        return zip(snapshot.queue.entries, snapshot.queueTracks).compactMap { pair in
            pair.0.mediaID == pair.1.id ? pair.1 : nil
        }
    }

    var homeTracks: [CoreTrack] {
        let queued = queueTracks
        if !queued.isEmpty {
            return Array(queued.prefix(8))
        }
        return Array(libraryTracks.prefix(8))
    }

    init() {
        core = ColorfulCoreBridge()
    }

    func refreshFromCore() async {
        do {
            let snapshot = try await core.loadSnapshot()
            coreSnapshot = snapshot
            coreError = nil

            guard let snapshot else {
                currentTrack = nil
                isPlaying = false
                return
            }

            currentTrack = currentTrack(in: snapshot)
            isPlaying = snapshot.playback.playing
        } catch {
            coreError = error.localizedDescription
        }
    }

    func play(_ track: CoreTrack) {
        dispatch(CorePlayTracksCommand(tracks: [track]))
    }

    func enqueue(_ track: CoreTrack) {
        dispatch(CoreEnqueueCommand(track: track))
    }

    func togglePlayback() {
        guard currentTrack != nil else {
            if let firstTrack = homeTracks.first {
                play(firstTrack)
            }
            return
        }

        dispatch(CoreSimpleCommand(command: isPlaying ? "pause" : "play"))
    }

    func stop() {
        dispatch(CoreSimpleCommand(command: "stop"))
    }

    private func dispatch<T: Encodable>(_ command: T) {
        guard let data = try? JSONEncoder().encode(command),
              let commandJSON = String(data: data, encoding: .utf8) else {
            coreError = "Could not encode the playback command."
            return
        }

        Task {
            _ = await core.dispatch(commandJSON: commandJSON)
            await refreshFromCore()
        }
    }

    private func currentTrack(in snapshot: ColorfulCoreSnapshot) -> CoreTrack? {
        if let currentEntryID = snapshot.queue.current,
           snapshot.queue.entries.count == snapshot.queueTracks.count,
           let index = snapshot.queue.entries.firstIndex(where: { $0.id == currentEntryID }),
           snapshot.queueTracks.indices.contains(index),
           snapshot.queue.entries[index].mediaID == snapshot.queueTracks[index].id {
            return snapshot.queueTracks[index]
        }

        guard let currentMediaID = snapshot.playback.current else {
            return nil
        }
        return snapshot.library.first(where: { $0.id == currentMediaID })
            ?? snapshot.queueTracks.first(where: { $0.id == currentMediaID })
    }
}
