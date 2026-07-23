import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    property int tab: 0
    readonly property bool homeEmpty: (colorful.tidalHub.dailyMixes || []).length === 0
                                      && (colorful.tidalHub.discoveryMixes || []).length === 0
                                      && (colorful.tidalHub.newReleaseMixes || []).length === 0
    readonly property bool collectionEmpty: (colorful.tidalHub.tracks || []).length === 0
                                            && (colorful.tidalHub.albums || []).length === 0
                                            && (colorful.tidalHub.artists || []).length === 0
    readonly property bool playlistsEmpty: (colorful.tidalHub.playlists || []).length === 0
                                           && (colorful.tidalHub.mixes || []).length === 0

    function accountValue(key, fallback) {
        const account = colorful.tidalHub.account || {}
        const value = account[key]
        return value === undefined || value === null || value === "" ? fallback : value
    }

    component MixShelf: Column {
        id: mixShelf
        required property string shelfTitle
        required property var entries
        required property string cursorSection
        width: parent ? parent.width : 0
        height: visible ? implicitHeight : 0
        visible: entries.length > 0
        spacing: 9

        RowLayout {
            width: parent.width
            Text { text: mixShelf.shelfTitle; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
            Item { Layout.fillWidth: true }
        }
        Item {
            width: parent.width
            height: 204
            ListView {
                id: mixShelfList
                anchors.fill: parent
                orientation: ListView.Horizontal
                model: mixShelf.entries
                spacing: 8
                clip: true
                pixelAligned: true
                boundsBehavior: Flickable.StopAtBounds
                cacheBuffer: width
                reuseItems: true
                delegate: PlaylistCard {
                    required property var modelData
                    entry: modelData
                    onOpenRequested: window.openPlaylist(modelData.id, "tidal")
                }
            }
            ShelfScrollButtons { view: mixShelfList }
        }
        ColorButton {
            visible: Boolean((colorful.tidalHub.cursors || {})[parent.cursorSection])
            text: colorful.tidalMoreLoading ? "Loading…" : "Show more"
            quiet: true
            enabled: !colorful.tidalMoreLoading
            onClicked: colorful.loadMoreTidal(parent.cursorSection)
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 16

        ProviderHeader {
            Layout.fillWidth: true
            title: "TIDAL"
            accountText: root.accountValue("countryCode", "")
            refreshEnabled: colorful.linked && !colorful.tidalHubLoading
            onRefreshRequested: colorful.loadTidalHub(true)
        }

        Row {
            Layout.fillWidth: true
            spacing: 0
            Repeater {
                model: ["Home", "Collection", "Playlists & mixes"]
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
                        font.pixelSize: 12
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

                        MixShelf {
                            shelfTitle: "Your daily mixes"
                            entries: colorful.tidalHub.dailyMixes || []
                            cursorSection: "dailyMixes"
                        }
                        MixShelf {
                            shelfTitle: "Daily discovery"
                            entries: colorful.tidalHub.discoveryMixes || []
                            cursorSection: "discoveryMixes"
                        }
                        MixShelf {
                            shelfTitle: "New releases for you"
                            entries: colorful.tidalHub.newReleaseMixes || []
                            cursorSection: "newReleaseMixes"
                        }
                    }
                }
                Column {
                    anchors.centerIn: parent
                    width: Math.min(420, parent.width - 48)
                    spacing: 10
                    visible: colorful.linked && !colorful.tidalHubLoading && root.homeEmpty
                    AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/home.svg"; opacity: 0.28 }
                    Text { width: parent.width; text: "No recommendations yet"; color: "#f5f5f5"; horizontalAlignment: Text.AlignHCenter; font.bold: true; font.pixelSize: 16 }
                    Text { width: parent.width; text: "TIDAL will place daily mixes, discovery, and new releases here when they become available for this account."; color: Qt.rgba(1, 1, 1, 0.44); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.pixelSize: 12 }
                }
            }

            Item {
                ListView {
                    id: collectionTracks
                    anchors.fill: parent
                    model: colorful.tidalHub.tracks || []
                    clip: true
                    spacing: 0
                    pixelAligned: true
                    boundsBehavior: Flickable.StopAtBounds
                    cacheBuffer: 400
                    reuseItems: true
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    header: Column {
                    width: collectionTracks.width
                    spacing: 14
                    visible: !root.collectionEmpty
                    height: visible ? implicitHeight : 0
                    RowLayout { width: parent.width; visible: (colorful.tidalHub.artists || []).length > 0
                        Text { text: "Saved artists"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                        Item { Layout.fillWidth: true }
                    }
                    Item {
                        width: parent.width; height: visible ? 190 : 0
                        visible: (colorful.tidalHub.artists || []).length > 0
                        ListView {
                            id: tidalArtistsShelf
                            anchors.fill: parent
                            orientation: ListView.Horizontal
                            model: colorful.tidalHub.artists || []
                            spacing: 8; clip: true; pixelAligned: true
                            cacheBuffer: width; reuseItems: true
                            delegate: CatalogCard {
                                required property var modelData
                                entry: modelData; artistMode: true
                                onOpenRequested: window.openArtistItem({ id: modelData.id, provider: "tidal" })
                            }
                        }
                        ShelfScrollButtons { view: tidalArtistsShelf }
                    }
                    ColorButton {
                        visible: Boolean((colorful.tidalHub.cursors || {}).artists)
                        text: colorful.tidalMoreLoading ? "Loading…" : "Show more artists"
                        quiet: true; enabled: !colorful.tidalMoreLoading
                        onClicked: colorful.loadMoreTidal("artists")
                    }
                    RowLayout { width: parent.width; visible: (colorful.tidalHub.albums || []).length > 0
                        Text { text: "Saved albums"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                        Item { Layout.fillWidth: true }
                    }
                    Item {
                        width: parent.width; height: visible ? 206 : 0
                        visible: (colorful.tidalHub.albums || []).length > 0
                        ListView {
                            id: tidalAlbumsShelf
                            anchors.fill: parent
                            orientation: ListView.Horizontal
                            model: colorful.tidalHub.albums || []
                            spacing: 8; clip: true; pixelAligned: true
                            cacheBuffer: width; reuseItems: true
                            delegate: CatalogCard {
                                required property var modelData
                                entry: modelData
                                onOpenRequested: window.openAlbumItem({ id: modelData.id, provider: "tidal" })
                            }
                        }
                        ShelfScrollButtons { view: tidalAlbumsShelf }
                    }
                    ColorButton {
                        visible: Boolean((colorful.tidalHub.cursors || {}).albums)
                        text: colorful.tidalMoreLoading ? "Loading…" : "Show more albums"
                        quiet: true; enabled: !colorful.tidalMoreLoading
                        onClicked: colorful.loadMoreTidal("albums")
                    }
                    Text { visible: (colorful.tidalHub.tracks || []).length > 0; text: "Saved tracks"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                }
                delegate: TrackDelegate {
                    required property var modelData
                    width: collectionTracks.width
                    track: modelData
                    showSaveAction: false
                    onPlayRequested: colorful.playCatalogTrack(modelData)
                    onAddRequested: colorful.enqueueCatalogTrack(modelData)
                    onPlayNextRequested: colorful.playNextCatalogTrack(modelData)
                    onDetailsRequested: window.openTrackItem(modelData)
                    onStartRadioRequested: colorful.startRadio(modelData)
                }
                footer: ColorButton {
                    anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
                    visible: Boolean((colorful.tidalHub.cursors || {}).tracks)
                    text: colorful.tidalMoreLoading ? "Loading…" : "Show 20 more tracks"
                    quiet: true; enabled: !colorful.tidalMoreLoading
                    onClicked: colorful.loadMoreTidal("tracks")
                }
                }
                Column {
                    anchors.centerIn: parent
                    width: Math.min(420, parent.width - 48)
                    spacing: 10
                    visible: colorful.linked && !colorful.tidalHubLoading && root.collectionEmpty
                    AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/library.svg"; opacity: 0.28 }
                    Text { width: parent.width; text: "Your TIDAL collection is empty"; color: "#f5f5f5"; horizontalAlignment: Text.AlignHCenter; font.bold: true; font.pixelSize: 16 }
                    Text { width: parent.width; text: "Albums, artists, and tracks you save on TIDAL will appear here."; color: Qt.rgba(1, 1, 1, 0.44); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.pixelSize: 12 }
                }
            }

            Item {
                ListView {
                    id: playlistList
                    anchors.fill: parent
                    model: colorful.tidalHub.playlists || []
                    clip: true; spacing: 8; pixelAligned: true
                    boundsBehavior: Flickable.StopAtBounds
                    cacheBuffer: 300; reuseItems: true
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    header: Column {
                    width: playlistList.width
                    spacing: 12
                    visible: !root.playlistsEmpty
                    height: visible ? implicitHeight : 0
                    Text { visible: (colorful.tidalHub.mixes || []).length > 0; text: "Made for you"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                    ListView {
                        width: parent.width; height: visible ? 204 : 0
                        visible: (colorful.tidalHub.mixes || []).length > 0
                        orientation: ListView.Horizontal
                        model: colorful.tidalHub.mixes || []
                        spacing: 8; clip: true; pixelAligned: true
                        cacheBuffer: width; reuseItems: true
                        delegate: PlaylistCard {
                            required property var modelData
                            entry: modelData
                            onOpenRequested: window.openPlaylist(modelData.id, "tidal")
                        }
                    }
                    Text { visible: (colorful.tidalHub.playlists || []).length > 0; text: "Your playlists"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                }
                delegate: Rectangle {
                    required property var modelData
                    width: playlistList.width; height: 62
                    color: rowHover.hovered ? Qt.rgba(1, 1, 1, 0.055) : "transparent"
                    border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.07)
                    ArtworkImage { x: 7; y: 7; width: 48; height: 48; source: modelData.coverUrl || ""; decodeSize: 192 }
                    AppIcon { x: 22; y: 22; width: 18; height: 18; iconSource: "icons/music.svg"; opacity: 0.3; visible: colorful.lowDataMode || !modelData.coverUrl }
                    Column {
                        x: 67; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 150; spacing: 3
                        Text { width: parent.width; text: modelData.name || "Untitled playlist"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 12; elide: Text.ElideRight }
                        Text { width: parent.width; text: modelData.numberOfItems ? modelData.numberOfItems + " tracks" : (modelData.playlistType || "TIDAL"); color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: 10 }
                    }
                    HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: window.openPlaylist(modelData.id, "tidal") }
                }
                footer: ColorButton {
                    anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
                    visible: Boolean((colorful.tidalHub.cursors || {}).playlists)
                    text: colorful.tidalMoreLoading ? "Loading…" : "Show more playlists"
                    quiet: true; enabled: !colorful.tidalMoreLoading
                    onClicked: colorful.loadMoreTidal("playlists")
                }
                }
                Column {
                    anchors.centerIn: parent
                    width: Math.min(420, parent.width - 48)
                    spacing: 10
                    visible: colorful.linked && !colorful.tidalHubLoading && root.playlistsEmpty
                    AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/music.svg"; opacity: 0.28 }
                    Text { width: parent.width; text: "No playlists or mixes yet"; color: "#f5f5f5"; horizontalAlignment: Text.AlignHCenter; font.bold: true; font.pixelSize: 16 }
                    Text { width: parent.width; text: "Your playlists and mixes made by TIDAL will show up here when they become available."; color: Qt.rgba(1, 1, 1, 0.44); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.pixelSize: 12 }
                }
            }

        }
    }

    BusyIndicator {
        anchors.centerIn: parent
        running: !colorful.providerStatusResolved || colorful.tidalHubLoading
        visible: running
    }
    Column {
        anchors.centerIn: parent; spacing: 12
        visible: colorful.providerStatusResolved && !colorful.linked
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Connect TIDAL to load your collection and account"; color: Qt.rgba(1, 1, 1, 0.52); font.pixelSize: 13 }
        ColorButton { anchors.horizontalCenter: parent.horizontalCenter; text: "Connect TIDAL"; onClicked: colorful.startLogin() }
    }
}
