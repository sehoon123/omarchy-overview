import QtQuick
import "Layout.js" as OverviewLayout

Item {
  id: root
  property var windowInfo: null
  property var sharedCapture: null
  property bool live: true
  property bool highlighted: false
  property bool showTitle: true
  readonly property string appName: windowInfo && windowInfo.lastIpcObject ? String(windowInfo.lastIpcObject.class || "Window").split(".").pop() : "Window"
  property string label: windowInfo ? (windowInfo.title || appName) : ""
  property color accent: "#76b5ff"
  property color surfaceColor: "#252a36"
  property color textColor: "#f1f2f5"
  readonly property bool bitmapMode: !!sharedCapture && !!sharedCapture.imageSource
  readonly property bool hasThumbnail: bitmapMode ? snapshotImage.status === Image.Ready : !!sharedCapture && sharedCapture.hasContent
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
        width: frame.width + 6 + index * 6
        height: frame.height + 6 + index * 3
        radius: 6 + index * 3
        color: "#18000000"
      }
    }
    Rectangle {
      anchors.fill: parent; anchors.margins: -4
      radius: 5; color: "transparent"
      border.width: 2; border.color: root.accent
      visible: root.highlighted
    }
    Rectangle {
      anchors.fill: parent
      color: root.surfaceColor; radius: 6
      visible: !root.hasThumbnail
      Column {
        anchors.centerIn: parent; width: Math.max(0, parent.width - 24); spacing: 10
        Text {
          width: parent.width; text: root.appName; textFormat: Text.PlainText
          horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
          color: root.textColor; font.pixelSize: 18; font.bold: true
        }
        Text {
          width: parent.width; text: "No visible snapshot yet"; textFormat: Text.PlainText
          horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
          color: root.textColor; opacity: .6; font.pixelSize: 11
          visible: root.showTitle && frame.width > 100 && frame.height > 80
        }
      }
    }
    Image {
      id: snapshotImage
      anchors.fill: parent
      source: root.bitmapMode ? root.sharedCapture.imageSource : ""
      fillMode: Image.PreserveAspectFit; cache: false; smooth: true
      visible: root.bitmapMode && root.hasThumbnail
    }
    ShaderEffectSource {
      anchors.fill: parent
      sourceItem: !root.bitmapMode && root.sharedCapture ? root.sharedCapture.image || null : null
      hideSource: true
      live: root.live && root.hasThumbnail
      smooth: true
      visible: !root.bitmapMode && root.hasThumbnail
    }
    Rectangle {
      anchors { left: parent.left; top: parent.top; margins: 6 }
      width: Math.min(frame.width - 12, snapshotLabel.implicitWidth + 12); height: 20; radius: 4; color: "#c0202633"
      visible: root.bitmapMode && root.hasThumbnail && root.showTitle && frame.width > 120
      Text {
        id: snapshotLabel
        anchors.centerIn: parent
        width: parent.width - 12; elide: Text.ElideRight
        text: (root.sharedCapture && root.sharedCapture.previous ? "Previous snapshot" : "Snapshot") +
          (root.sharedCapture && root.sharedCapture.partial ? " · visible portion" : "")
        color: "white"; font.pixelSize: 10
      }
    }
    Rectangle {
      anchors.top: parent.bottom; anchors.topMargin: 10
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.max(0, Math.min(frame.width + 20, 360, title.implicitWidth + 22)); height: 26
      radius: 6; color: Qt.rgba(root.surfaceColor.r, root.surfaceColor.g, root.surfaceColor.b, .94)
      visible: root.showTitle
      Text {
        id: title
        anchors.centerIn: parent
        width: Math.max(0, parent.width - 22)
        text: root.label; textFormat: Text.PlainText
        elide: Text.ElideRight; color: root.textColor; font.pixelSize: 12
      }
    }
  }
}
