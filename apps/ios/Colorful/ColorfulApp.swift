import SwiftUI

@main
struct ColorfulApp: App {
    @StateObject private var playback = PlaybackStore()
    @StateObject private var tidal = TidalAccountStore()

    var body: some Scene {
        WindowGroup {
            ColorfulRootView(store: playback, account: tidal)
        }
    }
}
