import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root

    function providerAvailable(provider) {
        if (provider === "tidal") return colorful.linked
        if (provider === "youtube") return colorful.youtubeLinked
        if (provider === "soundcloud") return colorful.soundcloudLinked
        return false
    }

    function providerLabel(provider) {
        if (provider === "youtube") return "YouTube Music"
        if (provider === "soundcloud") return "SoundCloud"
        return "TIDAL"
    }

    function providerScore(provider) {
        const stats = colorful.listenStats.providerStats || []
        for (let index = 0; index < stats.length; ++index) {
            if (stats[index].provider === provider) return Number(stats[index].listenedMs || 0)
        }
        return 0
    }

    function orderedProviders() {
        const fallback = ["tidal", "youtube", "soundcloud"]
        return fallback.filter(providerAvailable).sort(function(left, right) {
            const difference = providerScore(right) - providerScore(left)
            return difference !== 0 ? difference : fallback.indexOf(left) - fallback.indexOf(right)
        })
    }

    function playlistShelf(title, provider, entries) {
        return { title: title, provider: provider, kind: "playlist", entries: entries || [] }
    }

    function albumShelf(title, provider, entries) {
        return { title: title, provider: provider, kind: "album", entries: entries || [] }
    }

    function providerShelves(provider) {
        if (provider === "tidal") {
            const hub = colorful.tidalHub || {}
            return [
                playlistShelf("Your daily mixes", provider, hub.dailyMixes),
                playlistShelf("Daily discovery", provider, hub.discoveryMixes),
                playlistShelf("New releases for you", provider, hub.newReleaseMixes),
                playlistShelf("Made for you", provider, hub.mixes)
            ].filter(function(shelf) { return shelf.entries.length > 0 })
        }
        if (provider === "youtube") {
            const hub = colorful.youtubeHub || {}
            return [
                playlistShelf("For you", provider, hub.mixes),
                playlistShelf("Your playlists", provider, hub.playlists)
            ].filter(function(shelf) { return shelf.entries.length > 0 })
        }
        const sections = (colorful.soundcloudHub || {}).homeSections || []
        return sections.map(function(section) {
            return albumShelf(section.title || "For you", provider, section.items)
        }).filter(function(shelf) { return shelf.entries.length > 0 })
    }

    function assembledShelves() {
        const providers = orderedProviders()
        let result = []
        for (let index = 0; index < providers.length; ++index) {
            const candidates = providerShelves(providers[index])
            const limit = index === 0 ? 3 : 1
            result = result.concat(candidates.slice(0, limit))
        }
        return result
    }

    function load(refresh) {
        if (colorful.linked) colorful.loadTidalHub(refresh)
        if (colorful.youtubeLinked) colorful.loadYouTubeHub(refresh)
        if (colorful.soundcloudLinked) colorful.loadSoundCloudHub(refresh)
    }

    readonly property var providers: orderedProviders()
    readonly property var shelves: assembledShelves()
    readonly property string primaryProvider: providers.length > 0 ? providers[0] : ""
    readonly property bool loading: colorful.tidalHubLoading || colorful.youtubeHubLoading || colorful.soundcloudHubLoading

    Component.onCompleted: load(false)
    Connections {
        target: colorful
        function onLinkedChanged() { if (colorful.linked) colorful.loadTidalHub(false) }
        function onYoutubeAccountChanged() {
            if (colorful.youtubeLinked && !colorful.youtubeHubLoading
                    && !(colorful.youtubeHub || {}).tracks) colorful.loadYouTubeHub(false)
        }
        function onSoundcloudAccountChanged() {
            if (colorful.soundcloudLinked && !colorful.soundcloudHubLoading
                    && !(colorful.soundcloudHub || {}).tracks) colorful.loadSoundCloudHub(false)
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 14

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 48
            ColumnLayout {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: refreshButton.left
                anchors.rightMargin: 20
                spacing: 3
                Text { text: "Home"; color: "#f5f5f5"; font.bold: true; font.pixelSize: 24 }
                Text {
                    Layout.fillWidth: true
                    text: root.primaryProvider.length > 0 && root.providerScore(root.primaryProvider) > 0
                          ? "Led by " + root.providerLabel(root.primaryProvider) + " from your listening history"
                          : root.primaryProvider.length > 0 ? "Recommendations from your connected services"
                                                            : "Connect a music service to build your home feed"
                    color: Qt.rgba(1, 1, 1, 0.43)
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }
            ColorButton {
                id: refreshButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Refresh"
                quiet: true
                enabled: root.providers.length > 0 && !root.loading
                onClicked: root.load(true)
            }
        }

        ListView {
            id: feed
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: root.shelves
            spacing: 18
            clip: true
            pixelAligned: true
            boundsBehavior: Flickable.StopAtBounds
            cacheBuffer: 500
            reuseItems: true
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            footer: Item { width: feed.width; height: 24 }

            delegate: Column {
                id: shelf
                required property var modelData
                width: feed.width
                height: 228
                spacing: 9

                RowLayout {
                    width: parent.width
                    spacing: 8
                    Text { text: shelf.modelData.title; color: "#f5f5f5"; font.bold: true; font.pixelSize: 17 }
                    Text {
                        text: root.providerLabel(shelf.modelData.provider)
                        color: Qt.rgba(1, 1, 1, 0.34)
                        font.bold: true
                        font.pixelSize: 9
                        font.letterSpacing: 0.7
                    }
                    Item { Layout.fillWidth: true }
                }

                Item {
                    width: parent.width
                    height: 196
                    ListView {
                        id: shelfList
                        anchors.fill: parent
                        orientation: ListView.Horizontal
                        model: shelf.modelData.entries
                        spacing: 8
                        clip: true
                        pixelAligned: true
                        boundsBehavior: Flickable.StopAtBounds
                        cacheBuffer: width
                        reuseItems: true

                        delegate: Item {
                            id: shelfItem
                            required property var modelData
                            width: 154
                            height: 196
                            PlaylistCard {
                                anchors.fill: parent
                                visible: shelf.modelData.kind === "playlist"
                                entry: shelfItem.modelData
                                onOpenRequested: window.openPlaylist(shelfItem.modelData.id, shelf.modelData.provider)
                            }
                            CatalogCard {
                                anchors.fill: parent
                                visible: shelf.modelData.kind === "album"
                                entry: shelfItem.modelData
                                onOpenRequested: window.openAlbumItem(shelfItem.modelData)
                            }
                        }
                    }
                    ShelfScrollButtons { view: shelfList }
                }
            }
        }
    }

    BusyIndicator { anchors.centerIn: parent; running: root.loading && root.shelves.length === 0; visible: running }

    Column {
        anchors.centerIn: parent
        width: Math.min(460, parent.width - 48)
        spacing: 10
        visible: !root.loading && root.shelves.length === 0
        AppIcon { anchors.horizontalCenter: parent.horizontalCenter; width: 34; height: 34; iconSource: "icons/home.svg"; opacity: 0.28 }
        Text {
            width: parent.width
            text: root.providers.length > 0 ? "Your home feed is warming up" : "Connect a service to personalize Home"
            color: "#f5f5f5"; font.bold: true; font.pixelSize: 17; horizontalAlignment: Text.AlignHCenter
        }
        Text {
            width: parent.width
            text: root.providers.length > 0
                  ? "Recommendations and mixes will appear here as your connected providers return them."
                  : "Home combines mixes and recommendations from the services you use, ordered by your listening history."
            color: Qt.rgba(1, 1, 1, 0.44); font.pixelSize: 12; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
        }
        ColorButton { anchors.horizontalCenter: parent.horizontalCenter; text: "Open account settings"; visible: root.providers.length === 0; onClicked: window.openSettings(0) }
    }
}
