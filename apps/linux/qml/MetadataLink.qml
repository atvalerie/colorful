import QtQuick

Text {
    id: root
    signal activated()
    property color normalColor: Qt.rgba(1, 1, 1, 0.72)
    property bool linkEnabled: true

    color: pointer.containsMouse && linkEnabled ? colorful.accent : normalColor
    font.pixelSize: 13
    font.weight: Font.DemiBold
    font.underline: pointer.containsMouse && linkEnabled

    Behavior on color { ColorAnimation { duration: 90 } }

    MouseArea {
        id: pointer
        anchors.left: parent.left
        anchors.top: parent.top
        width: Math.min(root.width, root.paintedWidth)
        height: root.height
        enabled: root.linkEnabled
        hoverEnabled: true
        cursorShape: root.linkEnabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.activated()
    }
}
