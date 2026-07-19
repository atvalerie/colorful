import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    property int tab: 0
    signal integrationsRequested()

    function formatDate(value) {
        if (!value) return "Not reported"
        const date = new Date(value)
        return isNaN(date.getTime()) ? value : Qt.formatDateTime(date, "d MMM yyyy, HH:mm")
    }
    function remaining(value) {
        if (!value) return "Not reported"
        const milliseconds = new Date(value).getTime() - Date.now()
        if (!isFinite(milliseconds)) return "Not reported"
        if (milliseconds <= 0) return "Expired"
        const days = Math.floor(milliseconds / 86400000)
        const hours = Math.floor((milliseconds % 86400000) / 3600000)
        return days > 0 ? days + " days, " + hours + " hours" : hours + " hours"
    }
    function accountValue(key, fallback) {
        const account = colorful.tidalHub.account || {}
        const value = account[key]
        return value === undefined || value === null || value === "" ? fallback : value
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 16

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Text {
                text: "TIDAL"
                color: "#f5f5f5"
                font.bold: true
                font.pixelSize: 24
            }
            Text {
                text: root.accountValue("countryCode", "")
                visible: text.length > 0
                color: Qt.rgba(1, 1, 1, 0.42)
                font.pixelSize: 10
                font.letterSpacing: 1.2
            }
            Item { Layout.fillWidth: true }
            ColorButton {
                text: "Refresh"
                quiet: true
                enabled: colorful.linked && !colorful.tidalHubLoading
                onClicked: colorful.loadTidalHub(true)
            }
        }

        Row {
            Layout.fillWidth: true
            spacing: 0
            Repeater {
                model: ["Collection", "Playlists & mixes", "Account"]
                delegate: Rectangle {
                    required property string modelData
                    required property int index
                    width: tabLabel.implicitWidth + 30
                    height: 36
                    color: root.tab === index ? Qt.rgba(1, 1, 1, 0.075) : "transparent"
                    border.width: 1
                    border.color: root.tab === index ? colorful.accent : Qt.rgba(1, 1, 1, 0.1)
                    Text {
                        id: tabLabel
                        anchors.centerIn: parent
                        text: modelData
                        color: root.tab === index ? "#f5f5f5" : Qt.rgba(1, 1, 1, 0.56)
                        font.bold: root.tab === index
                        font.pixelSize: 12
                    }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.tab = index }
                }
            }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: root.tab

            ListView {
                id: collectionTracks
                model: colorful.tidalHub.tracks || []
                clip: true
                spacing: 0
                pixelAligned: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                header: Column {
                    width: collectionTracks.width
                    spacing: 14
                    Text { text: "Saved artists"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                    ListView {
                        width: parent.width; height: 190
                        orientation: ListView.Horizontal
                        model: colorful.tidalHub.artists || []
                        spacing: 8; clip: true; pixelAligned: true
                        delegate: CatalogCard {
                            required property var modelData
                            entry: modelData; artistMode: true
                            onOpenRequested: colorful.openArtist(modelData.id)
                        }
                    }
                    ColorButton {
                        visible: Boolean((colorful.tidalHub.cursors || {}).artists)
                        text: colorful.tidalMoreLoading ? "Loading…" : "Show more artists"
                        quiet: true; enabled: !colorful.tidalMoreLoading
                        onClicked: colorful.loadMoreTidal("artists")
                    }
                    Text { text: "Saved albums"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                    ListView {
                        width: parent.width; height: 206
                        orientation: ListView.Horizontal
                        model: colorful.tidalHub.albums || []
                        spacing: 8; clip: true; pixelAligned: true
                        delegate: CatalogCard {
                            required property var modelData
                            entry: modelData
                            onOpenRequested: colorful.openAlbum(modelData.id)
                        }
                    }
                    ColorButton {
                        visible: Boolean((colorful.tidalHub.cursors || {}).albums)
                        text: colorful.tidalMoreLoading ? "Loading…" : "Show more albums"
                        quiet: true; enabled: !colorful.tidalMoreLoading
                        onClicked: colorful.loadMoreTidal("albums")
                    }
                    Text { text: "Saved tracks"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                }
                delegate: TrackDelegate {
                    required property var modelData
                    width: collectionTracks.width
                    track: modelData
                    showSaveAction: false
                    onPlayRequested: colorful.playCatalogTrack(modelData)
                    onAddRequested: colorful.enqueueCatalogTrack(modelData)
                    onDetailsRequested: colorful.openTrack(modelData.id)
                }
                footer: ColorButton {
                    anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
                    visible: Boolean((colorful.tidalHub.cursors || {}).tracks)
                    text: colorful.tidalMoreLoading ? "Loading…" : "Show 20 more tracks"
                    quiet: true; enabled: !colorful.tidalMoreLoading
                    onClicked: colorful.loadMoreTidal("tracks")
                }
            }

            ListView {
                id: playlistList
                model: colorful.tidalHub.playlists || []
                clip: true; spacing: 8; pixelAligned: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                header: Column {
                    width: playlistList.width
                    spacing: 12
                    Text { text: "Made for you"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                    ListView {
                        width: parent.width; height: 204
                        orientation: ListView.Horizontal
                        model: colorful.tidalHub.mixes || []
                        spacing: 8; clip: true; pixelAligned: true
                        delegate: PlaylistCard {
                            required property var modelData
                            entry: modelData
                            onOpenRequested: colorful.openPlaylist(modelData.id)
                        }
                    }
                    Text { text: "Your playlists"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                }
                delegate: Rectangle {
                    required property var modelData
                    width: playlistList.width; height: 62
                    color: rowHover.hovered ? Qt.rgba(1, 1, 1, 0.055) : "transparent"
                    border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.07)
                    ArtworkImage { x: 7; y: 7; width: 48; height: 48; source: modelData.coverUrl || ""; decodeSize: 192 }
                    Column {
                        x: 67; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 150; spacing: 3
                        Text { width: parent.width; text: modelData.name || "Untitled playlist"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 12; elide: Text.ElideRight }
                        Text { width: parent.width; text: modelData.numberOfItems ? modelData.numberOfItems + " tracks" : (modelData.playlistType || "TIDAL"); color: Qt.rgba(1, 1, 1, 0.42); font.pixelSize: 10 }
                    }
                    HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: colorful.openPlaylist(modelData.id) }
                }
                footer: ColorButton {
                    anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
                    visible: Boolean((colorful.tidalHub.cursors || {}).playlists)
                    text: colorful.tidalMoreLoading ? "Loading…" : "Show more playlists"
                    quiet: true; enabled: !colorful.tidalMoreLoading
                    onClicked: colorful.loadMoreTidal("playlists")
                }
            }

            Flickable {
                clip: true; contentWidth: width; contentHeight: accountColumn.implicitHeight + 30
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                ColumnLayout {
                    id: accountColumn
                    width: Math.min(parent.width, 760)
                    spacing: 0
                    Text { text: root.accountValue("nickname", root.accountValue("username", "TIDAL account")); color: "#f5f5f5"; font.bold: true; font.pixelSize: 22; Layout.bottomMargin: 4 }
                    Text { text: root.accountValue("email", "Identity details unavailable"); color: Qt.rgba(1, 1, 1, 0.48); font.pixelSize: 12; Layout.bottomMargin: 20 }
                    Repeater {
                        model: [
                            ["Status", root.accountValue("status", "Unknown")],
                            ["Plan", root.accountValue("subscriptionType", "Not reported")],
                            ["Country", root.accountValue("countryCode", "US")],
                            ["Subscription started", root.formatDate(root.accountValue("startDate", ""))],
                            ["Valid until", root.formatDate(root.accountValue("validUntil", ""))],
                            ["Time remaining", root.remaining(root.accountValue("validUntil", ""))],
                            ["Highest quality", root.accountValue("highestSoundQuality", "Automatic")],
                            ["Full playback", root.accountValue("canStreamFull", false) ? "Available" : "Unavailable"],
                            ["Payment", root.accountValue("paymentOverdue", false) ? "Overdue" : "Current"],
                            ["Payment type", root.accountValue("paymentType", "Not reported")],
                            ["Offline grace period", root.accountValue("offlineGracePeriod", 0) + " days"],
                            ["Account created", root.formatDate(root.accountValue("accountCreated", ""))],
                            ["User ID", root.accountValue("userId", "Not reported")]
                        ]
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true; Layout.preferredHeight: 45
                            color: index % 2 ? Qt.rgba(1, 1, 1, 0.025) : "transparent"
                            border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.065)
                            Text { anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter; text: modelData[0]; color: Qt.rgba(1, 1, 1, 0.46); font.pixelSize: 11 }
                            Text { anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; width: parent.width * 0.58; horizontalAlignment: Text.AlignRight; text: modelData[1]; color: "#f5f5f5"; font.pixelSize: 12; elide: Text.ElideRight }
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true; Layout.topMargin: 16; spacing: 8
                        ColorButton { text: "Open TIDAL account"; onClicked: colorful.openTidalAccount() }
                        ColorButton { text: "Integrations"; quiet: true; onClicked: root.integrationsRequested() }
                        Item { Layout.fillWidth: true }
                        ColorButton { text: "Disconnect"; quiet: true; onClicked: colorful.unlink() }
                    }
                }
            }
        }
    }

    BusyIndicator { anchors.centerIn: parent; running: colorful.tidalHubLoading; visible: running }
    Column {
        anchors.centerIn: parent; spacing: 12
        visible: !colorful.linked
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Connect TIDAL to load your collection and account"; color: Qt.rgba(1, 1, 1, 0.52); font.pixelSize: 13 }
        ColorButton { anchors.horizontalCenter: parent.horizontalCenter; text: "Connect TIDAL"; onClicked: colorful.startLogin() }
    }
}
