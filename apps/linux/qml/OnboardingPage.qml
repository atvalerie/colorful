import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

FocusScope {
    id: root
    signal openAccountsRequested()
    property int step: 0
    readonly property int stepCount: 4
    readonly property var steps: [
        ["Welcome", "How colorful works"],
        ["Accounts", "Connect providers"],
        ["Playback", "Quality and behavior"],
        ["Storage", "Offline music"]
    ]

    function finish() { colorful.onboardingCompleted = true }

    component SettingToggle: Rectangle {
        id: toggle
        required property bool checked
        signal toggled()
        implicitWidth: 42
        implicitHeight: 22
        color: checked ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
        border.width: 1
        border.color: checked ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.18)
        Rectangle {
            width: 16; height: 16; y: 3
            x: toggle.checked ? parent.width - width - 3 : 3
            color: toggle.checked && (0.2126 * colorful.accent.r + 0.7152 * colorful.accent.g + 0.0722 * colorful.accent.b) > 0.56 ? "#111114" : "#f5f5f5"
            Behavior on x { NumberAnimation { duration: 100 } }
        }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: toggle.toggled() }
    }

    component SettingChoice: Rectangle {
        id: choice
        required property string label
        property string detail: ""
        property bool selected: false
        signal chosen()
        implicitHeight: 58
        color: selected ? Qt.rgba(1, 1, 1, 0.075)
                        : choiceHover.hovered ? Qt.rgba(1, 1, 1, 0.04) : "transparent"
        border.width: 1
        border.color: selected ? colorful.accent : Qt.rgba(1, 1, 1, 0.12)
        Column {
            anchors.centerIn: parent
            spacing: 2
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: choice.label; color: "#f5f5f5"; font.bold: true; font.pixelSize: 12 }
            Text { visible: choice.detail.length > 0; anchors.horizontalCenter: parent.horizontalCenter; text: choice.detail; color: Qt.rgba(1, 1, 1, 0.36); font.pixelSize: 9 }
        }
        HoverHandler { id: choiceHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: choice.chosen() }
    }

    anchors.fill: parent
    focus: visible

    Rectangle { anchors.fill: parent; color: "#101012" }
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 64
            color: "#151518"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.075)
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                spacing: 10
                Image { source: "qrc:/assets/branding/colorful.svg"; Layout.preferredWidth: 26; Layout.preferredHeight: 26; fillMode: Image.PreserveAspectFit }
                Text { text: "colorful"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                Text { text: "First-time setup"; color: Qt.rgba(1, 1, 1, 0.38); font.pixelSize: 11; Layout.leftMargin: 4 }
                Item { Layout.fillWidth: true }
                Text { text: "Step " + (root.step + 1) + " of " + root.stepCount; color: Qt.rgba(1, 1, 1, 0.38); font.pixelSize: 10 }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
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
                        text: "Setup"
                        color: "#f5f5f5"
                        font.bold: true
                        font.pixelSize: 22
                        Layout.leftMargin: 8
                        Layout.topMargin: 5
                        Layout.bottomMargin: 12
                    }
                    Repeater {
                        model: root.steps
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            Layout.preferredHeight: 50
                            color: root.step === index ? Qt.rgba(1, 1, 1, 0.075)
                                                       : stepHover.hovered ? Qt.rgba(1, 1, 1, 0.038) : "transparent"
                            border.width: root.step === index ? 1 : 0
                            border.color: root.step === index ? colorful.accent : "transparent"
                            Column {
                                anchors.left: parent.left; anchors.leftMargin: 11
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 22; spacing: 2
                                Text { text: modelData[0]; color: root.step === index ? "#f5f5f5" : Qt.rgba(1, 1, 1, 0.66); font.bold: root.step === index; font.pixelSize: 12 }
                                Text { width: parent.width; text: modelData[1]; color: Qt.rgba(1, 1, 1, 0.32); font.pixelSize: 9; elide: Text.ElideRight }
                            }
                            HoverHandler { id: stepHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: root.step = index }
                        }
                    }
                    Item { Layout.fillHeight: true }
                    Text {
                        Layout.fillWidth: true
                        Layout.margins: 8
                        text: "You can run this setup again from Settings → About."
                        color: Qt.rgba(1, 1, 1, 0.28)
                        font.pixelSize: 9
                        wrapMode: Text.WordWrap
                    }
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.rightMargin: 24

                ColumnLayout {
                    anchors.fill: parent
                    anchors.topMargin: 24
                    anchors.bottomMargin: 18
                    spacing: 14

                    StackLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        currentIndex: root.step

                        Item {
                            ColumnLayout {
                                width: Math.min(parent.width, 820)
                                spacing: 14
                                Text { text: "Welcome to colorful"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 24 }
                                Text { Layout.fillWidth: true; text: "A local-first personal music client for TIDAL, YouTube Music, and SoundCloud."; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 12; wrapMode: Text.WordWrap }
                                Rectangle {
                                    Layout.fillWidth: true; Layout.preferredHeight: 76
                                    color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                                    Column { anchors.fill: parent; anchors.margins: 15; spacing: 4
                                        Text { text: "Your data stays local"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 13 }
                                        Text { width: parent.width; text: "Your library database, listening history, and downloads live on this device."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; wrapMode: Text.WordWrap }
                                    }
                                }
                                Rectangle {
                                    Layout.fillWidth: true; Layout.preferredHeight: 76
                                    color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                                    Column { anchors.fill: parent; anchors.margins: 15; spacing: 4
                                        Text { text: "Connections are optional"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 13 }
                                        Text { width: parent.width; text: "Use one provider or all three. Public YouTube Music and SoundCloud content works without signing in."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; wrapMode: Text.WordWrap }
                                    }
                                }
                                Rectangle {
                                    Layout.fillWidth: true; Layout.preferredHeight: 76
                                    color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                                    Column { anchors.fill: parent; anchors.margins: 15; spacing: 4
                                        Text { text: "Change anything later"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 13 }
                                        Text { width: parent.width; text: "Every option in this guide is also available in Settings."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; wrapMode: Text.WordWrap }
                                    }
                                }
                            }
                        }

                        Item {
                            Flickable {
                                anchors.fill: parent
                                clip: true; contentWidth: width; contentHeight: accountBody.implicitHeight + 20
                                boundsBehavior: Flickable.StopAtBounds
                                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                                ColumnLayout {
                                    id: accountBody
                                    width: Math.min(parent.width, 820); spacing: 14
                                    Text { text: "Accounts"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 24 }
                                    Text { Layout.fillWidth: true; text: "Connect the services you use. Credentials are stored using the system credential store."; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 12; wrapMode: Text.WordWrap }
                                    Repeater {
                                        model: [
                                            { name: "TIDAL", detail: "Library, recommendations, and lossless playback", linked: colorful.linked, action: "tidal" },
                                            { name: "YouTube Music", detail: "Account-only and age-gated tracks", linked: colorful.youtubeLinked, action: "youtube" },
                                            { name: "SoundCloud", detail: "Personalized library and recommendations", linked: colorful.soundcloudLinked, action: "soundcloud" }
                                        ]
                                        delegate: Rectangle {
                                            required property var modelData
                                            Layout.fillWidth: true; Layout.preferredHeight: 76
                                            color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                                            RowLayout {
                                                anchors.fill: parent; anchors.margins: 15; spacing: 12
                                                ColumnLayout { Layout.fillWidth: true; spacing: 3
                                                    Text { text: modelData.name; color: "#f5f5f5"; font.bold: true; font.pixelSize: 13 }
                                                    Text { Layout.fillWidth: true; text: modelData.detail; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; elide: Text.ElideRight }
                                                }
                                                Text { text: modelData.linked ? "Connected" : "Not connected"; color: modelData.linked ? colorful.accent : Qt.rgba(1, 1, 1, 0.34); font.pixelSize: 10 }
                                                ColorButton {
                                                    text: modelData.linked ? "Done" : (modelData.action === "tidal" ? "Connect" : "Setup guide")
                                                    quiet: true; enabled: !modelData.linked && (modelData.action !== "tidal" || colorful.providerReady)
                                                    onClicked: {
                                                        if (modelData.action === "tidal") colorful.startLogin()
                                                        else if (modelData.action === "youtube") colorful.openYouTubeSetupGuide()
                                                        else colorful.openSoundCloudSetupGuide()
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    ColorButton { text: "Open detailed account settings"; quiet: true; onClicked: { root.finish(); root.openAccountsRequested() } }
                                }
                            }
                        }

                        Item {
                            Flickable {
                                anchors.fill: parent
                                clip: true; contentWidth: width; contentHeight: playbackBody.implicitHeight + 20
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
                                            anchors.left: parent.left; anchors.leftMargin: 15
                                            anchors.right: onboardingAutoplaySwitch.left; anchors.rightMargin: 18
                                            anchors.verticalCenter: parent.verticalCenter; spacing: 3
                                            Text { text: "Autoplay"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 13 }
                                            Text { width: parent.width; text: "Continue with related tracks when the queue ends."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; elide: Text.ElideRight }
                                        }
                                        SettingToggle {
                                            id: onboardingAutoplaySwitch
                                            anchors.right: parent.right; anchors.rightMargin: 15
                                            anchors.verticalCenter: parent.verticalCenter
                                            checked: colorful.autoplayEnabled
                                            onToggled: colorful.autoplayEnabled = !colorful.autoplayEnabled
                                        }
                                    }
                                    Text { text: "Stream quality"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 14; Layout.topMargin: 5 }
                                    Text { Layout.fillWidth: true; text: "The selected format is requested when the next track opens. Providers may fall back when a release has no matching format."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; wrapMode: Text.WordWrap }
                                    RowLayout { Layout.fillWidth: true; spacing: 0
                                        SettingChoice { Layout.preferredWidth: 150; label: "Best available"; detail: "Highest available"; selected: colorful.streamQuality === "best"; onChosen: colorful.streamQuality = "best" }
                                        SettingChoice { Layout.preferredWidth: 150; label: "Lossless"; detail: "FLAC → AAC"; selected: colorful.streamQuality === "lossless"; onChosen: colorful.streamQuality = "lossless" }
                                        SettingChoice { Layout.preferredWidth: 150; label: "High"; detail: "AAC"; selected: colorful.streamQuality === "high"; onChosen: colorful.streamQuality = "high" }
                                    }
                                    Text { text: "Audio processing"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 14; Layout.topMargin: 5 }
                                    Rectangle {
                                        Layout.fillWidth: true; Layout.preferredHeight: 76
                                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                                        Column {
                                            anchors.left: parent.left; anchors.leftMargin: 15
                                            anchors.right: onboardingNormalizationSwitch.left; anchors.rightMargin: 18
                                            anchors.verticalCenter: parent.verticalCenter; spacing: 3
                                            Text { text: "Volume normalization"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 13 }
                                            Text { width: parent.width; text: "Reduce loudness jumps between tracks using ReplayGain data."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; elide: Text.ElideRight }
                                        }
                                        SettingToggle {
                                            id: onboardingNormalizationSwitch
                                            anchors.right: parent.right; anchors.rightMargin: 15
                                            anchors.verticalCenter: parent.verticalCenter
                                            checked: colorful.normalizationEnabled
                                            onToggled: colorful.normalizationEnabled = !colorful.normalizationEnabled
                                        }
                                    }
                                    Rectangle {
                                        Layout.fillWidth: true; Layout.preferredHeight: 76
                                        color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                                        Column {
                                            anchors.left: parent.left; anchors.leftMargin: 15
                                            anchors.right: onboardingLowDataSwitch.left; anchors.rightMargin: 18
                                            anchors.verticalCenter: parent.verticalCenter; spacing: 3
                                            Text { text: "Low data mode"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 13 }
                                            Text { width: parent.width; text: "Use smaller artwork and reduce background traffic."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; elide: Text.ElideRight }
                                        }
                                        SettingToggle {
                                            id: onboardingLowDataSwitch
                                            anchors.right: parent.right; anchors.rightMargin: 15
                                            anchors.verticalCenter: parent.verticalCenter
                                            checked: colorful.lowDataMode
                                            onToggled: colorful.lowDataMode = !colorful.lowDataMode
                                        }
                                    }
                                }
                            }
                        }

                        Item {
                            ColumnLayout {
                                width: Math.min(parent.width, 820); spacing: 14
                                Text { text: "Storage"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 24 }
                                Text { Layout.fillWidth: true; text: "Choose how much space offline music may use. Catalog pages and artwork use a separate managed cache."; color: Qt.rgba(1, 1, 1, 0.45); font.pixelSize: 12; wrapMode: Text.WordWrap }
                                Text { text: "Offline download limit"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 14; Layout.topMargin: 5 }
                                GridLayout {
                                    Layout.fillWidth: true; columns: 2; columnSpacing: 0; rowSpacing: 0
                                    SettingChoice { Layout.fillWidth: true; label: "Unlimited"; selected: colorful.offlineStorageLimitBytes === 0; onChosen: colorful.offlineStorageLimitBytes = 0 }
                                    SettingChoice { Layout.fillWidth: true; label: "5 GB"; selected: colorful.offlineStorageLimitBytes === 5 * 1024 * 1024 * 1024; onChosen: colorful.offlineStorageLimitBytes = 5 * 1024 * 1024 * 1024 }
                                    SettingChoice { Layout.fillWidth: true; label: "10 GB"; selected: colorful.offlineStorageLimitBytes === 10 * 1024 * 1024 * 1024; onChosen: colorful.offlineStorageLimitBytes = 10 * 1024 * 1024 * 1024 }
                                    SettingChoice { Layout.fillWidth: true; label: "25 GB"; selected: colorful.offlineStorageLimitBytes === 25 * 1024 * 1024 * 1024; onChosen: colorful.offlineStorageLimitBytes = 25 * 1024 * 1024 * 1024 }
                                }
                                Rectangle {
                                    Layout.fillWidth: true; Layout.preferredHeight: 76; Layout.topMargin: 5
                                    color: Qt.rgba(1, 1, 1, 0.028); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.1)
                                    Column { anchors.fill: parent; anchors.margins: 15; spacing: 4
                                        Text { text: "Navigation shortcuts"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 13 }
                                        Text { width: parent.width; text: "Mouse Back/Forward and Alt+Left/Right move between pages. Playback shortcuts pause while typing."; color: Qt.rgba(1, 1, 1, 0.4); font.pixelSize: 11; wrapMode: Text.WordWrap }
                                    }
                                }
                            }
                        }
                    }

                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Qt.rgba(1, 1, 1, 0.075) }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        ColorButton { text: "Skip setup"; quiet: true; visible: root.step < root.stepCount - 1; onClicked: root.finish() }
                        Item { Layout.fillWidth: true }
                        ColorButton { text: "Back"; quiet: true; enabled: root.step > 0; onClicked: --root.step }
                        ColorButton {
                            text: root.step === root.stepCount - 1 ? "Start listening" : "Continue"
                            onClicked: root.step === root.stepCount - 1 ? root.finish() : ++root.step
                        }
                    }
                }
            }
        }
    }
}
