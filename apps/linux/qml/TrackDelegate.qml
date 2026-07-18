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
    height: 70
    hoverEnabled: true
    padding: 8
    onDoubleClicked: playRequested()

    background: Rectangle {
        radius: 15
        color: root.active ? Qt.rgba(colorful.accent.r, colorful.accent.g, colorful.accent.b, 0.24)
                           : root.hovered ? Qt.rgba(1, 1, 1, 0.075) : "transparent"
        border.width: root.active ? 1 : 0
        border.color: Qt.rgba(colorful.accent.r, colorful.accent.g, colorful.accent.b, 0.5)
        Behavior on color { ColorAnimation { duration: 150 } }
    }

    contentItem: RowLayout {
        spacing: 12

        Rectangle {
            Layout.preferredWidth: 52
            Layout.preferredHeight: 52
            radius: 11
            color: Qt.rgba(1, 1, 1, 0.08)
            clip: true
            Image {
                anchors.fill: parent
                source: root.track.coverUrl || ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }
            Text {
                anchors.centerIn: parent
                visible: !root.track.coverUrl
                text: "♪"
                color: Qt.rgba(1, 1, 1, 0.45)
                font.pixelSize: 21
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            Text {
                Layout.fillWidth: true
                text: root.track.title || "Unknown title"
                color: "#fffafc"
                elide: Text.ElideRight
                font.family: "Nunito"
                font.weight: Font.DemiBold
                font.pixelSize: 15
            }
            Text {
                Layout.fillWidth: true
                text: root.track.artistText || "Unknown artist"
                color: Qt.rgba(1, 1, 1, 0.6)
                elide: Text.ElideRight
                font.family: "Nunito"
                font.pixelSize: 12
            }
        }

        Text {
            text: root.track.durationMs ? formatDuration(root.track.durationMs) : ""
            color: Qt.rgba(1, 1, 1, 0.46)
            font.family: "Nunito"
            font.pixelSize: 12
        }

        ToolButton {
            text: root.queueMode ? "×" : "+"
            font.pixelSize: root.queueMode ? 22 : 20
            onClicked: root.queueMode ? root.removeRequested() : root.addRequested()
            contentItem: Text {
                text: parent.text
                color: parent.hovered ? "white" : Qt.rgba(1, 1, 1, 0.58)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                font.pixelSize: parent.font.pixelSize
            }
            background: Rectangle {
                radius: width / 2
                color: parent.hovered ? Qt.rgba(1, 1, 1, 0.1) : "transparent"
            }
        }
    }

    function formatDuration(milliseconds) {
        const seconds = Math.floor(milliseconds / 1000)
        return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0")
    }
}

