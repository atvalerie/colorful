import QtQuick

Item {
    id: root
    property url source: ""
    property int decodeSize: Math.max(64, Math.ceil(Math.max(width, height) * 4))

    Image {
        anchors.fill: parent
        source: colorful.lowDataMode ? "" : root.source
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        smooth: true
        sourceSize.width: root.decodeSize
        sourceSize.height: root.decodeSize
    }
}
