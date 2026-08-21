import AVFoundation
import AudioToolbox
import Combine
import CoreMedia
import Foundation

enum IOSOfflineExportError: LocalizedError {
    case unavailable
    case notExportable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The completed offline track could not be found."
        case .notExportable:
            return "iOS cannot export this downloaded TIDAL asset."
        case .failed(let detail):
            return "Could not create the M4A file: \(detail)"
        }
    }
}

struct IOSOfflineExport: Identifiable {
    let url: URL
    let isLossless: Bool

    var id: URL { url }
}

@MainActor
final class IOSOfflineDownloadManager: NSObject, ObservableObject {
    nonisolated static let backgroundSessionIdentifier = "sh.valerie.colorful.offline-audio"
    private static weak var processOwner: IOSOfflineDownloadManager?

    @Published private(set) var progressByTrack = [CoreMediaID: Double]()
    @Published private(set) var message: String?

    private let store: PlaybackStore
    private let account: TidalAccountStore
    private weak var owner: IOSOfflineDownloadManager?
    private var ownerCancellables = Set<AnyCancellable>()
    private var session: AVAssetDownloadURLSession!
    private var tasksByTrack = [CoreMediaID: AVAssetDownloadTask]()
    private var taskIDsByTrack = [CoreMediaID: Int]()
    private var trackIDsByTask = [Int: CoreMediaID]()
    private var tracksByID = [CoreMediaID: CoreTrack]()
    private var pendingCompletedLocations = [Int: (id: CoreMediaID, location: URL)]()
    private var resolutionTasks = [CoreMediaID: Task<Void, Never>]()
    private var removedTracks = Set<CoreMediaID>()
    private var cancelledTaskIDs = Set<Int>()
    private var jobsByTrack = [CoreMediaID: CoreDownloadJob]()
    private var startupTask: Task<Void, Never>?
    private var delegateEventTail: Task<Void, Never>?
    private var persistenceTail: Task<Void, Never>?
    private var backgroundCompletionHandlers = [() -> Void]()
    private var backgroundEventsDidFinish = false
    private var hasStarted = false

