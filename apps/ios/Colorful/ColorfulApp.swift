import SwiftUI

@main
struct ColorfulApp: App {
    @StateObject private var playback = PlaybackStore()

    var body: some Scene {
        WindowGroup {
            ColorfulRootView(store: playback)
        }
    }
}
