import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects

ApplicationWindow {
    id: window
    width: 1220
    height: 780
    minimumWidth: 920
    minimumHeight: 620
    visible: true
    title: "Colorful"
    color: "#100e14"

    readonly property color ink: "#fffafd"
    readonly property color mutedInk: Qt.rgba(1, 1, 1, 0.58)
    readonly property var now: colorful.currentTrack

    FontLoader {
        id: nunitoFont
        source: "qrc:/assets/fonts/Nunito.ttf"
    }

    function formatTime(milliseconds) {
        if (!milliseconds || milliseconds < 0) return "0:00"
        const seconds = Math.floor(milliseconds / 1000)
        return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0")
    }

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(colorful.accent.r * 0.24, colorful.accent.g * 0.24, colorful.accent.b * 0.24, 1) }
            GradientStop { position: 0.44; color: "#15111a" }
            GradientStop { position: 1.0; color: "#0d0c10" }
        }
    }

    Rectangle {
        width: Math.max(window.width * 0.48, 440)
        height: width
        radius: width / 2
        x: -width * 0.3
        y: -height * 0.55
        color: colorful.accent
        opacity: 0.13
        Behavior on color { ColorAnimation { duration: 650 } }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Rectangle {
                Layout.preferredWidth: 224
                Layout.fillHeight: true
                color: Qt.rgba(0.035, 0.03, 0.045, 0.72)
                border.color: Qt.rgba(1, 1, 1, 0.06)

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 22
                    spacing: 14

                    RowLayout {
                        spacing: 10
                        Rectangle {
                            width: 38; height: 38; radius: 12
                            color: colorful.accent
                            Text {
                                anchors.centerIn: parent
                                text: "C"
                                color: "white"
                                font.family: "Nunito"
                                font.bold: true
                                font.pixelSize: 22
                            }
                            Behavior on color { ColorAnimation { duration: 500 } }
                        }
                        Text {
                            text: "colorful"
                            color: window.ink
                            font.family: "Nunito"
                            font.weight: Font.Bold
                            font.pixelSize: 23
                        }
                    }

                    Text {
                        Layout.topMargin: 14
                        text: "YOUR MUSIC"
                        color: Qt.rgba(1, 1, 1, 0.34)
                        font.family: "Nunito"
                        font.weight: Font.Bold
                        font.pixelSize: 10
                        font.letterSpacing: 1.5
                    }

                    ColorButton {
                        Layout.fillWidth: true
                        text: "Discover"
                        quiet: true
                    }
                    ColorButton {
                        Layout.fillWidth: true
                        text: "Downloads"
                        quiet: true
                        enabled: false
                        ToolTip.visible: hovered
                        ToolTip.text: "Coming in the offline milestone"
                    }

                    Item { Layout.fillHeight: true }

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: accountColumn.implicitHeight + 28
                        radius: 17
                        color: Qt.rgba(1, 1, 1, 0.055)
                        border.color: Qt.rgba(1, 1, 1, 0.08)
                        ColumnLayout {
                            id: accountColumn
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.margins: 14
                            spacing: 7
                            Text {
                                text: colorful.linked ? "TIDAL connected" : "Connect TIDAL"
                                color: window.ink
                                font.family: "Nunito"
                                font.weight: Font.DemiBold
                                font.pixelSize: 13
                            }
                            Text {
                                Layout.fillWidth: true
                                text: colorful.linked ? "Your subscription powers playback" : "Link without sharing your password"
                                wrapMode: Text.WordWrap
                                color: window.mutedInk
                                font.family: "Nunito"
                                font.pixelSize: 11
                            }
                            ColorButton {
                                Layout.fillWidth: true
                                Layout.topMargin: 4
                                text: colorful.linked ? "Disconnect" : "Connect"
                                quiet: colorful.linked
                                onClicked: colorful.linked ? colorful.unlink() : colorful.startLogin()
                            }
                        }
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 30
                Layout.rightMargin: 24
                Layout.topMargin: 24
                Layout.bottomMargin: 18
                spacing: 16

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 48
                        radius: 24
                        color: Qt.rgba(1, 1, 1, 0.085)
                        border.color: searchField.activeFocus ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
                        border.width: searchField.activeFocus ? 2 : 1
                        Behavior on border.color { ColorAnimation { duration: 150 } }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 17
                            anchors.rightMargin: 8
                            Text { text: "⌕"; color: window.mutedInk; font.pixelSize: 21 }
                            TextField {
                                id: searchField
                                Layout.fillWidth: true
                                placeholderText: "Search tracks on TIDAL"
                                placeholderTextColor: Qt.rgba(1, 1, 1, 0.38)
                                color: window.ink
                                font.family: "Nunito"
                                font.pixelSize: 15
                                background: Item {}
                                selectByMouse: true
                                onAccepted: colorful.search(text)
                            }
                            ColorButton {
                                text: "Search"
                                implicitHeight: 36
                                enabled: colorful.providerReady && searchField.text.trim().length > 0 && !colorful.busy
                                onClicked: colorful.search(searchField.text)
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "Tracks"
                        color: window.ink
                        font.family: "Nunito"
                        font.weight: Font.Bold
                        font.pixelSize: 26
                    }
                    Item { Layout.fillWidth: true }
                    BusyIndicator {
                        running: colorful.busy
                        visible: running
                        implicitWidth: 28
                        implicitHeight: 28
                    }
                }

                ListView {
                    id: resultsList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: colorful.searchResults
                    spacing: 2
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar {}
                    delegate: TrackDelegate {
                        required property var modelData
                        track: modelData
                        onPlayRequested: colorful.playSearchResult(index)
                        onAddRequested: colorful.enqueueSearchResult(index)
                    }

                    Text {
                        anchors.centerIn: parent
                        width: Math.min(360, parent.width - 40)
                        visible: resultsList.count === 0
                        text: colorful.linked
                              ? "Search for a track, then double-click to play or + to build a queue."
                              : "Connect TIDAL for playback. You can already try catalog search."
                        color: Qt.rgba(1, 1, 1, 0.42)
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        font.family: "Nunito"
                        font.pixelSize: 15
                    }
                }
            }

            Rectangle {
                Layout.preferredWidth: Math.max(280, Math.min(340, window.width * 0.27))
                Layout.fillHeight: true
                color: Qt.rgba(0.025, 0.022, 0.032, 0.68)
                border.color: Qt.rgba(1, 1, 1, 0.06)

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 20
                    spacing: 12
                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: "Up next"
                            color: window.ink
                            font.family: "Nunito"
                            font.weight: Font.Bold
                            font.pixelSize: 20
                        }
                        Item { Layout.fillWidth: true }
                        Rectangle {
                            width: 28; height: 24; radius: 12
                            color: Qt.rgba(1, 1, 1, 0.08)
                            Text {
                                anchors.centerIn: parent
                                text: colorful.queue.length
                                color: window.mutedInk
                                font.family: "Nunito"
                                font.pixelSize: 11
                            }
                        }
                    }
                    ListView {
                        id: queueList
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        model: colorful.queue
                        spacing: 2
                        clip: true
                        ScrollBar.vertical: ScrollBar {}
                        delegate: TrackDelegate {
                            required property var modelData
                            track: modelData
                            queueMode: true
                            active: index === colorful.currentQueueIndex
                            onPlayRequested: {
                                colorful.playQueueIndex(index)
                            }
                            onRemoveRequested: colorful.removeQueueIndex(index)
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: queueList.count === 0
                            text: "Your queue is feeling\na little lonely"
                            color: Qt.rgba(1, 1, 1, 0.36)
                            horizontalAlignment: Text.AlignHCenter
                            font.family: "Nunito"
                            font.pixelSize: 14
                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 108
            color: Qt.rgba(0.035, 0.03, 0.045, 0.96)
            border.color: Qt.rgba(1, 1, 1, 0.08)

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 22
                anchors.rightMargin: 24
                spacing: 18

                Rectangle {
                    Layout.preferredWidth: 68
                    Layout.preferredHeight: 68
                    radius: 15
                    color: Qt.rgba(1, 1, 1, 0.08)
                    clip: true
                    Image {
                        anchors.fill: parent
                        source: window.now.coverUrl || ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: !window.now.coverUrl
                        text: "♪"
                        color: window.mutedInk
                        font.pixelSize: 25
                    }
                }

                ColumnLayout {
                    Layout.preferredWidth: 210
                    spacing: 2
                    Text {
                        Layout.fillWidth: true
                        text: window.now.title || "Nothing playing"
                        color: window.ink
                        elide: Text.ElideRight
                        font.family: "Nunito"
                        font.weight: Font.Bold
                        font.pixelSize: 15
                    }
                    Text {
                        Layout.fillWidth: true
                        text: window.now.artistText || "Pick something colorful"
                        color: window.mutedInk
                        elide: Text.ElideRight
                        font.family: "Nunito"
                        font.pixelSize: 12
                    }
                }

                RowLayout {
                    spacing: 5
                    ColorButton { text: "‹"; quiet: true; implicitWidth: 42; onClicked: colorful.previous() }
                    ColorButton {
                        text: colorful.playing ? "Ⅱ" : "▶"
                        implicitWidth: 48
                        implicitHeight: 48
                        enabled: Object.keys(window.now).length > 0
                        onClicked: colorful.togglePlay()
                    }
                    ColorButton { text: "›"; quiet: true; implicitWidth: 42; onClicked: colorful.next() }
                }

                Text {
                    text: window.formatTime(colorful.position)
                    color: window.mutedInk
                    font.family: "Nunito"
                    font.pixelSize: 11
                }
                Slider {
                    id: progress
                    Layout.fillWidth: true
                    from: 0
                    to: Math.max(1, colorful.duration)
                    onMoved: colorful.seek(value)
                    Binding on value {
                        value: colorful.position
                        when: !progress.pressed
                        restoreMode: Binding.RestoreBindingOrValue
                    }
                    background: Rectangle {
                        x: progress.leftPadding
                        y: progress.topPadding + progress.availableHeight / 2 - height / 2
                        width: progress.availableWidth
                        height: 4
                        radius: 2
                        color: Qt.rgba(1, 1, 1, 0.15)
                        Rectangle {
                            width: progress.visualPosition * parent.width
                            height: parent.height
                            radius: 2
                            color: colorful.accent
                        }
                    }
                    handle: Rectangle {
                        x: progress.leftPadding + progress.visualPosition * (progress.availableWidth - width)
                        y: progress.topPadding + progress.availableHeight / 2 - height / 2
                        implicitWidth: 14; implicitHeight: 14; radius: 7
                        color: "white"
                    }
                }
                Text {
                    text: window.formatTime(colorful.duration)
                    color: window.mutedInk
                    font.family: "Nunito"
                    font.pixelSize: 11
                }

                Text { text: "⌁"; color: window.mutedInk; font.pixelSize: 18 }
                Slider {
                    Layout.preferredWidth: 88
                    from: 0
                    to: 1
                    value: colorful.volume
                    onMoved: colorful.setVolume(value)
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 28
            color: Qt.rgba(0.02, 0.018, 0.025, 0.98)
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                spacing: 7
                Rectangle {
                    width: 7; height: 7; radius: 4
                    color: colorful.providerReady ? (colorful.linked ? "#62e6a7" : "#ffc45f") : "#ff6685"
                }
                Text {
                    Layout.fillWidth: true
                    text: colorful.statusMessage
                    color: Qt.rgba(1, 1, 1, 0.46)
                    elide: Text.ElideRight
                    font.family: "Nunito"
                    font.pixelSize: 10
                }
                Text {
                    text: "MPRIS • local-first"
                    color: Qt.rgba(1, 1, 1, 0.28)
                    font.family: "Nunito"
                    font.pixelSize: 10
                }
            }
        }
    }

    Popup {
        id: authPopup
        anchors.centerIn: Overlay.overlay
        width: 430
        height: 360
        modal: true
        closePolicy: Popup.NoAutoClose
        visible: colorful.authPending
        padding: 0
        background: Rectangle {
            radius: 24
            color: "#211b27"
            border.color: Qt.rgba(colorful.accent.r, colorful.accent.g, colorful.accent.b, 0.6)
            border.width: 1
        }
        contentItem: ColumnLayout {
            anchors.fill: parent
            anchors.margins: 30
            spacing: 14
            Text {
                text: "Connect your TIDAL"
                color: window.ink
                font.family: "Nunito"
                font.weight: Font.Bold
                font.pixelSize: 25
            }
            Text {
                Layout.fillWidth: true
                text: "Open TIDAL, approve Colorful, and come back here. Your password never touches this app."
                color: window.mutedInk
                wrapMode: Text.WordWrap
                font.family: "Nunito"
                font.pixelSize: 14
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 92
                Layout.topMargin: 6
                radius: 18
                color: Qt.rgba(1, 1, 1, 0.07)
                Column {
                    anchors.centerIn: parent
                    spacing: 3
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "YOUR CODE"
                        color: Qt.rgba(1, 1, 1, 0.38)
                        font.family: "Nunito"
                        font.bold: true
                        font.pixelSize: 10
                        font.letterSpacing: 1.5
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: colorful.userCode
                        color: window.ink
                        font.family: "monospace"
                        font.bold: true
                        font.pixelSize: 31
                        font.letterSpacing: 3
                    }
                }
            }
            ColorButton {
                Layout.fillWidth: true
                text: "Open TIDAL to approve"
                onClicked: colorful.openVerificationUrl()
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: "Waiting for approval…"
                color: window.mutedInk
                font.family: "Nunito"
                font.pixelSize: 12
            }
            Item { Layout.fillHeight: true }
        }
    }
}
