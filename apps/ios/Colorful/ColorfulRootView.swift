import SwiftUI

struct ColorfulRootView: View {
    @ObservedObject var store: PlaybackStore
    @State private var isShowingPlayer = false

    var body: some View {
        TabView(selection: $store.selectedTab) {
            NavigationStack {
                HomeView(store: store)
            }
            .tabItem { Label(ColorfulTab.home.title, systemImage: ColorfulTab.home.symbol) }
            .tag(ColorfulTab.home)

            NavigationStack {
                LibraryView(store: store)
            }
            .tabItem { Label(ColorfulTab.library.title, systemImage: ColorfulTab.library.symbol) }
            .tag(ColorfulTab.library)

            NavigationStack {
                OfflineView()
            }
            .tabItem { Label(ColorfulTab.offline.title, systemImage: ColorfulTab.offline.symbol) }
            .tag(ColorfulTab.offline)

            NavigationStack {
                SettingsView(store: store)
            }
            .tabItem { Label(ColorfulTab.settings.title, systemImage: ColorfulTab.settings.symbol) }
            .tag(ColorfulTab.settings)
        }
        .tint(ColorfulTheme.accent)
        .task {
            await store.refreshFromCore()
        }
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let track = store.currentTrack {
                MiniPlayer(track: track, isPlaying: store.isPlaying) {
                    store.togglePlayback()
                } onExpand: {
                    isShowingPlayer = true
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
        }
        .sheet(isPresented: $isShowingPlayer) {
            if let track = store.currentTrack {
                FullPlayer(track: track, isPlaying: store.isPlaying) {
                    store.togglePlayback()
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

private struct HomeView: View {
    @ObservedObject var store: PlaybackStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ColorfulSurface(fill: ColorfulTheme.surfaceRaised) {
                    HStack(spacing: 14) {
                        Image(systemName: "bolt.fill")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(ColorfulTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.core.availability.label)
                                .font(.headline)
                                .foregroundStyle(ColorfulTheme.ink)
                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(ColorfulTheme.mutedInk)
                        }
                        Spacer(minLength: 0)
                        Circle()
                            .fill(store.core.isReady && store.coreError == nil ? ColorfulTheme.accentSecondary : ColorfulTheme.warning)
                            .frame(width: 10, height: 10)
                    }
                    .padding(16)
                }

                Text(store.queueTracks.isEmpty ? "Library" : "Queue")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(ColorfulTheme.ink)

                if store.homeTracks.isEmpty {
                    ColorfulSurface {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("No tracks yet", systemImage: "music.note.list")
                                .font(.headline)
                                .foregroundStyle(ColorfulTheme.ink)
                            Text("Connect a provider to start building your library.")
                                .font(.subheadline)
                                .foregroundStyle(ColorfulTheme.mutedInk)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(store.homeTracks.enumerated()), id: \.offset) { item in
                            TrackRow(track: item.element) {
                                store.play(item.element)
                            } enqueue: {
                                store.enqueue(item.element)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .background(ColorfulTheme.background.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("colorful")
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .foregroundStyle(ColorfulTheme.accent)
                        .textCase(.uppercase)
                    Text("Good evening.")
                        .font(.system(.headline, design: .rounded).weight(.black))
                        .foregroundStyle(ColorfulTheme.ink)
                }
                .fixedSize()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {}) {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search")
            }
        }
    }

    private var statusText: String {
        if let coreError = store.coreError {
            return coreError
        }
        guard store.coreSnapshot != nil else {
            return "Waiting for snapshot"
        }
        return "\(store.libraryTracks.count) saved · \(store.queueTracks.count) queued"
    }
}

private struct TrackRow: View {
    let track: CoreTrack
    let play: () -> Void
    let enqueue: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                ColorfulAlbumArt(title: track.title, accent: track.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ColorfulTheme.ink)
                        .lineLimit(1)
                    Text("\(track.artistLabel) · \(track.albumLabel)")
                        .font(.caption)
                        .foregroundStyle(ColorfulTheme.mutedInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(track.durationLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ColorfulTheme.mutedInk)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play", systemImage: "play.fill") { play() }
            Button("Add to queue", systemImage: "text.line.first.and.arrowtriangle.forward") { enqueue() }
        }
    }
}

private struct LibraryView: View {
    @ObservedObject var store: PlaybackStore

    var body: some View {
        List {
            if !store.libraryTracks.isEmpty {
                Section("Saved tracks") {
                    ForEach(store.libraryTracks) { track in
                        TrackRow(track: track) {
                            store.play(track)
                        } enqueue: {
                            store.enqueue(track)
                        }
                        .listRowBackground(ColorfulTheme.surface)
                    }
                }
            } else {
                Section {
                    Label("No saved tracks yet", systemImage: "music.note.list")
                        .foregroundStyle(ColorfulTheme.mutedInk)
                        .listRowBackground(ColorfulTheme.surface)
                }
            }

            if !store.queueTracks.isEmpty {
                Section("Queue") {
                    ForEach(Array(store.queueTracks.enumerated()), id: \.offset) { item in
                        TrackRow(track: item.element) {
                            store.play(item.element)
                        } enqueue: {
                            store.enqueue(item.element)
                        }
                        .listRowBackground(ColorfulTheme.surface)
                    }
                }
            }

            if let coreError = store.coreError {
                Section("Engine") {
                    Label(coreError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(ColorfulTheme.warning)
                        .listRowBackground(ColorfulTheme.surface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ColorfulTheme.background.ignoresSafeArea())
        .navigationTitle("Library")
    }
}

private struct OfflineView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Nothing offline yet", systemImage: "arrow.down.circle")
        } description: {
            Text("Downloads will be available after the first TIDAL playback slice is connected.")
        }
        .foregroundStyle(ColorfulTheme.mutedInk)
        .background(ColorfulTheme.background.ignoresSafeArea())
        .navigationTitle("Offline")
    }
}

private struct SettingsView: View {
    @ObservedObject var store: PlaybackStore
    @AppStorage("appearance.accent") private var useMintAccent = false

    var body: some View {
        Form {
            Section("Playback") {
                LabeledContent("Engine", value: store.core.availability.label)
                LabeledContent("Audio session", value: "Not connected yet")
            }
            Section("Appearance") {
                Toggle("Mint accent", isOn: $useMintAccent)
                Text("The iOS shell keeps Colorful's dark block surfaces while native controls provide the system glass layer.")
                    .font(.footnote)
                    .foregroundStyle(ColorfulTheme.mutedInk)
            }
            Section("About") {
                LabeledContent("Build", value: "iOS shell 0.1")
                LabeledContent("Core ABI", value: "v1")
            }
        }
        .scrollContentBackground(.hidden)
        .background(ColorfulTheme.background.ignoresSafeArea())
        .navigationTitle("Settings")
    }
}

private struct MiniPlayer: View {
    let track: CoreTrack
    let isPlaying: Bool
    let onPlayPause: () -> Void
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onExpand) {
                HStack(spacing: 10) {
                    ColorfulAlbumArt(title: track.title, accent: track.accent, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ColorfulTheme.ink)
                            .lineLimit(1)
                        Text(track.artistLabel)
                            .font(.caption)
                            .foregroundStyle(ColorfulTheme.mutedInk)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open player for \(track.title)")
            Spacer(minLength: 0)
            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .foregroundStyle(ColorfulTheme.ink)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
        }
        .padding(8)
        .colorfulNativeGlass()
    }
}

private struct FullPlayer: View {
    let track: CoreTrack
    let isPlaying: Bool
    let onPlayPause: () -> Void

    var body: some View {
        ZStack {
            ColorfulTheme.background.ignoresSafeArea()
            VStack(spacing: 28) {
                ColorfulAlbumArt(title: track.title, accent: track.accent, size: 280)
                    .shadow(color: Color(hex: track.accent).opacity(0.35), radius: 28, x: 8, y: 8)
                VStack(spacing: 6) {
                    Text(track.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(ColorfulTheme.ink)
                    Text("\(track.artistLabel) · \(track.albumLabel)")
                        .font(.subheadline)
                        .foregroundStyle(ColorfulTheme.mutedInk)
                }
                ProgressView(value: 0.34)
                    .tint(ColorfulTheme.accent)
                HStack(spacing: 34) {
                    Button(action: {}) { Image(systemName: "backward.fill") }
                    Button(action: onPlayPause) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 58))
                    }
                    Button(action: {}) { Image(systemName: "forward.fill") }
                }
                .foregroundStyle(ColorfulTheme.ink)
            }
            .padding(24)
        }
    }
}
