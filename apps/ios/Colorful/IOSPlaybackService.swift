import AVFoundation
import Combine
import MediaPlayer
import UIKit
import UniformTypeIdentifiers

@MainActor
final class IOSPlaybackService: NSObject, ObservableObject {
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBuffering = false

    private let store: PlaybackStore
    private let account: TidalAccountStore
    private let downloads: IOSOfflineDownloadManager
    private let player = AVPlayer()
    private var cancellables = Set<AnyCancellable>()
    private var notificationTokens = [NSObjectProtocol]()
    private var timeObserver: Any?
    private var sourceTask: Task<Void, Never>?
    private var itemReadinessTask: Task<Void, Never>?
    private var itemStatusCancellable: AnyCancellable?
    private var activeTrackID: CoreMediaID?
    private var activeQueueEntryID: UInt64?
    private var installedTrackID: CoreMediaID?
    private var installedQueueEntryID: UInt64?
    private var failedTrackID: CoreMediaID?
    private var failedQueueEntryID: UInt64?
    private var lastCheckpointMs: UInt64 = 0
    private var lastNowPlayingPositionMs: UInt64 = 0
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

    init(store: PlaybackStore, account: TidalAccountStore, downloads: IOSOfflineDownloadManager) {
        self.store = store
        self.account = account
        self.downloads = downloads
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
        itemReadinessTask?.cancel()
        itemReadinessTask = nil
        itemStatusCancellable = nil
        artworkTask?.cancel()
        artworkTask = nil
        loadedArtworkURL = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        installedTrackID = nil
        installedQueueEntryID = nil
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
        itemReadinessTask?.cancel()
        itemStatusCancellable = nil
        activeTrackID = nil
        errorMessage = nil
        player.replaceCurrentItem(with: nil)
        installedTrackID = nil
        installedQueueEntryID = nil
        failedTrackID = nil
        failedQueueEntryID = nil
        store.resume()
        synchronize()
    }

    private func synchronize() {
        guard let track = store.currentTrack else {
            finishListeningSession()
            sourceTask?.cancel()
            itemReadinessTask?.cancel()
            itemStatusCancellable = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            isBuffering = false
            activeTrackID = nil
            activeQueueEntryID = nil
            installedTrackID = nil
            installedQueueEntryID = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let provider = track.id.provider.lowercased()
        guard provider == "tidal" || provider == "soundcloud" || provider == "youtube" else {
            player.pause()
            isBuffering = false
            errorMessage = "This provider is not available for iOS playback yet."
            return
        }

        let queueEntryID = store.currentQueueEntryID
        if failedTrackID == track.id, failedQueueEntryID == queueEntryID { return }
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

        let startsAtBeginning = activeTrackID != nil
            && (activeTrackID != track.id || activeQueueEntryID != queueEntryID)
        let initialPositionMs: UInt64 = startsAtBeginning ? 0 : store.positionMs
        if startsAtBeginning {
            store.updatePositionFromPlayer(0)
        }
        activeTrackID = track.id
        activeQueueEntryID = queueEntryID
        sourceTask?.cancel()
        itemReadinessTask?.cancel()
        itemStatusCancellable = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        installedTrackID = nil
        installedQueueEntryID = nil
        failedTrackID = nil
        failedQueueEntryID = nil
        isBuffering = store.effectiveIsPlaying
        errorMessage = nil
        sourceTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let localURL = downloads.localURL(for: track) {
                    guard !Task.isCancelled,
                          store.currentTrack?.id == track.id,
                          store.currentQueueEntryID == queueEntryID else { return }
                    install(
                        source: localURL,
                        track: track,
                        queueEntryID: queueEntryID,
                        initialPositionMs: initialPositionMs
                    )
                    return
                }
                let sourceURL: URL
                if provider == "soundcloud" {
                    sourceURL = try await SoundCloudClient.shared.playbackURL(for: track)
                } else if provider == "youtube" {
                    let source = try await YouTubeMusicClient.shared.playbackSource(for: track)
                    if source.mimeType.lowercased().contains("mpegurl") {
                        sourceURL = source.url
                    } else {
                        sourceURL = try await YouTubePlaybackCache.shared.localURL(
                            for: source,
                            videoID: track.id.providerID
                        )
                    }
                } else {
                    let resolution = try await account.playbackSource(for: track)
                    guard let resolvedURL = URL(string: resolution.source.uri) else {
                        throw TidalClientError.invalidResponse("TIDAL returned an invalid playback URL.")
                    }
                    sourceURL = resolvedURL
                }
                guard !Task.isCancelled,
                      store.currentTrack?.id == track.id,
                      store.currentQueueEntryID == queueEntryID else { return }
                install(
                    source: sourceURL,
                    track: track,
                    queueEntryID: queueEntryID,
                    initialPositionMs: initialPositionMs
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                isBuffering = false
                failedTrackID = track.id
                failedQueueEntryID = queueEntryID
                errorMessage = error.localizedDescription
                store.pause()
            }
        }
    }

