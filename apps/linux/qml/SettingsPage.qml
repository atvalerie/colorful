import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    property int tab: 0
    readonly property var pages: [
        ["Accounts", "Provider connections"],
        ["Playback", "Queue and audio behavior"],
        ["Integrations", "Discord and external services"],
        ["Appearance", "Color and interface"],
        ["Storage", "Cache and offline music"],
        ["Sync", "Devices and handoff"],
        ["About", "colorful and licenses"]
    ]

    function fieldBackground(field) {
        return field.activeFocus ? colorful.accent : Qt.rgba(1, 1, 1, 0.13)
    }

    RowLayout {
        anchors.fill: parent
        spacing: 20

        Rectangle {
            Layout.preferredWidth: 210
            Layout.fillHeight: true
            color: Qt.rgba(1, 1, 1, 0.018)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.075)

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 3
                Text {
                    text: "Settings"
                    color: "#f5f5f5"
                    font.bold: true
                    font.pixelSize: 22
                    Layout.leftMargin: 8
                    Layout.topMargin: 5
                    Layout.bottomMargin: 12
                }
                Repeater {
                    model: root.pages
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        Layout.preferredHeight: 50
                        color: root.tab === index ? Qt.rgba(1, 1, 1, 0.075)
                                                  : navHover.hovered ? Qt.rgba(1, 1, 1, 0.038) : "transparent"
                        border.width: root.tab === index ? 1 : 0
                        border.color: root.tab === index ? colorful.accent : "transparent"
                        Column {
                            anchors.left: parent.left; anchors.leftMargin: 11
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 22; spacing: 2
                            Text { text: modelData[0]; color: root.tab === index ? "#f5f5f5" : Qt.rgba(1, 1, 1, 0.66); font.bold: root.tab === index; font.pixelSize: 12 }
                            Text { width: parent.width; text: modelData[1]; color: Qt.rgba(1, 1, 1, 0.32); font.pixelSize: 9; elide: Text.ElideRight }
                        }
                        HoverHandler { id: navHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.tab = index }
                    }
                }
                Item { Layout.fillHeight: true }
            }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: root.tab

            Flickable {
                clip: true; contentWidth: width; contentHeight: accountsBody.implicitHeight + 30
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                ColumnLayout {
                    id: accountsBody
                    width: Math.min(parent.width, 820); spacing: 14
                    Text { text: "Accounts"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 24 }
                    Text { text: "Provider credentials remain on this device and are stored by the system credential service."; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 126
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        RowLayout {
                            anchors.fill: parent; anchors.margins: 16; spacing: 14
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 4
                                Text { text: "TIDAL"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                                Text { text: colorful.linked ? "Connected  ·  " + ((colorful.tidalHub.account || {}).countryCode || "region pending") : "Not connected"; color: colorful.linked ? "#55dca0" : Qt.rgba(1, 1, 1, 0.42); font.pixelSize: 11 }
                                Text { Layout.fillWidth: true; text: colorful.linked ? "Search, lossless playback, collection, playlists, and mixes use this account." : "Connect using TIDAL's device authorization flow."; color: Qt.rgba(1, 1, 1, 0.4); wrapMode: Text.WordWrap; font.pixelSize: 11 }
                            }
                            ColorButton { text: colorful.linked ? "View account" : "Connect"; onClicked: colorful.linked ? colorful.openTidalAccount() : colorful.startLogin() }
                            ColorButton { visible: colorful.linked; text: "Disconnect"; quiet: true; onClicked: colorful.unlink() }
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 92
                        color: Qt.rgba(1, 1, 1, 0.018); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.07)
                        Column { anchors.left: parent.left; anchors.leftMargin: 16; anchors.verticalCenter: parent.verticalCenter; spacing: 5
                            Text { text: "SoundCloud"; color: Qt.rgba(1, 1, 1, 0.52); font.bold: true; font.pixelSize: 15 }
                            Text { text: "Public account and catalog support is planned."; color: Qt.rgba(1, 1, 1, 0.32); font.pixelSize: 11 }
                        }
                    }
                }
            }

            Flickable {
                clip: true; contentWidth: width; contentHeight: playbackBody.implicitHeight + 30
                boundsBehavior: Flickable.StopAtBounds
                ColumnLayout {
                    id: playbackBody
                    width: Math.min(parent.width, 820); spacing: 14
                    Text { text: "Playback"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 24 }
                    Text { text: "Behavior shared by the desktop queue and playback controls."; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 12 }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 76
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        RowLayout {
                            anchors.fill: parent; anchors.margins: 15
                            ColumnLayout { Layout.fillWidth: true; spacing: 3
                                Text { text: "Autoplay"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 13 }
                                Text { text: "Continue with related tracks when the queue ends."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11 }
                            }
                            Rectangle {
                                width: 42; height: 22
                                color: colorful.autoplayEnabled ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
                                border.width: 1; border.color: colorful.autoplayEnabled ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.18)
                                Rectangle { width: 16; height: 16; y: 3; x: colorful.autoplayEnabled ? parent.width - width - 3 : 3; color: colorful.autoplayEnabled && (0.2126 * colorful.accent.r + 0.7152 * colorful.accent.g + 0.0722 * colorful.accent.b) > 0.56 ? "#111114" : "#f5f5f5"; Behavior on x { NumberAnimation { duration: 100 } } }
                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: colorful.autoplayEnabled = !colorful.autoplayEnabled }
                            }
                        }
                    }
                    AccountCard { Layout.fillWidth: true; title: "Audio engine"; rows: [["Desktop backend", "libmpv"], ["Stream quality", "Best available"], ["Output", "System default"]] }
                    Text { text: "Gapless playback, output selection, normalization, and EQ will appear here when their playback contracts are implemented."; color: Qt.rgba(1, 1, 1, 0.34); font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                }
            }

            Flickable {
                clip: true; contentWidth: width; contentHeight: integrationsBody.implicitHeight + 30
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                ColumnLayout {
                    id: integrationsBody
                    width: Math.min(parent.width, 820); spacing: 12
                    Text { text: "Integrations"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 24 }
                    Text { text: "Discord Rich Presence starts automatically. The optional profile widget publishes your local listening statistics."; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 62
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        RowLayout { anchors.fill: parent; anchors.margins: 13
                            ColumnLayout { Layout.fillWidth: true; spacing: 2
                                Text { text: "Discord profile widget"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 14 }
                                Text { text: colorful.discordWidgetStatus; color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: 10; elide: Text.ElideRight; Layout.fillWidth: true }
                            }
                            Text { text: colorful.discordWidgetEnabled ? "ENABLED" : "DISABLED"; color: colorful.discordWidgetEnabled ? "#55dca0" : Qt.rgba(1, 1, 1, 0.36); font.bold: true; font.pixelSize: 10; font.letterSpacing: 1 }
                        }
                    }
                    Text { text: "Application"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 14; Layout.topMargin: 5 }
                    TextField {
                        id: discordApplicationId
                        Layout.fillWidth: true; implicitHeight: 40; enabled: !colorful.discordWidgetBusy
                        text: colorful.discordApplicationId; inputMethodHints: Qt.ImhDigitsOnly
                        validator: RegularExpressionValidator { regularExpression: /^[0-9]{15,22}$/ }
                        placeholderText: "Discord Application ID"; placeholderTextColor: Qt.rgba(1, 1, 1, 0.34); color: "#f5f5f5"; selectByMouse: true
                        background: Rectangle { color: Qt.rgba(0.025, 0.025, 0.03, 0.86); border.width: 1; border.color: root.fieldBackground(discordApplicationId) }
                    }
                    RowLayout { Layout.fillWidth: true; spacing: 8
                        ColorButton { text: "Save application ID"; enabled: discordApplicationId.acceptableInput && discordApplicationId.text !== colorful.discordApplicationId && !colorful.discordWidgetBusy; onClicked: colorful.discordApplicationId = discordApplicationId.text }
                        ColorButton { text: "Authorize widget"; quiet: true; enabled: !colorful.discordWidgetBusy; onClicked: colorful.authorizeDiscordWidget() }
                        Item { Layout.fillWidth: true }
                    }
                    TextField {
                        id: discordRedirectUri
                        Layout.fillWidth: true; implicitHeight: 40; enabled: !colorful.discordWidgetBusy
                        text: colorful.discordRedirectUri; placeholderText: "OAuth2 redirect URI"; placeholderTextColor: Qt.rgba(1, 1, 1, 0.34); color: "#f5f5f5"; selectByMouse: true
                        background: Rectangle { color: Qt.rgba(0.025, 0.025, 0.03, 0.86); border.width: 1; border.color: root.fieldBackground(discordRedirectUri) }
                    }
                    ColorButton { text: "Save redirect URI"; Layout.alignment: Qt.AlignLeft; enabled: discordRedirectUri.text.trim().length > 0 && discordRedirectUri.text !== colorful.discordRedirectUri && !colorful.discordWidgetBusy; onClicked: colorful.discordRedirectUri = discordRedirectUri.text.trim() }
                    Text { text: "Widget owner"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 14; Layout.topMargin: 6 }
                    TextField {
                        id: discordWidgetUserId
                        Layout.fillWidth: true; implicitHeight: 40; enabled: !colorful.discordWidgetBusy
                        text: colorful.discordWidgetUserId; inputMethodHints: Qt.ImhDigitsOnly
                        validator: RegularExpressionValidator { regularExpression: /^[0-9]{15,22}$/ }
                        placeholderText: "Discord owner user ID"; placeholderTextColor: Qt.rgba(1, 1, 1, 0.34); color: "#f5f5f5"; selectByMouse: true
                        background: Rectangle { color: Qt.rgba(0.025, 0.025, 0.03, 0.86); border.width: 1; border.color: root.fieldBackground(discordWidgetUserId) }
                    }
                    RowLayout { Layout.fillWidth: true; spacing: 8
                        ColorButton { text: "Save owner ID"; enabled: discordWidgetUserId.acceptableInput && discordWidgetUserId.text !== colorful.discordWidgetUserId && !colorful.discordWidgetBusy; onClicked: colorful.discordWidgetUserId = discordWidgetUserId.text }
                        ColorButton { quiet: true; text: colorful.discordWidgetUserIdAutomatic ? "Using Discord IPC" : "Use detected Discord user"; enabled: !colorful.discordWidgetUserIdAutomatic && !colorful.discordWidgetBusy; onClicked: colorful.useDetectedDiscordWidgetUserId() }
                        Item { Layout.fillWidth: true }
                    }
                    Text { text: "Publishing credential"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 14; Layout.topMargin: 6 }
                    TextField {
                        id: discordWidgetToken
                        Layout.fillWidth: true; implicitHeight: 40; enabled: !colorful.discordWidgetBusy; echoMode: TextInput.Password
                        placeholderText: colorful.discordWidgetConfigured ? "Replace stored bot token" : "Bot token"; placeholderTextColor: Qt.rgba(1, 1, 1, 0.34); color: "#f5f5f5"; selectByMouse: true
                        background: Rectangle { color: Qt.rgba(0.025, 0.025, 0.03, 0.86); border.width: 1; border.color: root.fieldBackground(discordWidgetToken) }
                    }
                    RowLayout { Layout.fillWidth: true; spacing: 8
                        ColorButton { text: colorful.discordWidgetConfigured ? "Replace token" : "Store token"; enabled: discordWidgetToken.text.trim().length > 0 && !colorful.discordWidgetBusy; onClicked: { colorful.storeDiscordWidgetToken(discordWidgetToken.text); discordWidgetToken.clear() } }
                        ColorButton { quiet: true; text: colorful.discordWidgetEnabled ? "Disable widget" : "Enable widget"; enabled: colorful.discordWidgetConfigured && !colorful.discordWidgetBusy; onClicked: colorful.discordWidgetEnabled = !colorful.discordWidgetEnabled }
                        ColorButton { quiet: true; text: "Publish now"; enabled: colorful.discordWidgetEnabled && colorful.discordWidgetConfigured && !colorful.discordWidgetBusy && colorful.listenStats.playCount > 0; onClicked: colorful.publishDiscordWidgetNow() }
                        Item { Layout.fillWidth: true }
                        ColorButton { quiet: true; text: "Forget token"; enabled: colorful.discordWidgetConfigured && !colorful.discordWidgetBusy; onClicked: colorful.forgetDiscordWidgetToken() }
                    }
                }
            }

            Flickable {
                clip: true; contentWidth: width; contentHeight: appearanceBody.implicitHeight + 30
                ColumnLayout {
                    id: appearanceBody
                    width: Math.min(parent.width, 820); spacing: 14
                    Text { text: "Appearance"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 24 }
                    Text { text: "colorful currently derives a contrast-safe accent from the active album artwork."; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 12 }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 88
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        RowLayout { anchors.fill: parent; anchors.margins: 15; spacing: 14
                            Rectangle { width: 46; height: 46; color: colorful.accent; border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.35) }
                            ColumnLayout { Layout.fillWidth: true; spacing: 3
                                Text { text: "Album-derived accent"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 13 }
                                Text { text: "The current color is animated between tracks and corrected for dark-background contrast."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                            }
                        }
                    }
                }
            }

            Item {
                Column { anchors.centerIn: parent; width: Math.min(430, parent.width - 40); spacing: 9
                    AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/download.svg"; opacity: 0.28 }
                    Text { width: parent.width; text: "Storage controls are coming with offline downloads"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter }
                    Text { width: parent.width; text: "Download quality, cache limits, locations, and cleanup will live here."; color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: 12; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter }
                }
            }

            Item {
                Column { anchors.centerIn: parent; width: Math.min(430, parent.width - 40); spacing: 9
                    AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/library.svg"; opacity: 0.28 }
                    Text { width: parent.width; text: "Device sync is not enabled yet"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter }
                    Text { width: parent.width; text: "Device pairing, library sync, listening history, playback handoff, and desktop RPC relay controls will live here."; color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: 12; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter }
                }
            }

            Flickable {
                clip: true; contentWidth: width; contentHeight: aboutBody.implicitHeight + 30
                ColumnLayout {
                    id: aboutBody
                    width: Math.min(parent.width, 820); spacing: 14
                    Image { source: "qrc:/assets/branding/colorful.svg"; Layout.preferredWidth: 70; Layout.preferredHeight: 70; fillMode: Image.PreserveAspectFit; smooth: true; mipmap: true }
                    Text { text: "colorful"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 26 }
                    Text { text: "A local-first personal music client."; color: Qt.rgba(1, 1, 1, 0.48); font.pixelSize: 13 }
                    AccountCard { Layout.fillWidth: true; title: "Desktop build"; rows: [["Platform", "Linux"], ["Interface", "Qt Quick"], ["Playback", "libmpv"], ["License", "GPL-3.0-or-later"]] }
                    Text { Layout.fillWidth: true; text: "This personal project is entirely AI-made. It exists because its owner needed a stable music client that worked for them."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; wrapMode: Text.WordWrap }
                }
            }
        }
    }
}
