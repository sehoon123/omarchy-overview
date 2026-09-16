import QtQuick
import Quickshell.Wayland
import "OverviewLogic.js" as Logic
import "Layout.js" as OverviewLayout

FrameCache {
  id: producer
  required property var modelData
  readonly property var ipc: modelData && modelData.lastIpcObject ? modelData.lastIpcObject : ({})
  contentTag: modelData ? JSON.stringify([modelData.title || "", ipc.size || []]) : ""
  captureSource: modelData && Logic.workspaceKey(modelData.workspace) ? modelData.wayland || null : null
  readonly property real aspect: OverviewLayout.aspectFor(modelData, producer)
  x: -10000
  width: Math.min(1100, 1100 * aspect)
  height: width / aspect
  factory: Component {
    ScreencopyView {
      width: producer.width; height: producer.height
      paintCursor: false
    }
  }
}
