import QtQuick
import "Layout.js" as OverviewLayout

Item {
  id: root
  property var windowInfo: null
  property var sharedCapture: null
  property bool live: true
  property bool highlighted: false
  property bool showTitle: true
  property string label: windowInfo ? (windowInfo.title || windowInfo.lastIpcObject.class || "Window") : ""
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
      color: root.surfaceColor
      visible: !root.hasThumbnail
      Text {
        anchors.centerIn: parent; width: Math.max(0, parent.width - 24)
        text: root.sharedCapture && root.sharedCapture.hasFrame ? "Refreshing preview…"
          : root.windowInfo && root.windowInfo.lastIpcObject ? String(root.windowInfo.lastIpcObject.class || "Window").split(".").pop() : "Window"
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
        color: root.textColor; opacity: .75; font.pixelSize: 18
      }
    }
    ShaderEffectSource {
      anchors.fill: parent
      sourceItem: root.sharedCapture ? root.sharedCapture.image : null
      hideSource: true
      live: root.live && root.hasThumbnail
      smooth: true
      visible: root.hasThumbnail
    }
    Rectangle {
      anchors.top: parent.bottom; anchors.topMargin: 10
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(360, title.implicitWidth + 22); height: 26
      radius: 6; color: Qt.rgba(root.surfaceColor.r, root.surfaceColor.g, root.surfaceColor.b, .94)
      visible: root.highlighted && root.showTitle
      Text {
        id: title
        anchors.centerIn: parent
        width: Math.min(338, implicitWidth)
        text: root.label; textFormat: Text.PlainText
        elide: Text.ElideRight; color: root.textColor; font.pixelSize: 12
      }
    }
  }
}
