import QtQuick

Item {
    id: root
    required property int edges
    property int handleCursor: Qt.ArrowCursor

    visible: Window.window && Window.window.visibility === Window.Windowed
    z: 1000

    HoverHandler { cursorShape: root.handleCursor }
    DragHandler {
        target: null
        acceptedButtons: Qt.LeftButton
        onActiveChanged: {
            if (active && root.Window.window)
                root.Window.window.startSystemResize(root.edges)
        }
    }
}
