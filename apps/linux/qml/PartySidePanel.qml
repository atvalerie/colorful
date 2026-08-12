import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    property string pendingLink: ""
    property bool joinMode: pendingLink.length > 0
    property bool advancedOpen: false
    signal closeRequested()

    color: Qt.rgba(0.032, 0.032, 0.038, 0.96)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.09)

    onPendingLinkChanged: if (pendingLink.length > 0) joinMode = true
    function fieldBorder(field) { return field.activeFocus ? colorful.accent : Qt.rgba(1, 1, 1, 0.13) }
    function signedMs(value) { return (value > 0 ? "+" : "") + value + " ms" }
    function expiryText(value) {
        if (!value) return ""
        const minutes = Math.max(0, Math.ceil((value - Date.now()) / 60000))
        return minutes > 60 ? "Expires in " + Math.ceil(minutes / 60) + " h" : "Expires in " + minutes + " min"
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        RowLayout {
            Layout.fillWidth: true; Layout.preferredHeight: 34; spacing: 8
            Text { text: "Listen together"; color: "#f5f5f5"; font.weight: Font.Bold; font.pixelSize: Math.round(18 * colorful.textScale) }
            Rectangle { width: 7; height: 7; radius: 4; visible: party.active; color: party.connected ? "#76d890" : "#d8a35f" }
            Text {
                visible: party.active
                text: !party.connected ? "Reconnecting"
                      : party.role !== "host" && !party.clockSynchronized ? "Syncing clock…"
                      : party.role !== "host" ? party.latencyMs + " ms"
                      : "Live"
                color: Qt.rgba(1,1,1,0.38)
                font.pixelSize: Math.round(10 * colorful.textScale)
            }
            Item { Layout.fillWidth: true }
            IconButton { implicitWidth: 32; implicitHeight: 32; iconSource: "icons/close.svg"; tooltipText: "Close party"; onClicked: root.closeRequested() }
        }

        Text {
            Layout.fillWidth: true; visible: !party.active
            text: "Share the queue and stay in time. Everyone streams through their own provider."
            color: Qt.rgba(1,1,1,0.43); font.pixelSize: Math.round(11 * colorful.textScale); wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 36
            Layout.minimumHeight: 36
            Layout.maximumHeight: 36
            visible: !party.active
            spacing: 4
            Repeater {
                model: [["Create", false], ["Join", true]]
                delegate: Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36
                    Layout.minimumHeight: 36
                    Layout.maximumHeight: 36
                    color: root.joinMode === modelData[1] ? Qt.rgba(1,1,1,0.075) : modeHover.hovered ? Qt.rgba(1,1,1,0.035) : "transparent"
                    border.width: 1
                    border.color: root.joinMode === modelData[1] ? colorful.accent : Qt.rgba(1,1,1,0.08)
                    Text {
                        anchors.centerIn: parent; text: modelData[0]
                        color: root.joinMode === modelData[1] ? "#f5f5f5" : Qt.rgba(1,1,1,0.48)
                        font.weight: root.joinMode === modelData[1] ? Font.DemiBold : Font.Normal
                        font.pixelSize: Math.round(11 * colorful.textScale)
                    }
                    HoverHandler { id: modeHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { root.joinMode = modelData[1]; if (!root.joinMode) root.pendingLink = "" } }
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true; visible: !party.active; spacing: 7
            Text { text: "Your name"; color: Qt.rgba(1,1,1,0.36); font.pixelSize: Math.round(10 * colorful.textScale) }
            TextField {
                id: nameField; Layout.fillWidth: true; implicitHeight: 40; text: "Listener"
                placeholderText: "How others will see you"; placeholderTextColor: Qt.rgba(1,1,1,0.28)
                color: "#f5f5f5"; selectByMouse: true; font.pixelSize: Math.round(12 * colorful.textScale)
                background: Rectangle { color: Qt.rgba(0,0,0,0.2); border.width: 1; border.color: root.fieldBorder(nameField) }
            }
            Text { visible: root.joinMode; text: "Invite link"; color: Qt.rgba(1,1,1,0.36); font.pixelSize: Math.round(10 * colorful.textScale); Layout.topMargin: 4 }
            ScrollView {
                Layout.fillWidth: true; Layout.preferredHeight: 88; visible: root.joinMode; clip: true
                TextArea {
                    id: joinLink; text: root.pendingLink
                    onTextChanged: if (root.pendingLink !== text) root.pendingLink = text
                    placeholderText: "Paste a colorful party link"; placeholderTextColor: Qt.rgba(1,1,1,0.28)
                    color: "#f5f5f5"; selectByMouse: true; wrapMode: TextEdit.WrapAnywhere; font.pixelSize: Math.round(10 * colorful.textScale)
                    background: Rectangle { color: Qt.rgba(0,0,0,0.2); border.width: 1; border.color: root.fieldBorder(joinLink) }
                }
            }
            ColorButton {
                Layout.fillWidth: true; Layout.topMargin: 5
                text: root.joinMode ? "Join party" : "Start a party"
                enabled: nameField.text.trim().length > 0 && (!root.joinMode || root.pendingLink.trim().length > 0)
                onClicked: root.joinMode ? party.joinParty(root.pendingLink, nameField.text, relayField.text)
                                         : party.createParty(nameField.text, relayField.text)
            }
            ColorButton {
                text: root.advancedOpen ? "Hide relay settings" : "Relay settings"; quiet: true; implicitHeight: 30
                Layout.alignment: Qt.AlignHCenter; onClicked: root.advancedOpen = !root.advancedOpen
            }
            TextField {
                id: relayField; Layout.fillWidth: true; visible: root.advancedOpen; implicitHeight: 36
                text: "https://colorful.valerie.sh"; placeholderText: "https://relay.example"
                placeholderTextColor: Qt.rgba(1,1,1,0.28); color: "#f5f5f5"; selectByMouse: true
                font.pixelSize: Math.round(11 * colorful.textScale)
                background: Rectangle { color: Qt.rgba(0,0,0,0.2); border.width: 1; border.color: root.fieldBorder(relayField) }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true; visible: party.active && party.role === "host"; spacing: 7
            Text { text: "Invite people"; color: "#f5f5f5"; font.weight: Font.DemiBold; font.pixelSize: Math.round(13 * colorful.textScale) }
            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: 76
                color: Qt.rgba(1,1,1,0.028); border.width: 1; border.color: Qt.rgba(1,1,1,0.1)
                RowLayout {
                    anchors.fill: parent; anchors.margins: 10; spacing: 9
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Text { text: "Private party link"; color: Qt.rgba(1,1,1,0.68); font.weight: Font.DemiBold; font.pixelSize: Math.round(11 * colorful.textScale) }
                        TextInput { id: shareField; Layout.fillWidth: true; readOnly: true; text: party.shareUrl; color: Qt.rgba(1,1,1,0.32); selectByMouse: true; font.pixelSize: Math.round(9 * colorful.textScale); clip: true }
                    }
                    ColorButton {
                        text: "Copy"; quiet: true; implicitWidth: 66; implicitHeight: 32
                        onClicked: { shareField.selectAll(); shareField.copy(); shareField.deselect() }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Text { Layout.fillWidth: true; text: root.expiryText(party.expiresAtMs); color: Qt.rgba(1,1,1,0.34); font.pixelSize: Math.round(9 * colorful.textScale) }
                ColorButton {
                    text: party.joinEnabled ? "Joining on" : "Joining off"
                    quiet: true; implicitHeight: 28; implicitWidth: 90
                    onClicked: party.setJoinEnabled(!party.joinEnabled)
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 142
            visible: party.active && colorful.partyDiagnosticsEnabled
            color: Qt.rgba(1,1,1,0.022)
            border.width: 1
            border.color: Qt.rgba(1,1,1,0.08)
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 11; spacing: 7
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Sync diagnostics"; color: "#f5f5f5"; font.weight: Font.DemiBold; font.pixelSize: Math.round(11 * colorful.textScale) }
                    Item { Layout.fillWidth: true }
                    Text { text: party.correctionMode; color: party.correctionMode === "locked" || party.correctionMode === "authority" ? "#76d890" : "#d8a35f"; font.pixelSize: Math.round(9 * colorful.textScale) }
                }
                GridLayout {
                    Layout.fillWidth: true; columns: 2; rowSpacing: 6; columnSpacing: 16
                    Repeater {
                        model: party.role === "host"
                               ? [["Role", "Clock authority"], ["Generation", String(party.playbackGeneration)], ["Published", "1 Hz"], ["Transport", party.connected ? "Connected" : "Offline"]]
                               : [["Round trip", party.latencyMs + " ms"], ["Clock offset", root.signedMs(party.clockOffsetMs)], ["Playback drift", root.signedMs(party.driftMs)], ["Playback rate", Number(party.correctionRate).toFixed(3) + "×"], ["Clock samples", String(party.clockSampleCount)], ["Hard resyncs", String(party.hardResyncCount)]]
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true; spacing: 5
                            Text { text: modelData[0]; color: Qt.rgba(1,1,1,0.32); font.pixelSize: Math.round(9 * colorful.textScale) }
                            Item { Layout.fillWidth: true }
                            Text { text: modelData[1]; color: Qt.rgba(1,1,1,0.68); font.family: "Consolas"; font.pixelSize: Math.round(9 * colorful.textScale) }
                        }
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true; visible: party.active
            Text { text: "People"; color: "#f5f5f5"; font.weight: Font.DemiBold; font.pixelSize: Math.round(13 * colorful.textScale) }
            Text { text: String(party.participants.length); color: Qt.rgba(1,1,1,0.34); font.pixelSize: Math.round(10 * colorful.textScale) }
            Item { Layout.fillWidth: true }
        }

        ListView {
            Layout.fillWidth: true; Layout.fillHeight: true; visible: party.active
            model: party.participants; clip: true; spacing: 2; boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            delegate: ItemDelegate {
                required property var modelData
                width: ListView.view.width; height: 50; hoverEnabled: true
                background: Rectangle { color: parent.hovered ? Qt.rgba(1,1,1,0.055) : Qt.rgba(1,1,1,0.018); border.width: 1; border.color: Qt.rgba(1,1,1,0.065) }
                contentItem: RowLayout {
                    spacing: 9
                    Rectangle {
                        width: 28; height: 28; radius: 14
                        color: Qt.rgba(colorful.accent.r,colorful.accent.g,colorful.accent.b,0.18)
                        border.width: 1; border.color: Qt.rgba(colorful.accent.r,colorful.accent.g,colorful.accent.b,0.5)
                        Text { anchors.centerIn: parent; text: String(modelData.displayName || "?").slice(0,1).toUpperCase(); color: "#f5f5f5"; font.weight: Font.Bold; font.pixelSize: Math.round(11 * colorful.textScale) }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 1
                        Text { Layout.fillWidth: true; text: modelData.displayName || "Listener"; color: "#f5f5f5"; font.weight: Font.DemiBold; font.pixelSize: Math.round(11 * colorful.textScale); elide: Text.ElideRight }
                        Text { text: modelData.role === "host" ? "Host" : modelData.role === "co_host" ? "Co-host" : "Listening"; color: Qt.rgba(1,1,1,0.34); font.pixelSize: Math.round(9 * colorful.textScale) }
                    }
                    ColorButton {
                        visible: party.role === "host" && modelData.role !== "host"
                        text: modelData.role === "co_host" ? "Demote" : "Co-host"
                        quiet: true; implicitHeight: 30; implicitWidth: 72
                        onClicked: party.setCoHost(modelData.participantId, modelData.role !== "co_host")
                    }
                    ColorButton { visible: party.role === "host" && modelData.role !== "host"; text: "Remove"; quiet: true; implicitHeight: 30; implicitWidth: 64; onClicked: party.kick(modelData.participantId) }
                }
            }
        }

        Item { Layout.fillHeight: true; visible: !party.active }
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: privacyText.implicitHeight + 20
            color: Qt.rgba(1,1,1,0.02); border.width: 1; border.color: Qt.rgba(1,1,1,0.07)
            Text {
                id: privacyText; anchors.fill: parent; anchors.margins: 10
                text: party.active ? "Tracks play locally. No audio or provider login is shared."
                                   : "Party traffic is end-to-end encrypted. The relay only forwards opaque frames."
                color: Qt.rgba(1,1,1,0.34); font.pixelSize: Math.round(9 * colorful.textScale); wrapMode: Text.WordWrap
            }
        }
        ColorButton { Layout.fillWidth: true; visible: party.active; text: party.role === "host" ? "End party" : "Leave party"; quiet: true; onClicked: party.leave() }
    }
}
