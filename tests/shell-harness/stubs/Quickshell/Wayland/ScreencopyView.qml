import QtQuick
import Quickshell

Item {
  id: view
  property var captureSource: null
  property bool live: false
  property bool paintCursor: true
  readonly property bool hasContent: !!captureSource
  readonly property size sourceSize: Qt.size(800, 600)
  signal stopped()
  Component.onCompleted: Quickshell.screencopies = Quickshell.screencopies.concat([view])
}
