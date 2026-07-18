import QtQuick

Item {
    id: root
    property url iconSource

    implicitWidth: 20
    implicitHeight: 20

    Image {
        anchors.fill: parent
        source: root.iconSource
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
    }
}
