import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    property int tab: 0
    readonly property var hub: colorful.soundcloudHub || ({})
    readonly property bool libraryEmpty: (hub.tracks || []).length === 0
                                         && (hub.albums || []).length === 0
                                         && (hub.artists || []).length === 0
    readonly property bool homeEmpty: (hub.homeSections || []).length === 0
                                      && (hub.suggestedArtists || []).length === 0

    ColumnLayout {
        anchors.fill: parent
        spacing: 14

        RowLayout {
            Layout.fillWidth: true
            Text { text: "SoundCloud"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 24 }
            Text {
                text: (root.hub.account || {}).username || ""
                visible: text.length > 0; color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: 10
            }
            Item { Layout.fillWidth: true }
            ColorButton {
                text: "Refresh"; quiet: true
                enabled: colorful.soundcloudLinked && !colorful.soundcloudHubLoading
                onClicked: colorful.loadSoundCloudHub(true)
            }
        }

        Row {
            Layout.fillWidth: true
            Repeater {
                model: ["Home", "Library"]
                delegate: Rectangle {
                    required property string modelData
                    required property int index
                    width: label.implicitWidth + 30; height: 36
                    color: root.tab === index ? Qt.rgba(1, 1, 1, 0.075) : "transparent"
                    border.width: 1
                    border.color: root.tab === index ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
                    Text {
                        id: label; anchors.centerIn: parent; text: modelData
                        color: root.tab === index ? "#f5f5f5" : Qt.rgba(1, 1, 1, 0.56)
                        font.bold: root.tab === index; font.pixelSize: 12
                    }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.tab = index }
                }
            }
        }

        StackLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            currentIndex: root.tab

            Item {
                ListView {
                    id: homeList
                    anchors.fill: parent; model: root.hub.homeSections || []
                    spacing: 14; clip: true; pixelAligned: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    header: Column {
                        width: homeList.width; spacing: 8
                        visible: (root.hub.suggestedArtists || []).length > 0
                        height: visible ? 246 : 0
                        Text { text: "Who to follow"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                        ListView {
                            width: parent.width; height: 212; orientation: ListView.Horizontal
                            model: root.hub.suggestedArtists || []; spacing: 8; clip: true; pixelAligned: true
                            delegate: CatalogCard {
                                required property var modelData
                                entry: modelData; artistMode: true
                                onOpenRequested: window.openArtistItem(modelData)
                            }
                        }
                    }
                    delegate: Column {
                        required property var modelData
                        width: homeList.width; height: 252; spacing: 8
                        Text { text: modelData.title || "For you"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                        ListView {
                            width: parent.width; height: 212; orientation: ListView.Horizontal
                            model: modelData.items || []; spacing: 8; clip: true; pixelAligned: true
                            delegate: CatalogCard {
                                required property var modelData
                                entry: modelData
                                onOpenRequested: window.openAlbumItem(modelData)
                            }
                        }
                    }
                    footer: Item { width: homeList.width; height: 36 }
                }
                Column {
                    anchors.centerIn: parent; spacing: 8
                    visible: colorful.soundcloudLinked && !colorful.soundcloudHubLoading && root.homeEmpty
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Nothing recommended yet"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 16 }
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: "SoundCloud did not return any home shelves for this account."; color: Qt.rgba(1, 1, 1, 0.44); font.pixelSize: 12 }
                }
            }

            Item {
                ListView {
                    id: tracks
                    anchors.fill: parent; model: root.hub.tracks || []
                    clip: true; pixelAligned: true; boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    header: Column {
                        width: tracks.width; spacing: 12
                        visible: !root.libraryEmpty; height: visible ? implicitHeight + 10 : 0
                        Text { visible: (root.hub.artists || []).length > 0; text: "Following"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                        ListView {
                            width: parent.width; height: visible ? 212 : 0
                            visible: (root.hub.artists || []).length > 0
                            orientation: ListView.Horizontal; model: root.hub.artists || []
                            spacing: 8; clip: true; pixelAligned: true
                            delegate: CatalogCard {
                                required property var modelData
                                entry: modelData; artistMode: true
                                onOpenRequested: window.openArtistItem(modelData)
                            }
                        }
                        ColorButton {
                            visible: Boolean((root.hub.cursors || {}).artists)
                            text: colorful.soundcloudMoreLoading ? "Loading…" : "Show more profiles"
                            quiet: true; enabled: !colorful.soundcloudMoreLoading
                            onClicked: colorful.loadMoreSoundCloud("artists")
                        }
                        Text { visible: (root.hub.albums || []).length > 0; text: "Sets & playlists"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                        ListView {
                            width: parent.width; height: visible ? 220 : 0
                            visible: (root.hub.albums || []).length > 0
                            orientation: ListView.Horizontal; model: root.hub.albums || []
                            spacing: 8; clip: true; pixelAligned: true
                            delegate: CatalogCard {
                                required property var modelData
                                entry: modelData
                                onOpenRequested: window.openAlbumItem(modelData)
                            }
                        }
                        ColorButton {
                            visible: Boolean((root.hub.cursors || {}).albums)
                            text: colorful.soundcloudMoreLoading ? "Loading…" : "Show more sets"
                            quiet: true; enabled: !colorful.soundcloudMoreLoading
                            onClicked: colorful.loadMoreSoundCloud("albums")
                        }
                        Text { visible: (root.hub.tracks || []).length > 0; text: "Liked tracks"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                    }
                    delegate: TrackDelegate {
                        required property var modelData
                        width: tracks.width; track: modelData; showSaveAction: false
                        showDownloadAction: true
                        onPlayRequested: colorful.playCatalogTrack(modelData)
                        onAddRequested: colorful.enqueueCatalogTrack(modelData)
                        onPlayNextRequested: colorful.playNextCatalogTrack(modelData)
                        onDownloadRequested: colorful.downloadTrack(modelData)
                        onDetailsRequested: window.openTrackItem(modelData)
                        onStartRadioRequested: colorful.startRadio(modelData)
                    }
                    footer: Item {
                        width: tracks.width; height: moreTracks.visible ? 52 : 0
                        ColorButton {
                            id: moreTracks; anchors.centerIn: parent
                            visible: Boolean((root.hub.cursors || {}).tracks)
                            text: colorful.soundcloudMoreLoading ? "Loading…" : "Show more liked tracks"
                            quiet: true; enabled: !colorful.soundcloudMoreLoading
                            onClicked: colorful.loadMoreSoundCloud("tracks")
                        }
                    }
                }
                Column {
                    anchors.centerIn: parent; width: Math.min(430, parent.width - 48); spacing: 9
                    visible: colorful.soundcloudLinked && !colorful.soundcloudHubLoading && root.libraryEmpty
                    AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/soundcloud.svg"; opacity: 0.28 }
                    Text { width: parent.width; text: "Your SoundCloud library is empty"; color: "#f5f5f5"; horizontalAlignment: Text.AlignHCenter; font.bold: true; font.pixelSize: 16 }
                    Text { width: parent.width; text: "Liked tracks, sets, and followed profiles will appear here."; color: Qt.rgba(1, 1, 1, 0.44); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.pixelSize: 12 }
                }
            }
        }
    }

    BusyIndicator { anchors.centerIn: parent; running: colorful.soundcloudHubLoading; visible: running }
    Column {
        anchors.centerIn: parent; spacing: 12; visible: !colorful.soundcloudLinked
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Connect SoundCloud to load your home and library"; color: Qt.rgba(1, 1, 1, 0.52); font.pixelSize: 13 }
        ColorButton { anchors.horizontalCenter: parent.horizontalCenter; text: "Open account settings"; onClicked: window.openSettings(0) }
    }
}
