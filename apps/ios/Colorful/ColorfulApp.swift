import SwiftUI

@main
struct ColorfulApp: App {
    @StateObject private var playback: PlaybackStore
    @StateObject private var tidal: TidalAccountStore

    init() {
        let playback = PlaybackStore()
        _playback = StateObject(wrappedValue: playback)
        _tidal = StateObject(wrappedValue: TidalAccountStore(core: playback.core))
    }

    var body: some Scene {
        WindowGroup {
            ColorfulRootView(store: playback, account: tidal)
        }
    }
}
