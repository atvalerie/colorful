import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    property int tab: 0
    property string selectedPlaylistId: ""
    readonly property var selectedPlaylist: playlistById(selectedPlaylistId)

    function playlistById(id) {
        const playlists = colorful.localPlaylists || []
        for (let index = 0; index < playlists.length; ++index)
            if (playlists[index].id === id) return playlists[index]
        return ({})
    }

    function openCreate() {
        playlistName.text = ""
        createPopup.open()
        playlistName.forceActiveFocus()
    }

    Connections {
        target: colorful
        function onLocalPlaylistsChanged() {
            if (root.selectedPlaylistId && !root.playlistById(root.selectedPlaylistId).id)
                root.selectedPlaylistId = ""
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            ColorButton {
                visible: root.selectedPlaylistId.length > 0
                text: "Back"
                quiet: true
                implicitWidth: 62
                onClicked: root.selectedPlaylistId = ""
            }
            Text {
                text: root.selectedPlaylistId ? (root.selectedPlaylist.name || "Playlist") : "Your library"
                color: "#f5f5f5"
                font.bold: true
                font.pixelSize: 24
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            ColorButton {
                visible: root.selectedPlaylistId.length > 0
                text: "Play"
                enabled: (root.selectedPlaylist.tracks || []).length > 0
                onClicked: colorful.playLocalPlaylist(root.selectedPlaylistId)
            }
            ColorButton {
                visible: root.selectedPlaylistId.length > 0
                text: "Add to queue"
                quiet: true
                enabled: (root.selectedPlaylist.tracks || []).length > 0
                onClicked: colorful.enqueueLocalPlaylist(root.selectedPlaylistId)
            }
            ColorButton {
                visible: root.selectedPlaylistId.length > 0
                text: "Rename"
                quiet: true
                onClicked: {
                    renameName.text = root.selectedPlaylist.name || ""
                    renamePopup.open()
                    renameName.forceActiveFocus()
                }
            }
            ColorButton {
                visible: root.selectedPlaylistId.length > 0
                text: "Delete"
                quiet: true
                onClicked: deletePopup.open()
            }
            ColorButton {
                visible: !root.selectedPlaylistId && root.tab === 1
                text: "New playlist"
                onClicked: root.openCreate()
            }
        }

        Row {
            visible: !root.selectedPlaylistId
            spacing: 0
            ColorButton { text: "Saved tracks"; quiet: root.tab !== 0; implicitWidth: 110; onClicked: root.tab = 0 }
            ColorButton { text: "Playlists"; quiet: root.tab !== 1; implicitWidth: 92; onClicked: root.tab = 1 }
        }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.selectedPlaylistId && root.tab === 0
            model: colorful.library
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            pixelAligned: true
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            delegate: TrackDelegate {
                required property int index
                required property var modelData
                track: modelData
                libraryMode: true
                showDownloadAction: ["tidal", "youtube", "soundcloud"].includes(modelData.provider || "tidal")
                onPlayRequested: colorful.playLibraryIndex(index)
                onAddRequested: colorful.enqueueCatalogTrack(modelData)
                onPlayNextRequested: colorful.playNextCatalogTrack(modelData)
                onRemoveRequested: colorful.removeLibraryIndex(index)
                onDownloadRequested: colorful.downloadTrack(modelData)
                onDetailsRequested: window.openTrackItem(modelData)
                onStartRadioRequested: colorful.startRadio(modelData)
            }
            Column {
                anchors.centerIn: parent
                width: Math.min(420, parent.width - 48)
                spacing: 10
                visible: parent.count === 0
                AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/library.svg"; opacity: 0.28 }
                Text { width: parent.width; text: "Tracks you save will live here on this device"; color: Qt.rgba(1,1,1,0.46); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.pixelSize: 13 }
            }
        }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.selectedPlaylistId && root.tab === 1
            model: colorful.localPlaylists
            spacing: 4
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            delegate: ItemDelegate {
                required property var modelData
                width: ListView.view.width
                height: 68
                hoverEnabled: true
                onClicked: root.selectedPlaylistId = modelData.id
                background: Rectangle { color: parent.hovered ? Qt.rgba(1,1,1,0.045) : Qt.rgba(1,1,1,0.018); border.width: 1; border.color: Qt.rgba(1,1,1,0.08) }
                contentItem: RowLayout {
                    spacing: 12
                    Rectangle {
                        Layout.preferredWidth: 48; Layout.preferredHeight: 48
                        color: Qt.rgba(1,1,1,0.06); clip: true
                        ArtworkImage { anchors.fill: parent; source: modelData.coverUrl || ""; decodeSize: 160 }
                        AppIcon { anchors.centerIn: parent; width: 20; height: 20; iconSource: "icons/music.svg"; opacity: 0.3; visible: colorful.lowDataMode || !modelData.coverUrl }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text { Layout.fillWidth: true; text: modelData.name || "Untitled playlist"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 14; elide: Text.ElideRight }
                        Text { text: (modelData.numberOfItems || 0) + ((modelData.numberOfItems || 0) === 1 ? " track" : " tracks"); color: Qt.rgba(1,1,1,0.42); font.pixelSize: 11 }
                    }
                    ColorButton { text: "Play"; quiet: true; enabled: (modelData.numberOfItems || 0) > 0; onClicked: colorful.playLocalPlaylist(modelData.id) }
                }
            }
            Column {
                anchors.centerIn: parent
                width: Math.min(420, parent.width - 48)
                spacing: 10
                visible: parent.count === 0
                AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/music.svg"; opacity: 0.28 }
                Text { width: parent.width; text: "Build playlists from tracks across every provider"; color: Qt.rgba(1,1,1,0.46); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.pixelSize: 13 }
                ColorButton { anchors.horizontalCenter: parent.horizontalCenter; text: "Create your first playlist"; onClicked: root.openCreate() }
            }
        }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.selectedPlaylistId.length > 0
            model: root.selectedPlaylist.tracks || []
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            pixelAligned: true
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            delegate: TrackDelegate {
                required property int index
                required property var modelData
                track: modelData
                queueMode: true
                removeActionText: "Remove from playlist"
                queueIndex: index
                queueCount: ListView.view.count
                showDownloadAction: ["tidal", "youtube", "soundcloud"].includes(modelData.provider || "tidal")
                onPlayRequested: {
                    colorful.playLocalPlaylist(root.selectedPlaylistId, index)
                }
                onAddRequested: colorful.enqueueCatalogTrack(modelData)
                onPlayNextRequested: colorful.playNextCatalogTrack(modelData)
                onRemoveRequested: colorful.removeLocalPlaylistItem(root.selectedPlaylistId, index)
                onMoveUpRequested: colorful.moveLocalPlaylistItem(root.selectedPlaylistId, index, index - 1)
                onMoveDownRequested: colorful.moveLocalPlaylistItem(root.selectedPlaylistId, index, index + 1)
                onMoveRequested: function(targetIndex) { colorful.moveLocalPlaylistItem(root.selectedPlaylistId, index, targetIndex) }
                onDownloadRequested: colorful.downloadTrack(modelData)
                onDetailsRequested: window.openTrackItem(modelData)
                onStartRadioRequested: colorful.startRadio(modelData)
            }
            Column {
                anchors.centerIn: parent; width: Math.min(400, parent.width - 48); spacing: 8; visible: parent.count === 0
                Text { width: parent.width; text: "This playlist is empty"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter }
                Text { width: parent.width; text: "Use “Add to playlist” on any track."; color: Qt.rgba(1,1,1,0.44); font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter }
            }
        }
    }

    Popup {
        id: createPopup
        anchors.centerIn: Overlay.overlay; width: 360; height: 170; modal: true; padding: 20
        background: Rectangle { color: "#19191e"; border.width: 1; border.color: Qt.rgba(colorful.accent.r,colorful.accent.g,colorful.accent.b,0.7) }
        contentItem: ColumnLayout {
            spacing: 10
            Text { text: "Create playlist"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 18 }
            TextField { id: playlistName; Layout.fillWidth: true; placeholderText: "Playlist name"; color: "#f5f5f5"; onAccepted: if (text.trim()) { colorful.createLocalPlaylist(text); createPopup.close() } }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                ColorButton { text: "Cancel"; quiet: true; onClicked: createPopup.close() }
                ColorButton { text: "Create"; enabled: playlistName.text.trim().length > 0; onClicked: { colorful.createLocalPlaylist(playlistName.text); createPopup.close() } }
            }
        }
    }

    Popup {
        id: renamePopup
        anchors.centerIn: Overlay.overlay; width: 360; height: 170; modal: true; padding: 20
        background: Rectangle { color: "#19191e"; border.width: 1; border.color: Qt.rgba(colorful.accent.r,colorful.accent.g,colorful.accent.b,0.7) }
        contentItem: ColumnLayout {
            spacing: 10
            Text { text: "Rename playlist"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 18 }
            TextField { id: renameName; Layout.fillWidth: true; color: "#f5f5f5"; onAccepted: if (text.trim()) { colorful.renameLocalPlaylist(root.selectedPlaylistId, text); renamePopup.close() } }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                ColorButton { text: "Cancel"; quiet: true; onClicked: renamePopup.close() }
                ColorButton { text: "Rename"; enabled: renameName.text.trim().length > 0; onClicked: { colorful.renameLocalPlaylist(root.selectedPlaylistId, renameName.text); renamePopup.close() } }
            }
        }
    }

    Popup {
        id: deletePopup
        anchors.centerIn: Overlay.overlay; width: 370; height: 160; modal: true; padding: 20
        background: Rectangle { color: "#19191e"; border.width: 1; border.color: Qt.rgba(1,0.25,0.35,0.65) }
        contentItem: ColumnLayout {
            spacing: 10
            Text { text: "Delete “" + (root.selectedPlaylist.name || "playlist") + "”?"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 18; elide: Text.ElideRight; Layout.fillWidth: true }
            Text { text: "The tracks themselves and offline downloads are kept."; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11 }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                ColorButton { text: "Cancel"; quiet: true; onClicked: deletePopup.close() }
                ColorButton { text: "Delete"; onClicked: { colorful.deleteLocalPlaylist(root.selectedPlaylistId); root.selectedPlaylistId = ""; deletePopup.close() } }
            }
        }
    }
}
