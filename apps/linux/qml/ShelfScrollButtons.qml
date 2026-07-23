import QtQuick

Item {
    id: root
    required property var view

    anchors.fill: parent
    z: 20
    visible: view && view.contentWidth > view.width + 2

    function move(direction) {
        if (!view) return
        const maximum = Math.max(0, view.contentWidth - view.width)
        scrollAnimation.stop()
        scrollAnimation.from = Math.max(0, view.contentX)
        scrollAnimation.to = Math.max(0, Math.min(maximum,
            view.contentX + direction * Math.max(180, view.width * 0.78)))
        scrollAnimation.start()
    }

    NumberAnimation {
        id: scrollAnimation
        target: root.view
        property: "contentX"
        duration: 180
        easing.type: Easing.OutCubic
    }

    Rectangle {
        anchors.left: parent.left
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        width: 34; height: 36
        visible: leftButton.enabled
        color: "#242429"
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.16)
        opacity: 0.96
        IconButton {
            id: leftButton
            anchors.fill: parent
            iconSource: "icons/previous.svg"
            tooltipText: "Scroll left"
            enabled: root.view && root.view.contentX > 1
            onClicked: root.move(-1)
        }
    }

    Rectangle {
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        width: 34; height: 36
        visible: rightButton.enabled
        color: "#242429"
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.16)
        opacity: 0.96
        IconButton {
            id: rightButton
            anchors.fill: parent
            iconSource: "icons/next.svg"
            tooltipText: "Scroll right"
            enabled: root.view && root.view.contentX < root.view.contentWidth - root.view.width - 1
            onClicked: root.move(1)
        }
    }
}