    private func install(
        source url: URL,
        track: CoreTrack,
        queueEntryID: UInt64?,
        initialPositionMs: UInt64
    ) {
        guard store.currentTrack?.id == track.id,
              store.currentQueueEntryID == queueEntryID else { return }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        installedTrackID = track.id
        installedQueueEntryID = queueEntryID
        failedTrackID = nil
        failedQueueEntryID = nil
        itemStatusCancellable = item.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak item] status in
                guard let self, let item,
                      self.installedTrackID == track.id,
                      self.installedQueueEntryID == queueEntryID else { return }
                switch status {
                case .readyToPlay:
                    self.itemReadinessTask?.cancel()
                    self.itemReadinessTask = nil
                    self.isBuffering = false
                    self.applyPlaybackState()
                case .failed:
                    self.failInstalledItem(
                        track: track,
                        queueEntryID: queueEntryID,
                        message: self.playbackFailureMessage(for: item)
                    )
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        itemReadinessTask = Task { [weak self, weak item] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, let item,
                  item.status == .unknown,
                  self.installedTrackID == track.id,
                  self.installedQueueEntryID == queueEntryID else { return }
            self.failInstalledItem(
                track: track,
                queueEntryID: queueEntryID,
                message: "Playback timed out while opening the audio stream."
            )
        }
        if initialPositionMs > 0 {
            player.seek(to: CMTime(value: Int64(initialPositionMs), timescale: 1_000))
        }
        updateNowPlaying(for: track)
        applyPlaybackState()
    }

    private func failInstalledItem(
        track: CoreTrack,
        queueEntryID: UInt64?,
        message: String
    ) {
        guard installedTrackID == track.id, installedQueueEntryID == queueEntryID else { return }
        itemReadinessTask?.cancel()
        itemReadinessTask = nil
        itemStatusCancellable = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        installedTrackID = nil
        installedQueueEntryID = nil
        failedTrackID = track.id
        failedQueueEntryID = queueEntryID
        isBuffering = false
        errorMessage = message
        store.pause()
    }

