import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    required property var lyrics
    required property bool loading
    required property string errorText
    required property int playbackPosition
    property int offsetMs: 0
    signal closeRequested()
    signal refreshRequested()

    readonly property var lines: lyrics.lines || []
    readonly property bool synced: Boolean(lyrics.synced)
    readonly property int activeIndex: {
        if (!synced || lines.length === 0) return -1
        const clock = playbackPosition + offsetMs
        let selected = -1
        for (let index = 0; index < lines.length; ++index) {
            if ((lines[index].startMs || 0) > clock) break
            selected = index
        }
        return selected
    }

    color: Qt.rgba(0.032, 0.032, 0.038, 0.96)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.09)

    onActiveIndexChanged: {
        if (synced && lyricsList.visible && activeIndex >= 0)
            lyricsList.positionViewAtIndex(activeIndex, ListView.Center)
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            spacing: 7
            Text { text: "Lyrics"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 18 }
            Item { Layout.fillWidth: true }
            ColorButton {
                visible: root.synced
                text: root.offsetMs === 0 ? "Offset" : (root.offsetMs > 0 ? "+" : "") + root.offsetMs + " ms"
                quiet: true
                implicitHeight: 30
                implicitWidth: 82
                onClicked: root.offsetMs = 0
                ToolTip.visible: hovered
                ToolTip.text: "Reset lyric timing offset"
            }
            IconButton {
                implicitWidth: 32
                implicitHeight: 32
                iconSource: "icons/close.svg"
                tooltipText: "Close lyrics"
                onClicked: root.closeRequested()
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: Object.keys(root.lyrics).length > 0
            Text {
                Layout.fillWidth: true
                text: (root.lyrics.sourceLabel || "Lyrics") + (root.synced ? " · synced" : "")
                color: Qt.rgba(1, 1, 1, 0.42)
                font.pixelSize: 11
            }
            Row {
                visible: root.synced
                spacing: 3
                ColorButton { text: "−"; quiet: true; implicitWidth: 30; implicitHeight: 26; onClicked: root.offsetMs -= 250 }
                ColorButton { text: "+"; quiet: true; implicitWidth: 30; implicitHeight: 26; onClicked: root.offsetMs += 250 }
            }
        }

        ListView {
            id: lyricsList
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.loading && !root.errorText && root.lines.length > 0 && !root.lyrics.instrumental
            model: root.lines
            clip: true
            spacing: root.synced ? 10 : 4
            boundsBehavior: Flickable.StopAtBounds
            pixelAligned: true
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            delegate: Text {
                required property var modelData
                required property int index
                width: ListView.view.width - 8
                text: modelData.text || " "
                color: root.synced && index === root.activeIndex ? "#ffffff" : Qt.rgba(1, 1, 1, root.synced ? 0.42 : 0.78)
                font.pixelSize: root.synced ? (index === root.activeIndex ? 18 : 15) : 14
                font.weight: root.synced && index === root.activeIndex ? Font.DemiBold : Font.Normal
                wrapMode: Text.WordWrap
                lineHeight: 1.15
                Behavior on color { ColorAnimation { duration: 180 } }
            }
        }

        Column {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !lyricsList.visible
            spacing: 12
            Item { width: 1; height: Math.max(0, (parent.height - message.implicitHeight - retryButton.height) / 2 - 24) }
            BusyIndicator {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.loading
                running: visible
                implicitWidth: 30
                implicitHeight: 30
            }
            Text {
                id: message
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - 24
                text: root.loading ? "Finding lyrics…"
                    : root.lyrics.instrumental ? "This track is marked instrumental"
                    : root.errorText || "No lyrics loaded"
                color: Qt.rgba(1, 1, 1, 0.46)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                font.pixelSize: 13
            }
            ColorButton {
                id: retryButton
                anchors.horizontalCenter: parent.horizontalCenter
                visible: !root.loading
                text: "Try again"
                quiet: true
                onClicked: root.refreshRequested()
            }
        }
    }
}
