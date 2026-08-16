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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                miniPlayerInset
            }
            .tabItem { Label(ColorfulTab.home.title, systemImage: ColorfulTab.home.symbol) }
            .tag(ColorfulTab.home)

            NavigationStack {
                LibraryView(store: store)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                miniPlayerInset
            }
            .tabItem { Label(ColorfulTab.library.title, systemImage: ColorfulTab.library.symbol) }
            .tag(ColorfulTab.library)

            NavigationStack {
                OfflineView()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                miniPlayerInset
            }
            .tabItem { Label(ColorfulTab.offline.title, systemImage: ColorfulTab.offline.symbol) }
            .tag(ColorfulTab.offline)

            NavigationStack {
                SettingsView(store: store, account: account)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
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
                    account: account,
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
                isBuffering: playbackService.isBuffering,
                positionMs: store.positionMs,
                canSkipNext: store.canSkipNext
            ) {
                playbackService.togglePlayback()
            } onNext: {
                playbackService.skipNext()
            } onExpand: {
                isShowingPlayer = true
            }
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
                            TrackRow(track: item.element, store: store) {
                                store.play(item.element)
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
    @ObservedObject var store: PlaybackStore
    let removeFromPlaylist: (() -> Void)?
    let play: () -> Void

    init(
        track: CoreTrack,
        store: PlaybackStore,
        removeFromPlaylist: (() -> Void)? = nil,
        play: @escaping () -> Void
    ) {
        self.track = track
        _store = ObservedObject(wrappedValue: store)
        self.removeFromPlaylist = removeFromPlaylist
        self.play = play
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: play) {
                TrackRowContent(track: track)
            }
            .buttonStyle(.plain)
            Menu {
                TrackActionMenuItems(
                    track: track,
                    store: store,
                    removeFromPlaylist: removeFromPlaylist,
                    play: play
                )
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ColorfulTheme.mutedInk)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Actions for \(track.title)")
        }
        .background(ColorfulTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ColorfulTheme.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            TrackActionMenuItems(
                track: track,
                store: store,
                removeFromPlaylist: removeFromPlaylist,
                play: play
            )
        }
    }
}

private struct TrackActionMenuItems: View {
    let track: CoreTrack
    @ObservedObject var store: PlaybackStore
    let removeFromPlaylist: (() -> Void)?
    let play: () -> Void

    init(
        track: CoreTrack,
        store: PlaybackStore,
        removeFromPlaylist: (() -> Void)? = nil,
        play: @escaping () -> Void
    ) {
        self.track = track
        _store = ObservedObject(wrappedValue: store)
        self.removeFromPlaylist = removeFromPlaylist
        self.play = play
    }

