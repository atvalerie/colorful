import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    property int tab: 0
    readonly property bool collectionEmpty: (colorful.youtubeHub.tracks || []).length === 0
                                            && (colorful.youtubeHub.albums || []).length === 0
                                            && (colorful.youtubeHub.artists || []).length === 0
    readonly property bool playlistsEmpty: (colorful.youtubeHub.playlists || []).length === 0
                                           && (colorful.youtubeHub.mixes || []).length === 0

    ColumnLayout {
        anchors.fill: parent
        spacing: 16

        RowLayout {
            Layout.fillWidth: true
            Text { text: "YouTube Music"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 24 }
            Text {
                text: ((colorful.youtubeHub.account || {}).channelHandle) || ""
                visible: text.length > 0; color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: 10
            }
            Item { Layout.fillWidth: true }
            ColorButton {
                text: "Refresh"; quiet: true
                enabled: colorful.youtubeLinked && !colorful.youtubeHubLoading
                onClicked: colorful.loadYouTubeHub(true)
            }
        }

        Row {
            Layout.fillWidth: true; spacing: 0
            Repeater {
                model: ["Library", "Playlists & mixes"]
                delegate: Rectangle {
                    required property string modelData
                    required property int index
                    width: tabLabel.implicitWidth + 30; height: 36
                    color: root.tab === index ? Qt.rgba(1, 1, 1, 0.075) : "transparent"
                    border.width: 1; border.color: root.tab === index ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
                    Text { id: tabLabel; anchors.centerIn: parent; text: modelData; color: root.tab === index ? "#f5f5f5" : Qt.rgba(1, 1, 1, 0.56); font.bold: root.tab === index; font.pixelSize: 12 }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.tab = index }
                }
            }
        }

        StackLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; currentIndex: root.tab
            Item {
                ListView {
                    id: tracks
                    anchors.fill: parent; model: colorful.youtubeHub.tracks || []
                    clip: true; pixelAligned: true; boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    header: Column {
                        width: tracks.width; spacing: 14
                        visible: !root.collectionEmpty; height: visible ? implicitHeight : 0
                        Text { visible: (colorful.youtubeHub.artists || []).length > 0; text: "Library artists"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                        ListView {
                            width: parent.width; height: visible ? 190 : 0
                            visible: (colorful.youtubeHub.artists || []).length > 0
                            orientation: ListView.Horizontal; model: colorful.youtubeHub.artists || []
                            spacing: 8; clip: true; pixelAligned: true
                            delegate: CatalogCard {
                                required property var modelData
                                entry: modelData; artistMode: true
                                onOpenRequested: colorful.openArtistItem(modelData)
                            }
                        }
                        Text { visible: (colorful.youtubeHub.albums || []).length > 0; text: "Saved albums"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                        ListView {
                            width: parent.width; height: visible ? 206 : 0
                            visible: (colorful.youtubeHub.albums || []).length > 0
                            orientation: ListView.Horizontal; model: colorful.youtubeHub.albums || []
                            spacing: 8; clip: true; pixelAligned: true
                            delegate: CatalogCard {
                                required property var modelData
                                entry: modelData
                                onOpenRequested: colorful.openAlbumItem(modelData)
                            }
                        }
                        Text { visible: (colorful.youtubeHub.tracks || []).length > 0; text: "Library songs"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                    }
                    delegate: TrackDelegate {
                        required property var modelData
                        width: tracks.width; track: modelData; showSaveAction: false
                        onPlayRequested: colorful.playCatalogTrack(modelData)
                        onAddRequested: colorful.enqueueCatalogTrack(modelData)
                        onPlayNextRequested: colorful.playNextCatalogTrack(modelData)
                        onDetailsRequested: colorful.openTrackItem(modelData)
                        onStartRadioRequested: colorful.startRadio(modelData)
                    }
                }
                Column {
                    anchors.centerIn: parent; width: Math.min(430, parent.width - 48); spacing: 9
                    visible: colorful.youtubeLinked && !colorful.youtubeHubLoading && root.collectionEmpty
                    AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/library.svg"; opacity: 0.28 }
                    Text { width: parent.width; text: "Your YouTube Music library is empty"; color: "#f5f5f5"; horizontalAlignment: Text.AlignHCenter; font.bold: true; font.pixelSize: 16 }
                    Text { width: parent.width; text: "Liked and saved music associated with this account will appear here."; color: Qt.rgba(1, 1, 1, 0.44); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.pixelSize: 12 }
                }
            }

            Item {
                ListView {
                    id: playlists
                    anchors.fill: parent; model: colorful.youtubeHub.playlists || []
                    clip: true; spacing: 8; pixelAligned: true; boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    header: Column {
                        width: playlists.width; spacing: 12
                        visible: !root.playlistsEmpty; height: visible ? implicitHeight : 0
                        Text { visible: (colorful.youtubeHub.mixes || []).length > 0; text: "For you"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                        ListView {
                            width: parent.width; height: visible ? 204 : 0
                            visible: (colorful.youtubeHub.mixes || []).length > 0
                            orientation: ListView.Horizontal; model: colorful.youtubeHub.mixes || []
                            spacing: 8; clip: true; pixelAligned: true
                            delegate: PlaylistCard {
                                required property var modelData
                                entry: modelData
                                onOpenRequested: colorful.openPlaylist(modelData.id, "youtube")
                            }
                        }
                        Text { visible: (colorful.youtubeHub.playlists || []).length > 0; text: "Your playlists"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                    }
                    delegate: Rectangle {
                        required property var modelData
                        width: playlists.width; height: 62
                        color: rowHover.hovered ? Qt.rgba(1, 1, 1, 0.055) : "transparent"
                        border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.07)
                        ArtworkImage { x: 7; y: 7; width: 48; height: 48; source: modelData.coverUrl || ""; decodeSize: 192 }
                        AppIcon { x: 22; y: 22; width: 18; height: 18; iconSource: "icons/youtube.svg"; opacity: 0.34; visible: colorful.lowDataMode || !modelData.coverUrl }
                        Column {
                            x: 67; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 84; spacing: 3
                            Text { width: parent.width; text: modelData.name || "Untitled playlist"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 12; elide: Text.ElideRight }
                            Text { width: parent.width; text: modelData.numberOfItems ? modelData.numberOfItems + " tracks" : "YouTube Music"; color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: 10 }
                        }
                        HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: colorful.openPlaylist(modelData.id, "youtube") }
                    }
                }
                Column {
                    anchors.centerIn: parent; width: Math.min(430, parent.width - 48); spacing: 9
                    visible: colorful.youtubeLinked && !colorful.youtubeHubLoading && root.playlistsEmpty
                    AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/youtube.svg"; opacity: 0.28 }
                    Text { width: parent.width; text: "No private playlists or mixes found"; color: "#f5f5f5"; horizontalAlignment: Text.AlignHCenter; font.bold: true; font.pixelSize: 16 }
                    Text { width: parent.width; text: "Playlists saved to this YouTube Music account will appear here."; color: Qt.rgba(1, 1, 1, 0.44); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.pixelSize: 12 }
                }
            }
        }
    }

    BusyIndicator { anchors.centerIn: parent; running: colorful.youtubeHubLoading; visible: running }
    Column {
        anchors.centerIn: parent; spacing: 12; visible: !colorful.youtubeLinked
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Connect YouTube Music to load private playlists and your library"; color: Qt.rgba(1, 1, 1, 0.52); font.pixelSize: 13 }
        ColorButton { anchors.horizontalCenter: parent.horizontalCenter; text: "Open account settings"; onClicked: window.openSettings(0) }
    }
}
