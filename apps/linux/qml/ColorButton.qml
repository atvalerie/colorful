import QtQuick
import QtQuick.Controls

Button {
    id: control
    property color fillColor: colorful.accent
    property color textColor: "white"
    property bool quiet: false

    implicitHeight: 40
    implicitWidth: Math.max(96, contentItem.implicitWidth + 30)
    hoverEnabled: true

    contentItem: Text {
        text: control.text
        color: control.enabled ? control.textColor : Qt.rgba(1, 1, 1, 0.35)
        font.family: "Nunito"
        font.weight: Font.DemiBold
        font.pixelSize: 14
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    background: Rectangle {
        radius: height / 2
        color: control.quiet
               ? (control.hovered ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.07))
               : (control.pressed ? Qt.darker(control.fillColor, 1.18)
                                  : control.hovered ? Qt.lighter(control.fillColor, 1.08)
                                                    : control.fillColor)
        border.color: control.quiet ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.18)
        border.width: 1

        Behavior on color { ColorAnimation { duration: 140 } }
    }
}

