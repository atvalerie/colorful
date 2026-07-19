import QtQuick

Text {
    id: root
    signal activated()
    property color normalColor: Qt.rgba(1, 1, 1, 0.72)

    color: pointer.containsMouse ? colorful.accent : normalColor
    font.pixelSize: 13
    font.weight: Font.DemiBold
    font.underline: pointer.containsMouse

    Behavior on color { ColorAnimation { duration: 90 } }

    MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activated()
    }
}
