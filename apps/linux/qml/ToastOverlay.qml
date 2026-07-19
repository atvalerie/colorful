import QtQuick
import QtQuick.Layouts

Item {
    id: root
    width: 340
    height: Math.min(parent ? parent.height : 400, toastColumn.implicitHeight)

    ListModel { id: toastModel }

    function show(message, kind) {
        if (!message || !message.trim()) return
        toastModel.append({ "body": message, "tone": kind || "info" })
        while (toastModel.count > 4) toastModel.remove(0)
    }

    Column {
        id: toastColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: 7

        Repeater {
            model: toastModel
            delegate: Rectangle {
                id: toast
                required property string body
                required property string tone
                required property int index
                property bool closing: false
                property bool shown: false

                width: toastColumn.width
                height: Math.max(54, messageText.implicitHeight + 24)
                opacity: shown && !closing ? 1 : 0
                x: shown && !closing ? 0 : 22
                color: "#1a1a1f"
                border.width: 1
                border.color: tone === "error" ? Qt.rgba(1, 0.32, 0.38, 0.62)
                              : tone === "warning" ? Qt.rgba(1, 0.72, 0.28, 0.58)
                              : Qt.rgba(1, 1, 1, 0.15)

                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 3
                    color: toast.tone === "error" ? "#ff5964"
                           : toast.tone === "warning" ? "#ffb84d"
                           : toast.tone === "success" ? "#55dca0" : colorful.accent
                }

                Text {
                    id: messageText
                    anchors.left: parent.left
                    anchors.leftMargin: 15
                    anchors.right: closeHit.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: toast.body
                    color: "#f5f5f5"
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                    wrapMode: Text.Wrap
                }

                Item {
                    id: closeHit
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 38
                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        color: closeHover.hovered ? "#f5f5f5" : Qt.rgba(1, 1, 1, 0.42)
                        font.pixelSize: 19
                    }
                    HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: toast.dismiss() }
                }

                Timer {
                    interval: toast.tone === "error" ? 7000 : toast.tone === "warning" ? 5200 : 4000
                    running: true
                    onTriggered: toast.dismiss()
                }
                Timer {
                    id: removeTimer
                    interval: 160
                    onTriggered: {
                        if (toast.index >= 0 && toast.index < toastModel.count)
                            toastModel.remove(toast.index)
                    }
                }

                function dismiss() {
                    if (closing) return
                    closing = true
                    removeTimer.start()
                }

                Component.onCompleted: shown = true

                Behavior on opacity { NumberAnimation { duration: 150 } }
                Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
            }
        }
    }
}
