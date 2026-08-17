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
        return resolvedLocalURL(forStoredPath: path)
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
        if let path = job(for: track)?.localPath,
           let localURL = resolvedLocalURL(forStoredPath: path) {
            try? FileManager.default.removeItem(at: localURL)
        }
        try? FileManager.default.removeItem(at: exportURL(for: track, extension: "m4a"))
        try? FileManager.default.removeItem(at: exportURL(for: track, extension: "flac"))
        store.removeDownload(track.id)
        message = "Removed the offline copy of \(track.title)."
    }

    func prepareShareableExport(for track: CoreTrack) async throws -> IOSOfflineExport {
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
        message = nil
    }

    private func startDownload(_ track: CoreTrack, preserveProgress: Bool) {
        guard tasksByTrack[track.id] == nil,
              resolutionTasks[track.id] == nil else { return }
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

    private nonisolated static var usesStandaloneContainerDownload: Bool {
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path.lowercased()
        return bundlePath.contains("/documents/applications/")
            || bundlePath.contains("/applications/sh.valerie.colorful")
    }

    private nonisolated static func containerStagingURL(taskID: Int) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Colorful", isDirectory: true)
            .appendingPathComponent("OfflineStaging", isDirectory: true)
            .appendingPathComponent("asset-\(taskID).movpkg", isDirectory: true)
    }

    private func finalizeContainerPackage(at packageURL: URL, track: CoreTrack) async {
        defer { try? FileManager.default.removeItem(at: packageURL) }
        do {
            let asset = AVURLAsset(url: packageURL)
            let lossless = try await isLossless(asset: asset)
            let destination = exportURL(for: track, extension: lossless ? "flac" : "m4a")
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            if lossless {
                try await Self.writeFLAC(from: packageURL, to: destination)
            } else {
                guard try await asset.load(.isExportable) else {
                    throw IOSOfflineExportError.notExportable
                }
                try await writeM4A(asset: asset, track: track, destination: destination)
            }
            let size = sizeOfItem(at: destination)
            persist(track: track, state: .complete, localURL: destination, size: size)
            progressByTrack[track.id] = 1
            message = "\(track.title) is ready offline."
        } catch {
            persist(track: track, state: .failed, errorCode: "container_finalize_failed", preserveProgress: false)
            message = "Could not finalize \(track.title): \(error.localizedDescription)"
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
            localPath: localURL.map(portableStoredPath),
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

    private func portableStoredPath(for url: URL) -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        let relative = String(path.dropFirst(home.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "~/" : "~/\(relative)"
    }

    private func resolvedLocalURL(forStoredPath path: String) -> URL? {
        let fileManager = FileManager.default
        let directURL = URL(fileURLWithPath: path).standardizedFileURL
        if fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }

        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if path.hasPrefix("~/") {
            let candidate = home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
            return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
        }

        // App installs and sideloading containers can replace the absolute
        // sandbox UUID while preserving Library/Documents. Rebase legacy paths
        // onto the current home directory rather than discarding the job.
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
        var durableLocation = location
        var stagingError: String?
        if Self.usesStandaloneContainerDownload {
            let stagingURL = Self.containerStagingURL(taskID: taskID)
            do {
                try FileManager.default.createDirectory(
                    at: stagingURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(at: stagingURL)
                try FileManager.default.copyItem(at: location, to: stagingURL)
                durableLocation = stagingURL
            } catch {
                stagingError = error.localizedDescription
            }
        }
        Task { @MainActor [weak self] in
            guard let self, let id = mediaID(from: description),
                  let track = tracksByID[id] ?? store.downloadItems.first(where: { $0.id == id })?.track else { return }
            if let stagingError {
                persist(track: track, state: .failed, errorCode: "container_copy_failed", preserveProgress: false)
                message = "Could not retain \(track.title) inside LiveContainer: \(stagingError)"
                return
            }
            completedLocations[taskID] = durableLocation
            if Self.usesStandaloneContainerDownload {
                message = "Finalizing \(track.title)… Keep colorful open."
                await finalizeContainerPackage(at: durableLocation, track: track)
            } else {
                let size = sizeOfItem(at: durableLocation)
                persist(track: track, state: .complete, localURL: durableLocation, size: size)
                progressByTrack[id] = 1
                message = "\(track.title) is ready offline."
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