    private func playbackFailureMessage(for item: AVPlayerItem) -> String {
        var details = [String]()
        if let error = item.error as NSError? {
            details.append("\(error.localizedDescription) [\(error.domain) \(error.code)]")
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                details.append("\(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)]")
            }
        }
        if let event = item.errorLog()?.events.last {
            let comment = event.errorComment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let code = "\(event.errorDomain) \(event.errorStatusCode)"
            details.append(comment.isEmpty ? code : "\(comment) [\(code)]")
        }
        let useful = details.filter { !$0.isEmpty }.joined(separator: " · ")
        return useful.isEmpty ? "The audio stream could not be played by iOS." : useful
    }

    private func applyPlaybackState() {
        guard let currentTrack = store.currentTrack,
              installedTrackID == currentTrack.id,
              installedQueueEntryID == store.currentQueueEntryID,
              player.currentItem != nil else {
            // A core refresh can publish the new playing state before its
            // asynchronously resolved AVPlayerItem is installed. Never apply
            // that state to the stale item from the previous queue entry.
            player.pause()
            updateNowPlaying(for: store.currentTrack)
            return
        }
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
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
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
        if milliseconds >= lastNowPlayingPositionMs + 1_000 || milliseconds < lastNowPlayingPositionMs {
            lastNowPlayingPositionMs = milliseconds
            updateNowPlaying(for: store.currentTrack)
        }
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

private final class YouTubeMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    final class LoadingContext {
        let request: AVAssetResourceLoadingRequest
        let requestedRange: String
        var remainingBytes: Int64

        init(request: AVAssetResourceLoadingRequest, requestedRange: String, remainingBytes: Int64) {
            self.request = request
            self.requestedRange = requestedRange
            self.remainingBytes = remainingBytes
        }
    }

    let delegateQueue = DispatchQueue(label: "sh.valerie.colorful.youtube-media-loader")

    private let upstreamURL: URL
    private let httpHeaders: [String: String]
    private let mimeType: String
    private let contentLength: Int64
    private var contexts = [Int: LoadingContext]()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = delegateQueue
        return URLSession(configuration: configuration, delegate: self, delegateQueue: operationQueue)
    }()

    init(upstreamURL: URL, httpHeaders: [String: String], mimeType: String, contentLength: Int64) {
        self.upstreamURL = upstreamURL
        self.httpHeaders = httpHeaders
        self.mimeType = mimeType
        self.contentLength = contentLength
        super.init()
    }

    func invalidate() {
        delegateQueue.async { [self] in
            let cancellation = URLError(.cancelled)
            for context in contexts.values where !context.request.isFinished {
                context.request.finishLoading(with: cancellation)
            }
            contexts.removeAll()
            session.invalidateAndCancel()
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url?.scheme == "colorful-youtube" else { return false }

        let dataRequest = loadingRequest.dataRequest
        let requestedOffset = dataRequest.map {
            $0.currentOffset > 0 ? $0.currentOffset : $0.requestedOffset
        } ?? 0
        guard requestedOffset < contentLength else {
            loadingRequest.finishLoading()
            return true
        }

        let requestedLength: Int64
        if let dataRequest {
            requestedLength = dataRequest.requestsAllDataToEndOfResource
                ? contentLength - requestedOffset
                : min(Int64(dataRequest.requestedLength), contentLength - requestedOffset)
        } else {
            // AVFoundation can ask only for content information. A tiny GET
            // obtains valid response metadata without relying on HEAD, which
            // Google Video rejects for otherwise playable signed URLs.
            requestedLength = 2
        }

        var request = URLRequest(url: upstreamURL, timeoutInterval: 20)
        let requestedRange = "bytes=\(requestedOffset)-\(requestedOffset + max(1, requestedLength) - 1)"
        request.setValue(requestedRange, forHTTPHeaderField: "Range")
        for (name, value) in httpHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.dataTask(with: request)
        contexts[task.taskIdentifier] = LoadingContext(
            request: loadingRequest,
            requestedRange: requestedRange,
            remainingBytes: dataRequest == nil ? 0 : requestedLength
        )
        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        guard let entry = contexts.first(where: { $0.value.request === loadingRequest }) else { return }
        contexts.removeValue(forKey: entry.key)
        session.getAllTasks { tasks in
            tasks.first(where: { $0.taskIdentifier == entry.key })?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let context = contexts[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
            contexts.removeValue(forKey: dataTask.taskIdentifier)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            context.request.finishLoading(with: NSError(
                domain: "YouTubeMediaResourceLoader",
                code: status,
                userInfo: [NSLocalizedDescriptionKey:
                    "YouTube media returned HTTP \(status) for \(context.requestedRange)."]
            ))
            completionHandler(.cancel)
            return
        }

        context.request.response = response
        if let information = context.request.contentInformationRequest {
            information.contentType = UTType(mimeType: mimeType)?.identifier ?? AVFileType.m4a.rawValue
            information.contentLength = contentLength
            information.isByteRangeAccessSupported = true
        }
        if context.request.dataRequest == nil {
            contexts.removeValue(forKey: dataTask.taskIdentifier)
            context.request.finishLoading()
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let context = contexts[dataTask.taskIdentifier],
              let dataRequest = context.request.dataRequest else { return }
        let amount = min(Int64(data.count), context.remainingBytes)
        guard amount > 0 else { return }
        dataRequest.respond(with: Data(data.prefix(Int(amount))))
        context.remainingBytes -= amount
        if context.remainingBytes == 0 {
            contexts.removeValue(forKey: dataTask.taskIdentifier)
            context.request.finishLoading()
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let context = contexts.removeValue(forKey: task.taskIdentifier) else { return }
        if let error {
            context.request.finishLoading(with: error)
        } else if context.remainingBytes == 0 {
            context.request.finishLoading()
        } else {
            context.request.finishLoading(with: URLError(.networkConnectionLost))
        }
    }
}

private actor YouTubePlaybackCache {
    static let shared = YouTubePlaybackCache()

    private let fileManager = FileManager.default

    func localURL(for source: YouTubeMusicPlaybackSource, videoID: String) async throws -> URL {
        let directory = try cacheDirectory()
        let destination = directory.appending(path: "\(videoID).m4a")
        if fileManager.fileExists(atPath: destination.path) { return destination }

        var request = URLRequest(url: source.url, timeoutInterval: 30)
        request.setValue("audio/mp4,audio/aac,audio/mpeg,*/*", forHTTPHeaderField: "Accept")
        if let contentLength = source.contentLength, contentLength > 0 {
            request.setValue("bytes=0-\(contentLength - 1)", forHTTPHeaderField: "Range")
        }
        for (name, value) in source.httpHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "YouTubePlaybackCache",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "YouTube media download returned HTTP \(status)."]
            )
        }
        try Task.checkCancellation()
        try fileManager.moveItem(at: temporaryURL, to: destination)
        try? prune(directory: directory, keeping: 24)
        return destination
    }

    private func cacheDirectory() throws -> URL {
        let directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "YouTubePlayback", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func prune(directory: URL, keeping limit: Int) throws {
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        guard files.count > limit else { return }
        let ordered = files.sorted {
            let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (left ?? .distantPast) < (right ?? .distantPast)
        }
        for file in ordered.prefix(files.count - limit) { try? fileManager.removeItem(at: file) }
    }
}
