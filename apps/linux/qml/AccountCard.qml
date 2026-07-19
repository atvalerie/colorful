import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root
    required property string title
    property var rows: []
    implicitHeight: cardBody.implicitHeight + 28
    color: Qt.rgba(1, 1, 1, 0.028)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.1)

    ColumnLayout {
        id: cardBody
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 14
        spacing: 10

        Text {
            text: root.title
            color: "#f5f5f5"
            font.bold: true
            font.pixelSize: 14
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Qt.rgba(1, 1, 1, 0.09)
        }
        Repeater {
            model: root.rows
            delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 12
                Text {
                    Layout.fillWidth: true
                    text: modelData[0]
                    color: Qt.rgba(1, 1, 1, 0.43)
                    font.pixelSize: 11
                }
                Text {
                    Layout.maximumWidth: root.width * 0.58
                    text: modelData[1]
                    color: "#f5f5f5"
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                    font.pixelSize: 12
                }
            }
        }
    }
}
