import AVFoundation
import Combine
import MediaPlayer
import UIKit

@MainActor
final class IOSPlaybackService: NSObject, ObservableObject {
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBuffering = false

    private let store: PlaybackStore
    private let account: TidalAccountStore
    private let player = AVPlayer()
    private var cancellables = Set<AnyCancellable>()
    private var notificationTokens = [NSObjectProtocol]()
    private var timeObserver: Any?
    private var sourceTask: Task<Void, Never>?
    private var activeTrackID: CoreMediaID?
    private var activeQueueEntryID: UInt64?
    private var lastCheckpointMs: UInt64 = 0
    private var artworkTask: Task<Void, Never>?
    private var loadedArtworkURL: String?
    private var wasPlayingBeforeInterruption = false
    private var hasStarted = false
    private var listeningTrack: CoreTrack?
    private var listeningQueueEntryID: UInt64?
    private var listeningStartedAtMs: Int64 = 0
    private var accumulatedListenedMs: UInt64 = 0
    private var audibleClockStartedAt: TimeInterval?
    private let historyDeviceID: String

    init(store: PlaybackStore, account: TidalAccountStore) {
        self.store = store
        self.account = account
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: "identity.deviceId"), !stored.isEmpty {
            historyDeviceID = stored
        } else {
            let generated = UUID().uuidString.lowercased()
            defaults.set(generated, forKey: "identity.deviceId")
            historyDeviceID = generated
        }
        super.init()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        configureAudioSession(activate: false)
        installRemoteCommands()
        installNotifications()

