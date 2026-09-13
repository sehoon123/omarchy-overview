import QtQuick
import Quickshell.Wayland

FrameCache {
  id: producer
  required property var modelData
  readonly property var ipc: modelData && modelData.lastIpcObject ? modelData.lastIpcObject : ({})
  contentTag: modelData ? JSON.stringify([modelData.title || "", ipc.size || []]) : ""
  captureSource: modelData && modelData.workspace && modelData.workspace.id > 0 ? modelData.wayland || null : null
  readonly property real aspect: sourceSize && sourceSize.height > 0 ? sourceSize.width / sourceSize.height
    : ipc.size && ipc.size[1] > 0 ? ipc.size[0] / ipc.size[1] : 1.6
  x: -10000
  width: Math.min(1100, 1100 * aspect)
  height: width / Math.max(.01, aspect)
  factory: Component {
    ScreencopyView {
      width: producer.width; height: producer.height
      paintCursor: false
    }
  }
}
