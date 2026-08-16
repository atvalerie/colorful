import AVFoundation
import Combine
import MediaPlayer

@MainActor
final class IOSPlaybackService: NSObject, ObservableObject {
    @Published private(set) var errorMessage: String?

    private let store: PlaybackStore
    private let account: TidalAccountStore
    private let player = AVPlayer()
    private var cancellables = Set<AnyCancellable>()
    private var notificationTokens = [NSObjectProtocol]()
    private var timeObserver: Any?
    private var sourceTask: Task<Void, Never>?
    private var activeTrackID: CoreMediaID?
    private var lastCheckpointMs: UInt64 = 0
    private var hasStarted = false

    init(store: PlaybackStore, account: TidalAccountStore) {
        self.store = store
        self.account = account
        super.init()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        configureAudioSession()
        installRemoteCommands()
        installNotifications()

        store.$currentTrack
            .sink { [weak self] _ in self?.synchronize() }
            .store(in: &cancellables)
        store.$isPlaying
            .sink { [weak self] _ in self?.applyPlaybackState() }
            .store(in: &cancellables)

        synchronize()
    }

    func stop() {
        sourceTask?.cancel()
        sourceTask = nil
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

    private func synchronize() {
        guard let track = store.currentTrack else {
            sourceTask?.cancel()
            player.pause()
            player.replaceCurrentItem(with: nil)
            activeTrackID = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        guard track.id.provider.lowercased() == "tidal" else {
            player.pause()
            errorMessage = "This iOS playback slice only supports TIDAL tracks."
            return
        }

        if activeTrackID == track.id, player.currentItem != nil {
            applyPlaybackState()
            return
        }

        activeTrackID = track.id
        sourceTask?.cancel()
        player.pause()
        errorMessage = nil
        sourceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolution = try await account.playbackSource(for: track)
                guard !Task.isCancelled,
                      store.currentTrack?.id == track.id,
                      let url = URL(string: resolution.source.uri) else { return }
                install(source: url, track: track)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                store.pause()
            }
        }
    }

    private func install(source url: URL, track: CoreTrack) {
        guard store.currentTrack?.id == track.id else { return }
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
        if store.isPlaying {
            player.play()
        } else {
            player.pause()
        }
        updateNowPlaying(for: store.currentTrack)
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            errorMessage = "Could not activate the iOS audio session: \(error.localizedDescription)"
        }
    }

    private func installNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.store.skipNext()
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
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.updateNowPlaying(for: self.store.currentTrack)
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
            player.pause()
        case .ended:
            guard let rawOptions = values[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) else { return }
            applyPlaybackState()
        @unknown default:
            break
        }
    }

    private func updatePosition(_ time: CMTime) {
        guard time.isNumeric else { return }
        let milliseconds = max(0, UInt64(time.seconds * 1_000))
        store.updatePositionFromPlayer(milliseconds)
        if milliseconds >= lastCheckpointMs + 10_000 || milliseconds < lastCheckpointMs {
            lastCheckpointMs = milliseconds
            store.checkpointPosition()
        }
        updateNowPlaying(for: store.currentTrack)
    }

    private func updateNowPlaying(for track: CoreTrack?) {
        guard let track else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artistLabel
        info[MPMediaItemPropertyAlbumTitle] = track.albumLabel
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(store.positionMs) / 1_000
        info[MPNowPlayingInfoPropertyPlaybackRate] = store.isPlaying ? 1.0 : 0.0
        if let duration = player.currentItem?.asset.duration.seconds, duration.isFinite {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.store.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.store.pause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.store.skipNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.store.skipPrevious() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                self?.store.seek(to: max(0, UInt64(event.positionTime * 1_000)))
            }
            return .success
        }
    }
}
