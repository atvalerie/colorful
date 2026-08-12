import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Popup {
    id: panel
    width: Math.min(520, parent ? parent.width - 48 : 520)
    height: Math.min(650, parent ? parent.height - 48 : 650)
    anchors.centerIn: parent
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    padding: 0

    property alias pendingLink: joinLink.text

    background: Rectangle {
        radius: 16
        color: "#202026"
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.14)
    }

    contentItem: ColumnLayout {
        anchors.fill: parent
        anchors.margins: 22
        spacing: 14

        RowLayout {
            Layout.fillWidth: true
            Text {
                Layout.fillWidth: true
                text: "Listen together"
                color: "#f5f5f5"
                font.bold: true
                font.pixelSize: Math.round(22 * colorful.textScale)
            }
            Button { text: "Close"; onClicked: panel.close() }
        }

        Text {
            Layout.fillWidth: true
            text: party.status
            color: party.connected ? "#8ee6a8" : Qt.rgba(1, 1, 1, 0.58)
            wrapMode: Text.WordWrap
        }

        TextField {
            id: nameField
            Layout.fillWidth: true
            placeholderText: "Display name"
            text: "Listener"
            enabled: !party.active
        }
        TextField {
            id: relayField
            Layout.fillWidth: true
            placeholderText: "Relay URL"
            text: "https://colorful.valerie.sh"
            enabled: !party.active
        }

        RowLayout {
            Layout.fillWidth: true
            visible: !party.active
            Button {
                Layout.fillWidth: true
                text: "Create party"
                enabled: nameField.text.trim().length > 0
                onClicked: party.createParty(nameField.text, relayField.text)
            }
            Button {
                Layout.fillWidth: true
                text: "Join party"
                enabled: joinLink.text.trim().length > 0 && nameField.text.trim().length > 0
                onClicked: party.joinParty(joinLink.text, nameField.text, relayField.text)
            }
        }

        TextArea {
            id: joinLink
            Layout.fillWidth: true
            Layout.preferredHeight: 76
            visible: !party.active
            placeholderText: "Paste colorful://party/… link"
            wrapMode: TextEdit.WrapAnywhere
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: party.active
            spacing: 8
            Text { text: party.role === "host" ? "You are hosting" : "You joined as a guest"; color: "#f5f5f5"; font.bold: true }
            TextArea {
                id: shareField
                Layout.fillWidth: true
                Layout.preferredHeight: 74
                visible: party.role === "host"
                readOnly: true
                text: party.shareUrl
                wrapMode: TextEdit.WrapAnywhere
            }
            Button {
                visible: party.role === "host"
                text: "Copy invite"
                onClicked: { shareField.selectAll(); shareField.copy(); shareField.deselect() }
            }
        }

        Text {
            visible: party.active
            text: "Participants (" + party.participants.length + ")"
            color: "#f5f5f5"
            font.bold: true
        }
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: party.active
            clip: true
            model: party.participants
            delegate: Rectangle {
                required property var modelData
                width: ListView.view.width
                height: 42
                color: "transparent"
                RowLayout {
                    anchors.fill: parent
                    Text { Layout.fillWidth: true; text: modelData.displayName + " · " + modelData.role; color: "#e8e8ea" }
                    Button {
                        visible: party.role === "host" && modelData.role !== "host"
                        text: "Kick"
                        onClicked: party.kick(modelData.participantId)
                    }
                }
            }
        }

        Button {
            Layout.fillWidth: true
            visible: party.active
            text: "Leave party"
            onClicked: party.leave()
        }

        Text {
            Layout.fillWidth: true
            text: "Each device streams through its own provider account. The relay receives encrypted frames, never audio or provider credentials."
            color: Qt.rgba(1, 1, 1, 0.42)
            font.pixelSize: Math.round(11 * colorful.textScale)
            wrapMode: Text.WordWrap
        }
    }
}
