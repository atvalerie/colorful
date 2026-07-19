import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ItemDelegate {
    id: root
    required property var entry
    property bool artistMode: false
    signal openRequested()

    implicitWidth: 148
    implicitHeight: 190
    padding: 8
    hoverEnabled: true
    onClicked: openRequested()

    background: Rectangle {
        color: root.hovered ? Qt.rgba(1, 1, 1, 0.065) : Qt.rgba(1, 1, 1, 0.025)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, root.hovered ? 0.18 : 0.08)
    }

    contentItem: ColumnLayout {
        spacing: 7
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: width
            color: Qt.rgba(1, 1, 1, 0.06)
            clip: true
            ArtworkImage {
                anchors.fill: parent
                source: root.artistMode ? (root.entry.pictureUrl || "") : (root.entry.coverUrl || "")
                decodeSize: 512
            }
            AppIcon {
                anchors.centerIn: parent
                width: 24
                height: 24
                iconSource: root.artistMode ? "icons/user.svg" : "icons/music.svg"
                opacity: 0.3
                visible: root.artistMode ? !root.entry.pictureUrl : !root.entry.coverUrl
            }
        }
        Text {
            Layout.fillWidth: true
            text: root.artistMode ? (root.entry.name || "Unknown artist") : (root.entry.title || "Unknown album")
            color: "#f5f5f5"
            font.weight: Font.DemiBold
            font.pixelSize: 12
            elide: Text.ElideRight
        }
        Text {
            Layout.fillWidth: true
            visible: !root.artistMode
            text: root.entry.artistText || "Unknown artist"
            color: Qt.rgba(1, 1, 1, 0.46)
            font.pixelSize: 10
            elide: Text.ElideRight
        }
    }
}
