import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ItemDelegate {
    id: root

    component CompactMenuItem: MenuItem {
        implicitWidth: 168
        implicitHeight: visible ? 28 : 0
        height: visible ? 28 : 0
        padding: 0
        leftPadding: 9
        rightPadding: 9

        contentItem: Text {
            text: parent.text
            color: parent.enabled ? "#eeeeef" : Qt.rgba(1, 1, 1, 0.32)
            font.pixelSize: 12
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        background: Rectangle {
            color: parent.highlighted
                   ? Qt.rgba(colorful.accent.r, colorful.accent.g, colorful.accent.b, 0.22)
                   : "transparent"
        }
    }

    component CompactSeparator: MenuSeparator {
        implicitWidth: 168
        implicitHeight: 7
        padding: 3
        contentItem: Rectangle {
            implicitHeight: 1
            color: Qt.rgba(1, 1, 1, 0.12)
        }
    }

    required property var track
    property bool active: false
    property bool queueMode: false
    property bool libraryMode: false
    property bool showSaveAction: false
    property bool showDownloadAction: false
    property string removeActionText: ""
    property int queueIndex: -1
    property int queueCount: 0
    signal playRequested()
    signal addRequested()
    signal removeRequested()
    signal saveRequested()
    signal downloadRequested()
    signal detailsRequested()
    signal startRadioRequested()
    signal playNextRequested()
    signal moveRequested(int targetIndex)
    signal moveUpRequested()
    signal moveDownRequested()

    width: ListView.view ? ListView.view.width : (parent ? parent.width : 500)
    height: 54
    hoverEnabled: true
    padding: 6
    onDoubleClicked: playRequested()
    onClicked: detailsRequested()

    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: contextMenu.popup()
    }

    Menu {
        id: contextMenu
        implicitWidth: 176
        padding: 4
        margins: 0

        background: Rectangle {
            color: "#0d0d0f"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.2)
        }

        CompactMenuItem { text: "Play"; onTriggered: root.playRequested() }
        CompactMenuItem {
            visible: !root.queueMode
            text: "Play next"
            onTriggered: root.playNextRequested()
        }
        CompactMenuItem { text: "Start radio"; onTriggered: root.startRadioRequested() }
        CompactSeparator {}
        CompactMenuItem {
            text: root.queueMode ? (root.removeActionText || "Remove from queue") : "Add to queue"
            onTriggered: root.queueMode ? root.removeRequested() : root.addRequested()
        }
        CompactMenuItem {
            visible: root.queueMode
            enabled: root.queueIndex > 0
            text: "Move up"
            onTriggered: root.moveUpRequested()
        }
        CompactMenuItem {
            visible: root.queueMode
            enabled: root.queueIndex + 1 < root.queueCount
            text: "Move down"
            onTriggered: root.moveDownRequested()
        }
        CompactMenuItem {
            visible: root.libraryMode
            text: root.removeActionText || "Remove from library"
            onTriggered: root.removeRequested()
        }
        CompactMenuItem {
            visible: root.showSaveAction
            text: "Save to library"
            onTriggered: root.saveRequested()
        }
        CompactMenuItem {
            text: "Add to playlist…"
            onTriggered: colorful.showPlaylistPicker(root.track)
        }
        CompactMenuItem {
            visible: root.showDownloadAction
            text: "Download"
            onTriggered: root.downloadRequested()
        }
        CompactSeparator {}
        CompactMenuItem { text: "Open details"; onTriggered: root.detailsRequested() }
    }

    Drag.active: queueDrag.active
    Drag.source: root
    Drag.hotSpot.x: width / 2
    Drag.hotSpot.y: height / 2

    DragHandler {
        id: queueDrag
        enabled: root.queueMode
        target: null
        acceptedButtons: Qt.LeftButton
    }

    DropArea {
        anchors.fill: parent
        enabled: root.queueMode
        onDropped: function(drop) {
            if (drop.source && drop.source.queueIndex >= 0
                    && drop.source.queueIndex !== root.queueIndex) {
                drop.source.moveRequested(root.queueIndex)
                drop.acceptProposedAction()
            }
        }
    }

    background: Rectangle {
        color: root.active ? Qt.rgba(colorful.accent.r, colorful.accent.g, colorful.accent.b, 0.12)
                           : root.hovered ? Qt.rgba(1, 1, 1, 0.045) : "transparent"
        border.width: root.active ? 1 : 0
        border.color: Qt.rgba(colorful.accent.r, colorful.accent.g, colorful.accent.b, 0.42)
        Behavior on color { ColorAnimation { duration: 100 } }
    }

    contentItem: RowLayout {
        spacing: 10

        Rectangle {
            Layout.preferredWidth: 40
            Layout.preferredHeight: 40
            color: Qt.rgba(1, 1, 1, 0.07)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.09)
            clip: true

            ArtworkImage {
                anchors.fill: parent
                source: root.track.coverUrl || ""
                decodeSize: 160
            }
            AppIcon {
                anchors.centerIn: parent
                width: 18
                height: 18
                iconSource: "icons/music.svg"
                opacity: 0.34
                visible: colorful.lowDataMode || !root.track.coverUrl
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1
            Text {
                Layout.fillWidth: true
                text: root.track.title || "Unknown title"
                color: "#f5f5f5"
                elide: Text.ElideRight
                font.weight: Font.DemiBold
                font.pixelSize: 13
            }
            Text {
                Layout.fillWidth: true
                text: root.track.artistText || "Unknown artist"
                color: Qt.rgba(1, 1, 1, 0.48)
                elide: Text.ElideRight
                font.pixelSize: 11
            }
        }

        AppIcon {
            Layout.preferredWidth: 14
            Layout.preferredHeight: 14
            Layout.alignment: Qt.AlignVCenter
            iconSource: (root.track.provider || "tidal") === "youtube" ? "icons/youtube.svg"
                        : root.track.provider === "soundcloud" ? "icons/soundcloud.svg"
                        : "icons/tidal.svg"
            opacity: 0.48
        }

        Text {
            text: root.track.durationMs ? formatDuration(root.track.durationMs) : ""
            color: Qt.rgba(1, 1, 1, 0.4)
            font.pixelSize: 10
        }

        IconButton {
            implicitWidth: 36
            implicitHeight: 36
            iconSource: root.queueMode || root.libraryMode ? "icons/close.svg" : "icons/add.svg"
            tooltipText: root.queueMode ? (root.removeActionText || "Remove from queue")
                         : root.libraryMode ? (root.removeActionText || "Remove from library") : "Add to queue"
            onClicked: root.queueMode || root.libraryMode ? root.removeRequested() : root.addRequested()
        }

        IconButton {
            visible: root.showSaveAction
            implicitWidth: visible ? 36 : 0
            implicitHeight: 36
            iconSource: "icons/library.svg"
            tooltipText: "Save to library"
            onClicked: root.saveRequested()
        }

        IconButton {
            visible: root.showDownloadAction
            implicitWidth: visible ? 36 : 0
            implicitHeight: 36
            iconSource: "icons/download.svg"
            tooltipText: "Download for offline playback"
            onClicked: root.downloadRequested()
        }
    }

    function formatDuration(milliseconds) {
        const seconds = Math.floor(milliseconds / 1000)
        return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0")
    }
}