        store.$currentTrack
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.synchronize()
                }
            }
            .store(in: &cancellables)
        store.$isPlaying
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applyPlaybackState()
                }
            }
            .store(in: &cancellables)
        player.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                guard let self else { return }
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
                self.reconcileAudibleClock(for: status)
                self.updateNowPlaying(for: self.store.currentTrack)
            }
            .store(in: &cancellables)

        synchronize()
    }

    func stop() {
        finishListeningSession()
        sourceTask?.cancel()
        sourceTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        loadedArtworkURL = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        hasStarted = false
    }

    func reconcileAfterActivation() async {
        await store.refreshFromCore(adoptPosition: player.currentItem == nil)
        configureAudioSession(activate: store.effectiveIsPlaying)
        synchronize()
    }

    func appBecameInactive() {
        checkpointAudibleTime()
        store.checkpointPosition()
        updateNowPlaying(for: store.currentTrack)
    }

    func togglePlayback() {
        guard store.currentTrack != nil else {
            store.togglePlayback()
            return
        }

        if store.effectiveIsPlaying {
            player.pause()
            store.pause()
        } else {
            if player.currentItem != nil {
                configureAudioSession(activate: true)
                player.play()
            }
            store.resume()
        }
        updateNowPlaying(for: store.currentTrack)
    }

    func skipNext() {
        if nextQueueEntryID() == store.currentQueueEntryID {
            player.seek(to: .zero)
            store.updatePositionFromPlayer(0)
        }
        store.skipNext()
    }

    func skipPrevious() {
        if store.positionMs > 3_000 {
            player.seek(to: .zero)
            store.updatePositionFromPlayer(0)
        }
        store.skipPrevious()
    }

    func seek(to positionMs: UInt64) {
        let position = CMTime(value: Int64(positionMs), timescale: 1_000)
        if player.currentItem != nil {
            player.seek(to: position)
        }
        store.updatePositionFromPlayer(positionMs)
        store.seek(to: positionMs)
        updateNowPlaying(for: store.currentTrack)
    }

    func retryCurrentTrack() {
        guard store.currentTrack != nil else { return }
        sourceTask?.cancel()
        activeTrackID = nil
        errorMessage = nil
        player.replaceCurrentItem(with: nil)
        store.resume()
        synchronize()
    }

    private func synchronize() {
        guard let track = store.currentTrack else {
            finishListeningSession()
            sourceTask?.cancel()
            player.pause()
            player.replaceCurrentItem(with: nil)
            isBuffering = false
            activeTrackID = nil
            activeQueueEntryID = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        guard track.id.provider.lowercased() == "tidal" else {
            player.pause()
            isBuffering = false
            errorMessage = "This iOS playback slice only supports TIDAL tracks."
            return
        }

        let queueEntryID = store.currentQueueEntryID
        if listeningTrack?.id != track.id || listeningQueueEntryID != queueEntryID {
            finishListeningSession()
            beginListeningSession(track: track, queueEntryID: queueEntryID)
        }
        if activeTrackID == track.id,
           activeQueueEntryID == queueEntryID,
           player.currentItem != nil {
            applyPlaybackState()
            return
        }

        activeTrackID = track.id
        activeQueueEntryID = queueEntryID
        sourceTask?.cancel()
        player.pause()
        isBuffering = store.effectiveIsPlaying
        errorMessage = nil
        sourceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolution = try await account.playbackSource(for: track)
                guard !Task.isCancelled,
                      store.currentTrack?.id == track.id,
                      store.currentQueueEntryID == queueEntryID,
                      let url = URL(string: resolution.source.uri) else { return }
                install(source: url, track: track, queueEntryID: queueEntryID)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                isBuffering = false
                errorMessage = error.localizedDescription
                store.pause()
            }
        }
    }

    private func install(source url: URL, track: CoreTrack, queueEntryID: UInt64?) {
        guard store.currentTrack?.id == track.id,
              store.currentQueueEntryID == queueEntryID else { return }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if store.positionMs > 0 {
            player.seek(to: CMTime(value: Int64(store.positionMs), timescale: 1_000))
        }
        updateNowPlaying(for: track)
        applyPlaybackState()
    }

    private func applyPlaybackState() {
        guard player.currentItem != nil else { return }
        if store.effectiveIsPlaying {
            configureAudioSession(activate: true)
            player.play()
        } else {
            player.pause()
        }
        updateNowPlaying(for: store.currentTrack)
    }

    private func configureAudioSession(activate: Bool) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            if activate {
                try session.setActive(true)
            }
        } catch {
            // Sideloading containers can reject explicit session ownership while
            // AVPlayer still receives a working playback session. Player/item
            // failures are surfaced separately and remain actionable.
        }
    }

    private func installNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self,
                          let endedItem = notification.object as? AVPlayerItem,
                          let currentItem = self.player.currentItem,
                          endedItem === currentItem else { return }
                    self.skipNext()
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleInterruption(notification)
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                       AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable,
                       self.store.effectiveIsPlaying {
                        self.player.pause()
                        self.store.pause()
                    }
                    self.updateNowPlaying(for: self.store.currentTrack)
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self,
                          let failedItem = notification.object as? AVPlayerItem,
                          let currentItem = self.player.currentItem,
                          failedItem === currentItem else { return }
                    self.isBuffering = false
                    self.errorMessage = "Playback stopped unexpectedly."
                    self.player.pause()
                    self.store.pause()
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVPlayerItem.playbackStalledNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self,
                          let stalledItem = notification.object as? AVPlayerItem,
                          let currentItem = self.player.currentItem,
                          stalledItem === currentItem else { return }
                    self.isBuffering = true
                }
            }
        )
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.updatePosition(time)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let values = notification.userInfo,
              let rawType = values[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = store.effectiveIsPlaying
            player.pause()
            updateNowPlaying(for: store.currentTrack)
        case .ended:
            let rawOptions = values[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                .contains(.shouldResume)
            if wasPlayingBeforeInterruption, shouldResume {
                configureAudioSession(activate: true)
                applyPlaybackState()
            } else if wasPlayingBeforeInterruption {
                store.pause()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func updatePosition(_ time: CMTime) {
        guard time.isNumeric else { return }
        checkpointAudibleTime()
        resumeAudibleClockIfNeeded()
        let milliseconds = max(0, UInt64(time.seconds * 1_000))
        store.updatePositionFromPlayer(milliseconds)
        if milliseconds >= lastCheckpointMs + 10_000 || milliseconds < lastCheckpointMs {
            lastCheckpointMs = milliseconds
            store.checkpointPosition()
        }
        updateNowPlaying(for: store.currentTrack)
    }

    private func beginListeningSession(track: CoreTrack, queueEntryID: UInt64?) {
        listeningTrack = track
        listeningQueueEntryID = queueEntryID
        listeningStartedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        accumulatedListenedMs = 0
        audibleClockStartedAt = nil
        resumeAudibleClockIfNeeded()
    }

    private func reconcileAudibleClock(for status: AVPlayer.TimeControlStatus) {
        if status == .playing {
            resumeAudibleClockIfNeeded()
        } else {
            checkpointAudibleTime()
        }
    }

    private func resumeAudibleClockIfNeeded() {
        guard listeningTrack != nil,
              player.timeControlStatus == .playing,
              audibleClockStartedAt == nil else { return }
        audibleClockStartedAt = ProcessInfo.processInfo.systemUptime
    }

    private func checkpointAudibleTime() {
        guard let startedAt = audibleClockStartedAt else { return }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
        let boundedMilliseconds = min(UInt64(elapsed * 1_000), 15_000)
        accumulatedListenedMs += boundedMilliseconds
        audibleClockStartedAt = nil
    }

    private func finishListeningSession() {
        checkpointAudibleTime()
        defer {
            listeningTrack = nil
            listeningQueueEntryID = nil
            listeningStartedAtMs = 0
            accumulatedListenedMs = 0
            audibleClockStartedAt = nil
        }

        guard let track = listeningTrack else { return }
        let thresholdMs = min(track.durationMs.map { $0 / 2 } ?? 240_000, 240_000)
        guard thresholdMs > 0, accumulatedListenedMs >= thresholdMs else { return }
        let endedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        store.recordListen(
            track: track,
            event: CoreListenEvent(
                eventID: UUID().uuidString.lowercased(),
                deviceID: historyDeviceID,
                mediaID: track.id,
                startedAtMs: listeningStartedAtMs,
                endedAtMs: max(listeningStartedAtMs, endedAtMs),
                listenedMs: accumulatedListenedMs,
                trackDurationMs: track.durationMs
            )
        )
    }

    private func updateNowPlaying(for track: CoreTrack?) {
        guard let track else {
            artworkTask?.cancel()
            artworkTask = nil
            loadedArtworkURL = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artistLabel
        info[MPMediaItemPropertyAlbumTitle] = track.albumLabel
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(store.positionMs) / 1_000
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.timeControlStatus == .playing ? 1.0 : 0.0
        if let snapshot = store.coreSnapshot,
           let currentEntry = snapshot.queue.current,
           let queueIndex = snapshot.queue.playOrder.firstIndex(of: currentEntry) {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = snapshot.queue.playOrder.count
        }
        if let duration = player.currentItem?.asset.duration.seconds, duration.isFinite {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else if let durationMs = track.durationMs {
            info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1_000
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        updateRemoteCommandAvailability()

        let artworkURL = track.artwork?.url
        let artworkLink = artworkURL.flatMap { URL(string: $0)?.absoluteString }
        guard artworkLink != loadedArtworkURL else { return }
        artworkTask?.cancel()
        artworkTask = nil
        loadedArtworkURL = artworkLink
        guard let artworkLink, let url = URL(string: artworkLink) else { return }

        artworkTask = Task { @MainActor [weak self, track, url] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled,
                      (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true,
                      let image = UIImage(data: data),
                      let self,
                      self.store.currentTrack?.id == track.id,
                      self.loadedArtworkURL == url.absoluteString else { return }

                var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                currentInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
            } catch {
                // Artwork is supplemental; playback should not depend on the image request.
            }
        }
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.store.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.store.pause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipPrevious() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                self?.seek(to: max(0, UInt64(event.positionTime * 1_000)))
            }
            return .success
        }
        updateRemoteCommandAvailability()
    }

    private func updateRemoteCommandAvailability() {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = store.canSkipNext
        center.previousTrackCommand.isEnabled = store.canSkipPrevious
        center.changePlaybackPositionCommand.isEnabled = store.currentTrack != nil
    }

    private func nextQueueEntryID() -> UInt64? {
        guard let snapshot = store.coreSnapshot,
              let current = snapshot.queue.current else { return nil }
        if store.repeatMode == .one {
            return current
        }
        guard let index = snapshot.queue.playOrder.firstIndex(of: current) else { return nil }
        if snapshot.queue.playOrder.indices.contains(index + 1) {
            return snapshot.queue.playOrder[index + 1]
        }
        return store.repeatMode == .all ? snapshot.queue.playOrder.first : nil
    }
}
