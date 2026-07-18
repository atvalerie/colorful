import QtQuick
import QtQuick.Controls

Button {
    id: control
    property url iconSource
    property bool selected: false
    property bool strong: false
    property string tooltipText: ""

    implicitWidth: 40
    implicitHeight: 40
    hoverEnabled: true

    contentItem: AppIcon {
        anchors.centerIn: parent
        width: control.strong ? 20 : 18
        height: width
        iconSource: control.iconSource
        opacity: control.enabled ? (control.hovered || control.selected || control.strong ? 1 : 0.58) : 0.25
    }

    background: Rectangle {
        color: control.strong
               ? (control.pressed ? Qt.darker(colorful.accent, 1.18) : colorful.accent)
               : control.selected ? Qt.rgba(1, 1, 1, 0.1)
                                  : control.hovered ? Qt.rgba(1, 1, 1, 0.065) : "transparent"
        border.width: control.selected || control.strong ? 1 : 0
        border.color: control.strong ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.16)
        Behavior on color { ColorAnimation { duration: 100 } }
    }

    ToolTip.visible: control.hovered && control.tooltipText.length > 0
    ToolTip.text: control.tooltipText
    ToolTip.delay: 500
}
