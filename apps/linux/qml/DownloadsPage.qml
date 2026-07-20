import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root

    function formatBytes(bytes) {
        if (!bytes || bytes <= 0) return "0 KB"
        if (bytes < 1024 * 1024) return Math.round(bytes / 1024) + " KB"
        if (bytes < 1024 * 1024 * 1024)
            return (bytes / (1024 * 1024)).toFixed(bytes < 10 * 1024 * 1024 ? 1 : 0) + " MB"
        return (bytes / (1024 * 1024 * 1024)).toFixed(1) + " GB"
    }

    function countState(state) {
        let count = 0
        for (let index = 0; index < colorful.downloads.length; ++index)
            if (colorful.downloads[index].downloadState === state) ++count
        return count
    }

    function storedBytes() {
        let total = 0
        for (let index = 0; index < colorful.downloads.length; ++index)
            total += colorful.downloads[index].bytesDownloaded || 0
        return total
    }

    function unfinishedCount() {
        return colorful.downloads.length - countState("complete")
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
            ColorButton {
                text: "Remove completed"
                quiet: true
                enabled: root.countState("complete") > 0
                onClicked: removeCompletedDialog.open()
            }
            ColorButton {
                text: "Remove unfinished"
                quiet: true
                enabled: root.unfinishedCount() > 0
                onClicked: removeUnfinishedDialog.open()
            }
        }

        Text {
            Layout.fillWidth: true
            text: "Completed files play directly from this device. Expiring TIDAL manifests are never stored."
            color: Qt.rgba(1, 1, 1, 0.42)
            font.pixelSize: 11
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 18
            Text { text: root.formatBytes(root.storedBytes()) + " stored"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 12 }
            Text { text: root.countState("complete") + " available"; color: Qt.rgba(1, 1, 1, 0.48); font.pixelSize: 11 }
            Text { text: root.countState("downloading") + root.countState("resolving") + root.countState("queued") > 0 ? (root.countState("downloading") + root.countState("resolving") + root.countState("queued")) + " active" : ""; visible: text.length > 0; color: colorful.accent; font.pixelSize: 11 }
            Text { text: root.countState("paused") > 0 ? root.countState("paused") + " paused" : ""; visible: text.length > 0; color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: 11 }
            Item { Layout.fillWidth: true }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: colorful.offlineStorageLimitBytes > 0 ? 5 : 0
            visible: colorful.offlineStorageLimitBytes > 0
            color: Qt.rgba(1, 1, 1, 0.1)
            Rectangle {
                width: parent.width * Math.min(1, colorful.offlineStorageUsed / colorful.offlineStorageLimitBytes)
                height: parent.height
                color: colorful.offlineStorageUsed >= colorful.offlineStorageLimitBytes ? "#ff7777" : colorful.accent
            }
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
                        AppIcon { anchors.centerIn: parent; width: 18; height: 18; iconSource: "icons/music.svg"; opacity: 0.3; visible: colorful.lowDataMode || !modelData.coverUrl }
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

    Dialog {
        id: removeCompletedDialog
        anchors.centerIn: parent
        modal: true
        title: "Remove completed downloads?"
        standardButtons: Dialog.Cancel | Dialog.Ok
        onAccepted: colorful.removeCompletedDownloads()
        contentItem: Text {
            text: "This deletes " + root.countState("complete") + " offline audio "
                  + (root.countState("complete") === 1 ? "file" : "files") + " from this device."
            color: Qt.rgba(1, 1, 1, 0.65)
            font.pixelSize: 12
            wrapMode: Text.WordWrap
        }
        background: Rectangle {
            color: "#121216"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.2)
        }
    }


    Dialog {
        id: removeUnfinishedDialog
        anchors.centerIn: parent
        modal: true
        title: "Remove unfinished downloads?"
        standardButtons: Dialog.Cancel | Dialog.Ok
        onAccepted: colorful.removeUnfinishedDownloads()
        contentItem: Text {
            text: "This removes " + root.unfinishedCount() + " queued, partial, paused, or failed "
                  + (root.unfinishedCount() === 1 ? "download" : "downloads") + "."
            color: Qt.rgba(1, 1, 1, 0.65)
            font.pixelSize: 12
            wrapMode: Text.WordWrap
        }
        background: Rectangle {
            color: "#121216"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.2)
        }
    }
}
