import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    readonly property bool empty: (colorful.soundcloudHub.tracks || []).length === 0
                                  && (colorful.soundcloudHub.albums || []).length === 0
                                  && (colorful.soundcloudHub.artists || []).length === 0

    ColumnLayout {
        anchors.fill: parent
        spacing: 16

        RowLayout {
            Layout.fillWidth: true
            Text { text: "SoundCloud"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 24 }
            Text {
                text: ((colorful.soundcloudHub.account || {}).username) || ""
                visible: text.length > 0; color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: 10
            }
            Item { Layout.fillWidth: true }
            ColorButton {
                text: "Refresh"; quiet: true
                enabled: colorful.soundcloudLinked && !colorful.soundcloudHubLoading
                onClicked: colorful.loadSoundCloudHub(true)
            }
        }

        ListView {
            id: tracks
            Layout.fillWidth: true; Layout.fillHeight: true
            model: colorful.soundcloudHub.tracks || []
            clip: true; pixelAligned: true; boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            header: Column {
                width: tracks.width; spacing: 14
                visible: !root.empty; height: visible ? implicitHeight + 12 : 0
                Text { visible: (colorful.soundcloudHub.artists || []).length > 0; text: "Following"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                ListView {
                    width: parent.width; height: visible ? 190 : 0
                    visible: (colorful.soundcloudHub.artists || []).length > 0
                    orientation: ListView.Horizontal; model: colorful.soundcloudHub.artists || []
                    spacing: 8; clip: true; pixelAligned: true
                    delegate: CatalogCard {
                        required property var modelData
                        entry: modelData; artistMode: true
                        onOpenRequested: colorful.openArtistItem(modelData)
                    }
                }
                Text { visible: (colorful.soundcloudHub.albums || []).length > 0; text: "Sets & playlists"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                ListView {
                    width: parent.width; height: visible ? 206 : 0
                    visible: (colorful.soundcloudHub.albums || []).length > 0
                    orientation: ListView.Horizontal; model: colorful.soundcloudHub.albums || []
                    spacing: 8; clip: true; pixelAligned: true
                    delegate: CatalogCard {
                        required property var modelData
                        entry: modelData
                        onOpenRequested: colorful.openAlbumItem(modelData)
                    }
                }
                Text { visible: (colorful.soundcloudHub.tracks || []).length > 0; text: "Liked tracks"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
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
    }

    BusyIndicator { anchors.centerIn: parent; running: colorful.soundcloudHubLoading; visible: running }
    Column {
        anchors.centerIn: parent; width: Math.min(430, parent.width - 48); spacing: 9
        visible: colorful.soundcloudLinked && !colorful.soundcloudHubLoading && root.empty
        AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/soundcloud.svg"; opacity: 0.28 }
        Text { width: parent.width; text: "Your SoundCloud library is empty"; color: "#f5f5f5"; horizontalAlignment: Text.AlignHCenter; font.bold: true; font.pixelSize: 16 }
        Text { width: parent.width; text: "Liked tracks, sets, and followed profiles will appear here."; color: Qt.rgba(1, 1, 1, 0.44); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.pixelSize: 12 }
    }
    Column {
        anchors.centerIn: parent; spacing: 12; visible: !colorful.soundcloudLinked
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Connect SoundCloud to load your library"; color: Qt.rgba(1, 1, 1, 0.52); font.pixelSize: 13 }
        ColorButton { anchors.horizontalCenter: parent.horizontalCenter; text: "Open account settings"; onClicked: window.openSettings(0) }
    }
}