    init(store: PlaybackStore, account: TidalAccountStore) {
        self.store = store
        self.account = account
        super.init()

        if let existing = Self.processOwner {
            owner = existing
            progressByTrack = existing.progressByTrack
            message = existing.message
            existing.$progressByTrack
                .sink { [weak self] value in self?.progressByTrack = value }
                .store(in: &ownerCancellables)
            existing.$message
                .sink { [weak self] value in self?.message = value }
                .store(in: &ownerCancellables)
            return
        }

        Self.processOwner = self
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.backgroundSessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        session = AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: self,
            delegateQueue: OperationQueue.main
        )
    }

    func start() {
        if let owner {
            owner.start()
            return
        }
        guard !hasStarted else { return }
        hasStarted = true
        startupTask = Task { [weak self] in
            guard let self else { return }
            await refreshAndRestore()
        }
    }

    func handleBackgroundEvents(
        for identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if let owner {
            owner.handleBackgroundEvents(for: identifier, completionHandler: completionHandler)
            return
        }
        guard identifier == Self.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        backgroundCompletionHandlers.append(completionHandler)
        start()
        if backgroundEventsDidFinish {
            enqueueDelegateEvent { [weak self] in
                guard let self else { return }
                await finishBackgroundEventCycleIfReady()
            }
        }
    }

    func job(for track: CoreTrack) -> CoreDownloadJob? {
        if let owner { return owner.job(for: track) }
        guard !removedTracks.contains(track.id) else { return nil }
        return jobsByTrack[track.id] ?? store.downloadItems.first { $0.id == track.id }?.job
    }

    func localURL(for track: CoreTrack) -> URL? {
        if let owner { return owner.localURL(for: track) }
        guard let job = job(for: track), job.state == .complete,
              let path = job.localPath, !path.isEmpty,
              let url = resolvedLocalURL(forStoredPath: path),
              isPlayableOffline(at: url) else { return nil }
        return url
    }

    func download(_ track: CoreTrack) {
        if let owner {
            owner.download(track)
            return
        }
        download([track])
    }

    func download(_ tracks: [CoreTrack]) {
        if let owner {
            owner.download(tracks)
            return
        }
        for track in tracks where track.id.provider.lowercased() == "tidal" {
            startDownload(track, preserveProgress: false)
        }
    }

    func pause(_ track: CoreTrack) {
        if let owner {
            owner.pause(track)
            return
        }
        resolutionTasks.removeValue(forKey: track.id)?.cancel()
        if let task = tasksByTrack[track.id] {
            task.suspend()
        }
        persist(track: track, state: .paused)
        message = "Paused \(track.title)."
    }

    func resume(_ track: CoreTrack) {
        if let owner {
            owner.resume(track)
            return
        }
        if let task = tasksByTrack[track.id] {
            task.resume()
            persist(track: track, state: .downloading)
            message = "Resuming \(track.title)…"
        } else {
            startDownload(track, preserveProgress: true)
        }
    }

    func remove(_ track: CoreTrack) {
        if let owner {
            owner.remove(track)
            return
        }
        let storedLocalPath = job(for: track)?.localPath
        removedTracks.insert(track.id)
        let pendingTaskIDs = pendingCompletedLocations.compactMap { taskID, pending in
            pending.id == track.id ? taskID : nil
        }
        for taskID in pendingTaskIDs {
            if let pending = pendingCompletedLocations.removeValue(forKey: taskID) {
                try? FileManager.default.removeItem(at: pending.location)
            }
            cancelledTaskIDs.insert(taskID)
        }
        resolutionTasks.removeValue(forKey: track.id)?.cancel()
        if let task = tasksByTrack.removeValue(forKey: track.id) {
            cancelledTaskIDs.insert(task.taskIdentifier)
            task.cancel()
            trackIDsByTask.removeValue(forKey: task.taskIdentifier)
        }
        taskIDsByTrack.removeValue(forKey: track.id)
        progressByTrack.removeValue(forKey: track.id)
        if let path = storedLocalPath,
           let localURL = resolvedLocalURL(forStoredPath: path) {
            try? FileManager.default.removeItem(at: localURL)
        }
        try? FileManager.default.removeItem(at: exportURL(for: track, extension: "m4a"))
        try? FileManager.default.removeItem(at: exportURL(for: track, extension: "flac"))
        jobsByTrack.removeValue(forKey: track.id)
        enqueuePersistence(CoreRemoveDownloadCommand(id: track.id))
        message = "Removed the offline copy of \(track.title)."
    }

    func prepareShareableExport(for track: CoreTrack) async throws -> IOSOfflineExport {
        if let owner { return try await owner.prepareShareableExport(for: track) }
        guard let localURL = localURL(for: track) else {
            throw IOSOfflineExportError.unavailable
        }
        let asset = AVURLAsset(url: localURL)
        if localURL.pathExtension.lowercased() == "flac" {
            return IOSOfflineExport(url: localURL, isLossless: true)
        }
        if localURL.pathExtension.lowercased() == "m4a" {
            return IOSOfflineExport(url: localURL, isLossless: false)
        }
        let lossless = try await isLossless(asset: asset)
        let destination = exportURL(for: track, extension: lossless ? "flac" : "m4a")
        if FileManager.default.fileExists(atPath: destination.path) {
            return IOSOfflineExport(url: destination, isLossless: lossless)
        }

        guard try await asset.load(.isExportable) else {
            throw IOSOfflineExportError.notExportable
        }
        if lossless {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await Self.writeFLAC(from: localURL, to: destination)
            return IOSOfflineExport(url: destination, isLossless: true)
        }
        try await writeM4A(asset: asset, track: track, destination: destination)
        return IOSOfflineExport(url: destination, isLossless: false)
    }

    private func writeM4A(asset: AVAsset, track: CoreTrack, destination: URL) async throws {
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw IOSOfflineExportError.notExportable
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        exporter.outputURL = destination
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = false
        exporter.metadata = exportMetadata(for: track)
        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously {
                continuation.resume()
            }
        }
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw IOSOfflineExportError.failed(
                exporter.error?.localizedDescription ?? "the media exporter stopped unexpectedly"
            )
        }
    }

    func dismissMessage() {
        if let owner {
            owner.dismissMessage()
            return
        }
        message = nil
    }

    private func startDownload(_ track: CoreTrack, preserveProgress: Bool) {
        guard tasksByTrack[track.id] == nil,
              resolutionTasks[track.id] == nil else { return }
        removedTracks.remove(track.id)
        if let local = localURL(for: track) {
            message = "\(track.title) is already available offline."
            _ = local
            return
        }
        tracksByID[track.id] = track
        if let previous = job(for: track) {
            if let path = previous.localPath,
               let localURL = resolvedLocalURL(forStoredPath: path) {
                try? FileManager.default.removeItem(at: localURL)
            }
            jobsByTrack.removeValue(forKey: track.id)
            enqueuePersistence(CoreRemoveDownloadCommand(id: track.id))
        }
        persist(
            track: track,
            state: .queued,
            preserveProgress: preserveProgress,
            preserveLocalPath: false
        )
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
                taskIDsByTrack[track.id] = task.taskIdentifier
                trackIDsByTask[task.taskIdentifier] = track.id
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

    private func refreshAndRestore() async {
        await store.refreshFromCore()
        let firstTasks = await allBackgroundTasks()
        restoreBackgroundTasks(firstTasks)
        guard store.coreSnapshot == nil else { return }

        // A background relaunch can race the first core open. Keep the session
        // attached and retry once so pending completion locations are not lost
        // just because the UI snapshot was not ready on the first pass.
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard !Task.isCancelled else { return }
        await store.refreshFromCore()
        let retryTasks = await allBackgroundTasks()
        restoreBackgroundTasks(retryTasks)
    }

    private func allBackgroundTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    private func restoreBackgroundTasks(_ tasks: [URLSessionTask]) {
        let items = store.downloadItems
        let hasLoadedSnapshot = store.coreSnapshot != nil
        jobsByTrack.removeAll(keepingCapacity: true)
        for item in items {
            jobsByTrack[item.id] = item.job
        }

        for case let task as AVAssetDownloadTask in tasks {
            guard let id = mediaID(from: task.taskDescription) else {
                task.cancel()
                continue
            }
            guard !hasLoadedSnapshot || items.contains(where: { $0.id == id }) else {
                task.cancel()
                continue
            }
            tasksByTrack[id] = task
            taskIDsByTrack[id] = task.taskIdentifier
            trackIDsByTask[task.taskIdentifier] = id
            if let item = items.first(where: { $0.id == id }) {
                tracksByID[id] = item.track
                if item.job.state != .complete,
                   let path = item.job.localPath,
                   let location = resolvedLocalURL(forStoredPath: path) {
                    pendingCompletedLocations[task.taskIdentifier] = (id: id, location: location)
                }
            }
        }

        for item in items {
            let restoredTask = tasksByTrack[item.id]
            switch item.job.state {
            case .queued, .resolving:
                if let restoredTask {
                    if restoredTask.state == .suspended { restoredTask.resume() }
                    persist(track: item.track, state: .downloading, preserveProgress: true)
                } else {
                    startDownload(item.track, preserveProgress: true)
                }
            case .downloading:
                if let restoredTask {
                    if restoredTask.state == .suspended { restoredTask.resume() }
                } else {
                    startDownload(item.track, preserveProgress: true)
                }
            case .complete:
                // Do not delete here. A location or completion callback may
                // already be queued even when getAllTasks no longer lists it.
                break
            case .failed, .paused:
                break
            }
        }
    }

    private func persist(
        track: CoreTrack,
        state: CoreDownloadState,
        localURL: URL? = nil,
        size: UInt64? = nil,
        errorCode: String? = nil,
        preserveProgress: Bool = true,
        preserveLocalPath: Bool = true
    ) {
        let previous = job(for: track)
        let downloaded = size ?? (preserveProgress ? previous?.bytesDownloaded ?? 0 : 0)
        let total = state == .complete ? downloaded : previous?.bytesTotal
        let localPath = localURL.map(portableStoredPath)
            ?? (preserveLocalPath ? previous?.localPath : nil)
        let job = CoreDownloadJob(
            mediaID: track.id,
            state: state,
            localPath: localPath,
            bytesDownloaded: downloaded,
            bytesTotal: total,
            sourceExpiresAtMs: nil,
            errorCode: errorCode,
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        jobsByTrack[track.id] = job
        enqueuePersistence(CoreSaveDownloadCommand(track: track, job: job))
    }

    private func enqueuePersistence<T: Encodable>(_ command: T) {
        guard let data = try? JSONEncoder().encode(command),
              let commandJSON = String(data: data, encoding: .utf8) else { return }
        let previous = persistenceTail
        persistenceTail = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            let succeeded = await store.core.dispatch(commandJSON: commandJSON)
            await store.refreshFromCore()
            if !succeeded {
                message = "Could not save the offline download state."
            }
        }
    }

    private func awaitPersistenceBarrier() async {
        let tail = persistenceTail
        await tail?.value
    }

    private func taskDescription(for id: CoreMediaID) -> String {
        "\(id.provider)\n\(id.providerID)"
    }

    private func portableStoredPath(for url: URL) -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        let relative = String(path.dropFirst(home.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Apple documents saving the asset's path relative to the current
        // container. This survives application-container UUID changes caused
        // by reinstalling or moving a sideloaded app.
        return relative
    }

    private func resolvedLocalURL(forStoredPath path: String) -> URL? {
        let fileManager = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if path.hasPrefix("~/") {
            let candidate = home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
            return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
        }

        if path.hasPrefix("/") {
            let directURL = URL(fileURLWithPath: path).standardizedFileURL
            if fileManager.fileExists(atPath: directURL.path) {
                return directURL
            }

            // Legacy records stored an absolute path. Rebase the managed
            // Library/Documents/tmp portion onto the current container.
            let components = directURL.pathComponents
            for anchor in ["Library", "Documents", "tmp"] {
                guard let index = components.lastIndex(of: anchor) else { continue }
                let relativeComponents = components[index...]
                let candidate = relativeComponents.reduce(home) { partial, component in
                    partial.appendingPathComponent(component)
                }.standardizedFileURL
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return nil
        }

        // New records use a container-relative path. Keep accepting the
        // previous relative-to-home format for upgrades from older builds.
        let candidate = home.appendingPathComponent(path).standardizedFileURL
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func mediaID(from description: String?) -> CoreMediaID? {
        guard let parts = description?.split(separator: "\n", maxSplits: 1), parts.count == 2 else {
            return nil
        }
        return CoreMediaID(provider: String(parts[0]), providerID: String(parts[1]))
    }

    private func allocatedSizeOfManagedPackage(at url: URL) -> UInt64 {
        // The .movpkg contents are private to AVFoundation. Read metadata from
        // the package root only; never enumerate or rewrite its internals.
        let keys: Set<URLResourceKey> = [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        return UInt64(max(0, values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0))
    }

    private func isPlayableOffline(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        return asset.assetCache?.isPlayableOffline == true
    }

    private func exportURL(for track: CoreTrack, extension fileExtension: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let artist = safeFilenameComponent(track.artists.first?.name ?? "Unknown artist")
        let title = safeFilenameComponent(track.title)
        let identity = safeFilenameComponent(String(track.id.providerID.suffix(10)))
        return support
            .appendingPathComponent("Colorful", isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
            .appendingPathComponent("\(artist) - \(title) [\(identity)].\(fileExtension)", isDirectory: false)
    }

    private func safeFilenameComponent(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(80)).isEmpty ? "Track" : String(cleaned.prefix(80))
    }

    private func exportMetadata(for track: CoreTrack) -> [AVMetadataItem] {
        var result = [AVMetadataItem]()
        result.append(metadataItem(identifier: .commonIdentifierTitle, value: track.title))
        result.append(metadataItem(identifier: .commonIdentifierArtist, value: track.artistLabel))
        if let album = track.albumTitle, !album.isEmpty {
            result.append(metadataItem(identifier: .commonIdentifierAlbumName, value: album))
        }
        return result
    }

    private func metadataItem(identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    private func isLossless(asset: AVAsset) async throws -> Bool {
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw IOSOfflineExportError.unavailable
        }
        let descriptions = try await audioTrack.load(.formatDescriptions)
        return descriptions.contains { description in
            let subtype = CMFormatDescriptionGetMediaSubType(description)
            return subtype == kAudioFormatFLAC
                || subtype == kAudioFormatAppleLossless
                || subtype == kAudioFormatLinearPCM
        }
    }

    private nonisolated static func writeFLAC(from source: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw IOSOfflineExportError.unavailable
        }
        let descriptions = try await audioTrack.load(.formatDescriptions)
        guard let description = descriptions.first,
              let sourceFormat = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            throw IOSOfflineExportError.failed("the source audio format is unavailable")
        }

        let sampleRate = sourceFormat.mSampleRate > 0 ? sourceFormat.mSampleRate : 44_100
        let channels = max(1, sourceFormat.mChannelsPerFrame)
        let bytesPerFrame = channels * 4
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw IOSOfflineExportError.failed("iOS could not decode the downloaded audio")
        }
        reader.add(output)

        var destinationFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatFLAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: sourceFormat.mBitsPerChannel == 16 ? 16 : 24,
            mReserved: 0
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkAudioStatus(
            AudioFormatGetProperty(
                kAudioFormatProperty_FormatInfo,
                0,
                nil,
                &formatSize,
                &destinationFormat
            ),
            operation: "configure FLAC"
        )

        var outputFile: ExtAudioFileRef?
        try checkAudioStatus(
            ExtAudioFileCreateWithURL(
                destination as CFURL,
                kAudioFileFLACType,
                &destinationFormat,
                nil,
                AudioFileFlags.eraseFile.rawValue,
                &outputFile
            ),
            operation: "create FLAC"
        )
        guard let outputFile else {
            throw IOSOfflineExportError.failed("iOS did not create the FLAC file")
        }
        defer { ExtAudioFileDispose(outputFile) }

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try checkAudioStatus(
            ExtAudioFileSetProperty(
                outputFile,
                kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &clientFormat
            ),
            operation: "configure FLAC encoder"
        )
        guard reader.startReading() else {
            throw IOSOfflineExportError.failed(reader.error?.localizedDescription ?? "the decoder could not start")
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: byteCount)
            let copyStatus = data.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: baseAddress
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                throw IOSOfflineExportError.failed("iOS could not read decoded audio")
            }
            let frameCount = UInt32(CMSampleBufferGetNumSamples(sampleBuffer))
            try data.withUnsafeMutableBytes { bytes in
                var audioBuffer = AudioBuffer(
                    mNumberChannels: channels,
                    mDataByteSize: UInt32(byteCount),
                    mData: bytes.baseAddress
                )
                var bufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: audioBuffer
                )
                try checkAudioStatus(
                    ExtAudioFileWrite(outputFile, frameCount, &bufferList),
                    operation: "write FLAC"
                )
            }
        }
        guard reader.status == .completed else {
            throw IOSOfflineExportError.failed(reader.error?.localizedDescription ?? "the decoder stopped unexpectedly")
        }
    }

    private nonisolated static func checkAudioStatus(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw IOSOfflineExportError.failed("\(operation) failed (AudioToolbox \(status))")
        }
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
        let taskID = assetDownloadTask.taskIdentifier
        let description = assetDownloadTask.taskDescription
        MainActor.assumeIsolated { [weak self] in
            self?.enqueueDelegateEvent { [weak self] in
                guard let self,
                      let id = idForTask(taskID, description: description),
                      !removedTracks.contains(id),
                      !cancelledTaskIDs.contains(taskID),
                      taskIDsByTrack[id] == nil || taskIDsByTrack[id] == taskID else { return }
                progressByTrack[id] = progress
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        let taskID = assetDownloadTask.taskIdentifier
        let description = assetDownloadTask.taskDescription
        MainActor.assumeIsolated { [weak self] in
            self?.enqueueDelegateEvent { [weak self] in
                guard let self else { return }
                await awaitStartup()
                handleManagedLocation(taskID: taskID, description: description, location: location)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskID = task.taskIdentifier
        let description = task.taskDescription
        MainActor.assumeIsolated { [weak self] in
            self?.enqueueDelegateEvent { [weak self] in
                guard let self else { return }
                await awaitStartup()
                handleTaskCompletion(taskID: taskID, description: description, error: error)
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard session.configuration.identifier == Self.backgroundSessionIdentifier else { return }
        MainActor.assumeIsolated { [weak self] in
            self?.enqueueDelegateEvent { [weak self] in
                guard let self else { return }
                await awaitStartup()
                backgroundEventsDidFinish = true
                await finishBackgroundEventCycleIfReady()
            }
        }
    }
}

private extension IOSOfflineDownloadManager {
    func enqueueDelegateEvent(_ operation: @escaping @MainActor () async -> Void) {
        let previous = delegateEventTail
        delegateEventTail = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func awaitStartup() async {
        start()
        let task = startupTask
        await task?.value
    }

    func idForTask(_ taskID: Int, description: String?) -> CoreMediaID? {
        mediaID(from: description) ?? trackIDsByTask[taskID]
    }

    func handleManagedLocation(taskID: Int, description: String?, location: URL) {
        guard let id = idForTask(taskID, description: description) else {
            try? FileManager.default.removeItem(at: location)
            return
        }
        guard !removedTracks.contains(id), !cancelledTaskIDs.contains(taskID) else {
            pendingCompletedLocations.removeValue(forKey: taskID)
            try? FileManager.default.removeItem(at: location)
            return
        }
        if let currentTaskID = taskIDsByTrack[id], currentTaskID != taskID {
            try? FileManager.default.removeItem(at: location)
            return
        }
        guard let track = tracksByID[id]
                ?? store.downloadItems.first(where: { $0.id == id })?.track,
              job(for: track) != nil else {
            try? FileManager.default.removeItem(at: location)
            return
        }

        taskIDsByTrack[id] = taskID
        trackIDsByTask[taskID] = id
        tracksByID[id] = track
        pendingCompletedLocations[taskID] = (id: id, location: location)
        let state: CoreDownloadState = job(for: track)?.state == .paused ? .paused : .downloading
        persist(track: track, state: state, localURL: location, preserveProgress: true)
    }

    func handleTaskCompletion(taskID: Int, description: String?, error: Error?) {
        guard let id = idForTask(taskID, description: description) else {
            pendingCompletedLocations.removeValue(forKey: taskID)
            return
        }

        defer {
            if taskIDsByTrack[id] == taskID {
                tasksByTrack.removeValue(forKey: id)
                taskIDsByTrack.removeValue(forKey: id)
            }
            trackIDsByTask.removeValue(forKey: taskID)
        }

        if cancelledTaskIDs.contains(taskID) || removedTracks.contains(id) {
            if let pending = pendingCompletedLocations.removeValue(forKey: taskID) {
                try? FileManager.default.removeItem(at: pending.location)
            }
            return
        }
        if let currentTaskID = taskIDsByTrack[id], currentTaskID != taskID {
            if let pending = pendingCompletedLocations.removeValue(forKey: taskID) {
                try? FileManager.default.removeItem(at: pending.location)
            }
            return
        }
        guard let track = tracksByID[id]
                ?? store.downloadItems.first(where: { $0.id == id })?.track,
              job(for: track) != nil else {
            if let pending = pendingCompletedLocations.removeValue(forKey: taskID) {
                try? FileManager.default.removeItem(at: pending.location)
            }
            return
        }

        if let error {
            let location = pendingCompletedLocations.removeValue(forKey: taskID)?.location
            persist(
                track: track,
                state: .failed,
                localURL: location,
                errorCode: "transfer_failed",
                preserveProgress: true
            )
            message = "Download failed for \(track.title): \(error.localizedDescription)"
            return
        }

        let storedLocation = job(for: track)?.localPath.flatMap {
            resolvedLocalURL(forStoredPath: $0)
        }
        let location = pendingCompletedLocations.removeValue(forKey: taskID)?.location
            ?? storedLocation
        guard let location, isPlayableOffline(at: location) else {
            jobsByTrack.removeValue(forKey: id)
            enqueuePersistence(CoreRemoveDownloadCommand(id: id))
            progressByTrack.removeValue(forKey: id)
            message = "Removed an unavailable offline copy of \(track.title)."
            return
        }

        let size = allocatedSizeOfManagedPackage(at: location)
        persist(track: track, state: .complete, localURL: location, size: size)
        progressByTrack[id] = 1
        message = "\(track.title) is ready offline."
        Task { [weak account] in
            await account?.prefetchLyrics(for: track)
        }
    }

    func reconcileCompletedRecordsAfterDelegateDrain() {
        let pendingIDs = Set(pendingCompletedLocations.values.map(\.id))
        for item in store.downloadItems where item.job.state == .complete {
            guard !pendingIDs.contains(item.id), tasksByTrack[item.id] == nil else { continue }
            guard localURL(for: item.track) == nil else { continue }
            jobsByTrack.removeValue(forKey: item.id)
            enqueuePersistence(CoreRemoveDownloadCommand(id: item.id))
            progressByTrack.removeValue(forKey: item.id)
        }
    }

    func finishBackgroundEventCycleIfReady() async {
        guard backgroundEventsDidFinish, !backgroundCompletionHandlers.isEmpty else { return }

        // Delegate callbacks are serialized ahead of this operation. The two
        // barriers also include persistence queued while reconciliation runs.
        await awaitPersistenceBarrier()
        reconcileCompletedRecordsAfterDelegateDrain()
        await awaitPersistenceBarrier()

        let handlers = backgroundCompletionHandlers
        backgroundCompletionHandlers.removeAll()
        backgroundEventsDidFinish = false
        handlers.forEach { $0() }
    }
}
