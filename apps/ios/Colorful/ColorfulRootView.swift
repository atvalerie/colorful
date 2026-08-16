import AVKit
import SwiftUI

struct ColorfulRootView: View {
    @ObservedObject var store: PlaybackStore
    @ObservedObject var account: TidalAccountStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playbackService: IOSPlaybackService
    @State private var isShowingPlayer = false

    init(store: PlaybackStore, account: TidalAccountStore) {
        self.store = store
        self.account = account
        _playbackService = StateObject(wrappedValue: IOSPlaybackService(store: store, account: account))
    }

    var body: some View {
        TabView(selection: $store.selectedTab) {
            NavigationStack {
                HomeView(store: store, account: account)
            }
            .safeAreaInset(edge: .bottom, spacing: 8) {
                miniPlayerInset
            }
            .tabItem { Label(ColorfulTab.home.title, systemImage: ColorfulTab.home.symbol) }
            .tag(ColorfulTab.home)

            NavigationStack {
                LibraryView(store: store)
            }
            .safeAreaInset(edge: .bottom, spacing: 8) {
                miniPlayerInset
            }
            .tabItem { Label(ColorfulTab.library.title, systemImage: ColorfulTab.library.symbol) }
            .tag(ColorfulTab.library)

            NavigationStack {
                OfflineView()
            }
            .safeAreaInset(edge: .bottom, spacing: 8) {
                miniPlayerInset
            }
            .tabItem { Label(ColorfulTab.offline.title, systemImage: ColorfulTab.offline.symbol) }
            .tag(ColorfulTab.offline)

            NavigationStack {
                SettingsView(store: store, account: account)
            }
            .safeAreaInset(edge: .bottom, spacing: 8) {
                miniPlayerInset
            }
            .tabItem { Label(ColorfulTab.settings.title, systemImage: ColorfulTab.settings.symbol) }
            .tag(ColorfulTab.settings)
        }
        .tint(ColorfulTheme.accent)
        .task {
            playbackService.start()
            account.appBecameActive()
            await playbackService.reconcileAfterActivation()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                account.appBecameActive()
                Task { @MainActor in
                    await playbackService.reconcileAfterActivation()
                }
            case .background, .inactive:
                account.appBecameInactive()
                playbackService.appBecameInactive()
            @unknown default:
                break
            }
        }
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .sheet(isPresented: $isShowingPlayer) {
            if let track = store.currentTrack {
                FullPlayer(
                    store: store,
                    track: track,
                    isPlaying: store.effectiveIsPlaying,
                    positionMs: store.positionMs,
                    shuffleEnabled: store.isShuffleEnabled,
                    repeatMode: store.repeatMode,
                    canSkipPrevious: store.canSkipPrevious,
                    canSkipNext: store.canSkipNext,
                    isBuffering: playbackService.isBuffering,
                    playbackError: playbackService.errorMessage,
                    onSeek: { playbackService.seek(to: $0) },
                    onPrevious: { playbackService.skipPrevious() },
                    onPlayPause: { playbackService.togglePlayback() },
                    onNext: { playbackService.skipNext() },
                    onShuffle: { store.toggleShuffle() },
                    onRepeat: { store.cycleRepeat() },
                    onRetry: { playbackService.retryCurrentTrack() }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private var miniPlayerInset: some View {
        if let track = store.currentTrack {
            MiniPlayer(
                track: track,
                isPlaying: store.effectiveIsPlaying,
                isBuffering: playbackService.isBuffering
            ) {
                playbackService.togglePlayback()
            } onExpand: {
                isShowingPlayer = true
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }
}

private struct HomeView: View {
    @ObservedObject var store: PlaybackStore
    @ObservedObject var account: TidalAccountStore
    @State private var isShowingSearch = false

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
                            } playNext: {
                                store.playNext(item.element)
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
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HomeHeader(greeting: greeting) {
                isShowingSearch = true
            }
        }
        .sheet(isPresented: $isShowingSearch) {
            SearchView(account: account, store: store) { track in
                store.play(track)
                isShowingSearch = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning."
        case 12..<18: return "Good afternoon."
        default: return "Good evening."
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

private struct HomeHeader: View {
    let greeting: String
    let onSearch: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text("colorful")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .foregroundStyle(ColorfulTheme.accent)
                    .textCase(.uppercase)
                Text(greeting)
                    .font(.system(.headline, design: .rounded).weight(.black))
                    .foregroundStyle(ColorfulTheme.ink)
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(ColorfulTheme.ink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial, in: Circle())
            .accessibilityLabel("Search")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ColorfulTheme.border)
                .frame(height: 1)
        }
    }
}

private struct TrackRow: View {
    let track: CoreTrack
    let play: () -> Void
    let enqueue: () -> Void
    let playNext: () -> Void

    var body: some View {
        Button(action: play) {
            TrackRowContent(track: track)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play", systemImage: "play.fill") { play() }
            Button("Play next", systemImage: "text.insert") { playNext() }
            Button("Add to queue", systemImage: "text.line.first.and.arrowtriangle.forward") { enqueue() }
        }
    }
}

private struct TrackRowContent: View {
    let track: CoreTrack

    var body: some View {
        HStack(spacing: 12) {
            ColorfulAlbumArt(
                title: track.title,
                accent: track.accent,
                artworkURL: track.artwork?.url
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ColorfulTheme.ink)
                    .lineLimit(1)
                Text("\(track.compactArtistLabel) · \(track.albumLabel)")
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
}

private struct SearchView: View {
    @ObservedObject var account: TidalAccountStore
    @ObservedObject var store: PlaybackStore
    let onPlay: (CoreTrack) -> Void

    @State private var query = ""
    @State private var results: [CoreTrack] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(ColorfulTheme.mutedInk)
                    TextField("Search TIDAL", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isSearchFocused)
                        .onSubmit(search)
                    if !query.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill") {
                            query = ""
                            results = []
                            errorMessage = nil
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(ColorfulTheme.mutedInk)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(ColorfulTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: ColorfulTheme.cardRadius, style: .continuous))

                if isSearching {
                    ProgressView("Searching…")
                        .tint(ColorfulTheme.accent)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Search failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    }
                } else if results.isEmpty {
                    ContentUnavailableView {
                        Label("Search TIDAL", systemImage: "music.magnifyingglass")
                    } description: {
                        Text("Search for a track, artist, or album.")
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(results) { track in
                                SearchResultRow(track: track, account: account, store: store, onPlay: onPlay)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(ColorfulTheme.background.ignoresSafeArea())
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Search", systemImage: "arrow.right") {
                        search()
                    }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                }
            }
        }
        .task {
            isSearchFocused = true
        }
    }

    private func search() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isSearching else { return }
        isSearching = true
        errorMessage = nil
        Task {
            do {
                results = try await account.searchTracks(query: value, core: store.core)
            } catch {
                results = []
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }
}

private struct SearchResultRow: View {
    let track: CoreTrack
    @ObservedObject var account: TidalAccountStore
    @ObservedObject var store: PlaybackStore
    let onPlay: (CoreTrack) -> Void

    var body: some View {
        if let albumID = track.albumID?.providerID {
            NavigationLink {
                AlbumCollectionView(albumID: albumID, account: account, store: store)
            } label: {
                TrackRowContent(track: track)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Play", systemImage: "play.fill") { onPlay(track) }
                Button("Play next", systemImage: "text.insert") {
                    store.playNext(track)
                }
                Button("Add to queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    store.enqueue(track)
                }
            }
        } else {
            TrackRow(track: track) {
                onPlay(track)
            } enqueue: {
                store.enqueue(track)
            } playNext: {
                store.playNext(track)
            }
        }
    }
}

private struct AlbumCollectionView: View {
    let albumID: String
    @ObservedObject var account: TidalAccountStore
    @ObservedObject var store: PlaybackStore
    @State private var collection: TidalAlbumCollection?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @StateObject private var paletteLoader = ColorfulArtworkPaletteLoader()

    var body: some View {
        ZStack {
            ColorfulCollectionBackground(palette: paletteLoader.palette)
            Group {
                if isLoading {
                    ProgressView("Loading album…")
                        .tint(ColorfulTheme.accent)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Album unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    }
                } else if let collection {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 12) {
                                ColorfulAlbumArt(
                                    title: collection.title,
                                    accent: 0xFF5C9A,
                                    artworkURL: collection.artworkURL,
                                    size: 220
                                )
                                Text(collection.title)
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(ColorfulTheme.ink)
                                    .lineLimit(2)
                                Text(collection.artistLabel)
                                    .font(.subheadline)
                                    .foregroundStyle(ColorfulTheme.mutedInk)
                                    .lineLimit(2)
                                Button("Play album", systemImage: "play.fill") {
                                    store.playTracks(collection.tracks)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(paletteLoader.palette.primaryColor)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            LazyVStack(spacing: 10) {
                                ForEach(collection.tracks) { track in
                                    TrackRow(track: track) {
                                        store.play(track)
                                    } enqueue: {
                                        store.enqueue(track)
                                    } playNext: {
                                        store.playNext(track)
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorfulTheme.background.ignoresSafeArea())
        .navigationTitle(collection?.title ?? "Album")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
        .task(id: collection?.artworkURL) {
            paletteLoader.load(for: collection?.artworkURL)
        }
    }

    private func load() async {
        guard collection == nil else { return }
        do {
            collection = try await account.loadAlbum(albumID: albumID, core: store.core)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
                        } playNext: {
                            store.playNext(track)
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
                        } playNext: {
                            store.playNext(item.element)
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
    @ObservedObject var account: TidalAccountStore
    @AppStorage("appearance.accent") private var useMintAccent = false

    var body: some View {
        Form {
            Section("Playback") {
                LabeledContent("Engine", value: store.core.availability.label)
                LabeledContent("Audio session", value: "Not connected yet")
            }
            Section("TIDAL") {
                if account.isLinked {
                    LabeledContent("Status", value: "Connected")
                    LabeledContent("Country", value: account.countryCode)
                    LabeledContent("Email", value: account.email ?? "Loading…")
                    Button("Disconnect TIDAL", role: .destructive) {
                        account.unlink()
                    }
                } else {
                    Button(account.isBusy ? "Waiting for TIDAL…" : "Connect TIDAL") {
                        account.startLink()
                    }
                    .disabled(account.isBusy)
                }

                if let pending = account.pendingAuthorization {
                    if let url = URL(string: pending.authorization.verificationURL) {
                        Link(destination: url) {
                            Label("Open TIDAL authorization URL", systemImage: "arrow.up.right.square")
                        }
                    }
                    Text("This is a link URL. It opens TIDAL in Safari; return to colorful after approving the device.")
                        .font(.footnote)
                        .foregroundStyle(ColorfulTheme.mutedInk)
                    Text("Code: \(pending.authorization.userCode)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(ColorfulTheme.mutedInk)
                    Text(pending.authorization.verificationURL)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(ColorfulTheme.mutedInk)
                }

                if let message = account.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(ColorfulTheme.mutedInk)
                }
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
    let isBuffering: Bool
    let onPlayPause: () -> Void
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onExpand) {
                HStack(spacing: 10) {
                    ColorfulAlbumArt(
                        title: track.title,
                        accent: track.accent,
                        artworkURL: track.artwork?.url,
                        size: 40
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ColorfulTheme.ink)
                            .lineLimit(1)
                        Text(track.compactArtistLabel)
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
                Group {
                    if isBuffering {
                        ProgressView().tint(ColorfulTheme.ink)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.headline)
                            .foregroundStyle(ColorfulTheme.ink)
                    }
                }
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel(isBuffering ? "Buffering, pause playback" : (isPlaying ? "Pause" : "Play"))
        }
        .padding(8)
        .colorfulNativeGlass()
    }
}

private struct FullPlayer: View {
    @ObservedObject var store: PlaybackStore
    let track: CoreTrack
    let isPlaying: Bool
    let positionMs: UInt64
    let shuffleEnabled: Bool
    let repeatMode: CoreRepeatMode
    let canSkipPrevious: Bool
    let canSkipNext: Bool
    let isBuffering: Bool
    let playbackError: String?
    let onSeek: (UInt64) -> Void
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onShuffle: () -> Void
    let onRepeat: () -> Void
    let onRetry: () -> Void
    @StateObject private var paletteLoader: ColorfulArtworkPaletteLoader
    @State private var scrubPosition = 0.0
    @State private var isScrubbing = false
    @State private var isShowingQueue = false

    init(
        store: PlaybackStore,
        track: CoreTrack,
        isPlaying: Bool,
        positionMs: UInt64,
        shuffleEnabled: Bool,
        repeatMode: CoreRepeatMode,
        canSkipPrevious: Bool,
        canSkipNext: Bool,
        isBuffering: Bool,
        playbackError: String?,
        onSeek: @escaping (UInt64) -> Void,
        onPrevious: @escaping () -> Void,
        onPlayPause: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onShuffle: @escaping () -> Void,
        onRepeat: @escaping () -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.store = store
        self.track = track
        self.isPlaying = isPlaying
        self.positionMs = positionMs
        self.shuffleEnabled = shuffleEnabled
        self.repeatMode = repeatMode
        self.canSkipPrevious = canSkipPrevious
        self.canSkipNext = canSkipNext
        self.isBuffering = isBuffering
        self.playbackError = playbackError
        self.onSeek = onSeek
        self.onPrevious = onPrevious
        self.onPlayPause = onPlayPause
        self.onNext = onNext
        self.onShuffle = onShuffle
        self.onRepeat = onRepeat
        self.onRetry = onRetry
        _paletteLoader = StateObject(wrappedValue: ColorfulArtworkPaletteLoader())
    }

    private var durationSeconds: Double {
        max(Double(track.durationMs ?? 1_000) / 1_000, 1)
    }

    private var elapsedLabel: String {
        let totalSeconds = Int(isScrubbing ? scrubPosition : Double(positionMs) / 1_000)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private var remainingLabel: String {
        let currentSeconds = isScrubbing ? scrubPosition : Double(positionMs) / 1_000
        let remaining = max(0, Int(durationSeconds - currentSeconds))
        return String(format: "-%d:%02d", remaining / 60, remaining % 60)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ColorfulArtworkBackground(palette: paletteLoader.palette, image: paletteLoader.image)
                ScrollView {
                    VStack(spacing: 22) {
                        ColorfulAlbumArt(
                            title: track.title,
                            accent: track.accent,
                            artworkURL: track.artwork?.url,
                            size: artworkSize(in: proxy.size)
                        )
                        .padding(.top, 8)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(ColorfulTheme.ink)
                                .lineLimit(2)
                            Text(track.compactArtistLabel)
                                .font(.body)
                                .foregroundStyle(ColorfulTheme.ink.opacity(0.78))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if track.albumLabel != "Single" {
                                Text(track.albumLabel)
                                    .font(.caption)
                                    .foregroundStyle(ColorfulTheme.mutedInk)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(spacing: 2) {
                            Slider(
                                value: $scrubPosition,
                                in: 0...durationSeconds,
                                onEditingChanged: { editing in
                                    isScrubbing = editing
                                    if !editing {
                                        onSeek(UInt64(scrubPosition * 1_000))
                                    }
                                }
                            )
                            .tint(paletteLoader.palette.primaryColor)
                            HStack {
                                Text(elapsedLabel)
                                Spacer()
                                Text(remainingLabel)
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ColorfulTheme.ink.opacity(0.62))
                        }
                        .onAppear {
                            scrubPosition = min(Double(positionMs) / 1_000, durationSeconds)
                        }
                        .onChange(of: positionMs) { _, newPosition in
                            guard !isScrubbing else { return }
                            scrubPosition = min(Double(newPosition) / 1_000, durationSeconds)
                        }

                        HStack {
                            transportButton(
                                symbol: "backward.fill",
                                label: "Previous",
                                enabled: canSkipPrevious,
                                action: onPrevious
                            )
                            Spacer()
                            Button(action: onPlayPause) {
                                ZStack {
                                    Circle().fill(ColorfulTheme.ink)
                                    if isBuffering {
                                        ProgressView().tint(.black)
                                    } else {
                                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: 25, weight: .bold))
                                            .foregroundStyle(.black)
                                            .offset(x: isPlaying ? 0 : 1)
                                    }
                                }
                                .frame(width: 66, height: 66)
                            }
                            .accessibilityLabel(isBuffering ? "Buffering, pause playback" : (isPlaying ? "Pause" : "Play"))
                            Spacer()
                            transportButton(
                                symbol: "forward.fill",
                                label: "Next",
                                enabled: canSkipNext,
                                action: onNext
                            )
                        }
                        .padding(.horizontal, 22)

                        if let playbackError {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text(playbackError)
                                    .font(.footnote)
                                    .lineLimit(2)
                                Spacer(minLength: 4)
                                Button("Retry", action: onRetry)
                                    .font(.footnote.weight(.semibold))
                            }
                            .foregroundStyle(ColorfulTheme.ink)
                            .padding(12)
                            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
                        }

                        HStack {
                            utilityButton(
                                symbol: shuffleEnabled ? "shuffle.circle.fill" : "shuffle",
                                label: shuffleEnabled ? "Disable shuffle" : "Enable shuffle",
                                active: shuffleEnabled,
                                action: onShuffle
                            )
                            Spacer()
                            IOSRoutePicker()
                                .frame(width: 48, height: 48)
                            Spacer()
                            utilityButton(
                                symbol: "list.bullet",
                                label: "Open queue",
                                action: { isShowingQueue = true }
                            )
                            Spacer()
                            utilityButton(
                                symbol: repeatMode.symbol,
                                label: repeatMode.label,
                                active: repeatMode != .off,
                                action: onRepeat
                            )
                        }
                        .padding(.horizontal, 8)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(minHeight: proxy.size.height)
                }
                .scrollIndicators(.hidden)
            }
        }
        .task(id: track.artwork?.url) {
            paletteLoader.load(for: track.artwork?.url)
        }
        .sheet(isPresented: $isShowingQueue) {
            QueueView(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(ColorfulTheme.background)
        }
    }

    private func artworkSize(in size: CGSize) -> CGFloat {
        min(max(190, size.height * 0.37), min(340, size.width - 64))
    }

    private func transportButton(
        symbol: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 56, height: 56)
        }
        .foregroundStyle(ColorfulTheme.ink)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.32)
        .accessibilityLabel(label)
    }

    private func utilityButton(
        symbol: String,
        label: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 48, height: 48)
        }
        .foregroundStyle(active ? paletteLoader.palette.primaryColor : ColorfulTheme.ink.opacity(0.72))
        .accessibilityLabel(label)
    }
}

private struct IOSRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = UIColor(ColorfulTheme.accent)
        picker.prioritizesVideoDevices = false
        picker.accessibilityLabel = "Choose audio output"
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

private struct QueueView: View {
    @ObservedObject var store: PlaybackStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.queueItems.isEmpty {
                    ContentUnavailableView {
                        Label("Queue is empty", systemImage: "text.line.first.and.arrowtriangle.forward")
                    } description: {
                        Text("Play a track or add one to the queue to see it here.")
                    }
                } else {
                    List {
                        Section {
                            HStack {
                                Label(
                                    store.isShuffleEnabled ? "Shuffle on" : "Shuffle off",
                                    systemImage: store.isShuffleEnabled ? "shuffle.circle.fill" : "shuffle"
                                )
                                Spacer()
                                Button(action: store.toggleShuffle) {
                                    Text(store.isShuffleEnabled ? "Turn off" : "Turn on")
                                }
                            }
                            .foregroundStyle(store.isShuffleEnabled ? ColorfulTheme.accent : ColorfulTheme.mutedInk)

                            Button(action: store.cycleRepeat) {
                                Label(store.repeatMode.label, systemImage: store.repeatMode.symbol)
                            }
                            .foregroundStyle(ColorfulTheme.mutedInk)
                        }

                        Section {
                            ForEach(store.queueItems) { item in
                                Button {
                                    store.selectQueueEntry(item.entry.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        TrackRowContent(track: item.track)
                                        if store.currentQueueEntryID == item.entry.id {
                                            Image(systemName: store.effectiveIsPlaying ? "speaker.wave.2.fill" : "pause.fill")
                                                .foregroundStyle(ColorfulTheme.accent)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        store.removeQueueEntry(item.entry.id)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                            .onMove { offsets, destination in
                                guard let source = offsets.first,
                                      store.queueItems.indices.contains(source) else { return }
                                let target = destination > source ? destination - 1 : destination
                                store.moveQueueEntry(store.queueItems[source].entry.id, to: target)
                            }
                        } header: {
                            Text("Queue order")
                        } footer: {
                            if store.isShuffleEnabled {
                                Text("Reordering changes the saved queue order. The current shuffled play order stays active until shuffle is turned off.")
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(ColorfulTheme.background.ignoresSafeArea())
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                if !store.queueItems.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
            }
        }
    }
}
