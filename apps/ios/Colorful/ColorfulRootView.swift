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
            await store.refreshFromCore()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                account.appBecameActive()
            case .background, .inactive:
                account.appBecameInactive()
            @unknown default:
                break
            }
        }
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
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

    @ViewBuilder
    private var miniPlayerInset: some View {
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

    var body: some View {
        Button(action: play) {
            TrackRowContent(track: track)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play", systemImage: "play.fill") { play() }
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
                Button("Add to queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    store.enqueue(track)
                }
            }
        } else {
            TrackRow(track: track) {
                onPlay(track)
            } enqueue: {
                store.enqueue(track)
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

    var body: some View {
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
                            Text(collection.artistLabel)
                                .font(.subheadline)
                                .foregroundStyle(ColorfulTheme.mutedInk)
                            Button("Play album", systemImage: "play.fill") {
                                store.playTracks(collection.tracks)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ColorfulTheme.accent)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        LazyVStack(spacing: 10) {
                            ForEach(collection.tracks) { track in
                                TrackRow(track: track) {
                                    store.play(track)
                                } enqueue: {
                                    store.enqueue(track)
                                }
                            }
                        }
                    }
                    .padding(16)
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
                ColorfulAlbumArt(
                    title: track.title,
                    accent: track.accent,
                    artworkURL: track.artwork?.url,
                    size: 280
                )
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
