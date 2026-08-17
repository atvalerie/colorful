import AVFoundation
import Combine
import Foundation

@MainActor
final class IOSOfflineDownloadManager: NSObject, ObservableObject {
    @Published private(set) var progressByTrack = [CoreMediaID: Double]()
    @Published private(set) var message: String?

    private let store: PlaybackStore
    private let account: TidalAccountStore
    private var session: AVAssetDownloadURLSession!
    private var tasksByTrack = [CoreMediaID: AVAssetDownloadTask]()
    private var tracksByID = [CoreMediaID: CoreTrack]()
    private var completedLocations = [Int: URL]()
    private var resolutionTasks = [CoreMediaID: Task<Void, Never>]()
    private var removedTracks = Set<CoreMediaID>()
    private var hasStarted = false

    init(store: PlaybackStore, account: TidalAccountStore) {
        self.store = store
        self.account = account
        super.init()

        let configuration = URLSessionConfiguration.background(
            withIdentifier: "sh.valerie.colorful.offline-audio"
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        session = AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: self,
            delegateQueue: OperationQueue.main
        )
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        Task { [weak self] in
            guard let self else { return }
            await store.refreshFromCore()
            attachBackgroundTasksAndRestore()
        }
    }

    func job(for track: CoreTrack) -> CoreDownloadJob? {
        store.downloadItems.first { $0.id == track.id }?.job
    }

    func localURL(for track: CoreTrack) -> URL? {
        guard let job = job(for: track), job.state == .complete,
              let path = job.localPath, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ track: CoreTrack) {
        download([track])
    }

    func download(_ tracks: [CoreTrack]) {
        for track in tracks where track.id.provider.lowercased() == "tidal" {
            startDownload(track, preserveProgress: false)
        }
    }

    func pause(_ track: CoreTrack) {
        resolutionTasks.removeValue(forKey: track.id)?.cancel()
        if let task = tasksByTrack[track.id] {
            task.suspend()
        }
        persist(track: track, state: .paused)
        message = "Paused \(track.title)."
    }

    func resume(_ track: CoreTrack) {
        if let task = tasksByTrack[track.id] {
            task.resume()
            persist(track: track, state: .downloading)
            message = "Resuming \(track.title)…"
        } else {
            startDownload(track, preserveProgress: true)
        }
    }

