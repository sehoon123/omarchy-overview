import QtQuick
import Quickshell.Wayland

CaptureStream {
  required property var modelData
  captureSource: modelData ? modelData.wayland : null
  factory: Component {
    ScreencopyView { paintCursor: false }
  }
}
