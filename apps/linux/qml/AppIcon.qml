import QtQuick

Item {
    id: root
    property url iconSource

    implicitWidth: 20
    implicitHeight: 20

    Image {
        anchors.fill: parent
        source: root.iconSource
        sourceSize: Qt.size(Math.max(1, Math.round(width * Screen.devicePixelRatio)),
                            Math.max(1, Math.round(height * Screen.devicePixelRatio)))
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: false
    }
}
