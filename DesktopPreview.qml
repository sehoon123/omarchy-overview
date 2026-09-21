import QtQuick
import "Layout.js" as OverviewLayout

Item {
  id: root
  property var desktopId: 1
  property string label: "Desktop " + desktopId
  property var members: []
  property var captureFor: address => null
  property string wallpaper: ""
  property bool live: true
  property bool highlighted: false
  property bool hovered: false
  property bool dropTarget: false
  property bool canRemove: false
  property color accent: "#76b5ff"
  width: 148; height: 108
  // The model can be unset or hold a member that disappeared this turn; a throw in
  // this binding would take the whole strip (and the tile indices below) with it.
  readonly property var memberList: members && members.map ? members : []
  readonly property var miniLayout: OverviewLayout.arrange(
    memberList.map(w => OverviewLayout.aspectFor(w, w ? captureFor(w.address) : null)), 132, 68, true)
  property alias removeButton: removeCircle

  Rectangle {
    x: -3; y: -3; width: 154; height: 90; radius: 5
    color: "transparent"; border.width: root.dropTarget ? 3 : 2
    border.color: root.dropTarget ? "#91e2b1" : root.highlighted ? root.accent : root.hovered ? "#88ffffff" : "transparent"
  }
  Image {
    width: 148; height: 84; source: root.wallpaper
    sourceSize: Qt.size(296, 168); fillMode: Image.PreserveAspectCrop
    Rectangle { anchors.fill: parent; color: "#300b0e17" }
  }
  Repeater {
    model: root.memberList
    delegate: Rectangle {
      id: tile
      objectName: "desktopTile"
      required property var modelData
      required property int index
      readonly property var sharedCapture: modelData ? root.captureFor(modelData.address) : null
      readonly property var rect: root.miniLayout[index] || ({ x: 0, y: 0, width: 0, height: 0 })
      x: 8 + rect.x; y: 8 + rect.y; width: rect.width; height: rect.height
      color: "#cb282c37"
      Loader {
        anchors.fill: parent
        active: !!tile.sharedCapture && tile.sharedCapture.hasContent
        sourceComponent: ShaderEffectSource {
          objectName: "desktopTexture"
          sourceItem: tile.sharedCapture ? tile.sharedCapture.image || null : null
          // Quantised to a 64 px grid and clamped to the native source for the same
          // reason as WindowPreview.qml: the strip re-lays out whenever membership or
          // a capture aspect changes, and every textureSize change recreates the FBO.
          textureSize: Qt.size(Math.max(1, Math.min(sourceItem ? sourceItem.width : 1, Math.ceil(width * 2 / 64) * 64)),
                               Math.max(1, Math.min(sourceItem ? sourceItem.height : 1, Math.ceil(height * 2 / 64) * 64)))
          hideSource: true
          live: root.live && !!tile.sharedCapture && tile.sharedCapture.hasContent
          smooth: true; mipmap: true
        }
      }
    }
  }
  Text {
    objectName: "desktopLabel"
    y: 93; anchors.horizontalCenter: parent.horizontalCenter
    text: root.label; textFormat: Text.PlainText
    width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
    color: "#f0f1f5"; font.pixelSize: 12
    style: Text.Outline; styleColor: "#66000000"
  }
  Rectangle {
    id: removeCircle
    x: -10; y: -10; width: 22; height: 22; radius: 11
    color: "#e9eef5"
    visible: root.canRemove && root.hovered && !root.dropTarget
    Text { anchors.centerIn: parent; text: "×"; color: "#242a35"; font.pixelSize: 18 }
  }
}
