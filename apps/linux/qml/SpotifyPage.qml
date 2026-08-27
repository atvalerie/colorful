import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Spotify is a catalog/recommendation provider in colorful, not an audio
// source.  The provider host supplies Spotify-shaped catalog objects here;
// opening or playing one still goes through the normal TIDAL/ISRC path.
Item {
    id: root
    property int tab: 0

    function hub() { return colorful.spotifyHub || {} }
    function list(name) { return hub()[name] || [] }
    function cursor(name) { return (hub().cursors || {})[name] || "" }
    function accountValue(key, fallback) {
        const account = colorful.spotifyAccount || {}
        const value = account[key]
        return value === undefined || value === null || value === "" ? fallback : value
    }
    function load(refresh) {
        if (typeof colorful.loadSpotifyHub === "function") colorful.loadSpotifyHub(refresh)
    }
    function loadMore(section) {
        if (typeof colorful.loadMoreSpotify === "function") colorful.loadMoreSpotify(section)
    }
    function openSearch() {
        window.searchProvider = "spotify"
        window.submittedQuery = ""
        window.navigateToSection("search")
    }

    readonly property bool homeEmpty: list("mixes").length === 0
                                  && list("albums").length === 0
    readonly property bool libraryEmpty: list("tracks").length === 0
                                     && list("albums").length === 0
                                     && list("artists").length === 0
    readonly property bool playlistsEmpty: list("playlists").length === 0
                                        && list("mixes").length === 0

    Component.onCompleted: if (colorful.spotifyLinked) root.load(false)
    Connections {
        target: colorful
        function onSpotifyAccountChanged() {
            if (colorful.spotifyLinked && !root.loading) root.load(false)
        }
    }

    readonly property bool loading: Boolean(colorful.spotifyHubLoading)

    ColumnLayout {
        anchors.fill: parent
        spacing: 16

        ProviderHeader {
            Layout.fillWidth: true
            title: "Spotify"
            accountText: root.accountValue("displayName", root.accountValue("id", ""))
            refreshEnabled: colorful.spotifyLinked && !root.loading
            onRefreshRequested: root.load(true)
        }

        Row {
            Layout.fillWidth: true
            spacing: 0
            Repeater {
                model: ["Home", "Library", "Playlists & mixes"]
                delegate: Rectangle {
                    required property string modelData
                    required property int index
                    width: tabLabel.implicitWidth + 30
                    height: 36
                    color: root.tab === index ? Qt.rgba(1, 1, 1, 0.075) : "transparent"
                    border.width: 1
                    border.color: root.tab === index ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
                    Text {
                        id: tabLabel
                        anchors.centerIn: parent
                        text: modelData
                        color: root.tab === index ? "#f5f5f5" : Qt.rgba(1, 1, 1, 0.56)
                        font.bold: root.tab === index
                        font.pixelSize: Math.round(12 * colorful.textScale)
                    }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.tab = index }
                }
            }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: root.tab

            Item {
                Flickable {
                    anchors.fill: parent
                    clip: true
                    contentWidth: width
                    contentHeight: homeColumn.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    Column {
                        id: homeColumn
                        width: parent.width
                        spacing: 18
                        topPadding: 2
                        bottomPadding: 24

                        Column {
                            width: parent.width
                            spacing: 9
                            visible: root.list("mixes").length > 0
                            Text { text: "Made for you"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(17 * colorful.textScale) }
                            Item {
                                width: parent.width
                                height: 204
                                ListView {
                                    id: spotifyMixesShelf
                                    anchors.fill: parent
                                    orientation: ListView.Horizontal
                                    model: root.list("mixes")
                                    spacing: 8
                                    clip: true
                                    cacheBuffer: width
                                    reuseItems: true
                                    delegate: PlaylistCard {
                                        required property var modelData
                                        entry: modelData
                                        onOpenRequested: window.openPlaylist(modelData.id, "spotify")
                                    }
                                }
                                ShelfScrollButtons { view: spotifyMixesShelf }
                            }
                        }

                        Column {
                            width: parent.width
                            spacing: 9
                            visible: root.list("albums").length > 0
                            Text { text: "Saved albums"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(17 * colorful.textScale) }
                            Item {
                                width: parent.width
                                height: 204
                                ListView {
                                    id: spotifyAlbumsShelf
                                    anchors.fill: parent
                                    orientation: ListView.Horizontal
                                    model: root.list("albums")
                                    spacing: 8
                                    clip: true
                                    cacheBuffer: width
                                    reuseItems: true
                                    delegate: CatalogCard {
                                        required property var modelData
                                        entry: modelData
                                        onOpenRequested: window.openAlbumItem(modelData)
                                    }
                                }
                                ShelfScrollButtons { view: spotifyAlbumsShelf }
                            }
                        }
                    }
                }
                Column {
                    anchors.centerIn: parent
                    width: Math.min(460, parent.width - 48)
                    spacing: 10
                    visible: colorful.spotifyLinked && !root.loading && root.homeEmpty
                    AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/music.svg"; opacity: 0.28 }
                    Text { width: parent.width; text: "Spotify catalog is ready"; color: "#f5f5f5"; horizontalAlignment: Text.AlignHCenter; font.bold: true; font.pixelSize: Math.round(16 * colorful.textScale) }
                    Text { width: parent.width; text: "Search Spotify for tracks, albums, artists, playlists, and mixes. Spotify supplies metadata and personalization; matching audio plays from TIDAL by ISRC."; color: Qt.rgba(1, 1, 1, 0.44); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.pixelSize: Math.round(12 * colorful.textScale) }
                    ColorButton { anchors.horizontalCenter: parent.horizontalCenter; text: "Search Spotify"; onClicked: root.openSearch() }
                }
            }

            Item {
                ListView {
                    id: spotifyCollection
                    anchors.fill: parent
                    model: root.list("tracks")
                    clip: true
                    spacing: 0
                    boundsBehavior: Flickable.StopAtBounds
                    cacheBuffer: 400
                    reuseItems: true
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    header: Column {
                        width: spotifyCollection.width
                        spacing: 14
                        visible: !root.libraryEmpty
                        height: visible ? implicitHeight : 0
                        Text { visible: root.list("artists").length > 0; text: "Saved artists"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(17 * colorful.textScale) }
                        Item {
                            width: parent.width
                            height: visible ? 190 : 0
                            visible: root.list("artists").length > 0
                            ListView {
                                id: spotifyArtistsShelf
                                anchors.fill: parent
                                orientation: ListView.Horizontal
                                model: root.list("artists")
                                spacing: 8; clip: true; cacheBuffer: width; reuseItems: true
                                delegate: CatalogCard {
                                    required property var modelData
                                    entry: modelData; artistMode: true
                                    onOpenRequested: window.openArtistItem({ id: modelData.id, provider: "spotify" })
                                }
                            }
                            ShelfScrollButtons { view: spotifyArtistsShelf }
                        }
                        Text { visible: root.list("albums").length > 0; text: "Saved albums"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(17 * colorful.textScale) }
                        Item {
                            width: parent.width
                            height: visible ? 204 : 0
                            visible: root.list("albums").length > 0
                            ListView {
                                id: spotifySavedAlbumsShelf
                                anchors.fill: parent
                                orientation: ListView.Horizontal
                                model: root.list("albums")
                                spacing: 8; clip: true; cacheBuffer: width; reuseItems: true
                                delegate: CatalogCard {
                                    required property var modelData
                                    entry: modelData
                                    onOpenRequested: window.openAlbumItem(modelData)
                                }
                            }
                            ShelfScrollButtons { view: spotifySavedAlbumsShelf }
                        }
                        Text { visible: root.list("tracks").length > 0; text: "Saved tracks"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(17 * colorful.textScale) }
                    }
                    delegate: TrackDelegate {
                        required property var modelData
                        width: spotifyCollection.width
                        track: modelData
                        showSaveAction: false
                        showDownloadAction: false
                        onPlayRequested: colorful.playCatalogTrack(modelData)
                        onAddRequested: colorful.enqueueCatalogTrack(modelData)
                        onPlayNextRequested: colorful.playNextCatalogTrack(modelData)
                        onDetailsRequested: window.openTrackItem(modelData)
                        onStartRadioRequested: colorful.startRadio(modelData)
                    }
                }
                Column {
                    anchors.centerIn: parent
                    width: Math.min(460, parent.width - 48)
                    spacing: 10
                    visible: colorful.spotifyLinked && !root.loading && root.libraryEmpty
                    AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/library.svg"; opacity: 0.28 }
                    Text { width: parent.width; text: "Your Spotify library is empty"; color: "#f5f5f5"; horizontalAlignment: Text.AlignHCenter; font.bold: true; font.pixelSize: Math.round(16 * colorful.textScale) }
                    Text { width: parent.width; text: "Albums, artists, and tracks saved on Spotify will appear here when the account catalog is available."; color: Qt.rgba(1, 1, 1, 0.44); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.pixelSize: Math.round(12 * colorful.textScale) }
                }
            }

            Item {
                ListView {
                    id: spotifyPlaylistList
                    anchors.fill: parent
                    model: root.list("playlists")
                    clip: true; spacing: 8; boundsBehavior: Flickable.StopAtBounds
                    cacheBuffer: 300; reuseItems: true
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    header: Column {
                        width: spotifyPlaylistList.width
                        spacing: 12
                        visible: !root.playlistsEmpty
                        height: visible ? implicitHeight : 0
                        Text { visible: root.list("mixes").length > 0; text: "Made for you"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(17 * colorful.textScale) }
                        ListView {
                            width: parent.width; height: visible ? 204 : 0
                            visible: root.list("mixes").length > 0
                            orientation: ListView.Horizontal
                            model: root.list("mixes")
                            spacing: 8; clip: true; cacheBuffer: width; reuseItems: true
                            delegate: PlaylistCard {
                                required property var modelData
                                entry: modelData
                                onOpenRequested: window.openPlaylist(modelData.id, "spotify")
                            }
                        }
                        Text { visible: root.list("playlists").length > 0; text: "Your playlists"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(17 * colorful.textScale) }
                    }
                    delegate: Rectangle {
                        required property var modelData
                        width: spotifyPlaylistList.width; height: 62
                        color: hover.hovered ? Qt.rgba(1, 1, 1, 0.055) : "transparent"
                        border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.07)
                        ArtworkImage { x: 7; y: 7; width: 48; height: 48; source: modelData.coverUrl || ""; decodeSize: 192 }
                        AppIcon { x: 22; y: 22; width: 18; height: 18; iconSource: "icons/music.svg"; opacity: 0.3; visible: colorful.lowDataMode || !modelData.coverUrl }
                        Column {
                            x: 67; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 150; spacing: 3
                            Text { width: parent.width; text: modelData.name || "Untitled playlist"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(12 * colorful.textScale); elide: Text.ElideRight }
                            Text { width: parent.width; text: modelData.numberOfItems ? modelData.numberOfItems + " tracks" : (modelData.playlistType || "Spotify"); color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: Math.round(10 * colorful.textScale) }
                        }
                        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: window.openPlaylist(modelData.id, "spotify") }
                    }
                }
                Column {
                    anchors.centerIn: parent
                    width: Math.min(460, parent.width - 48)
                    spacing: 10
                    visible: colorful.spotifyLinked && !root.loading && root.playlistsEmpty
                    AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/music.svg"; opacity: 0.28 }
                    Text { width: parent.width; text: "No Spotify playlists or mixes yet"; color: "#f5f5f5"; horizontalAlignment: Text.AlignHCenter; font.bold: true; font.pixelSize: Math.round(16 * colorful.textScale) }
                    Text { width: parent.width; text: "Spotify playlists and personalized mixes will appear here. Search is also available from the bar above."; color: Qt.rgba(1, 1, 1, 0.44); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.pixelSize: Math.round(12 * colorful.textScale) }
                }
            }
        }
    }

    BusyIndicator { anchors.centerIn: parent; running: root.loading; visible: running }
    Column {
        anchors.centerIn: parent
        width: Math.min(460, parent.width - 48)
        spacing: 10
        visible: colorful.providerStatusResolved && !colorful.spotifyLinked
        AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/music.svg"; opacity: 0.28 }
        Text { width: parent.width; text: "Connect Spotify to browse its catalog"; color: "#f5f5f5"; horizontalAlignment: Text.AlignHCenter; font.bold: true; font.pixelSize: Math.round(16 * colorful.textScale) }
        Text { width: parent.width; text: "Spotify is used for recommendations and metadata. colorful never streams Spotify audio; playable results are matched to TIDAL by ISRC."; color: Qt.rgba(1, 1, 1, 0.44); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.pixelSize: Math.round(12 * colorful.textScale) }
        ColorButton { anchors.horizontalCenter: parent.horizontalCenter; text: "Open Spotify settings"; onClicked: window.openSettings(0) }
    }
}
