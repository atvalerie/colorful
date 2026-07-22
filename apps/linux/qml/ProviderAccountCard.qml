import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    required property string providerName
    required property string statusText
    required property string description
    property bool connected: false
    property bool loading: false
    property string primaryText: "Connect"
    property bool primaryVisible: true
    property string secondaryText: "Disconnect"
    property bool secondaryVisible: root.connected
    property bool extraVisible: false
    property var details: []
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
                    color: !root.loading && root.connected ? "#55dca0" : Qt.rgba(1, 1, 1, 0.42)
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }
            BusyIndicator {
                visible: root.loading
                running: visible
                implicitWidth: 24
                implicitHeight: 24
            }
            ColorButton {
                visible: root.primaryVisible && !root.loading
                text: root.primaryText
                onClicked: root.primaryRequested()
            }
            ColorButton {
                visible: root.secondaryVisible && !root.loading
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
        Row {
            Layout.fillWidth: true
            visible: !root.loading && root.connected && root.details.length > 0
            spacing: 0
            Repeater {
                model: root.details
                delegate: ColumnLayout {
                    required property var modelData
                    width: root.details.length > 0 ? parent.width / root.details.length : 0
                    spacing: 2
                    Text {
                        Layout.fillWidth: true
                        text: modelData[0]
                        color: "#f5f5f5"
                        font.bold: true
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        text: modelData[1]
                        color: Qt.rgba(1, 1, 1, 0.34)
                        font.pixelSize: 9
                        elide: Text.ElideRight
                    }
                }
            }
        }
        ColumnLayout {
            id: extra
            Layout.fillWidth: true
            Layout.preferredHeight: root.extraVisible ? implicitHeight : 0
            visible: root.extraVisible && !root.loading
            spacing: 7
        }
    }
}
