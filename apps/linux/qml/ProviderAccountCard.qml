import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root
    required property string providerName
    required property string statusText
    required property string description
    property bool connected: false
    property string primaryText: "Connect"
    property bool primaryVisible: true
    property string secondaryText: "Disconnect"
    property bool secondaryVisible: root.connected
    property bool extraVisible: false
    default property alias extraContent: extra.data
    signal primaryRequested()
    signal secondaryRequested()

    implicitHeight: body.implicitHeight + 32
    color: Qt.rgba(1, 1, 1, 0.028)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.1)

    ColumnLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 16
        spacing: 9

        RowLayout {
            Layout.fillWidth: true
            spacing: 14
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3
                Text {
                    text: root.providerName
                    color: "#f5f5f5"
                    font.bold: true
                    font.pixelSize: 17
                }
                Text {
                    Layout.fillWidth: true
                    text: root.statusText
                    color: root.connected ? "#55dca0" : Qt.rgba(1, 1, 1, 0.42)
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }
            ColorButton {
                visible: root.primaryVisible
                text: root.primaryText
                onClicked: root.primaryRequested()
            }
            ColorButton {
                visible: root.secondaryVisible
                text: root.secondaryText
                quiet: true
                onClicked: root.secondaryRequested()
            }
        }
        Text {
            Layout.fillWidth: true
            text: root.description
            color: Qt.rgba(1, 1, 1, 0.4)
            wrapMode: Text.WordWrap
            font.pixelSize: 11
        }
        ColumnLayout {
            id: extra
            Layout.fillWidth: true
            Layout.preferredHeight: root.extraVisible ? implicitHeight : 0
            visible: root.extraVisible
            spacing: 7
        }
    }
}
