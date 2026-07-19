import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: window
    width: 1240
    height: 780
    minimumWidth: 920
    minimumHeight: 620
    visible: true
    title: "colorful"
    color: "#101012"
    flags: Qt.Window | Qt.FramelessWindowHint

    readonly property color ink: "#f5f5f5"
    readonly property color mutedInk: Qt.rgba(1, 1, 1, 0.5)
    readonly property var now: colorful.currentTrack
    property bool queueOpen: false
    property string submittedQuery: ""
    property string currentSection: "search"
    onCurrentSectionChanged: Qt.callLater(function() { resultsList.positionViewAtBeginning() })

    Connections {
        target: colorful
        function onSearchResultsChanged() {
            Qt.callLater(function() { resultsList.positionViewAtBeginning() })
        }
        function onToastRequested(message, kind) {
            toastOverlay.show(message, kind)
        }
    }

    function formatTime(milliseconds) {
        if (!milliseconds || milliseconds < 0) return "0:00"
        const seconds = Math.floor(milliseconds / 1000)
        return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0")
    }

    function runSearch() {
        const query = searchField.text.trim()
        if (!query || colorful.busy || !colorful.providerReady) return
        submittedQuery = query
        currentSection = "search"
        colorful.closeCatalog()
        colorful.search(query)
    }

    function openSettings(tab) {
        settingsPage.tab = tab
        currentSection = "settings"
        colorful.closeCatalog()
    }

    Rectangle {
        anchors.fill: parent
        color: "#101012"
    }

    ToastOverlay {
        id: toastOverlay
        anchors.right: parent.right
        anchors.rightMargin: 16
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 100
        z: 997
    }

    Rectangle {
        anchors.fill: parent
        opacity: 0.9
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop {
                position: 0
                color: Qt.rgba(colorful.accent.r, colorful.accent.g, colorful.accent.b, 0.065)
            }
            GradientStop { position: 0.42; color: "transparent" }
        }
        Behavior on color { ColorAnimation { duration: 350 } }
    }

    Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        z: 998
        height: 2
        color: colorful.accent
        Behavior on color { ColorAnimation { duration: 350 } }

        DragHandler {
            target: null
            acceptedButtons: Qt.LeftButton
            onActiveChanged: {
                if (active)
                    window.startSystemMove()
            }
        }
        TapHandler {
            acceptedButtons: Qt.LeftButton
            onDoubleTapped: {
                if (window.visibility === Window.Maximized)
                    window.showNormal()
                else
                    window.showMaximized()
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: 2
        spacing: 0

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 28
            color: window.active ? "#17171b" : "#131316"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, window.active ? 0.09 : 0.055)

            RowLayout {
                anchors.fill: parent
                spacing: 0

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 9
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        Image {
                            width: 15
                            height: 15
                            anchors.verticalCenter: parent.verticalCenter
                            source: "qrc:/assets/branding/colorful.svg"
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                            mipmap: true
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: window.title
                            color: Qt.rgba(1, 1, 1, window.active ? 0.68 : 0.38)
                            font.weight: Font.DemiBold
                            font.pixelSize: 10
                        }
                    }

                    DragHandler {
                        target: null
                        acceptedButtons: Qt.LeftButton
                        onActiveChanged: {
                            if (active)
                                window.startSystemMove()
                        }
                    }
                    TapHandler {
                        acceptedButtons: Qt.LeftButton
                        onDoubleTapped: {
                            if (window.visibility === Window.Maximized)
                                window.showNormal()
                            else
                                window.showMaximized()
                        }
                    }
                }

                TitleButton {
                    id: minimizeButton
                    iconSource: "icons/minimize.svg"
                    tooltipText: "Minimize"
                    onClicked: window.showMinimized()
                }
                TitleButton {
                    id: maximizeButton
                    iconSource: window.visibility === Window.Maximized
                                ? "icons/restore.svg" : "icons/maximize.svg"
                    tooltipText: window.visibility === Window.Maximized ? "Restore" : "Maximize"
                    onClicked: window.visibility === Window.Maximized
                               ? window.showNormal() : window.showMaximized()
                }
                TitleButton {
                    id: closeButton
                    iconSource: "icons/close.svg"
                    tooltipText: "Close"
                    danger: true
                    onClicked: window.close()
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Rectangle {
                Layout.preferredWidth: 64
                Layout.fillHeight: true
                color: Qt.rgba(0.035, 0.035, 0.043, 0.94)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.08)

                ColumnLayout {
                    anchors.fill: parent
                    anchors.topMargin: 14
                    anchors.bottomMargin: 14
                    spacing: 7

                    Item {
                        Layout.alignment: Qt.AlignHCenter
                        width: 44
                        height: 44

                        IconButton {
                            anchors.fill: parent
                            iconSource: "icons/home.svg"
                            selected: window.currentSection === "search"
                            tooltipText: "Search"
                            onClicked: {
                                window.currentSection = "search"
                                colorful.closeCatalog()
                            }
                        }
                        Rectangle {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: 3
                            height: 26
                            color: colorful.accent
                            visible: window.currentSection === "search"
                        }
                    }

                    IconButton {
                        Layout.alignment: Qt.AlignHCenter
                        iconSource: "icons/library.svg"
                        selected: window.currentSection === "library"
                        tooltipText: "Library"
                        onClicked: {
                            window.currentSection = "library"
                            colorful.closeCatalog()
                        }
                    }

                    IconButton {
                        Layout.alignment: Qt.AlignHCenter
                        iconSource: "icons/settings.svg"
                        selected: window.currentSection === "settings"
                        tooltipText: "Settings"
                        onClicked: window.openSettings(0)
                    }

                    IconButton {
                        Layout.alignment: Qt.AlignHCenter
                        iconSource: "icons/download.svg"
                        selected: window.currentSection === "downloads"
                        tooltipText: "Offline music"
                        onClicked: {
                            window.currentSection = "downloads"
                            colorful.closeCatalog()
                        }
                    }

                    Item { Layout.fillHeight: true }

                    IconButton {
                        Layout.alignment: Qt.AlignHCenter
                        iconSource: "icons/tidal.svg"
                        selected: window.currentSection === "tidal"
                        tooltipText: "TIDAL library"
                        onClicked: {
                            window.currentSection = "tidal"
                            colorful.closeCatalog()
                            colorful.loadTidalHub(false)
                        }
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 64
                    color: Qt.rgba(0.045, 0.043, 0.052, 0.72)
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.075)

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 20
                        anchors.rightMargin: 20
                        spacing: 10

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.maximumWidth: 620
                            implicitHeight: 40
                            color: Qt.rgba(0.025, 0.025, 0.03, 0.86)
                            border.width: 1
                            border.color: searchField.activeFocus
                                          ? Qt.rgba(colorful.accent.r, colorful.accent.g, colorful.accent.b, 0.72)
                                          : Qt.rgba(1, 1, 1, 0.13)

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 5
                                spacing: 9

                                AppIcon {
                                    Layout.preferredWidth: 18
                                    Layout.preferredHeight: 18
                                    iconSource: "icons/search.svg"
                                    opacity: 0.48
                                }

                                TextField {
                                    id: searchField
                                    Layout.fillWidth: true
                                    placeholderText: "Search tracks, albums, artists"
                                    placeholderTextColor: Qt.rgba(1, 1, 1, 0.34)
                                    color: window.ink
                                    font.pixelSize: 13
                                    background: Item {}
                                    selectByMouse: true
                                    onAccepted: window.runSearch()
                                }

                                BusyIndicator {
                                    visible: colorful.busy
                                    running: visible
                                    implicitWidth: 24
                                    implicitHeight: 24
                                }
                            }
                        }

                        ColorButton {
                            text: "Search"
                            implicitWidth: 82
                            enabled: colorful.providerReady && searchField.text.trim().length > 0 && !colorful.busy
                            onClicked: window.runSearch()
                        }

                        Item { Layout.fillWidth: true }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 0

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.leftMargin: 28
                        Layout.rightMargin: 28
                        Layout.topMargin: 24
                        Layout.bottomMargin: 12
                        spacing: 14

                        CatalogPage {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: (window.currentSection === "search" || window.currentSection === "library")
                                     && (colorful.catalogLoading || (colorful.catalogPage.kind || "").length > 0)
                            page: colorful.catalogPage
                            loading: colorful.catalogLoading
                        }

                        TidalPage {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: window.currentSection === "tidal"
                        }

                        SettingsPage {
                            id: settingsPage
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: window.currentSection === "settings"
                        }

                        DownloadsPage {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: window.currentSection === "downloads"
                        }

                        RowLayout {
                            visible: (window.currentSection === "search" || window.currentSection === "library")
                                     && !colorful.catalogLoading && !(colorful.catalogPage.kind || "")
                            Layout.fillWidth: true
                            spacing: 10

                            Text {
                                text: window.currentSection === "library"
                                      ? "Your library"
                                      : window.submittedQuery.length > 0 ? "Search results" : "Search"
                                color: window.ink
                                font.weight: Font.Bold
                                font.pixelSize: 24
                            }
                            Text {
                                visible: (window.currentSection === "library" ? colorful.library.length
                                          : colorful.searchResults.length + colorful.searchAlbums.length + colorful.searchArtists.length) > 0
                                text: window.currentSection === "library" ? colorful.library.length
                                      : colorful.searchResults.length + colorful.searchAlbums.length + colorful.searchArtists.length
                                color: window.mutedInk
                                font.pixelSize: 11
                            }
                            Item { Layout.fillWidth: true }
                        }

                        ListView {
                            id: resultsList
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            model: window.currentSection === "library" ? colorful.library : colorful.searchResults
                            visible: (window.currentSection === "search" || window.currentSection === "library")
                                     && !colorful.catalogLoading && !(colorful.catalogPage.kind || "")
                            spacing: 0
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            pixelAligned: true
                            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                            delegate: TrackDelegate {
                                required property int index
                                required property var modelData
                                track: modelData
                                libraryMode: window.currentSection === "library"
                                showSaveAction: window.currentSection === "search"
                                showDownloadAction: true
                                onPlayRequested: window.currentSection === "library"
                                                 ? colorful.playLibraryIndex(index)
                                                 : colorful.playSearchResult(index)
                                onAddRequested: colorful.enqueueSearchResult(index)
                                onRemoveRequested: colorful.removeLibraryIndex(index)
                                onSaveRequested: colorful.addSearchResultToLibrary(index)
                                onDownloadRequested: colorful.downloadTrack(modelData)
                                onDetailsRequested: colorful.openTrack(modelData.id)
                            }

                            header: Column {
                                width: resultsList.width
                                spacing: 16
                                visible: window.currentSection === "search"
                                         && (colorful.searchAlbums.length > 0 || colorful.searchArtists.length > 0)
                                height: visible ? implicitHeight + 18 : 0

                                Text {
                                    visible: colorful.searchArtists.length > 0
                                    text: "Artists"
                                    color: window.ink
                                    font.bold: true
                                    font.pixelSize: 16
                                }
                                ListView {
                                    width: parent.width
                                    height: visible ? 190 : 0
                                    visible: colorful.searchArtists.length > 0
                                    orientation: ListView.Horizontal
                                    spacing: 8
                                    clip: true
                                    pixelAligned: true
                                    model: colorful.searchArtists
                                    delegate: CatalogCard {
                                        required property var modelData
                                        entry: modelData
                                        artistMode: true
                                        onOpenRequested: colorful.openArtist(modelData.id)
                                    }
                                }
                                Text {
                                    visible: colorful.searchAlbums.length > 0
                                    text: "Albums"
                                    color: window.ink
                                    font.bold: true
                                    font.pixelSize: 16
                                }
                                ListView {
                                    width: parent.width
                                    height: visible ? 190 : 0
                                    visible: colorful.searchAlbums.length > 0
                                    orientation: ListView.Horizontal
                                    spacing: 8
                                    clip: true
                                    pixelAligned: true
                                    model: colorful.searchAlbums
                                    delegate: CatalogCard {
                                        required property var modelData
                                        entry: modelData
                                        onOpenRequested: colorful.openAlbum(modelData.id)
                                    }
                                }
                                Text {
                                    visible: colorful.searchResults.length > 0
                                    text: "Tracks"
                                    color: window.ink
                                    font.bold: true
                                    font.pixelSize: 16
                                }
                            }

                            Column {
                                anchors.centerIn: parent
                                width: Math.min(400, parent.width - 48)
                                spacing: 12
                                visible: window.currentSection === "library" ? resultsList.count === 0
                                         : colorful.searchResults.length + colorful.searchAlbums.length + colorful.searchArtists.length === 0

                                AppIcon {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: 28
                                    height: 28
                                    iconSource: window.currentSection === "library" ? "icons/library.svg"
                                                : window.submittedQuery.length > 0 ? "icons/search.svg" : "icons/music.svg"
                                    opacity: 0.3
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: parent.width
                                    text: window.currentSection === "library"
                                          ? "Tracks you save will live here on this device"
                                          : window.submittedQuery.length > 0
                                          ? "No tracks found for “" + window.submittedQuery + "”"
                                          : colorful.linked
                                            ? "Search TIDAL to start listening"
                                            : "Connect TIDAL, then search for something to play"
                                    color: Qt.rgba(1, 1, 1, 0.48)
                                    horizontalAlignment: Text.AlignHCenter
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: 13
                                }
                                ColorButton {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    visible: !colorful.linked
                                    text: "Connect TIDAL"
                                    onClicked: colorful.startLogin()
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.preferredWidth: window.queueOpen ? 330 : 0
                        Layout.fillHeight: true
                        visible: window.queueOpen
                        color: Qt.rgba(0.032, 0.032, 0.038, 0.96)
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.09)

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 16
                            spacing: 10

                            RowLayout {
                                Layout.fillWidth: true
                                Text {
                                    text: "Queue"
                                    color: window.ink
                                    font.weight: Font.Bold
                                    font.pixelSize: 18
                                }
                                Text {
                                    text: colorful.queue.length
                                    color: window.mutedInk
                                    font.pixelSize: 11
                                }
                                ColorButton {
                                    text: colorful.autoplayEnabled ? "Autoplay on" : "Autoplay off"
                                    quiet: true
                                    implicitWidth: 94
                                    implicitHeight: 30
                                    onClicked: colorful.autoplayEnabled = !colorful.autoplayEnabled
                                }
                                Item { Layout.fillWidth: true }
                                ColorButton {
                                    text: "Clear"
                                    quiet: true
                                    enabled: colorful.queue.length > 0
                                    implicitWidth: 52
                                    implicitHeight: 30
                                    onClicked: colorful.clearQueue()
                                }
                                IconButton {
                                    implicitWidth: 36
                                    implicitHeight: 36
                                    iconSource: "icons/close.svg"
                                    tooltipText: "Close queue"
                                    onClicked: window.queueOpen = false
                                }
                            }

                            ListView {
                                id: queueList
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                model: colorful.queue
                                spacing: 0
                                clip: true
                                pixelAligned: true
                                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                                delegate: TrackDelegate {
                                    required property int index
                                    required property var modelData
                                    track: modelData
                                    queueMode: true
                                    showDownloadAction: true
                                    active: index === colorful.currentQueueIndex
                                    onPlayRequested: colorful.playQueueIndex(index)
                                    onRemoveRequested: colorful.removeQueueIndex(index)
                                    onDownloadRequested: colorful.downloadTrack(modelData)
                                    onDetailsRequested: colorful.openTrack(modelData.id)
                                }

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 9
                                    visible: queueList.count === 0
                                    AppIcon {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: 24
                                        height: 24
                                        iconSource: "icons/queue.svg"
                                        opacity: 0.28
                                    }
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: "Your queue is empty"
                                        color: Qt.rgba(1, 1, 1, 0.42)
                                        font.pixelSize: 12
                                    }
                                }
                            }
                        }
                    }
                }

            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 88
            color: Qt.rgba(0.027, 0.027, 0.033, 0.98)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.11)

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 20

                Item {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 280
                    Layout.minimumWidth: 200
                    Layout.fillHeight: true

                    RowLayout {
                        anchors.fill: parent
                        spacing: 10

                        Rectangle {
                            Layout.preferredWidth: 50
                            Layout.preferredHeight: 50
                            color: Qt.rgba(1, 1, 1, 0.07)
                            border.width: 1
                            border.color: Qt.rgba(1, 1, 1, 0.1)
                            clip: true

                            ArtworkImage {
                                anchors.fill: parent
                                source: window.now.coverUrl || ""
                                decodeSize: 200
                            }
                            AppIcon {
                                anchors.centerIn: parent
                                width: 20
                                height: 20
                                iconSource: "icons/music.svg"
                                opacity: 0.34
                                visible: !window.now.coverUrl
                            }
                            MouseArea {
                                anchors.fill: parent
                                enabled: Boolean(window.now.id)
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: colorful.openTrack(window.now.id)
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            MetadataLink {
                                Layout.fillWidth: true
                                text: window.now.title || "Nothing playing"
                                normalColor: window.ink
                                elide: Text.ElideRight
                                font.weight: Font.DemiBold
                                font.pixelSize: 13
                                linkEnabled: Boolean(window.now.id)
                                onActivated: {
                                    if (window.now.id) colorful.openTrack(window.now.id)
                                }
                            }
                            RowLayout {
                                id: playerMetadataLine
                                Layout.fillWidth: true
                                height: 16
                                spacing: 5
                                clip: true
                                Row {
                                    visible: (window.now.artistCredits || []).length > 0
                                    Layout.preferredWidth: Math.min(implicitWidth,
                                        playerMetadataLine.width * (window.now.albumId ? 0.52 : 1))
                                    Layout.maximumWidth: playerMetadataLine.width * (window.now.albumId ? 0.52 : 1)
                                    spacing: 4
                                    clip: true
                                    Repeater {
                                        model: window.now.artistCredits || []
                                        delegate: Row {
                                            required property var modelData
                                            required property int index
                                            spacing: 0
                                            MetadataLink {
                                                text: modelData.name
                                                normalColor: window.mutedInk
                                                font.pixelSize: 11
                                                font.weight: Font.Normal
                                                onActivated: colorful.openTrackArtist(window.now, index)
                                            }
                                            Text {
                                                visible: index + 1 < (window.now.artistCredits || []).length
                                                text: ","
                                                color: window.mutedInk
                                                font.pixelSize: 11
                                            }
                                        }
                                    }
                                }
                                Text {
                                    visible: !(window.now.artistCredits || []).length
                                    Layout.preferredWidth: implicitWidth
                                    Layout.maximumWidth: playerMetadataLine.width * (window.now.albumId ? 0.52 : 1)
                                    text: "Choose a track"
                                    color: window.mutedInk
                                    elide: Text.ElideRight
                                    font.pixelSize: 11
                                }
                                Text {
                                    visible: Boolean(window.now.albumId)
                                    text: "·"
                                    color: Qt.rgba(1, 1, 1, 0.3)
                                    font.pixelSize: 11
                                }
                                MetadataLink {
                                    visible: Boolean(window.now.albumId)
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 0
                                    text: window.now.albumTitle || "Open album"
                                    normalColor: window.mutedInk
                                    elide: Text.ElideRight
                                    font.pixelSize: 11
                                    font.weight: Font.Normal
                                    onActivated: colorful.openAlbum(window.now.albumId)
                                }
                            }
                        }
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.maximumWidth: 560
                    Layout.minimumWidth: 310
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 3

                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 7

                        IconButton {
                            implicitWidth: 36
                            implicitHeight: 36
                            iconSource: "icons/previous.svg"
                            tooltipText: "Previous"
                            enabled: colorful.queue.length > 0
                            onClicked: colorful.previous()
                        }
                        IconButton {
                            implicitWidth: 42
                            implicitHeight: 42
                            iconSource: colorful.playing ? "icons/pause-dark.svg" : "icons/play-dark.svg"
                            tooltipText: colorful.playing ? "Pause" : "Play"
                            strong: true
                            enabled: Object.keys(window.now).length > 0
                            onClicked: colorful.togglePlay()
                        }
                        IconButton {
                            implicitWidth: 36
                            implicitHeight: 36
                            iconSource: "icons/next.svg"
                            tooltipText: "Next"
                            enabled: colorful.queue.length > 0
                            onClicked: colorful.next()
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text {
                            text: window.formatTime(colorful.position)
                            color: window.mutedInk
                            font.pixelSize: 10
                        }
                        Slider {
                            id: progress
                            Layout.fillWidth: true
                            implicitHeight: 18
                            from: 0
                            to: Math.max(1, colorful.duration)
                            onPressedChanged: {
                                if (!pressed) colorful.seek(value)
                            }
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
                                color: Qt.rgba(1, 1, 1, 0.16)
                                Rectangle {
                                    width: progress.visualPosition * parent.width
                                    height: parent.height
                                    color: colorful.accent
                                }
                            }
                            handle: Rectangle {
                                x: progress.leftPadding + progress.visualPosition * (progress.availableWidth - width)
                                y: progress.topPadding + progress.availableHeight / 2 - height / 2
                                implicitWidth: progress.pressed ? 12 : 8
                                implicitHeight: implicitWidth
                                radius: width / 2
                                color: "white"
                            }
                        }
                        Text {
                            text: window.formatTime(colorful.duration)
                            color: window.mutedInk
                            font.pixelSize: 10
                        }
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 280
                    Layout.minimumWidth: 200
                    Layout.fillHeight: true

                    RowLayout {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 5

                        AppIcon {
                            Layout.preferredWidth: 18
                            Layout.preferredHeight: 18
                            iconSource: "icons/volume.svg"
                            opacity: 0.58
                        }
                        Slider {
                            id: volumeSlider
                            Layout.preferredWidth: 90
                            implicitHeight: 28
                            from: 0
                            to: 1
                            value: colorful.volume
                            onMoved: colorful.setVolume(value)
                            background: Rectangle {
                                x: volumeSlider.leftPadding
                                y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                                width: volumeSlider.availableWidth
                                height: 4
                                color: Qt.rgba(1, 1, 1, 0.16)
                                Rectangle {
                                    width: volumeSlider.visualPosition * parent.width
                                    height: parent.height
                                    color: colorful.accent
                                }
                            }
                            handle: Rectangle {
                                x: volumeSlider.leftPadding + volumeSlider.visualPosition * (volumeSlider.availableWidth - width)
                                y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                                implicitWidth: 9
                                implicitHeight: 9
                                radius: 5
                                color: "white"
                            }
                        }
                        Item {
                            Layout.preferredWidth: 42
                            Layout.preferredHeight: 42
                            IconButton {
                                anchors.fill: parent
                                iconSource: "icons/queue.svg"
                                selected: window.queueOpen
                                tooltipText: "Queue"
                                onClicked: window.queueOpen = !window.queueOpen
                            }
                            Rectangle {
                                anchors.right: parent.right
                                anchors.top: parent.top
                                width: 15
                                height: 15
                                visible: colorful.queue.length > 0
                                color: colorful.accent
                                border.width: 1
                                border.color: "#0b0b0d"
                                Text {
                                    anchors.centerIn: parent
                                    text: colorful.queue.length
                                    color: "#08080a"
                                    font.bold: true
                                    font.pixelSize: 8
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Preserve desktop title-bar edge targeting without making the visible
    // controls taller. These hit targets cover the accent strip above them.
    Row {
        anchors.top: parent.top
        anchors.right: parent.right
        width: 114
        height: 2
        z: 1001

        Item {
            width: 38
            height: 2
            HoverHandler { onHoveredChanged: minimizeButton.edgeHovered = hovered }
            TapHandler {
                acceptedButtons: Qt.LeftButton
                onTapped: window.showMinimized()
            }
        }
        Item {
            width: 38
            height: 2
            HoverHandler { onHoveredChanged: maximizeButton.edgeHovered = hovered }
            TapHandler {
                acceptedButtons: Qt.LeftButton
                onTapped: window.visibility === Window.Maximized
                          ? window.showNormal() : window.showMaximized()
            }
        }
        Item {
            width: 38
            height: 2
            HoverHandler { onHoveredChanged: closeButton.edgeHovered = hovered }
            TapHandler {
                acceptedButtons: Qt.LeftButton
                onTapped: window.close()
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        z: 999
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, window.active ? 0.16 : 0.09)
        visible: window.visibility === Window.Windowed
    }

    ResizeHandle {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom; topMargin: 7; bottomMargin: 7 }
        width: 7
        edges: Qt.LeftEdge
        handleCursor: Qt.SizeHorCursor
    }
    ResizeHandle {
        anchors { right: parent.right; top: parent.top; bottom: parent.bottom; topMargin: 7; bottomMargin: 7 }
        width: 7
        edges: Qt.RightEdge
        handleCursor: Qt.SizeHorCursor
    }
    ResizeHandle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 7; rightMargin: 7 }
        height: 7
        edges: Qt.BottomEdge
        handleCursor: Qt.SizeVerCursor
    }
    ResizeHandle {
        anchors { left: parent.left; top: parent.top }
        width: 9
        height: 9
        edges: Qt.LeftEdge | Qt.TopEdge
        handleCursor: Qt.SizeFDiagCursor
    }
    ResizeHandle {
        anchors { right: parent.right; top: parent.top }
        width: 9
        height: 9
        edges: Qt.RightEdge | Qt.TopEdge
        handleCursor: Qt.SizeBDiagCursor
    }
    ResizeHandle {
        anchors { left: parent.left; bottom: parent.bottom }
        width: 9
        height: 9
        edges: Qt.LeftEdge | Qt.BottomEdge
        handleCursor: Qt.SizeBDiagCursor
    }
    ResizeHandle {
        anchors { right: parent.right; bottom: parent.bottom }
        width: 9
        height: 9
        edges: Qt.RightEdge | Qt.BottomEdge
        handleCursor: Qt.SizeFDiagCursor
    }

    Popup {
        id: entitlementPopup
        anchors.centerIn: Overlay.overlay
        width: 410
        height: 230
        modal: true
        closePolicy: Popup.NoAutoClose
        visible: colorful.entitlementWarningVisible
        padding: 0

        background: Rectangle {
            color: "#19191e"
            border.width: 1
            border.color: Qt.rgba(colorful.accent.r, colorful.accent.g, colorful.accent.b, 0.72)
        }

        contentItem: ColumnLayout {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 12

            Text {
                text: "TIDAL playback unavailable"
                color: window.ink
                font.weight: Font.Bold
                font.pixelSize: 20
            }
            Text {
                Layout.fillWidth: true
                text: colorful.entitlementMessage
                color: window.mutedInk
                wrapMode: Text.WordWrap
                font.pixelSize: 13
            }
            Item { Layout.fillHeight: true }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Item { Layout.fillWidth: true }
                ColorButton {
                    text: "Dismiss"
                    quiet: true
                    onClicked: colorful.dismissEntitlementWarning()
                }
                ColorButton {
                    text: "Open TIDAL account"
                    onClicked: {
                        colorful.openTidalAccount()
                        colorful.dismissEntitlementWarning()
                    }
                }
            }
        }
    }

    Popup {
        id: authPopup
        anchors.centerIn: Overlay.overlay
        width: 420
        height: 330
        modal: true
        closePolicy: Popup.NoAutoClose
        visible: colorful.authPending
        padding: 0

        background: Rectangle {
            color: "#19191e"
            border.width: 1
            border.color: Qt.rgba(colorful.accent.r, colorful.accent.g, colorful.accent.b, 0.72)
        }

        contentItem: ColumnLayout {
            anchors.fill: parent
            anchors.margins: 26
            spacing: 13

            Text {
                text: "Connect TIDAL"
                color: window.ink
                font.weight: Font.Bold
                font.pixelSize: 22
            }
            Text {
                Layout.fillWidth: true
                text: "Approve colorful in TIDAL, then return here. Your password never touches this app."
                color: window.mutedInk
                wrapMode: Text.WordWrap
                font.pixelSize: 13
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 86
                Layout.topMargin: 4
                color: Qt.rgba(1, 1, 1, 0.045)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.11)

                Column {
                    anchors.centerIn: parent
                    spacing: 4
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "DEVICE CODE"
                        color: Qt.rgba(1, 1, 1, 0.4)
                        font.bold: true
                        font.pixelSize: 9
                        font.letterSpacing: 1.4
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: colorful.userCode
                        color: window.ink
                        font.family: "monospace"
                        font.bold: true
                        font.pixelSize: 29
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
                font.pixelSize: 11
            }
            Item { Layout.fillHeight: true }
        }
    }
}
