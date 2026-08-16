import SwiftUI

enum ColorfulTab: String, CaseIterable, Hashable {
    case home
    case library
    case offline
    case settings

    var title: String {
        rawValue.capitalized
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "books.vertical.fill"
        case .offline: return "arrow.down.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct DemoTrack: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: String
    let accent: UInt32
}

@MainActor
final class PlaybackStore: ObservableObject {
    @Published var selectedTab: ColorfulTab = .home
    @Published var currentTrack: DemoTrack?
    @Published var isPlaying = false

    let core: ColorfulCoreBridge

    let recommendations = [
        DemoTrack(id: "tidal-demo-1", title: "Soft Focus", artist: "Colorful Radio", album: "Night Routes", duration: "3:42", accent: 0xFF5C9A),
        DemoTrack(id: "tidal-demo-2", title: "Afterimage", artist: "Mira Vale", album: "Afterimage", duration: "4:08", accent: 0x7DE2D1),
        DemoTrack(id: "tidal-demo-3", title: "Low Orbit", artist: "North Arcade", album: "Low Orbit", duration: "2:57", accent: 0xFFC857),
        DemoTrack(id: "tidal-demo-4", title: "Window Seat", artist: "Aster Bloom", album: "Window Seat", duration: "3:15", accent: 0xA18CFF),
    ]

    init() {
        core = ColorfulCoreBridge()
    }

    func play(_ track: DemoTrack) {
        currentTrack = track
        isPlaying = true
    }

    func togglePlayback() {
        guard currentTrack != nil else {
            play(recommendations[0])
            return
        }
        isPlaying.toggle()
        let command = isPlaying ? #"{"command":"play"}"# : #"{"command":"pause"}"#
        Task {
            _ = await core.dispatch(commandJSON: command)
        }
    }

    func stop() {
        isPlaying = false
        Task {
            _ = await core.dispatch(commandJSON: #"{"command":"stop"}"#)
        }
    }
}
