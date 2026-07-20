import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root

    function formatBytes(bytes) {
        if (!bytes || bytes <= 0) return ""
        if (bytes < 1024 * 1024) return Math.round(bytes / 1024) + " KB"
        return (bytes / (1024 * 1024)).toFixed(bytes < 10 * 1024 * 1024 ? 1 : 0) + " MB"
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: "Offline music"
                color: "#f5f5f5"
                font.bold: true
                font.pixelSize: 24
            }
            Item { Layout.fillWidth: true }
            ColorButton {
                text: "Open folder"
                quiet: true
                onClicked: colorful.openDownloadsFolder()
            }
        }

        Text {
            Layout.fillWidth: true
            text: "Completed files play directly from this device. Expiring TIDAL manifests are never stored."
            color: Qt.rgba(1, 1, 1, 0.42)
            font.pixelSize: 11
            wrapMode: Text.WordWrap
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: colorful.downloads
            clip: true
            pixelAligned: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Rectangle {
                required property var modelData
                width: ListView.view.width
                height: 62
                color: rowHover.hovered ? Qt.rgba(1, 1, 1, 0.04) : "transparent"
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.065)

                HoverHandler { id: rowHover }
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 7
                    spacing: 10
                    Rectangle {
                        Layout.preferredWidth: 46
                        Layout.preferredHeight: 46
                        color: Qt.rgba(1, 1, 1, 0.06)
                        clip: true
                        ArtworkImage { anchors.fill: parent; source: modelData.coverUrl || ""; decodeSize: 184 }
                        AppIcon { anchors.centerIn: parent; width: 18; height: 18; iconSource: "icons/music.svg"; opacity: 0.3; visible: !modelData.coverUrl }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text { Layout.fillWidth: true; text: modelData.title || "Unknown track"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 13; elide: Text.ElideRight }
                        Text { Layout.fillWidth: true; text: modelData.artistText || "Unknown artist"; color: Qt.rgba(1, 1, 1, 0.43); font.pixelSize: 11; elide: Text.ElideRight }
                    }
                    ColumnLayout {
                        Layout.preferredWidth: 125
                        spacing: 2
                        Text {
                            Layout.alignment: Qt.AlignRight
                            text: modelData.downloadState === "complete" ? "Available offline"
                                  : modelData.downloadState === "downloading" ? "Downloading"
                                  : modelData.downloadState === "resolving" ? "Preparing"
                                  : modelData.downloadState === "queued" ? "Queued"
                                  : modelData.downloadState === "paused" ? "Paused" : "Failed"
                            color: modelData.downloadState === "complete" ? "#55dca0"
                                   : modelData.downloadState === "failed" ? "#ff7777" : colorful.accent
                            font.bold: true
                            font.pixelSize: 10
                        }
                        Text {
                            Layout.alignment: Qt.AlignRight
                            text: root.formatBytes(modelData.bytesDownloaded)
                            color: Qt.rgba(1, 1, 1, 0.34)
                            font.pixelSize: 9
                        }
                    }
                    ColorButton {
                        text: modelData.downloadState === "complete" ? "Play"
                              : modelData.downloadState === "paused" ? "Resume"
                              : modelData.downloadState === "failed" ? "Retry" : "Pause"
                        quiet: modelData.downloadState !== "complete"
                        onClicked: {
                            if (modelData.downloadState === "complete") colorful.playCatalogTrack(modelData)
                            else if (modelData.downloadState === "paused" || modelData.downloadState === "failed") colorful.downloadTrack(modelData)
                            else colorful.pauseDownload(modelData.id, modelData.provider || "tidal")
                        }
                    }
                    IconButton {
                        iconSource: "icons/close.svg"
                        tooltipText: "Remove offline copy"
                        onClicked: colorful.removeDownload(modelData.id, modelData.provider || "tidal")
                    }
                }
            }

            Column {
                anchors.centerIn: parent
                width: Math.min(420, parent.width - 40)
                spacing: 10
                visible: list.count === 0
                AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 30; height: 30; iconSource: "icons/download.svg"; opacity: 0.28 }
                Text { width: parent.width; text: "Nothing downloaded yet"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter }
                Text { width: parent.width; text: "Use the download action on a track, album, or playlist. Completed music remains playable without a network connection."; color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: 12; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter }
            }
        }
    }
}
