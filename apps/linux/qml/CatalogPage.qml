import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    required property var page
    property bool loading: false

    readonly property string kind: page.kind || ""
    readonly property var primary: kind === "track" ? (page.track || {})
                                           : kind === "album" ? (page.album || {})
                                                              : (page.artist || {})
    readonly property var tracks: kind === "track" ? (page.relatedTracks || [])
                                         : kind === "album" ? (page.tracks || [])
                                                            : (page.topTracks || [])

    function formatTime(milliseconds) {
        if (!milliseconds || milliseconds < 0) return ""
        const seconds = Math.floor(milliseconds / 1000)
        const minutes = Math.floor(seconds / 60)
        if (minutes < 60) return minutes + ":" + String(seconds % 60).padStart(2, "0")
        return Math.floor(minutes / 60) + " hr " + (minutes % 60) + " min"
    }

    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: body.implicitHeight + 40
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ColumnLayout {
            id: body
            width: parent.width
            spacing: 22

            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                IconButton {
                    iconSource: "icons/previous.svg"
                    tooltipText: colorful.canNavigateCatalogBack ? "Back" : "Back to results"
                    onClicked: colorful.canNavigateCatalogBack ? colorful.navigateCatalogBack() : colorful.closeCatalog()
                }
                Text {
                    text: root.kind === "track" ? "Track" : root.kind === "album" ? "Album" : "Artist"
                    color: Qt.rgba(1, 1, 1, 0.46)
                    font.pixelSize: 11
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: 1.2
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: "TIDAL"
                    color: Qt.rgba(1, 1, 1, 0.42)
                    font.bold: true
                    font.pixelSize: 10
                    font.letterSpacing: 1.4
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 24
                Rectangle {
                    Layout.preferredWidth: root.kind === "artist" ? 176 : 196
                    Layout.preferredHeight: width
                    color: Qt.rgba(1, 1, 1, 0.06)
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.12)
                    clip: true
                    Image {
                        anchors.fill: parent
                        source: root.kind === "artist" ? (root.primary.pictureUrl || "") : (root.primary.coverUrl || "")
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                    }
                    AppIcon {
                        anchors.centerIn: parent
                        width: 34
                        height: 34
                        iconSource: root.kind === "artist" ? "icons/user.svg" : "icons/music.svg"
                        opacity: 0.28
                        visible: root.kind === "artist" ? !root.primary.pictureUrl : !root.primary.coverUrl
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignBottom
                    spacing: 8
                    Text {
                        Layout.fillWidth: true
                        text: root.kind === "artist" ? (root.primary.name || "Unknown artist") : (root.primary.title || "Unknown title")
                        color: "#f5f5f5"
                        font.bold: true
                        font.pixelSize: 34
                        wrapMode: Text.Wrap
                    }
                    Row {
                        spacing: 4
                        visible: root.kind !== "artist" && (root.primary.artistCredits || []).length > 0
                        Repeater {
                            model: root.primary.artistCredits || []
                            delegate: Row {
                                required property var modelData
                                required property int index
                                spacing: 4
                                MetadataLink {
                                    text: modelData.name
                                    onActivated: colorful.openArtist(modelData.id)
                                }
                                Text {
                                    visible: index + 1 < (root.primary.artistCredits || []).length
                                    text: "·"
                                    color: Qt.rgba(1, 1, 1, 0.34)
                                    font.pixelSize: 13
                                }
                            }
                        }
                    }
                    Text {
                        visible: root.kind === "album"
                        text: [root.primary.albumType, root.primary.releaseDate ? root.primary.releaseDate.slice(0, 4) : "",
                               root.primary.numberOfTracks ? root.primary.numberOfTracks + " tracks" : "",
                               root.formatTime(root.primary.durationMs)].filter(Boolean).join("  ·  ")
                        color: Qt.rgba(1, 1, 1, 0.48)
                        font.pixelSize: 11
                    }
                    MetadataLink {
                        visible: root.kind === "track" && root.primary.albumId
                        text: root.primary.albumTitle || "Open album"
                        normalColor: Qt.rgba(1, 1, 1, 0.5)
                        font.pixelSize: 12
                        onActivated: colorful.openAlbum(root.primary.albumId)
                    }
                    RowLayout {
                        Layout.topMargin: 8
                        spacing: 8
                        ColorButton {
                            text: root.kind === "track" ? "Play track" : root.kind === "album" ? "Play album" : "Play top tracks"
                            onClicked: colorful.playCatalogCollection()
                        }
                        ColorButton {
                            visible: root.kind === "track"
                            text: "Add to queue"
                            quiet: true
                            onClicked: colorful.enqueueCatalogTrack(root.primary)
                        }
                        ColorButton {
                            visible: root.kind === "track"
                            text: "Save"
                            quiet: true
                            onClicked: colorful.saveCatalogTrack(root.primary)
                        }
                    }
                }
            }

            Text {
                visible: root.tracks.length > 0
                text: root.kind === "track" ? "Related tracks" : root.kind === "album" ? "Tracks" : "Popular tracks"
                color: "#f5f5f5"
                font.bold: true
                font.pixelSize: 18
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Repeater {
                    model: root.tracks
                    delegate: TrackDelegate {
                        required property var modelData
                        Layout.fillWidth: true
                        track: modelData
                        showSaveAction: true
                        onPlayRequested: colorful.playCatalogTrack(modelData)
                        onAddRequested: colorful.enqueueCatalogTrack(modelData)
                        onSaveRequested: colorful.saveCatalogTrack(modelData)
                        onDetailsRequested: colorful.openTrack(modelData.id)
                    }
                }
            }

            Text {
                visible: root.kind === "artist" && (root.page.albums || []).length > 0
                text: "Releases"
                color: "#f5f5f5"
                font.bold: true
                font.pixelSize: 18
            }
            Flow {
                Layout.fillWidth: true
                Layout.preferredHeight: childrenRect.height
                spacing: 10
                visible: root.kind === "artist"
                Repeater {
                    model: root.page.albums || []
                    delegate: CatalogCard {
                        required property var modelData
                        entry: modelData
                        onOpenRequested: colorful.openAlbum(modelData.id)
                    }
                }
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        visible: root.loading
        color: Qt.rgba(0.04, 0.04, 0.05, 0.78)
        BusyIndicator { anchors.centerIn: parent; running: parent.visible }
    }
}
