import QtQuick
import QtQuick.Controls

Button {
    id: control
    property url iconSource
    property bool danger: false
    property string tooltipText: ""
    property bool edgeHovered: false

    implicitWidth: 38
    implicitHeight: 28
    hoverEnabled: true

    contentItem: AppIcon {
        anchors.centerIn: parent
        width: 12
        height: 12
        iconSource: control.iconSource
        opacity: control.enabled ? ((control.hovered || control.edgeHovered) ? 1 : 0.62) : 0.25
    }

    background: Rectangle {
        color: control.hovered || control.edgeHovered
               ? (control.danger ? "#c94b5b" : Qt.rgba(1, 1, 1, 0.08))
               : "transparent"
        Behavior on color { ColorAnimation { duration: 80 } }
    }

    ToolTip.visible: (control.hovered || control.edgeHovered) && control.tooltipText.length > 0
    ToolTip.text: control.tooltipText
    ToolTip.delay: 600
}
