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
    @Published private(set) var positionMs: UInt64 = 0
    @Published private(set) var coreSnapshot: ColorfulCoreSnapshot?
    @Published private(set) var coreError: String?

    let core: ColorfulCoreBridge

    private var commandTask: Task<Void, Never>?
    private var pendingPlayingState: Bool?

    var effectiveIsPlaying: Bool {
        pendingPlayingState ?? isPlaying
    }

    var libraryTracks: [CoreTrack] {
        coreSnapshot?.library ?? []
    }

    var playlists: [CoreLocalPlaylist] {
        coreSnapshot?.playlists ?? []
    }

    func isSaved(_ track: CoreTrack) -> Bool {
        libraryTracks.contains { $0.id == track.id }
    }

    var queueItems: [CoreQueueItem] {
        guard let snapshot = coreSnapshot,
              snapshot.queue.entries.count == snapshot.queueTracks.count else {
            return []
        }

        return zip(snapshot.queue.entries, snapshot.queueTracks).compactMap { entry, track in
            entry.mediaID == track.id ? CoreQueueItem(entry: entry, track: track) : nil
        }
    }

    var queueTracks: [CoreTrack] {
        queueItems.map(\.track)
    }

    var currentQueueEntryID: UInt64? {
        coreSnapshot?.queue.current
    }

    var repeatMode: CoreRepeatMode {
        CoreRepeatMode(rawValue: coreSnapshot?.playback.repeatMode ?? "") ?? .off
    }

    var isShuffleEnabled: Bool {
        coreSnapshot?.playback.shuffle ?? false
    }

    var canSkipNext: Bool {
        guard let snapshot = coreSnapshot,
              let current = snapshot.queue.current,
              let index = snapshot.queue.playOrder.firstIndex(of: current) else {
            return false
        }
        return index < snapshot.queue.playOrder.count - 1 || repeatMode != .off
    }

    var canSkipPrevious: Bool {
        if positionMs > 3_000 {
            return true
        }
        guard let snapshot = coreSnapshot,
              let current = snapshot.queue.current,
              let index = snapshot.queue.playOrder.firstIndex(of: current) else {
            return false
        }
        return index > 0 || repeatMode == .all
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

    func refreshFromCore(adoptPosition: Bool = false) async {
        do {
            let snapshot = try await core.loadSnapshot()
            let previousEntryID = coreSnapshot?.queue.current
            coreSnapshot = snapshot
            coreError = nil

            guard let snapshot else {
                currentTrack = nil
                isPlaying = false
                pendingPlayingState = nil
                return
            }

            currentTrack = currentTrack(in: snapshot)
            let coreIsPlaying = snapshot.playback.playing
            if let pendingPlayingState {
                if pendingPlayingState == coreIsPlaying {
                    self.pendingPlayingState = nil
                    isPlaying = coreIsPlaying
                }
            } else {
                isPlaying = coreIsPlaying
            }
            if adoptPosition || previousEntryID != snapshot.queue.current {
                positionMs = snapshot.playback.positionMs
            }
        } catch {
            coreError = error.localizedDescription
        }
    }

    func play(_ track: CoreTrack) {
        dispatch(CorePlayTracksCommand(tracks: [track]))
    }

    func playTracks(_ tracks: [CoreTrack]) {
        guard !tracks.isEmpty else { return }
        dispatch(CorePlayTracksCommand(tracks: tracks))
    }

    func enqueue(_ track: CoreTrack) {
        dispatch(CoreEnqueueCommand(track: track))
    }

    func playNext(_ track: CoreTrack) {
        dispatch(CorePlayNextCommand(track: track))
    }

    func toggleSaved(_ track: CoreTrack) {
        if isSaved(track) {
            dispatch(CoreRemoveFromLibraryCommand(id: track.id))
        } else {
            dispatch(CoreAddToLibraryCommand(track: track))
        }
    }

    func createPlaylist(named name: String, tracks: [CoreTrack] = []) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dispatch(CoreCreatePlaylistCommand(name: trimmed, tracks: tracks))
    }

    func renamePlaylist(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !trimmed.isEmpty else { return }
        dispatch(CoreRenamePlaylistCommand(id: id, name: trimmed))
    }

    func deletePlaylist(_ id: String) {
        guard !id.isEmpty else { return }
        dispatch(CorePlaylistCommand(command: "delete_playlist", id: id))
    }

    func add(_ track: CoreTrack, toPlaylist id: String) {
        guard !id.isEmpty else { return }
        dispatch(CoreAddPlaylistTrackCommand(id: id, track: track))
    }

    func removePlaylistItem(from id: String, at position: Int) {
        guard !id.isEmpty, position >= 0 else { return }
        dispatch(CorePlaylistItemCommand(command: "remove_playlist_item", id: id, position: position))
    }

    func movePlaylistItem(in id: String, from position: Int, to target: Int) {
        guard !id.isEmpty, position >= 0, target >= 0, position != target else { return }
        dispatch(CoreMovePlaylistItemCommand(id: id, position: position, target: target))
    }

    func selectQueueEntry(_ entryID: UInt64) {
        dispatch(CoreQueueEntryCommand(command: "select", entryID: entryID))
    }

    func removeQueueEntry(_ entryID: UInt64) {
        dispatch(CoreQueueEntryCommand(command: "remove", entryID: entryID))
    }

    func moveQueueEntry(_ entryID: UInt64, to targetIndex: Int) {
        dispatch(CoreMoveQueueEntryCommand(entryID: entryID, targetIndex: targetIndex))
    }

    func cycleRepeat() {
        let next: CoreRepeatMode
        switch repeatMode {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .off
        }
        dispatch(CoreSetRepeatCommand(repeatMode: next))
    }

    func toggleShuffle() {
        let seed = coreSnapshot?.queue.shuffleSeed ?? UInt64.random(in: 1...UInt64.max)
        dispatch(CoreSetShuffleCommand(enabled: !isShuffleEnabled, seed: seed))
    }

    func pause() {
        pendingPlayingState = false
        isPlaying = false
        dispatch(CoreSimpleCommand(command: "pause"))
    }

    func resume() {
        pendingPlayingState = true
        isPlaying = true
        dispatch(CoreSimpleCommand(command: "play"))
    }

    func skipNext() {
        dispatch(CoreSimpleCommand(command: "skip_next"))
    }

    func skipPrevious() {
        dispatch(CoreSimpleCommand(command: "skip_previous"))
    }

    func seek(to positionMs: UInt64) {
        dispatch(CorePositionCommand(command: "seek_to", positionMs: positionMs))
    }

    func updatePositionFromPlayer(_ positionMs: UInt64) {
        self.positionMs = positionMs
    }

    func checkpointPosition() {
        dispatch(CorePositionCommand(command: "checkpoint_position", positionMs: positionMs))
    }

    func togglePlayback() {
        guard currentTrack != nil else {
            if let firstTrack = homeTracks.first {
                play(firstTrack)
            }
            return
        }

        if effectiveIsPlaying {
            pause()
        } else {
            resume()
        }
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

        let previousTask = commandTask
        commandTask = Task { [weak self] in
            await previousTask?.value
            guard let self, !Task.isCancelled else { return }
            let succeeded = await self.core.dispatch(commandJSON: commandJSON)
            if !succeeded {
                self.pendingPlayingState = nil
            }
            await self.refreshFromCore()
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
