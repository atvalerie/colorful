import QtQuick
import QtQuick.Controls

Item {
    id: root
    required property var entry
    signal openRequested()
    width: 154
    height: 196

    Rectangle {
        anchors.fill: parent
        color: hover.hovered ? Qt.rgba(1, 1, 1, 0.065) : Qt.rgba(1, 1, 1, 0.025)
        border.width: 1
        border.color: hover.hovered ? Qt.rgba(colorful.accent.r, colorful.accent.g, colorful.accent.b, 0.58)
                                          : Qt.rgba(1, 1, 1, 0.09)
    }
    ArtworkImage {
        x: 7; y: 7; width: 140; height: 140
        source: root.entry.coverUrl || ""
        decodeSize: 512
    }
    AppIcon {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -21
        width: 28; height: 28
        iconSource: "icons/music.svg"
        opacity: 0.25
        visible: !root.entry.coverUrl
    }
    Text {
        x: 8; y: 151; width: parent.width - 16
        text: root.entry.name || "Untitled playlist"
        color: "#f5f5f5"
        font.bold: true
        font.pixelSize: 12
        elide: Text.ElideRight
    }
    Text {
        x: 8; y: 171; width: parent.width - 16
        text: root.entry.numberOfItems ? root.entry.numberOfItems + " tracks" : (root.entry.playlistType || "TIDAL")
        color: Qt.rgba(1, 1, 1, 0.42)
        font.pixelSize: 10
        elide: Text.ElideRight
    }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: root.openRequested() }
}
