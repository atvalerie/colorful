import Foundation
import SwiftUI
import UIKit

/// Keeps a bounded, shareable copy of the native playback diagnostics.
///
/// The file intentionally receives already-redacted event descriptions from
/// the provider and playback layers. It never stores cookies, authorization
/// headers, visitor data, or URL query values.
final class ColorfulDiagnostics: @unchecked Sendable {
    static let shared = ColorfulDiagnostics()

    let logURL: URL

    private let queue = DispatchQueue(label: "sh.valerie.colorful.diagnostics")
    private let maximumBytes = 4 * 1024 * 1024

    private init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directory = applicationSupport.appendingPathComponent("Colorful", isDirectory: true)
        logURL = directory.appendingPathComponent("diagnostics.log")
    }

    func append(category: String, message: String) {
        queue.sync {
            do {
                try ensureDirectory()
                let formatter = ISO8601DateFormatter()
                let line = "\(formatter.string(from: Date())) [\(category)] \(redacted(message))\n"
                var data = (try? Data(contentsOf: logURL)) ?? Data()
                data.append(Data(line.utf8))
                if data.count > maximumBytes {
                    data = Data(data.suffix(maximumBytes))
                }
                try data.write(to: logURL, options: .atomic)
            } catch {
                // Unified logging remains available if the app container is
                // temporarily unavailable or the file cannot be written.
            }
        }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    func exportURL() throws -> URL {
        try queue.sync {
            try ensureDirectory()
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try Data().write(to: logURL, options: .atomic)
            }
            let exportURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("colorful-ios-diagnostics-\(UUID().uuidString).log")
            try FileManager.default.copyItem(at: logURL, to: exportURL)
            return exportURL
        }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func redacted(_ message: String) -> String {
        var result = message
        if let urlExpression = try? NSRegularExpression(pattern: #"https?://[^\s]+"#) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            for match in urlExpression.matches(in: result, range: range).reversed() {
                guard let matchRange = Range(match.range, in: result),
                      let url = URL(string: String(result[matchRange])),
                      let scheme = url.scheme,
                      let host = url.host else { continue }
                let safeURL = "\(scheme)://\(host)\(url.path)"
                result.replaceSubrange(matchRange, with: safeURL)
            }
        }
        if let valueExpression = try? NSRegularExpression(
            pattern: #"(?i)(poToken|visitorData|authorization|cookie|token|signature|sig|lsig|pot|ump|n)=((?!(?:true|false)(?:\s|$))\S+)"#
        ) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = valueExpression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1=<redacted>"
            )
        }
        return result
    }
}

@MainActor
final class ColorfulApplicationServices {
    static let shared = ColorfulApplicationServices()

    let playback: PlaybackStore
    let tidal: TidalAccountStore
    let offlineDownloads: IOSOfflineDownloadManager

    private init() {
        let playback = PlaybackStore()
        let tidal = TidalAccountStore(core: playback.core)
        self.playback = playback
        self.tidal = tidal
        offlineDownloads = IOSOfflineDownloadManager(store: playback, account: tidal)
    }
}

@MainActor
final class ColorfulAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // This creates the sole background asset-download session before a
        // SwiftUI scene or ColorfulRootView is required.
        ColorfulApplicationServices.shared.offlineDownloads.start()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == IOSOfflineDownloadManager.backgroundSessionIdentifier else {
            completionHandler()
            return
        }

        let downloads = ColorfulApplicationServices.shared.offlineDownloads
        downloads.handleBackgroundEvents(
            for: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct ColorfulApp: App {
    @UIApplicationDelegateAdaptor(ColorfulAppDelegate.self) private var appDelegate
    @StateObject private var playback: PlaybackStore
    @StateObject private var tidal: TidalAccountStore

    init() {
        let services = ColorfulApplicationServices.shared
        _playback = StateObject(wrappedValue: services.playback)
        _tidal = StateObject(wrappedValue: services.tidal)
    }

    var body: some Scene {
        WindowGroup {
            ColorfulRootView(store: playback, account: tidal)
        }
    }
}
