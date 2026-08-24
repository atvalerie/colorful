import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

Item {
    id: root
    property int tab: 0
    property url pendingTravelImportFile: ""
    readonly property var aboutBuild: colorful.buildInfo || {}
    readonly property var pages: [
        ["Accounts", "Provider connections"],
        ["Playback", "Queue and audio behavior"],
        ["Integrations", "Discord and external services"],
        ["Appearance", "Color and interface"],
        ["Storage", "Cache and offline music"],
        ["Sync", "Devices and handoff"],
        ["About", "Build, runtime, and licenses"]
    ]

    function fieldBackground(field) {
        return field.activeFocus ? colorful.accent : Qt.rgba(1, 1, 1, 0.13)
    }

    function formatStorage(bytes) {
        if (!bytes) return "0 MB"
        if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + " MB"
        return (bytes / (1024 * 1024 * 1024)).toFixed(2) + " GB"
    }

    function shortDate(value) {
        if (!value) return "Pending"
        return String(value).slice(0, 10)
    }

    function readablePlan(value, fallback) {
        if (!value) return fallback
        return String(value).replace(/^creator-/, "").replace(/-/g, " ").replace(/\b\w/g, function(letter) { return letter.toUpperCase() })
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
                    font.pixelSize: Math.round(22 * colorful.textScale)
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
                            Text { text: modelData[0]; color: root.tab === index ? "#f5f5f5" : Qt.rgba(1, 1, 1, 0.66); font.bold: root.tab === index; font.pixelSize: Math.round(12 * colorful.textScale) }
                            Text { width: parent.width; text: modelData[1]; color: Qt.rgba(1, 1, 1, 0.32); font.pixelSize: Math.round(9 * colorful.textScale); elide: Text.ElideRight }
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
                    Text { text: "Accounts"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(24 * colorful.textScale) }
                    Text { text: "Provider credentials remain on this device and are stored by the system credential service."; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: Math.round(12 * colorful.textScale); wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    ProviderAccountCard {
                        Layout.fillWidth: true
                        providerName: "TIDAL"
                        loading: !colorful.providerStatusResolved
                        connected: colorful.linked
                        statusText: !colorful.providerStatusResolved ? "Checking saved account…" : colorful.linked
                                    ? "Connected  ·  " + (((colorful.tidalHub.account || {}).email)
                                                         || ((colorful.tidalHub.account || {}).username)
                                                         || ((colorful.tidalHub.account || {}).countryCode)
                                                         || "account ready")
                                    : "Not connected"
                        description: colorful.linked ? "Search, lossless playback, collection, playlists, and mixes use this account." : "Connect using TIDAL's device authorization flow."
                        details: {
                            const account = colorful.tidalHub.account || {}
                            return [
                                [root.readablePlan(account.subscriptionType, account.status || "Active"), "Plan"],
                                [root.shortDate(account.validUntil), "Valid until"],
                                [account.countryCode || "Pending", "Region"]
                            ]
                        }
                        primaryText: colorful.linked ? "View account" : "Connect"
                        onPrimaryRequested: colorful.linked ? colorful.openTidalAccount() : colorful.startLogin()
                        onSecondaryRequested: colorful.unlink()
                    }
                    ProviderAccountCard {
                        Layout.fillWidth: true
                        providerName: "YouTube Music"
                        loading: !colorful.providerStatusResolved
                        connected: colorful.youtubeLinked
                        statusText: !colorful.providerStatusResolved ? "Checking saved account…" : colorful.youtubeLinked
                                    ? "Connected  ·  " + (((colorful.youtubeHub.account || {}).channelHandle) || ((colorful.youtubeHub.account || {}).accountName) || "account ready")
                                    : "Anonymous catalog mode"
                        description: colorful.youtubeLinked
                                     ? "Private playlists, liked music, library artists, albums, and personalized mixes use this account."
                                     : "Sign in through an isolated Chromium-based browser window. colorful captures only the YouTube Music session needed for your library."
                        details: [
                            [((colorful.youtubeHub.account || {}).premiumStatus) || "Unknown", "Plan"],
                            [String((colorful.youtubeHub.tracks || []).length), "Liked tracks"],
                            [String((colorful.youtubeHub.playlists || []).length + (colorful.youtubeHub.mixes || []).length), "Playlists & mixes"]
                        ]
                        primaryText: colorful.youtubeLinked ? "Reconnect" : "Sign in"
                        extraVisible: !colorful.youtubeLinked
                        onPrimaryRequested: colorful.startYouTubeBrowserLogin()
                        onSecondaryRequested: colorful.unlinkYouTube()
                        Text {
                            visible: !colorful.youtubeLinked; Layout.fillWidth: true
                            text: "Manual fallback — paste a logged-in /browse request or Copy as cURL:"
                            color: Qt.rgba(1, 1, 1, 0.34); wrapMode: Text.WordWrap
                            font.pixelSize: Math.round(10 * colorful.textScale)
                        }
                        RowLayout {
                            visible: !colorful.youtubeLinked; Layout.fillWidth: true; spacing: 8
                            ScrollView {
                                Layout.fillWidth: true; Layout.preferredHeight: 118; clip: true
                                TextArea {
                                    id: youtubeBrowserHeaders
                                    placeholderText: "Paste request headers or Copy as cURL here"
                                    placeholderTextColor: Qt.rgba(1, 1, 1, 0.3)
                                    color: "#f5f5f5"; selectByMouse: true; wrapMode: TextEdit.WrapAnywhere; font.pixelSize: Math.round(11 * colorful.textScale)
                                    background: Rectangle { color: Qt.rgba(0, 0, 0, 0.22); border.width: 1; border.color: root.fieldBackground(youtubeBrowserHeaders) }
                                }
                            }
                            ColorButton {
                                text: "Connect session"; enabled: youtubeBrowserHeaders.text.trim().length > 0 && !colorful.busy
                                onClicked: colorful.connectYouTubeBrowserSession(youtubeBrowserHeaders.text)
                            }
                        }
                    }
                    ProviderAccountCard {
                        Layout.fillWidth: true
                        providerName: "SoundCloud"
                        loading: !colorful.providerStatusResolved
                        connected: colorful.soundcloudLinked
                        statusText: !colorful.providerStatusResolved ? "Checking saved account…" : colorful.soundcloudLinked
                                    ? "Connected  ·  " + (((colorful.soundcloudHub.account || {}).username) || "account ready")
                                    : "Public catalog mode"
                        description: colorful.soundcloudLinked
                                     ? "Liked tracks, sets, and followed profiles use this account. Only the OAuth token is retained."
                                     : "Sign in through an isolated Chromium-based browser window. colorful retains only the SoundCloud OAuth session token."
                        details: {
                            const account = colorful.soundcloudHub.account || {}
                            return [
                                [root.readablePlan(account.plan, "Free"), "Plan"],
                                [String(account.followersCount || 0), "Followers"],
                                [String(account.likesCount || 0), "Likes"]
                            ]
                        }
                        primaryText: colorful.soundcloudLinked ? "Reconnect" : "Sign in"
                        extraVisible: !colorful.soundcloudLinked
                        onPrimaryRequested: colorful.startSoundCloudBrowserLogin()
                        onSecondaryRequested: colorful.unlinkSoundCloud()
                        Text {
                            visible: !colorful.soundcloudLinked; Layout.fillWidth: true
                            text: "Manual fallback — paste a logged-in SoundCloud API request copied as cURL:"
                            color: Qt.rgba(1, 1, 1, 0.34); wrapMode: Text.WordWrap
                            font.pixelSize: Math.round(10 * colorful.textScale)
                        }
                        RowLayout {
                            visible: !colorful.soundcloudLinked; Layout.fillWidth: true; spacing: 8
                            ScrollView {
                                Layout.fillWidth: true; Layout.preferredHeight: 118; clip: true
                                TextArea {
                                    id: soundcloudCurl
                                    placeholderText: "Paste a logged-in SoundCloud request copied as cURL"
                                    placeholderTextColor: Qt.rgba(1, 1, 1, 0.3)
                                    color: "#f5f5f5"; selectByMouse: true; wrapMode: TextEdit.WrapAnywhere; font.pixelSize: Math.round(11 * colorful.textScale)
                                    background: Rectangle { color: Qt.rgba(0, 0, 0, 0.22); border.width: 1; border.color: root.fieldBackground(soundcloudCurl) }
                                }
                            }
                            ColorButton {
                                text: "Connect session"; enabled: soundcloudCurl.text.trim().length > 0 && !colorful.busy
                                onClicked: colorful.connectSoundCloudSession(soundcloudCurl.text)
                            }
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
                    Text { text: "Playback"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(24 * colorful.textScale) }
                    Text { text: "Behavior shared by the desktop queue and playback controls."; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: Math.round(12 * colorful.textScale) }
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
                            Text { text: "Autoplay"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(13 * colorful.textScale) }
                            Text { width: parent.width; text: "Continue with related tracks when the queue ends."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); elide: Text.ElideRight }
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
                    Text { text: "TIDAL stream quality"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(14 * colorful.textScale); Layout.topMargin: 5 }
                    Text { text: "The selected format is requested when the next track opens. TIDAL may fall back when a release has no matching format."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); wrapMode: Text.WordWrap; Layout.fillWidth: true }
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
                                    Text { id: qualityText; anchors.horizontalCenter: parent.horizontalCenter; text: modelData[1]; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(12 * colorful.textScale) }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData[2]; color: Qt.rgba(1, 1, 1, 0.36); font.pixelSize: Math.round(9 * colorful.textScale) }
                                }
                                HoverHandler { id: qualityHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: colorful.streamQuality = modelData[0] }
                            }
                        }
                    }
                    Text { text: "Audio output"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(14 * colorful.textScale); Layout.topMargin: 8 }
                    Text {
                        text: colorful.buildInfo.platform === "windows"
                              ? "Choose the Windows output used by libmpv. System default follows WASAPI routing changes."
                              : "Choose the Linux output used by libmpv. System default follows PipeWire routing changes."
                        color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        ComboBox {
                            id: outputPicker
                            Layout.fillWidth: true; implicitHeight: 38
                            model: colorful.audioDevices
                            textRole: "description"
                            valueRole: "name"
                            currentIndex: {
                                for (let index = 0; index < colorful.audioDevices.length; ++index) {
                                    if (colorful.audioDevices[index].name === colorful.audioDevice) return index
                                }
                                return 0
                            }
                            onActivated: colorful.audioDevice = currentValue
                            contentItem: Text {
                                leftPadding: 12; rightPadding: 28
                                text: outputPicker.displayText
                                color: "#f5f5f5"; font.pixelSize: Math.round(12 * colorful.textScale)
                                verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                            }
                            background: Rectangle {
                                color: outputPicker.hovered ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(1, 1, 1, 0.035)
                                border.width: 1; border.color: outputPicker.activeFocus ? colorful.accent : Qt.rgba(1, 1, 1, 0.14)
                            }
                            indicator: Item {
                                x: outputPicker.width - width - 12
                                y: (outputPicker.height - height) / 2
                                width: 12; height: 8
                                Rectangle { width: 7; height: 1; color: Qt.rgba(1, 1, 1, 0.55); rotation: 35; x: 0; y: 3 }
                                Rectangle { width: 7; height: 1; color: Qt.rgba(1, 1, 1, 0.55); rotation: -35; x: 5; y: 3 }
                            }
                            delegate: ItemDelegate {
                                required property var modelData
                                width: outputPicker.width; height: 34
                                contentItem: Text {
                                    text: modelData.description || modelData.name
                                    color: "#f5f5f5"; font.pixelSize: Math.round(11 * colorful.textScale)
                                    verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                                }
                                background: Rectangle {
                                    color: parent.highlighted ? Qt.rgba(colorful.accent.r, colorful.accent.g, colorful.accent.b, 0.2) : "#121216"
                                }
                            }
                            popup.background: Rectangle {
                                color: "#121216"; border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.16)
                            }
                            popup.height: Math.min(outputPicker.count * 34 + 2, 274)
                            popup.width: outputPicker.width
                            popup.contentItem.clip: true
                        }
                        ColorButton {
                            text: "Refresh"; quiet: true
                            implicitWidth: 72; implicitHeight: 38
                            onClicked: colorful.refreshAudioDevices()
                        }
                    }
                    Rectangle {
                        visible: colorful.buildInfo.platform === "windows"
                        Layout.fillWidth: true; Layout.preferredHeight: visible ? 76 : 0
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        Column {
                            anchors.left: parent.left; anchors.leftMargin: 15
                            anchors.right: exclusiveSwitch.left; anchors.rightMargin: 18
                            anchors.verticalCenter: parent.verticalCenter; spacing: 3
                            Text { text: "WASAPI exclusive mode"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(13 * colorful.textScale) }
                            Text {
                                width: parent.width
                                text: "Bypass the Windows mixer and match the source format when the device allows it. Other apps cannot use that output; ReplayGain and EQ still alter samples."
                                color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); elide: Text.ElideRight
                            }
                        }
                        Rectangle {
                            id: exclusiveSwitch
                            anchors.right: parent.right; anchors.rightMargin: 15
                            anchors.verticalCenter: parent.verticalCenter
                            width: 42; height: 24
                            color: colorful.audioExclusive ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
                            border.width: 1; border.color: colorful.audioExclusive ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.18)
                            Rectangle { width: 16; height: 16; y: 3; x: colorful.audioExclusive ? parent.width - width - 3 : 3; color: colorful.audioExclusive && (0.2126 * colorful.accent.r + 0.7152 * colorful.accent.g + 0.0722 * colorful.accent.b) > 0.56 ? "#111114" : "#f5f5f5"; Behavior on x { NumberAnimation { duration: 100 } } }
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: colorful.audioExclusive = !colorful.audioExclusive }
                        }
                    }
                    Text { text: "Volume normalization"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(14 * colorful.textScale); Layout.topMargin: 8 }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 76
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        Column {
                            anchors.left: parent.left; anchors.leftMargin: 15
                            anchors.right: normalizationSwitch.left; anchors.rightMargin: 18
                            anchors.verticalCenter: parent.verticalCenter; spacing: 3
                            Text { text: "ReplayGain"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(13 * colorful.textScale) }
                            Text { width: parent.width; text: "Use TIDAL manifest loudness data or embedded ReplayGain tags, with peak-based clipping protection."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); elide: Text.ElideRight }
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
                        Text { text: "Equalizer"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(14 * colorful.textScale) }
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
                                Text { id: presetLabel; anchors.centerIn: parent; text: modelData; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(10 * colorful.textScale) }
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
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: Number(eqSlider.value).toFixed(1) + " dB"; color: Qt.rgba(1, 1, 1, 0.54); font.pixelSize: Math.round(9 * colorful.textScale) }
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
                                    Text { id: bandLabel; anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter; text: modelData[0] + " Hz"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(9 * colorful.textScale) }
                                }
                            }
                        }
                    }
                    Text { text: "EQ is applied locally through the native playback engine. Boosted bands are protected by a limiter; Flat leaves the audio filter path untouched."; color: Qt.rgba(1, 1, 1, 0.34); font.pixelSize: Math.round(11 * colorful.textScale); wrapMode: Text.WordWrap; Layout.fillWidth: true }
                }
            }

            Flickable {
                clip: true; contentWidth: width; contentHeight: integrationsBody.implicitHeight + 30
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                ColumnLayout {
                    id: integrationsBody
                    width: Math.min(parent.width, 820); spacing: 12
                    Text { text: "Integrations"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(24 * colorful.textScale) }
                    Text { text: "Choose what colorful shares through the running Discord desktop client."; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: Math.round(12 * colorful.textScale); wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 166
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        Column {
                            anchors.fill: parent; anchors.margins: 15; spacing: 12
                            Item {
                                width: parent.width; height: 54
                                Column {
                                    anchors.left: parent.left; anchors.leftMargin: 0
                                    anchors.right: presenceSwitch.left; anchors.rightMargin: 18
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 3
                                    Text { text: "Discord Rich Presence"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(13 * colorful.textScale) }
                                    Text { width: parent.width; text: "Show what you are listening to in your Discord profile while Discord is running."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); wrapMode: Text.WordWrap; elide: Text.ElideRight }
                                }
                                Rectangle {
                                    id: presenceSwitch
                                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    width: 42; height: 22
                                    color: colorful.discordPresenceEnabled ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
                                    border.width: 1; border.color: colorful.discordPresenceEnabled ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.18)
                                    Rectangle { width: 16; height: 16; y: 3; x: colorful.discordPresenceEnabled ? parent.width - width - 3 : 3; color: colorful.discordPresenceEnabled && (0.2126 * colorful.accent.r + 0.7152 * colorful.accent.g + 0.0722 * colorful.accent.b) > 0.56 ? "#111114" : "#f5f5f5"; Behavior on x { NumberAnimation { duration: 100 } } }
                                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                                    TapHandler { onTapped: colorful.discordPresenceEnabled = !colorful.discordPresenceEnabled }
                                }
                            }
                            Item {
                                width: parent.width; height: 70
                                opacity: colorful.discordPresenceEnabled ? 1 : 0.42
                                Column {
                                    anchors.left: parent.left; anchors.leftMargin: 18
                                    anchors.right: trackButtonSwitch.left; anchors.rightMargin: 18
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 3
                                    Text { text: "View Track button"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(12 * colorful.textScale) }
                                    Text { width: parent.width; text: "Let other users open the current track directly at its provider."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); wrapMode: Text.WordWrap; elide: Text.ElideRight }
                                }
                                Rectangle {
                                    id: trackButtonSwitch
                                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    width: 42; height: 22; enabled: colorful.discordPresenceEnabled
                                    color: colorful.discordTrackButtonEnabled ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
                                    border.width: 1; border.color: colorful.discordTrackButtonEnabled ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.18)
                                    Rectangle { width: 16; height: 16; y: 3; x: colorful.discordTrackButtonEnabled ? parent.width - width - 3 : 3; color: colorful.discordTrackButtonEnabled && (0.2126 * colorful.accent.r + 0.7152 * colorful.accent.g + 0.0722 * colorful.accent.b) > 0.56 ? "#111114" : "#f5f5f5"; Behavior on x { NumberAnimation { duration: 100 } } }
                                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                                    TapHandler { onTapped: colorful.discordTrackButtonEnabled = !colorful.discordTrackButtonEnabled }
                                }
                            }
                        }
                    }
                }
            }

            Flickable {
                clip: true; contentWidth: width; contentHeight: appearanceBody.implicitHeight + 30
                ColumnLayout {
                    id: appearanceBody
                    width: Math.min(parent.width, 820); spacing: 14
                    Text { text: "Appearance"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(24 * colorful.textScale) }
                    Text { text: "Use the active album artwork or keep one accent across the interface."; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: Math.round(12 * colorful.textScale) }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 76
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        Column {
                            anchors.left: parent.left; anchors.leftMargin: 15
                            anchors.right: lowDataSwitch.left; anchors.rightMargin: 18
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3
                            Text { text: "Low data mode"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(13 * colorful.textScale) }
                            Text { width: parent.width; text: "Do not request or decode artwork and profile images. App icons remain visible."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); elide: Text.ElideRight }
                        }
                        Rectangle {
                            id: lowDataSwitch
                            anchors.right: parent.right; anchors.rightMargin: 15
                            anchors.verticalCenter: parent.verticalCenter
                            width: 42; height: 22
                            color: colorful.lowDataMode ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
                            border.width: 1; border.color: colorful.lowDataMode ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.18)
                            Rectangle { width: 16; height: 16; y: 3; x: colorful.lowDataMode ? parent.width - width - 3 : 3; color: colorful.lowDataMode && (0.2126 * colorful.accent.r + 0.7152 * colorful.accent.g + 0.0722 * colorful.accent.b) > 0.56 ? "#111114" : "#f5f5f5"; Behavior on x { NumberAnimation { duration: 100 } } }
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: colorful.lowDataMode = !colorful.lowDataMode }
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 76
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        Column {
                            anchors.left: parent.left; anchors.leftMargin: 15
                            anchors.right: hardwareAccelerationSwitch.left; anchors.rightMargin: 18
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3
                            Text { text: "Hardware acceleration"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(13 * colorful.textScale) }
                            Text { width: parent.width; text: "Use the GPU for the interface. Restart colorful after changing this setting."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); elide: Text.ElideRight }
                        }
                        Rectangle {
                            id: hardwareAccelerationSwitch
                            anchors.right: parent.right; anchors.rightMargin: 15
                            anchors.verticalCenter: parent.verticalCenter
                            width: 42; height: 22
                            color: colorful.hardwareAccelerationEnabled ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
                            border.width: 1; border.color: colorful.hardwareAccelerationEnabled ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.18)
                            Rectangle { width: 16; height: 16; y: 3; x: colorful.hardwareAccelerationEnabled ? parent.width - width - 3 : 3; color: colorful.hardwareAccelerationEnabled && (0.2126 * colorful.accent.r + 0.7152 * colorful.accent.g + 0.0722 * colorful.accent.b) > 0.56 ? "#111114" : "#f5f5f5"; Behavior on x { NumberAnimation { duration: 100 } } }
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: colorful.hardwareAccelerationEnabled = !colorful.hardwareAccelerationEnabled }
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 82
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        RowLayout {
                            anchors.fill: parent; anchors.margins: 15; spacing: 18
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 3
                                Text { text: "Text size"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(13 * colorful.textScale) }
                                Text { Layout.fillWidth: true; text: "Scale typography independently from controls and artwork."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); elide: Text.ElideRight }
                            }
                            Row {
                                spacing: 0
                                Repeater {
                                    model: [[1.0, "100%"], [1.1, "110%"], [1.2, "120%"]]
                                    delegate: Rectangle {
                                        required property var modelData
                                        width: 62; height: 36
                                        color: Math.abs(colorful.textScale - modelData[0]) < 0.01 ? Qt.rgba(1, 1, 1, 0.075) : textScaleHover.hovered ? Qt.rgba(1, 1, 1, 0.04) : "transparent"
                                        border.width: 1
                                        border.color: Math.abs(colorful.textScale - modelData[0]) < 0.01 ? colorful.accent : Qt.rgba(1, 1, 1, 0.12)
                                        Text { anchors.centerIn: parent; text: modelData[1]; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(11 * colorful.textScale) }
                                        HoverHandler { id: textScaleHover; cursorShape: Qt.PointingHandCursor }
                                        TapHandler { onTapped: colorful.textScale = modelData[0] }
                                    }
                                }
                            }
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 88
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        RowLayout { anchors.fill: parent; anchors.margins: 15; spacing: 14
                            Rectangle { width: 46; height: 46; color: colorful.accent; border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.35) }
                            ColumnLayout { Layout.fillWidth: true; spacing: 3
                                Text { text: colorful.accentMode === "album" ? "Album-derived accent" : "Fixed accent"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(13 * colorful.textScale) }
                                Text { text: colorful.accentMode === "album" ? (colorful.lowDataMode ? "Album color updates are paused while low data mode is active." : "Colors animate between tracks and are corrected for dark-background contrast.") : "This color remains active when the track changes."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); wrapMode: Text.WordWrap; Layout.fillWidth: true }
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
                                Text { id: modeText; anchors.centerIn: parent; text: modelData[1]; color: "#f5f5f5"; font.bold: colorful.accentMode === modelData[0]; font.pixelSize: Math.round(11 * colorful.textScale) }
                                HoverHandler { id: modeHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: colorful.accentMode = modelData[0] }
                            }
                        }
                    }
                    Text { text: "Fixed color"; visible: colorful.accentMode === "fixed"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(14 * colorful.textScale); Layout.topMargin: 4 }
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
                            Text { text: "Custom color"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(12 * colorful.textScale) }
                            Text { text: colorful.fixedAccent.toString().toUpperCase(); color: Qt.rgba(1, 1, 1, 0.38); font.pixelSize: Math.round(10 * colorful.textScale) }
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
                    Text { text: "Storage"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(24 * colorful.textScale) }
                    Text { Layout.fillWidth: true; text: "Offline files are private application data. They contain playable audio and do not depend on an expiring manifest after completion."; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: Math.round(12 * colorful.textScale); wrapMode: Text.WordWrap }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: storageFolderColumn.implicitHeight + 32
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        ColumnLayout {
                            id: storageFolderColumn
                            anchors.fill: parent; anchors.margins: 16; spacing: 8
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 3
                                Text { text: "Download folder"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(13 * colorful.textScale) }
                                Text { Layout.fillWidth: true; text: colorful.downloadDirectory; color: Qt.rgba(1, 1, 1, 0.48); font.pixelSize: Math.round(11 * colorful.textScale); elide: Text.ElideMiddle }
                                Text { Layout.fillWidth: true; text: "New downloads use this folder. Existing completed downloads stay where they are."; color: Qt.rgba(1, 1, 1, 0.34); font.pixelSize: Math.round(10 * colorful.textScale); wrapMode: Text.WordWrap }
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                ColorButton { text: "Choose folder…"; quiet: true; onClicked: downloadFolderDialog.open() }
                                ColorButton { text: "Open folder"; quiet: true; onClicked: colorful.openDownloadsFolder() }
                                ColorButton { text: "Use default"; quiet: true; enabled: !colorful.downloadDirectoryIsDefault; onClicked: colorful.resetDownloadDirectory() }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 3
                                Text { text: root.formatStorage(colorful.offlineStorageUsed); color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(22 * colorful.textScale) }
                                Text { text: colorful.downloads.length + " offline " + (colorful.downloads.length === 1 ? "entry" : "entries"); color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: Math.round(11 * colorful.textScale) }
                                Text { text: colorful.offlineStorageLimitBytes > 0 ? "Limit: " + root.formatStorage(colorful.offlineStorageLimitBytes) : "No storage limit"; color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: Math.round(11 * colorful.textScale) }
                            }
                        }
                    }
                    Text { text: "Offline storage limit"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(14 * colorful.textScale) }
                    Text { Layout.fillWidth: true; text: "Downloads pause at the limit. colorful never removes completed music automatically."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); wrapMode: Text.WordWrap }
                    Row {
                        Layout.fillWidth: true; spacing: 0
                        Repeater {
                            model: [["Unlimited", 0], ["2 GB", 2], ["5 GB", 5], ["10 GB", 10], ["25 GB", 25], ["50 GB", 50]]
                            delegate: Rectangle {
                                required property var modelData
                                readonly property real bytes: modelData[1] * 1024 * 1024 * 1024
                                width: 108; height: 42
                                color: colorful.offlineStorageLimitBytes === bytes ? Qt.rgba(1, 1, 1, 0.075) : quotaHover.hovered ? Qt.rgba(1, 1, 1, 0.04) : "transparent"
                                border.width: 1
                                border.color: colorful.offlineStorageLimitBytes === bytes ? colorful.accent : Qt.rgba(1, 1, 1, 0.12)
                                Text { anchors.centerIn: parent; text: modelData[0]; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(11 * colorful.textScale) }
                                HoverHandler { id: quotaHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: colorful.offlineStorageLimitBytes = parent.bytes }
                            }
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 6
                        visible: colorful.offlineStorageLimitBytes > 0
                        color: Qt.rgba(1, 1, 1, 0.1)
                        Rectangle {
                            width: parent.width * Math.min(1, colorful.offlineStorageUsed / colorful.offlineStorageLimitBytes)
                            height: parent.height
                            color: colorful.offlineStorageUsed >= colorful.offlineStorageLimitBytes ? "#ff7777" : colorful.accent
                        }
                    }
                    Text { text: "Download quality"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(14 * colorful.textScale) }
                    Text { Layout.fillWidth: true; text: "TIDAL downloads follow the stream-quality choice in Playback. SoundCloud normally uses its preferred AAC 160 stream."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); wrapMode: Text.WordWrap }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 82
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        Column {
                            anchors.left: parent.left; anchors.leftMargin: 15
                            anchors.right: soundcloudOriginalSwitch.left; anchors.rightMargin: 18
                            anchors.verticalCenter: parent.verticalCenter; spacing: 3
                            Text { text: "Prefer SoundCloud originals"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(13 * colorful.textScale) }
                            Text {
                                width: parent.width
                                text: "Use the uploader's WAV, FLAC, or other original when downloads are enabled. Originals can be hundreds of megabytes; unavailable originals fall back to AAC."
                                color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); wrapMode: Text.WordWrap
                            }
                        }
                        Rectangle {
                            id: soundcloudOriginalSwitch
                            anchors.right: parent.right; anchors.rightMargin: 15
                            anchors.verticalCenter: parent.verticalCenter
                            width: 42; height: 22
                            color: colorful.soundcloudOriginalDownloads ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
                            border.width: 1; border.color: colorful.soundcloudOriginalDownloads ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.18)
                            Rectangle { width: 16; height: 16; y: 3; x: colorful.soundcloudOriginalDownloads ? parent.width - width - 3 : 3; color: colorful.soundcloudOriginalDownloads && (0.2126 * colorful.accent.r + 0.7152 * colorful.accent.g + 0.0722 * colorful.accent.b) > 0.56 ? "#111114" : "#f5f5f5"; Behavior on x { NumberAnimation { duration: 100 } } }
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: colorful.soundcloudOriginalDownloads = !colorful.soundcloudOriginalDownloads }
                        }
                    }
                }
            }

            Flickable {
                clip: true; contentWidth: width; contentHeight: syncBody.implicitHeight + 30
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                ColumnLayout {
                    id: syncBody
                    width: Math.min(parent.width, 820); spacing: 14
                    Text { text: "Sync"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(24 * colorful.textScale) }
                    Text {
                        Layout.fillWidth: true
                        text: "Listening parties use encrypted timing messages and a local monotonic clock. Device identity and cross-device handoff are still being built."
                        color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: Math.round(12 * colorful.textScale); wrapMode: Text.WordWrap
                    }
                    Text { text: "Diagnostics"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(14 * colorful.textScale); Layout.topMargin: 8 }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 82
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        Column {
                            anchors.left: parent.left; anchors.leftMargin: 15
                            anchors.right: partyDiagnosticsSwitch.left; anchors.rightMargin: 18
                            anchors.verticalCenter: parent.verticalCenter; spacing: 3
                            Text { text: "Party synchronization stats"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(13 * colorful.textScale) }
                            Text {
                                width: parent.width
                                text: "Show live RTT, clock offset, playback drift, correction state, samples, and hard resyncs in Listen together. Stored only on this device."
                                color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); wrapMode: Text.WordWrap
                            }
                        }
                        Rectangle {
                            id: partyDiagnosticsSwitch
                            anchors.right: parent.right; anchors.rightMargin: 15
                            anchors.verticalCenter: parent.verticalCenter
                            width: 42; height: 22
                            color: colorful.partyDiagnosticsEnabled ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
                            border.width: 1; border.color: colorful.partyDiagnosticsEnabled ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.18)
                            Rectangle { width: 16; height: 16; y: 3; x: colorful.partyDiagnosticsEnabled ? parent.width - width - 3 : 3; color: colorful.partyDiagnosticsEnabled && (0.2126 * colorful.accent.r + 0.7152 * colorful.accent.g + 0.0722 * colorful.accent.b) > 0.56 ? "#111114" : "#f5f5f5"; Behavior on x { NumberAnimation { duration: 100 } } }
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: colorful.partyDiagnosticsEnabled = !colorful.partyDiagnosticsEnabled }
                        }
                    }
                    Rectangle {
                        id: travelSnapshotCard
                        Layout.fillWidth: true
                        Layout.preferredHeight: travelSnapshotColumn.implicitHeight + 28
                        implicitHeight: travelSnapshotColumn.implicitHeight + 28
                        color: Qt.rgba(1, 1, 1, 0.018); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.07)
                        Column {
                            id: travelSnapshotColumn
                            anchors.fill: parent; anchors.margins: 14; spacing: 8
                            Text { text: "Travel snapshot"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(13 * colorful.textScale) }
                            Text {
                                width: parent.width
                                text: "Move your library, playlists, queue, playback position, and selected playback settings between devices. Downloads and accounts stay on this device."
                                color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: Math.round(11 * colorful.textScale); wrapMode: Text.WordWrap
                            }
                            RowLayout {
                                width: parent.width; spacing: 8
                                ColorButton {
                                    text: "Export JSON"
                                    quiet: true
                                    enabled: !colorful.busy
                                    onClicked: travelExportDialog.open()
                                }
                                ColorButton {
                                    text: "Import JSON"
                                    enabled: !colorful.busy
                                    onClicked: travelImportDialog.open()
                                }
                            }
                            Text {
                                width: parent.width
                                text: "Import replaces portable state after confirmation."
                                color: Qt.rgba(1, 1, 1, 0.3); font.pixelSize: Math.round(10 * colorful.textScale); wrapMode: Text.WordWrap
                            }
                        }
                    }
                }
            }

            Flickable {
                clip: true; contentWidth: width; contentHeight: aboutBody.implicitHeight + 30
                ColumnLayout {
                    id: aboutBody
                    width: Math.min(parent.width, 820); spacing: 14
                    Image { source: "qrc:/assets/branding/colorful.svg"; Layout.preferredWidth: 70; Layout.preferredHeight: 70; fillMode: Image.PreserveAspectFit; smooth: true; mipmap: true }
                    Text { text: "colorful"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(26 * colorful.textScale) }
                    Text { text: "A local-first personal music client."; color: Qt.rgba(1, 1, 1, 0.48); font.pixelSize: Math.round(13 * colorful.textScale) }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        ColorButton {
                            text: "Run setup again"
                            quiet: true
                            onClicked: colorful.onboardingCompleted = false
                        }
                        ColorButton {
                            text: updater.state === "checking" ? "Checking…" : "Check for updates"
                            quiet: true
                            enabled: updater.state !== "checking" && updater.state !== "downloading"
                            onClicked: updater.checkForUpdates(true)
                        }
                        Text {
                            Layout.fillWidth: true
                            text: updater.status
                            color: updater.state === "error" ? "#ff8585" : Qt.rgba(1, 1, 1, 0.42)
                            font.pixelSize: Math.round(11 * colorful.textScale)
                            elide: Text.ElideRight
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: updatesColumn.implicitHeight + 30
                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                        ColumnLayout {
                            id: updatesColumn
                            anchors.fill: parent; anchors.margins: 15; spacing: 8
                            Text { text: "Updates"; color: "#f5f5f5"; font.bold: true; font.pixelSize: Math.round(14 * colorful.textScale) }
                            Text {
                                Layout.fillWidth: true
                                text: updater.channel === "preview" ? "Preview follows development releases and may change more often." : "Stable receives tagged releases intended for everyday use."
                                color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: Math.round(11 * colorful.textScale); wrapMode: Text.WordWrap
                            }
                            Row {
                                Layout.fillWidth: true; spacing: 0
                                Rectangle {
                                    width: stableChannelText.implicitWidth + 28; height: 36
                                    color: updater.channel === "stable" ? Qt.rgba(1, 1, 1, 0.075) : stableChannelHover.hovered ? Qt.rgba(1, 1, 1, 0.04) : "transparent"
                                    border.width: 1; border.color: updater.channel === "stable" ? colorful.accent : Qt.rgba(1, 1, 1, 0.12)
                                    Text { id: stableChannelText; anchors.centerIn: parent; text: "Stable"; color: "#f5f5f5"; font.bold: updater.channel === "stable"; font.pixelSize: Math.round(11 * colorful.textScale) }
                                    HoverHandler { id: stableChannelHover; cursorShape: Qt.PointingHandCursor }
                                    TapHandler { onTapped: if (updater.channel !== "stable") updater.channel = "stable" }
                                }
                                Rectangle {
                                    width: previewChannelText.implicitWidth + 28; height: 36
                                    color: updater.channel === "preview" ? Qt.rgba(1, 1, 1, 0.075) : previewChannelHover.hovered ? Qt.rgba(1, 1, 1, 0.04) : "transparent"
                                    border.width: 1; border.color: updater.channel === "preview" ? colorful.accent : Qt.rgba(1, 1, 1, 0.12)
                                    Text { id: previewChannelText; anchors.centerIn: parent; text: "Preview"; color: "#f5f5f5"; font.bold: updater.channel === "preview"; font.pixelSize: Math.round(11 * colorful.textScale) }
                                    HoverHandler { id: previewChannelHover; cursorShape: Qt.PointingHandCursor }
                                    TapHandler { onTapped: if (updater.channel !== "preview") updater.channel = "preview" }
                                }
                            }
                            Text {
                                visible: updater.channel === "preview"
                                Layout.fillWidth: true
                                text: "Preview builds can include unfinished changes. Switch back to Stable at any time; returning may install an older version."
                                color: Qt.rgba(1, 0.72, 0.38, 0.82); font.pixelSize: Math.round(10 * colorful.textScale); wrapMode: Text.WordWrap
                            }
                            Text {
                                visible: Boolean((updater.release || {}).downgrade)
                                Layout.fillWidth: true
                                text: "A Stable release is available to return from this Preview build."
                                color: Qt.rgba(1, 1, 1, 0.5); font.pixelSize: Math.round(10 * colorful.textScale); wrapMode: Text.WordWrap
                            }
                        }
                    }
                    AccountCard {
                        Layout.fillWidth: true
                        title: "Build identity"
                        rows: [
                            ["Semantic version", aboutBuild.semanticVersion || "unknown"],
                            ["Display version", aboutBuild.version || "unknown"],
                            ["Git tag / state", aboutBuild.tag || "Not on a tagged commit"],
                            ["Channel", aboutBuild.channel || "unknown"],
                            ["Build number", aboutBuild.buildNumber || "Not set"],
                            ["Commit (short)", aboutBuild.commitShort || aboutBuild.commit || "unknown"],
                            ["Commit (full)", aboutBuild.commitFull || "unknown"],
                            ["Built (UTC)", aboutBuild.buildDate || "unknown"]
                        ]
                    }
                    AccountCard {
                        Layout.fillWidth: true
                        title: "Environment"
                        rows: [
                            ["Platform", aboutBuild.platform || "unknown"],
                            ["Operating system", aboutBuild.system || "unknown"],
                            ["Architecture", aboutBuild.architecture || "unknown"],
                            ["Compiler", aboutBuild.compiler || "unknown"]
                        ]
                    }
                    AccountCard {
                        Layout.fillWidth: true
                        title: "Runtime"
                        rows: [
                            ["Qt / UI", "Qt " + (aboutBuild.qt || "unknown") + " / Qt Quick"],
                            ["Playback", aboutBuild.mpv ? "libmpv " + aboutBuild.mpv : "libmpv (not reported)"]
                        ]
                    }
                    AccountCard {
                        Layout.fillWidth: true
                        title: "Licenses"
                        rows: [
                            ["colorful", aboutBuild.license || "GPL-3.0-or-later"],
                            ["Qt", "LGPL-3.0 / GPL-3.0"]
                        ]
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        ColorButton {
                            text: "Repository"
                            quiet: true
                            visible: Boolean(aboutBuild.repository)
                            onClicked: Qt.openUrlExternally(aboutBuild.repository)
                        }
                        ColorButton {
                            text: "Releases"
                            quiet: true
                            visible: Boolean(aboutBuild.releases)
                            onClicked: Qt.openUrlExternally(aboutBuild.releases)
                        }
                        ColorButton {
                            text: "Issues"
                            quiet: true
                            visible: Boolean(aboutBuild.issues)
                            onClicked: Qt.openUrlExternally(aboutBuild.issues)
                        }
                        ColorButton {
                            text: "License"
                            quiet: true
                            visible: Boolean(aboutBuild.licenseUrl)
                            onClicked: Qt.openUrlExternally(aboutBuild.licenseUrl)
                        }
                        ColorButton {
                            text: "Third-party notices"
                            quiet: true
                            visible: Boolean(aboutBuild.noticesUrl)
                            onClicked: Qt.openUrlExternally(aboutBuild.noticesUrl)
                        }
                    }
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

    FileDialog {
        id: travelExportDialog
        title: "Export a colorful travel snapshot"
        fileMode: FileDialog.SaveFile
        nameFilters: ["Colorful travel snapshots (*.json)", "All files (*)"]
        onAccepted: colorful.exportTravelSnapshot(selectedFile)
    }

    FolderDialog {
        id: downloadFolderDialog
        title: "Choose the download folder"
        currentFolder: colorful.downloadDirectoryUrl
        onAccepted: colorful.setDownloadDirectory(selectedFolder)
    }

    FileDialog {
        id: travelImportDialog
        title: "Choose a colorful travel snapshot"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Colorful travel snapshots (*.json)", "All files (*)"]
        onAccepted: {
            root.pendingTravelImportFile = selectedFile
            travelImportConfirm.open()
        }
    }

    Dialog {
        id: travelImportConfirm
        anchors.centerIn: Overlay.overlay
        modal: true
        title: "Replace portable state?"
        standardButtons: Dialog.Cancel | Dialog.Ok
        onAccepted: {
            colorful.importTravelSnapshot(root.pendingTravelImportFile)
            root.pendingTravelImportFile = ""
        }
        onRejected: root.pendingTravelImportFile = ""
        contentItem: ColumnLayout {
            implicitWidth: 420
            Text {
                Layout.fillWidth: true
                text: "This replaces the current library, playlists, queue, playback position, and portable playback settings. Downloads, provider accounts, history, and other device-local data stay here."
                color: Qt.rgba(1, 1, 1, 0.65)
                font.pixelSize: Math.round(12 * colorful.textScale)
                wrapMode: Text.WordWrap
            }
        }
    }
}
