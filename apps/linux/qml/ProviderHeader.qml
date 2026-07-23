import QtQuick
import QtQuick.Layouts

Item {
    id: root
    required property string title
    property string accountText: ""
    property bool refreshEnabled: true
    signal refreshRequested()

    implicitHeight: 40

    RowLayout {
        anchors.fill: parent
        spacing: 8
        Text {
            text: root.title
            color: "#f5f5f5"
            font.bold: true
            font.pixelSize: 24
            Layout.alignment: Qt.AlignVCenter
        }
        Text {
            text: root.accountText
            visible: text.length > 0
            color: Qt.rgba(1, 1, 1, 0.42)
            font.pixelSize: 10
            Layout.alignment: Qt.AlignVCenter
        }
        Item { Layout.fillWidth: true }
        ColorButton {
            text: "Refresh"
            quiet: true
            enabled: root.refreshEnabled
            implicitHeight: 34
            Layout.alignment: Qt.AlignVCenter
            onClicked: root.refreshRequested()
        }
    }
}
