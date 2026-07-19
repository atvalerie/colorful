import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
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

    function downloadedBytes() {
        let total = 0
        for (let index = 0; index < colorful.downloads.length; ++index)
            if (colorful.downloads[index].downloadState === "complete")
                total += colorful.downloads[index].bytesDownloaded || 0
        return total
    }

    function formatStorage(bytes) {
        if (!bytes) return "0 MB"
        if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + " MB"
        return (bytes / (1024 * 1024 * 1024)).toFixed(2) + " GB"
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
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                ColumnLayout {
                    id: playbackBody
                    width: Math.min(parent.width, 820); spacing: 14
                    Text { text: "Playback"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 24 }
                    Text { text: "Behavior shared by the desktop queue and playback controls."; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 12 }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 76
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: 15
                            anchors.right: autoplaySwitch.left
                            anchors.rightMargin: 18
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3
                            Text { text: "Autoplay"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 13 }
                            Text { width: parent.width; text: "Continue with related tracks when the queue ends."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; elide: Text.ElideRight }
                        }
                        Rectangle {
                            id: autoplaySwitch
                            anchors.right: parent.right
                            anchors.rightMargin: 15
                            anchors.verticalCenter: parent.verticalCenter
                            width: 42
                            height: 22
                            color: colorful.autoplayEnabled ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
                            border.width: 1; border.color: colorful.autoplayEnabled ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.18)
                            Rectangle { width: 16; height: 16; y: 3; x: colorful.autoplayEnabled ? parent.width - width - 3 : 3; color: colorful.autoplayEnabled && (0.2126 * colorful.accent.r + 0.7152 * colorful.accent.g + 0.0722 * colorful.accent.b) > 0.56 ? "#111114" : "#f5f5f5"; Behavior on x { NumberAnimation { duration: 100 } } }
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: colorful.autoplayEnabled = !colorful.autoplayEnabled }
                        }
                    }
                    Text { text: "TIDAL stream quality"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 14; Layout.topMargin: 5 }
                    Text { text: "The selected format is requested when the next track opens. TIDAL may fall back when a release has no matching format."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    Row {
                        Layout.fillWidth: true; spacing: 0
                        Repeater {
                            model: [["best", "Best available", "Hi-res → lossless → AAC"], ["lossless", "Lossless", "FLAC → AAC"], ["high", "High", "AAC"]]
                            delegate: Rectangle {
                                required property var modelData
                                width: Math.max(150, qualityText.implicitWidth + 30); height: 58
                                color: colorful.streamQuality === modelData[0] ? Qt.rgba(1, 1, 1, 0.075) : qualityHover.hovered ? Qt.rgba(1, 1, 1, 0.04) : "transparent"
                                border.width: 1
                                border.color: colorful.streamQuality === modelData[0] ? colorful.accent : Qt.rgba(1, 1, 1, 0.12)
                                Column { anchors.centerIn: parent; spacing: 2
                                    Text { id: qualityText; anchors.horizontalCenter: parent.horizontalCenter; text: modelData[1]; color: "#f5f5f5"; font.bold: true; font.pixelSize: 12 }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData[2]; color: Qt.rgba(1, 1, 1, 0.36); font.pixelSize: 9 }
                                }
                                HoverHandler { id: qualityHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: colorful.streamQuality = modelData[0] }
                            }
                        }
                    }
                    Text { text: "Volume normalization"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 14; Layout.topMargin: 8 }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 76
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        Column {
                            anchors.left: parent.left; anchors.leftMargin: 15
                            anchors.right: normalizationSwitch.left; anchors.rightMargin: 18
                            anchors.verticalCenter: parent.verticalCenter; spacing: 3
                            Text { text: "ReplayGain"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 13 }
                            Text { width: parent.width; text: "Use TIDAL manifest loudness data or embedded ReplayGain tags, with peak-based clipping protection."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; elide: Text.ElideRight }
                        }
                        Rectangle {
                            id: normalizationSwitch
                            anchors.right: parent.right; anchors.rightMargin: 15
                            anchors.verticalCenter: parent.verticalCenter
                            width: 42; height: 22
                            color: colorful.normalizationEnabled ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
                            border.width: 1; border.color: colorful.normalizationEnabled ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.18)
                            Rectangle { width: 16; height: 16; y: 3; x: colorful.normalizationEnabled ? parent.width - width - 3 : 3; color: colorful.normalizationEnabled && (0.2126 * colorful.accent.r + 0.7152 * colorful.accent.g + 0.0722 * colorful.accent.b) > 0.56 ? "#111114" : "#f5f5f5"; Behavior on x { NumberAnimation { duration: 100 } } }
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: colorful.normalizationEnabled = !colorful.normalizationEnabled }
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true; Layout.topMargin: 7
                        Text { text: "Equalizer"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 14 }
                        Item { Layout.fillWidth: true }
                    }
                    Row {
                        Layout.fillWidth: true; spacing: 0
                        Repeater {
                            model: ["Flat", "Bass boost", "Treble boost", "Vocal", "V-shaped"]
                            delegate: Rectangle {
                                required property string modelData
                                width: presetLabel.implicitWidth + 24; height: 34
                                color: colorful.equalizerPreset === modelData ? Qt.rgba(1, 1, 1, 0.075) : presetHover.hovered ? Qt.rgba(1, 1, 1, 0.04) : "transparent"
                                border.width: 1; border.color: colorful.equalizerPreset === modelData ? colorful.accent : Qt.rgba(1, 1, 1, 0.12)
                                Text { id: presetLabel; anchors.centerIn: parent; text: modelData; color: "#f5f5f5"; font.bold: true; font.pixelSize: 10 }
                                HoverHandler { id: presetHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: colorful.applyEqualizerPreset(modelData) }
                            }
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 230
                        color: Qt.rgba(1, 1, 1, 0.018); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.08)
                        Row {
                            anchors.fill: parent; anchors.margins: 12; spacing: 0
                            Repeater {
                                model: [["31", 0], ["62", 1], ["125", 2], ["250", 3], ["500", 4], ["1k", 5], ["2k", 6], ["4k", 7], ["8k", 8], ["16k", 9]]
                                delegate: Item {
                                    required property var modelData
                                    width: parent.width / 10; height: parent.height
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: Number(eqSlider.value).toFixed(1) + " dB"; color: Qt.rgba(1, 1, 1, 0.54); font.pixelSize: 9 }
                                    Slider {
                                        id: eqSlider
                                        anchors.horizontalCenter: parent.horizontalCenter; anchors.top: parent.top; anchors.topMargin: 25; anchors.bottom: bandLabel.top; anchors.bottomMargin: 7
                                        orientation: Qt.Vertical; from: -12; to: 12; stepSize: 0.5
                                        Component.onCompleted: value = Number(colorful.equalizerBands[modelData[1]] || 0)
                                        onPressedChanged: if (!pressed) colorful.setEqualizerBand(modelData[1], value)
                                        background: Rectangle { x: eqSlider.leftPadding + eqSlider.availableWidth / 2 - 1; y: eqSlider.topPadding; width: 2; height: eqSlider.availableHeight; color: Qt.rgba(1, 1, 1, 0.16) }
                                        handle: Rectangle { x: eqSlider.leftPadding + eqSlider.availableWidth / 2 - width / 2; y: eqSlider.topPadding + eqSlider.visualPosition * (eqSlider.availableHeight - height); width: 12; height: 4; color: colorful.accent; border.width: 1; border.color: "#111114" }
                                        Connections {
                                            target: colorful
                                            function onAudioProcessingChanged() {
                                                if (!eqSlider.pressed)
                                                    eqSlider.value = Number(colorful.equalizerBands[modelData[1]] || 0)
                                            }
                                        }
                                    }
                                    Text { id: bandLabel; anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter; text: modelData[0] + " Hz"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 9 }
                                }
                            }
                        }
                    }
                    Text { text: "EQ is applied locally through the native playback engine. Boosted bands are protected by a limiter; Flat leaves the audio filter path untouched."; color: Qt.rgba(1, 1, 1, 0.34); font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true }
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
                    Text { text: "Use the active album artwork or keep one accent across the interface."; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 12 }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 88
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        RowLayout { anchors.fill: parent; anchors.margins: 15; spacing: 14
                            Rectangle { width: 46; height: 46; color: colorful.accent; border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.35) }
                            ColumnLayout { Layout.fillWidth: true; spacing: 3
                                Text { text: colorful.accentMode === "album" ? "Album-derived accent" : "Fixed accent"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 13 }
                                Text { text: colorful.accentMode === "album" ? "Colors animate between tracks and are corrected for dark-background contrast." : "This color remains active when the track changes."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                            }
                        }
                    }
                    Row {
                        Layout.fillWidth: true; spacing: 0
                        Repeater {
                            model: [["album", "Follow album artwork"], ["fixed", "Use a fixed color"]]
                            delegate: Rectangle {
                                required property var modelData
                                width: modeText.implicitWidth + 30; height: 40
                                color: colorful.accentMode === modelData[0] ? Qt.rgba(1, 1, 1, 0.075) : modeHover.hovered ? Qt.rgba(1, 1, 1, 0.04) : "transparent"
                                border.width: 1; border.color: colorful.accentMode === modelData[0] ? colorful.accent : Qt.rgba(1, 1, 1, 0.12)
                                Text { id: modeText; anchors.centerIn: parent; text: modelData[1]; color: "#f5f5f5"; font.bold: colorful.accentMode === modelData[0]; font.pixelSize: 11 }
                                HoverHandler { id: modeHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: colorful.accentMode = modelData[0] }
                            }
                        }
                    }
                    Text { text: "Fixed color"; visible: colorful.accentMode === "fixed"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 14; Layout.topMargin: 4 }
                    Row {
                        visible: colorful.accentMode === "fixed"
                        Layout.fillWidth: true; spacing: 8
                        Repeater {
                            model: ["#a970ff", "#ff4f91", "#f06a3c", "#e8ce42", "#37d6c1", "#4f8cff", "#f5f5f5"]
                            delegate: Rectangle {
                                required property string modelData
                                width: 42; height: 42; color: modelData
                                border.width: colorful.fixedAccent.toString().toLowerCase() === modelData ? 3 : 1
                                border.color: colorful.fixedAccent.toString().toLowerCase() === modelData ? "#f5f5f5" : Qt.rgba(1, 1, 1, 0.28)
                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: colorful.fixedAccent = modelData }
                            }
                        }
                    }
                    RowLayout {
                        visible: colorful.accentMode === "fixed"
                        Layout.fillWidth: true
                        spacing: 10
                        Rectangle {
                            Layout.preferredWidth: 42
                            Layout.preferredHeight: 42
                            color: colorful.fixedAccent
                            border.width: 1
                            border.color: Qt.rgba(1, 1, 1, 0.35)
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Text { text: "Custom color"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 12 }
                            Text { text: colorful.fixedAccent.toString().toUpperCase(); color: Qt.rgba(1, 1, 1, 0.38); font.pixelSize: 10 }
                        }
                        ColorButton {
                            text: "Choose color…"
                            quiet: true
                            onClicked: {
                                accentColorDialog.selectedColor = colorful.fixedAccent
                                accentColorDialog.open()
                            }
                        }
                    }
                }
            }

            Flickable {
                clip: true; contentWidth: width; contentHeight: storageBody.implicitHeight + 30
                boundsBehavior: Flickable.StopAtBounds
                ColumnLayout {
                    id: storageBody
                    width: Math.min(parent.width, 820); spacing: 14
                    Text { text: "Storage"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 24 }
                    Text { Layout.fillWidth: true; text: "Offline files are private application data. They contain playable audio and do not depend on an expiring manifest after completion."; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 12; wrapMode: Text.WordWrap }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 105
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        RowLayout {
                            anchors.fill: parent; anchors.margins: 16; spacing: 18
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 3
                                Text { text: root.formatStorage(root.downloadedBytes()); color: "#f5f5f5"; font.bold: true; font.pixelSize: 22 }
                                Text { text: colorful.downloads.length + " offline " + (colorful.downloads.length === 1 ? "entry" : "entries"); color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: 11 }
                            }
                            ColorButton { text: "Open folder"; quiet: true; onClicked: colorful.openDownloadsFolder() }
                        }
                    }
                    Text { text: "Download quality"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 14 }
                    Text { Layout.fillWidth: true; text: "New downloads currently follow the TIDAL stream-quality choice in Playback settings. Per-download quality and automatic cache limits can be added without changing the stored-file format."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; wrapMode: Text.WordWrap }
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
                    AccountCard {
                        Layout.fillWidth: true
                        title: "Build"
                        rows: [
                            ["Version", colorful.buildInfo.version || "unknown"],
                            ["Commit", colorful.buildInfo.commit || "unknown"],
                            ["System", colorful.buildInfo.system || "Linux"],
                            ["Architecture", colorful.buildInfo.architecture || "unknown"],
                            ["Compiler", colorful.buildInfo.compiler || "unknown"]
                        ]
                    }
                    AccountCard {
                        Layout.fillWidth: true
                        title: "Runtime components"
                        rows: [
                            ["Interface", "Qt " + (colorful.buildInfo.qt || "unknown") + " / Qt Quick"],
                            ["Playback", "libmpv " + (colorful.buildInfo.mpv || "unknown")],
                            ["Core", "Rust / SQLite"],
                            ["Provider host", "Bun / TypeScript"]
                        ]
                    }
                    AccountCard {
                        Layout.fillWidth: true
                        title: "Licenses"
                        rows: [
                            ["colorful", colorful.buildInfo.license || "GPL-3.0-or-later"],
                            ["Qt", "LGPL-3.0 / GPL-3.0"],
                            ["libmpv", "GPL-compatible build"],
                            ["Bun", "MIT"],
                            ["Nunito", "OFL-1.1"]
                        ]
                    }
                    Text { Layout.fillWidth: true; text: "This personal project is entirely AI-made. It exists because its owner needed a stable music client that worked for them."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; wrapMode: Text.WordWrap }
                }
            }
        }
    }

    ColorDialog {
        id: accentColorDialog
        title: "Choose a colorful accent"
        onAccepted: {
            colorful.fixedAccent = selectedColor
            colorful.accentMode = "fixed"
        }
    }
}