    var body: some View {
        Button("Play", systemImage: "play.fill", action: play)
        Button("Play next", systemImage: "text.insert") {
            store.playNext(track)
        }
        Button("Add to queue", systemImage: "text.line.first.and.arrowtriangle.forward") {
            store.enqueue(track)
        }
        Divider()
        Button(
            store.isSaved(track) ? "Remove from library" : "Save to library",
            systemImage: store.isSaved(track) ? "heart.slash" : "heart"
        ) {
            store.toggleSaved(track)
        }
        if let removeFromPlaylist {
            Button("Remove from playlist", systemImage: "minus.circle", role: .destructive) {
                removeFromPlaylist()
            }
        }
        if !store.playlists.isEmpty {
            Menu("Add to playlist", systemImage: "text.badge.plus") {
                ForEach(store.playlists) { playlist in
                    let occurrenceCount = playlist.tracks.filter { $0.id == track.id }.count
                    Button {
                        store.add(track, toPlaylist: playlist.id)
                    } label: {
                        Label(
                            occurrenceCount == 0 ? playlist.name : "\(playlist.name) (\(occurrenceCount))",
                            systemImage: occurrenceCount == 0 ? "music.note.list" : "checkmark"
                        )
                    }
                }
            }
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
                artworkURL: track.artwork?.url,
                size: 48
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
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct SearchView: View {
    @ObservedObject var account: TidalAccountStore
    @ObservedObject var store: PlaybackStore
    let onPlay: (CoreTrack) -> Void

    @State private var query = ""
    @State private var results: TidalCatalogSearchResults?
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchID = UUID()
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
                            searchID = UUID()
                            query = ""
                            results = nil
                            isSearching = false
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
                } else if results == nil {
                    ContentUnavailableView {
                        Label("Search TIDAL", systemImage: "music.magnifyingglass")
                    } description: {
                        Text("Search for a track, artist, or album.")
                    }
                } else if results?.isEmpty == true {
                    ContentUnavailableView {
                        Label("No results", systemImage: "music.magnifyingglass")
                    } description: {
                        Text("Try a different artist, album, or track name.")
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            if let artists = results?.artists, !artists.isEmpty {
                                searchSectionHeader("Artists", count: artists.count)
                                ScrollView(.horizontal) {
                                    LazyHStack(alignment: .top, spacing: 14) {
                                        ForEach(artists) { artist in
                                            NavigationLink {
                                                ArtistCollectionView(
                                                    artist: CoreArtistCredit(
                                                        id: CoreMediaID(provider: "tidal", providerID: artist.id),
                                                        name: artist.name
                                                    ),
                                                    account: account,
                                                    store: store,
                                                    showsDismissButton: false
                                                )
                                            } label: {
                                                VStack(spacing: 7) {
                                                    ColorfulAlbumArt(
                                                        title: artist.name,
                                                        accent: 0xFF5C9A,
                                                        artworkURL: artist.artworkURL,
                                                        size: 92
                                                    )
                                                    .clipShape(Circle())
                                                    Text(artist.name)
                                                        .font(.subheadline.weight(.semibold))
                                                        .foregroundStyle(ColorfulTheme.ink)
                                                        .lineLimit(2)
                                                        .multilineTextAlignment(.center)
                                                }
                                                .frame(width: 104)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .scrollIndicators(.hidden)
                            }

                            if let albums = results?.albums, !albums.isEmpty {
                                searchSectionHeader("Albums", count: albums.count)
                                ScrollView(.horizontal) {
                                    LazyHStack(alignment: .top, spacing: 14) {
                                        ForEach(albums) { album in
                                            NavigationLink {
                                                AlbumCollectionView(
                                                    albumID: album.id,
                                                    account: account,
                                                    store: store
                                                )
                                            } label: {
                                                VStack(alignment: .leading, spacing: 6) {
                                                    ColorfulAlbumArt(
                                                        title: album.title,
                                                        accent: 0xFF5C9A,
                                                        artworkURL: album.artworkURL,
                                                        size: 138
                                                    )
                                                    Text(album.title)
                                                        .font(.subheadline.weight(.semibold))
                                                        .foregroundStyle(ColorfulTheme.ink)
                                                        .lineLimit(2)
                                                    Text(album.artistLabel)
                                                        .font(.caption)
                                                        .foregroundStyle(ColorfulTheme.mutedInk)
                                                        .lineLimit(1)
                                                }
                                                .frame(width: 138, alignment: .leading)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .scrollIndicators(.hidden)
                            }

                            if let tracks = results?.tracks, !tracks.isEmpty {
                                searchSectionHeader("Tracks", count: tracks.count)
                                LazyVStack(spacing: 8) {
                                    ForEach(tracks) { track in
                                        SearchResultRow(
                                            track: track,
                                            account: account,
                                            store: store,
                                            onPlay: onPlay
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 16)
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
        let requestID = UUID()
        searchID = requestID
        isSearching = true
        errorMessage = nil
        Task {
            do {
                let response = try await account.searchCatalog(query: value, core: store.core)
                guard searchID == requestID else { return }
                results = response
            } catch {
                guard searchID == requestID else { return }
                results = nil
                errorMessage = error.localizedDescription
            }
            guard searchID == requestID else { return }
            isSearching = false
        }
    }

    private func searchSectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(ColorfulTheme.ink)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(ColorfulTheme.mutedInk)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct SearchResultRow: View {
    let track: CoreTrack
    @ObservedObject var account: TidalAccountStore
    @ObservedObject var store: PlaybackStore
    let onPlay: (CoreTrack) -> Void

    var body: some View {
        if let albumID = track.albumID?.providerID {
            HStack(spacing: 0) {
                NavigationLink {
                    AlbumCollectionView(albumID: albumID, account: account, store: store)
                } label: {
                    TrackRowContent(track: track)
                }
                .buttonStyle(.plain)
                Menu {
                    TrackActionMenuItems(track: track, store: store) {
                        onPlay(track)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ColorfulTheme.mutedInk)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Actions for \(track.title)")
            }
            .contextMenu {
                TrackActionMenuItems(track: track, store: store) {
                    onPlay(track)
                }
            }
        } else {
            TrackRow(track: track, store: store) {
                onPlay(track)
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
                                Button {
                                    store.playTracks(collection.tracks)
                                } label: {
                                    Label("Play album", systemImage: "play.fill")
                                        .font(.headline)
                                        .foregroundStyle(paletteLoader.palette.primaryForegroundColor)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 11)
                                        .background(
                                            paletteLoader.palette.primaryColor,
                                            in: Capsule(style: .continuous)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            LazyVStack(spacing: 10) {
                                ForEach(collection.tracks) { track in
                                    TrackRow(track: track, store: store) {
                                        store.play(track)
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
    @State private var isCreatingPlaylist = false
    @State private var playlistName = ""

    var body: some View {
        List {
            Section("Playlists") {
                if store.playlists.isEmpty {
                    Button {
                        isCreatingPlaylist = true
                    } label: {
                        Label("Create your first playlist", systemImage: "plus.circle")
                    }
                    .foregroundStyle(ColorfulTheme.ink)
                    .listRowBackground(ColorfulTheme.surface)
                } else {
                    ForEach(store.playlists) { playlist in
                        NavigationLink {
                            LocalPlaylistView(playlistID: playlist.id, store: store)
                        } label: {
                            HStack(spacing: 12) {
                                playlistArtwork(playlist)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playlist.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(ColorfulTheme.ink)
                                        .lineLimit(1)
                                    Text("\(playlist.tracks.count) \(playlist.tracks.count == 1 ? "track" : "tracks")")
                                        .font(.caption)
                                        .foregroundStyle(ColorfulTheme.mutedInk)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(ColorfulTheme.surface)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                store.deletePlaylist(playlist.id)
                            }
                        }
                    }
                }
            }

            if !store.libraryTracks.isEmpty {
                Section("Saved tracks") {
                    ForEach(store.libraryTracks) { track in
                        TrackRow(track: track, store: store) {
                            store.play(track)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing) {
                            Button("Remove", systemImage: "heart.slash", role: .destructive) {
                                store.toggleSaved(track)
                            }
                        }
                    }
                }
            } else {
                Section {
                    Label("No saved tracks yet", systemImage: "music.note.list")
                        .foregroundStyle(ColorfulTheme.mutedInk)
                        .listRowBackground(ColorfulTheme.surface)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New playlist", systemImage: "plus") {
                    playlistName = ""
                    isCreatingPlaylist = true
                }
            }
        }
        .alert("New playlist", isPresented: $isCreatingPlaylist) {
            TextField("Playlist name", text: $playlistName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                store.createPlaylist(named: playlistName)
            }
            .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Playlists are stored locally by the Colorful core.")
        }
    }

    @ViewBuilder
    private func playlistArtwork(_ playlist: CoreLocalPlaylist) -> some View {
        if let track = playlist.tracks.first {
            ColorfulAlbumArt(
                title: playlist.name,
                accent: track.accent,
                artworkURL: track.artwork?.url,
                size: 52
            )
        } else {
            ZStack {
                ColorfulTheme.surfaceRaised
                Image(systemName: "music.note.list")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ColorfulTheme.mutedInk)
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

private struct LocalPlaylistView: View {
    let playlistID: String
    @ObservedObject var store: PlaybackStore
    @Environment(\.dismiss) private var dismiss
    @State private var isRenaming = false
    @State private var renamedPlaylist = ""
    @State private var isConfirmingDeletion = false

    private var playlist: CoreLocalPlaylist? {
        store.playlists.first { $0.id == playlistID }
    }

    var body: some View {
        Group {
            if let playlist {
                List {
                    Section {
                        Button {
                            store.playTracks(playlist.tracks)
                        } label: {
                            Label("Play playlist", systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(playlist.tracks.isEmpty)
                        .listRowBackground(ColorfulTheme.surface)
                    }

                    Section("Tracks") {
                        if playlist.tracks.isEmpty {
                            Label("Add tracks from any track menu", systemImage: "text.badge.plus")
                                .foregroundStyle(ColorfulTheme.mutedInk)
                                .listRowBackground(ColorfulTheme.surface)
                        } else {
                            ForEach(Array(playlist.tracks.enumerated()), id: \.offset) { item in
                                TrackRow(
                                    track: item.element,
                                    store: store,
                                    removeFromPlaylist: {
                                        store.removePlaylistItem(from: playlist.id, at: item.offset)
                                    }
                                ) {
                                    store.playTracks(Array(playlist.tracks.dropFirst(item.offset)))
                                }
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                            .onDelete { offsets in
                                for position in offsets.sorted(by: >) {
                                    store.removePlaylistItem(from: playlist.id, at: position)
                                }
                            }
                            .onMove { offsets, destination in
                                guard offsets.count == 1, let source = offsets.first else { return }
                                let target = destination > source ? destination - 1 : destination
                                store.movePlaylistItem(in: playlist.id, from: source, to: target)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView("Playlist unavailable", systemImage: "music.note.list")
            }
        }
        .background(ColorfulTheme.background.ignoresSafeArea())
        .navigationTitle(playlist?.name ?? "Playlist")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if playlist?.tracks.isEmpty == false {
                    EditButton()
                }
                if let playlist {
                    Menu("Playlist actions", systemImage: "ellipsis.circle") {
                        Button("Rename", systemImage: "pencil") {
                            renamedPlaylist = playlist.name
                            isRenaming = true
                        }
                        Button("Delete playlist", systemImage: "trash", role: .destructive) {
                            isConfirmingDeletion = true
                        }
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .alert("Rename playlist", isPresented: $isRenaming) {
            TextField("Playlist name", text: $renamedPlaylist)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                store.renamePlaylist(playlistID, to: renamedPlaylist)
            }
            .disabled(renamedPlaylist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            "Delete this playlist?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete playlist", role: .destructive) {
                store.deletePlaylist(playlistID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The playlist will be removed from this device. Its tracks stay in your library and queue.")
        }
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
    let positionMs: UInt64
    let canSkipNext: Bool
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onExpand: () -> Void

    private var progress: Double {
        guard let durationMs = track.durationMs, durationMs > 0 else { return 0 }
        return min(max(Double(positionMs) / Double(durationMs), 0), 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    ColorfulTheme.border
                    ColorfulTheme.ink.opacity(0.82)
                        .frame(width: proxy.size.width * CGFloat(progress))
                }
            }
            .frame(height: 2)
            .accessibilityHidden(true)

            HStack(spacing: 10) {
                Button(action: onExpand) {
                    HStack(spacing: 10) {
                        ColorfulAlbumArt(
                            title: track.title,
                            accent: track.accent,
                            artworkURL: track.artwork?.url,
                            size: 44
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
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(ColorfulTheme.ink)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .accessibilityLabel(isBuffering ? "Buffering, pause playback" : (isPlaying ? "Pause" : "Play"))
                Button(action: onNext) {
                    Image(systemName: "forward.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ColorfulTheme.ink.opacity(canSkipNext ? 1 : 0.32))
                        .frame(width: 44, height: 44)
                }
                .disabled(!canSkipNext)
                .accessibilityLabel("Next")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }
}

private struct FullPlayer: View {
    @ObservedObject var store: PlaybackStore
    @ObservedObject var account: TidalAccountStore
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
    @State private var artistDestination: ArtistDestination?

    init(
        store: PlaybackStore,
        account: TidalAccountStore,
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
        self.account = account
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
        ZStack {
            ColorfulArtworkBackground(palette: paletteLoader.palette, image: paletteLoader.image)
            ScrollView {
                VStack(spacing: 22) {
                        ColorfulAlbumArt(
                            title: track.title,
                            accent: track.accent,
                            artworkURL: track.artwork?.url,
                            size: 280
                        )
                        .padding(.top, 108)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(ColorfulTheme.ink)
                                .lineLimit(2)
                            artistControl
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
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Retry", action: onRetry)
                                    .font(.footnote.weight(.semibold))
                                    .fixedSize()
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
                .padding(.bottom, 32)
                .containerRelativeFrame(.horizontal)
            }
            .scrollIndicators(.hidden)
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
        .sheet(item: $artistDestination) { destination in
            NavigationStack {
                ArtistCollectionView(artist: destination.artist, account: account, store: store)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(ColorfulTheme.background)
        }
    }

    @ViewBuilder
    private var artistControl: some View {
        if navigableArtists.isEmpty {
            Text(track.compactArtistLabel)
                .font(.body)
                .foregroundStyle(ColorfulTheme.ink.opacity(0.78))
                .lineLimit(1)
        } else if navigableArtists.count == 1, let artist = navigableArtists.first {
            Button(action: openArtist) {
                HStack(spacing: 6) {
                    Text(track.compactArtistLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .font(.body)
                .foregroundStyle(ColorfulTheme.ink.opacity(0.82))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open artist \(artist.name)")
        } else {
            Menu {
                ForEach(Array(navigableArtists.enumerated()), id: \.offset) { item in
                    Button(item.element.name) {
                        artistDestination = ArtistDestination(artist: item.element)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(track.compactArtistLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .font(.body)
                .foregroundStyle(ColorfulTheme.ink.opacity(0.82))
            }
            .accessibilityLabel("Choose an artist from \(track.compactArtistLabel)")
        }
    }

    private var navigableArtists: [CoreArtistCredit] {
        track.artists.filter {
            $0.id?.provider.lowercased() == "tidal" && $0.id?.providerID.isEmpty == false
        }
    }

    private func openArtist() {
        if let artist = navigableArtists.first {
            artistDestination = ArtistDestination(artist: artist)
        }
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

private struct ArtistDestination: Identifiable {
    let id = UUID()
    let artist: CoreArtistCredit
}

private struct ArtistCollectionView: View {
    let artist: CoreArtistCredit
    @ObservedObject var account: TidalAccountStore
    @ObservedObject var store: PlaybackStore
    let showsDismissButton: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var paletteLoader = ColorfulArtworkPaletteLoader()
    @State private var collection: TidalArtistCollection?
    @State private var isLoading = true
    @State private var errorMessage: String?

    init(
        artist: CoreArtistCredit,
        account: TidalAccountStore,
        store: PlaybackStore,
        showsDismissButton: Bool = true
    ) {
        self.artist = artist
        _account = ObservedObject(wrappedValue: account)
        _store = ObservedObject(wrappedValue: store)
        self.showsDismissButton = showsDismissButton
    }

    var body: some View {
        ZStack {
            ColorfulCollectionBackground(palette: paletteLoader.palette)
            Group {
                if isLoading {
                    ProgressView("Loading artist…")
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Artist unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { Task { await load(force: true) } }
                    }
                } else if let collection {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            VStack(spacing: 12) {
                                ColorfulAlbumArt(
                                    title: collection.name,
                                    accent: 0xFF5C9A,
                                    artworkURL: collection.artworkURL,
                                    size: 190
                                )
                                .clipShape(Circle())
                                Text(collection.name)
                                    .font(.largeTitle.bold())
                                    .foregroundStyle(ColorfulTheme.ink)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                if !collection.topTracks.isEmpty {
                                    Button {
                                        store.playTracks(collection.topTracks)
                                    } label: {
                                        Label("Play top tracks", systemImage: "play.fill")
                                            .font(.headline)
                                            .foregroundStyle(paletteLoader.palette.primaryForegroundColor)
                                            .padding(.horizontal, 22)
                                            .padding(.vertical, 12)
                                            .background(
                                                paletteLoader.palette.primaryColor,
                                                in: Capsule(style: .continuous)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(maxWidth: .infinity)

                            if !collection.albums.isEmpty {
                                Text("Albums")
                                    .font(.title2.bold())
                                    .foregroundStyle(ColorfulTheme.ink)
                                ScrollView(.horizontal) {
                                    LazyHStack(alignment: .top, spacing: 14) {
                                        ForEach(collection.albums) { album in
                                            NavigationLink {
                                                AlbumCollectionView(
                                                    albumID: album.id,
                                                    account: account,
                                                    store: store
                                                )
                                            } label: {
                                                VStack(alignment: .leading, spacing: 6) {
                                                    ColorfulAlbumArt(
                                                        title: album.title,
                                                        accent: 0xFF5C9A,
                                                        artworkURL: album.artworkURL,
                                                        size: 148
                                                    )
                                                    Text(album.title)
                                                        .font(.subheadline.weight(.semibold))
                                                        .foregroundStyle(ColorfulTheme.ink)
                                                        .lineLimit(2)
                                                    Text(album.artistLabel)
                                                        .font(.caption)
                                                        .foregroundStyle(ColorfulTheme.mutedInk)
                                                        .lineLimit(1)
                                                }
                                                .frame(width: 148, alignment: .leading)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .scrollIndicators(.hidden)
                            }

                            if collection.topTracks.isEmpty {
                                ContentUnavailableView(
                                    "No tracks available",
                                    systemImage: "music.note.list",
                                    description: Text("TIDAL did not return top tracks for this artist.")
                                )
                            } else {
                                Text("Top tracks")
                                    .font(.title2.bold())
                                    .foregroundStyle(ColorfulTheme.ink)
                                LazyVStack(spacing: 10) {
                                    ForEach(collection.topTracks) { track in
                                        TrackRow(track: track, store: store) {
                                            store.play(track)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(20)
                    }
                }
            }
        }
        .navigationTitle(collection?.name ?? artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDismissButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load(force: false) }
        .task(id: collection?.artworkURL) {
            paletteLoader.load(for: collection?.artworkURL)
        }
    }

    private func load(force: Bool) async {
        guard force || collection == nil else { return }
        guard let id = artist.id?.providerID else {
            errorMessage = "This track does not include an artist identifier."
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            collection = try await account.loadArtist(artistID: id, core: store.core)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    queueControl(
                        title: store.isShuffleEnabled ? "Shuffle on" : "Shuffle off",
                        symbol: store.isShuffleEnabled ? "shuffle.circle.fill" : "shuffle",
                        active: store.isShuffleEnabled,
                        action: store.toggleShuffle
                    )
                    queueControl(
                        title: store.repeatMode.label,
                        symbol: store.repeatMode.symbol,
                        active: store.repeatMode != .off,
                        action: store.cycleRepeat
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider().overlay(ColorfulTheme.border)

                if store.queueItems.isEmpty {
                    ContentUnavailableView {
                        Label("Queue is empty", systemImage: "text.line.first.and.arrowtriangle.forward")
                    } description: {
                        Text("Play a track or add one to the queue to see it here.")
                    }
                } else {
                    HStack {
                        Text("Queue order")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ColorfulTheme.mutedInk)
                        Spacer()
                        Text("\(store.queueItems.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ColorfulTheme.mutedInk)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)

                    List {
                        ForEach(store.queueItems) { item in
                            Button {
                                store.selectQueueEntry(item.entry.id)
                            } label: {
                                HStack(spacing: 10) {
                                    ColorfulAlbumArt(
                                        title: item.track.title,
                                        accent: item.track.accent,
                                        artworkURL: item.track.artwork?.url,
                                        size: 48
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.track.title)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(ColorfulTheme.ink)
                                            .lineLimit(1)
                                        Text("\(item.track.compactArtistLabel) · \(item.track.albumLabel)")
                                            .font(.caption)
                                            .foregroundStyle(ColorfulTheme.mutedInk)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 6)
                                    Text(item.track.durationLabel)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(ColorfulTheme.mutedInk)
                                    if store.currentQueueEntryID == item.entry.id {
                                        Image(systemName: store.effectiveIsPlaying ? "speaker.wave.2.fill" : "pause.fill")
                                            .foregroundStyle(ColorfulTheme.accent)
                                            .frame(width: 22)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    store.currentQueueEntryID == item.entry.id
                                        ? ColorfulTheme.accent.opacity(0.12)
                                        : ColorfulTheme.surface,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
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
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 0)
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

    private func queueControl(
        title: String,
        symbol: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(active ? ColorfulTheme.accent : ColorfulTheme.ink.opacity(0.78))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(ColorfulTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
