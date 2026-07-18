import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ItemDelegate {
    id: root
    required property var track
    property bool active: false
    property bool queueMode: false
    signal playRequested()
    signal addRequested()
    signal removeRequested()

    width: ListView.view ? ListView.view.width : 500
    height: 54
    hoverEnabled: true
    padding: 6
    onDoubleClicked: playRequested()

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

            Image {
                anchors.fill: parent
                source: root.track.coverUrl || ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }
            AppIcon {
                anchors.centerIn: parent
                width: 18
                height: 18
                iconSource: "icons/music.svg"
                opacity: 0.34
                visible: !root.track.coverUrl
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

        Text {
            text: root.track.durationMs ? formatDuration(root.track.durationMs) : ""
            color: Qt.rgba(1, 1, 1, 0.4)
            font.pixelSize: 10
        }

        IconButton {
            implicitWidth: 36
            implicitHeight: 36
            iconSource: root.queueMode ? "icons/close.svg" : "icons/add.svg"
            tooltipText: root.queueMode ? "Remove from queue" : "Add to queue"
            onClicked: root.queueMode ? root.removeRequested() : root.addRequested()
        }
    }

    function formatDuration(milliseconds) {
        const seconds = Math.floor(milliseconds / 1000)
        return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0")
    }
}
