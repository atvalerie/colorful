import SwiftUI
import UIKit

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