    func remove(_ track: CoreTrack) {
        removedTracks.insert(track.id)
        resolutionTasks.removeValue(forKey: track.id)?.cancel()
        tasksByTrack.removeValue(forKey: track.id)?.cancel()
        progressByTrack.removeValue(forKey: track.id)
        if let path = job(for: track)?.localPath, !path.isEmpty {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
        store.removeDownload(track.id)
        message = "Removed the offline copy of \(track.title)."
    }

    func dismissMessage() {
        message = nil
    }

    private func startDownload(_ track: CoreTrack, preserveProgress: Bool) {
        guard tasksByTrack[track.id] == nil, resolutionTasks[track.id] == nil else { return }
        if let local = localURL(for: track) {
            message = "\(track.title) is already available offline."
            _ = local
            return
        }
        removedTracks.remove(track.id)
        tracksByID[track.id] = track
        if job(for: track)?.state == .complete {
            store.removeDownload(track.id)
        }
        persist(track: track, state: .queued, preserveProgress: preserveProgress)
        message = "Queued \(track.title) for offline playback."

        resolutionTasks[track.id] = Task { [weak self] in
            guard let self else { return }
            persist(track: track, state: .resolving, preserveProgress: preserveProgress)
            do {
                let resolution = try await account.playbackSource(for: track)
                try Task.checkCancellation()
                guard let sourceURL = URL(string: resolution.source.uri) else {
                    throw TidalClientError.invalidResponse("TIDAL returned an invalid download URL.")
                }
                let asset = AVURLAsset(url: sourceURL)
                guard let task = session.makeAssetDownloadTask(
                    asset: asset,
                    assetTitle: track.title,
                    assetArtworkData: nil,
                    options: nil
                ) else {
                    throw TidalClientError.invalidResponse("iOS could not create the offline download.")
                }
                task.taskDescription = taskDescription(for: track.id)
                tasksByTrack[track.id] = task
                resolutionTasks.removeValue(forKey: track.id)
                persist(track: track, state: .downloading, preserveProgress: preserveProgress)
                task.resume()
            } catch is CancellationError {
                resolutionTasks.removeValue(forKey: track.id)
            } catch {
                resolutionTasks.removeValue(forKey: track.id)
                persist(track: track, state: .failed, errorCode: "resolution_failed", preserveProgress: true)
                message = "Could not download \(track.title): \(error.localizedDescription)"
            }
        }
    }

    private func attachBackgroundTasksAndRestore() {
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for case let task as AVAssetDownloadTask in tasks {
                    guard let id = mediaID(from: task.taskDescription) else { continue }
                    tasksByTrack[id] = task
                    if let item = store.downloadItems.first(where: { $0.id == id }) {
                        tracksByID[id] = item.track
                    }
                }
                for item in store.downloadItems {
                    switch item.job.state {
                    case .queued, .resolving:
                        startDownload(item.track, preserveProgress: true)
                    case .downloading:
                        if let task = tasksByTrack[item.id] {
                            task.resume()
                        } else {
                            startDownload(item.track, preserveProgress: true)
                        }
                    case .complete:
                        if localURL(for: item.track) == nil {
                            store.removeDownload(item.id)
                        }
                    case .failed, .paused:
                        break
                    }
                }
            }
        }
    }

    private func persist(
        track: CoreTrack,
        state: CoreDownloadState,
        localURL: URL? = nil,
        size: UInt64? = nil,
        errorCode: String? = nil,
        preserveProgress: Bool = true
    ) {
        let previous = job(for: track)
        let downloaded = size ?? (preserveProgress ? previous?.bytesDownloaded ?? 0 : 0)
        let total = state == .complete ? downloaded : previous?.bytesTotal
        let job = CoreDownloadJob(
            mediaID: track.id,
            state: state,
            localPath: localURL?.path,
            bytesDownloaded: downloaded,
            bytesTotal: total,
            sourceExpiresAtMs: nil,
            errorCode: errorCode,
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        store.saveDownload(track: track, job: job)
    }

    private func taskDescription(for id: CoreMediaID) -> String {
        "\(id.provider)\n\(id.providerID)"
    }

    private func mediaID(from description: String?) -> CoreMediaID? {
        guard let parts = description?.split(separator: "\n", maxSplits: 1), parts.count == 2 else {
            return nil
        }
        return CoreMediaID(provider: String(parts[0]), providerID: String(parts[1]))
    }

    private func sizeOfItem(at url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            let values = try? url.resourceValues(forKeys: keys)
            return UInt64(max(0, values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0))
        }
        var total: UInt64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += UInt64(max(0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0))
        }
        return total
    }
}

extension IOSOfflineDownloadManager: AVAssetDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        let expected = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        guard expected.isFinite, expected > 0 else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { partial, value in
            partial + max(0, CMTimeGetSeconds(value.timeRangeValue.duration))
        }
        let progress = min(1, max(0, loaded / expected))
        let description = assetDownloadTask.taskDescription
        Task { @MainActor [weak self] in
            guard let self, let id = mediaID(from: description) else { return }
            progressByTrack[id] = progress
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = assetDownloadTask.taskIdentifier
        let description = assetDownloadTask.taskDescription
        Task { @MainActor [weak self] in
            guard let self, let id = mediaID(from: description),
                  let track = tracksByID[id] ?? store.downloadItems.first(where: { $0.id == id })?.track else { return }
            completedLocations[taskID] = location
            let size = sizeOfItem(at: location)
            persist(track: track, state: .complete, localURL: location, size: size)
            progressByTrack[id] = 1
            message = "\(track.title) is ready offline."
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskID = task.taskIdentifier
        let description = task.taskDescription
        Task { @MainActor [weak self] in
            guard let self, let id = mediaID(from: description) else { return }
            tasksByTrack.removeValue(forKey: id)
            if completedLocations.removeValue(forKey: taskID) != nil || removedTracks.remove(id) != nil {
                return
            }
            guard let error,
                  let track = tracksByID[id] ?? store.downloadItems.first(where: { $0.id == id })?.track else { return }
            persist(track: track, state: .failed, errorCode: "transfer_failed", preserveProgress: true)
            message = "Download failed for \(track.title): \(error.localizedDescription)"
        }
    }
}
