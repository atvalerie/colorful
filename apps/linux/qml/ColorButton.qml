import QtQuick
import QtQuick.Controls

Button {
    id: control
    property color fillColor: colorful.accent
    property color textColor: strong ? "#0b0b0d" : "white"
    property bool quiet: false
    property bool strong: !quiet

    implicitHeight: 40
    implicitWidth: Math.max(88, contentItem.implicitWidth + 28)
    hoverEnabled: true

    contentItem: Text {
        text: control.text
        color: control.enabled ? control.textColor : Qt.rgba(1, 1, 1, 0.3)
        font.weight: Font.DemiBold
        font.pixelSize: 12
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    background: Rectangle {
        color: control.quiet
               ? (control.hovered ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(1, 1, 1, 0.035))
               : (control.pressed ? Qt.darker(control.fillColor, 1.18)
                                  : control.hovered ? Qt.lighter(control.fillColor, 1.06)
                                                    : control.fillColor)
        border.color: control.quiet ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(1, 1, 1, 0.24)
        border.width: 1
        Behavior on color { ColorAnimation { duration: 100 } }
    }
}
