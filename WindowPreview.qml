import QtQuick
import "Layout.js" as OverviewLayout

Item {
  id: root
  property var windowInfo: null
  property var sharedCapture: null
  property bool live: true
  property bool highlighted: false
  property bool showTitle: true
  property string unavailableText: "Live preview unavailable"
  // A reverse-DNS class ending in a separator ("org.gnome.Nautilus.") used to pop
  // an empty segment and leave the card heading blank, so empty parts are skipped.
  readonly property string appName: windowInfo && windowInfo.lastIpcObject
    ? String(windowInfo.lastIpcObject.class || "Window").split(".").filter(part => part.length > 0).pop() || "Window"
    : "Window"
  property string label: windowInfo ? (windowInfo.title || appName) : ""
  property color accent: "#76b5ff"
  property color surfaceColor: "#252a36"
  property color textColor: "#f1f2f5"
  readonly property bool hasThumbnail: !!sharedCapture && sharedCapture.hasContent
  readonly property real aspect: OverviewLayout.aspectFor(windowInfo, sharedCapture)
  property alias surface: frame

  Item {
    id: frame
    anchors.centerIn: parent
    width: Math.min(root.width, root.height * root.aspect)
    height: width / root.aspect
    Repeater {
      model: 3
      delegate: Rectangle {
        required property int index
        x: -3 - index * 3; y: 4 + index * 2
        width: frame.width + 6 + index * 6; height: frame.height + 6 + index * 3
        radius: 6 + index * 3; color: "#18000000"
      }
    }
    Rectangle {
      anchors.fill: parent; anchors.margins: -4
      radius: 5; color: "transparent"
      border.width: 2; border.color: root.accent; visible: root.highlighted
    }
    Rectangle {
      objectName: "previewPlaceholder"
      anchors.fill: parent; color: root.surfaceColor; radius: 6
      visible: !root.hasThumbnail
      Column {
        anchors.centerIn: parent; width: Math.max(0, parent.width - 24); spacing: 10
        Text {
          objectName: "previewHeading"
          width: parent.width; text: root.appName; textFormat: Text.PlainText
          horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
          color: root.textColor; font.pixelSize: 18; font.bold: true
        }
        Text {
          objectName: "previewUnavailable"
          width: parent.width; text: root.unavailableText; textFormat: Text.PlainText
          horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
          color: root.textColor; opacity: .6; font.pixelSize: 11
          visible: root.showTitle && frame.width > 100 && frame.height > 80
        }
      }
    }
    Loader {
      anchors.fill: parent
      active: root.hasThumbnail
      sourceComponent: ShaderEffectSource {
        objectName: "previewTexture"
        sourceItem: root.sharedCapture ? root.sharedCapture.image || null : null
        // One native source, sampled at 2x presentation size for clear text, with
        // the request quantised to a 64 px grid: a ShaderEffectSource recreates its
        // FBO whenever textureSize changes, and the card's width/height are animated
        // (shell.qml:684-687), so tracking them pixel by pixel reallocated a texture
        // on essentially every animation frame. Never below ceil(size * 2), never
        // above the native source.
        textureSize: Qt.size(Math.max(1, Math.min(sourceItem ? sourceItem.width : 1, Math.ceil(width * 2 / 64) * 64)),
                             Math.max(1, Math.min(sourceItem ? sourceItem.height : 1, Math.ceil(height * 2 / 64) * 64)))
        hideSource: true; live: root.live && root.hasThumbnail
        smooth: true; mipmap: true
      }
    }
    Rectangle {
      objectName: "previewPaused"
      anchors { left: parent.left; top: parent.top; margins: 6 }
      width: 52; height: 20; radius: 4; color: "#c0202633"
      visible: root.hasThumbnail && root.showTitle && root.sharedCapture && root.sharedCapture.allowStart !== false && !root.sharedCapture.fresh && frame.width > 120
      Text { anchors.centerIn: parent; text: "Paused"; color: "white"; font.pixelSize: 10 }
    }
    Rectangle {
      anchors.top: parent.bottom; anchors.topMargin: 10; anchors.horizontalCenter: parent.horizontalCenter
      width: Math.max(0, Math.min(frame.width + 20, 360, title.implicitWidth + 22)); height: 26
      radius: 6; color: Qt.rgba(root.surfaceColor.r, root.surfaceColor.g, root.surfaceColor.b, .94)
      visible: root.showTitle
      Text {
        id: title
        objectName: "previewTitle"
        anchors.centerIn: parent; width: Math.max(0, parent.width - 22)
        text: root.label; textFormat: Text.PlainText
        elide: Text.ElideRight; color: root.textColor; font.pixelSize: 12
      }
    }
  }
}
