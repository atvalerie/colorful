import QtQuick

Image {
    property int decodeSize: Math.max(64, Math.ceil(Math.max(width, height) * 4))

    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    cache: true
    smooth: true
    mipmap: true
    antialiasing: true
    sourceSize.width: decodeSize
    sourceSize.height: decodeSize
}
