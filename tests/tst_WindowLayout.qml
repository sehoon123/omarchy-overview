import QtQuick
import QtTest
import ".."
import "../Layout.js" as Layout

Item {
  id: scene
  width: 2304; height: 900
  property var windows: []
  QtObject { id: first; property size sourceSize: Qt.size(800, 1000); property bool hasContent: false; property bool hasFrame: true; property var image: null }
  QtObject { id: second; property size sourceSize: Qt.size(950, 1000); property bool hasContent: false; property bool hasFrame: true; property var image: null }
  QtObject { id: third; property size sourceSize: Qt.size(1100, 1000); property bool hasContent: false; property bool hasFrame: true; property var image: null }
  function captureFor(address) { return ({ a: first, b: second, c: third })[address] }
  readonly property string layoutKey: JSON.stringify(windows.map(w => Layout.aspectFor(w, captureFor(w.address))))
  readonly property var placements: Layout.arrange(JSON.parse(layoutKey), width, height)
  Repeater {
    id: cards
    model: scene.windows
    delegate: WindowPreview {
      required property var modelData
      required property int index
      readonly property var rect: scene.placements[index] || ({ x: 0, y: 0, width: 0, height: 0 })
      x: rect.x; y: rect.y; width: rect.width; height: rect.height
      windowInfo: modelData; sharedCapture: scene.captureFor(modelData.address)
    }
  }
  TestCase {
    name: "OverviewWindowLayout"; when: windowShown
    function init() {
      scene.width = 2304; scene.height = 900
      first.sourceSize = Qt.size(800, 1000)
      second.sourceSize = Qt.size(950, 1000)
      third.sourceSize = Qt.size(1100, 1000)
      scene.windows = ["a", "b", "c"].map(address => ({ address: address, title: "Test window", lastIpcObject: { size: [1600, 1000] } }))
      wait(0)
    }
    function assertFitted() {
      for (let i = 0; i < cards.count; i++) {
        const surface = cards.itemAt(i).surface
        const point = surface.mapToItem(scene, 0, 0)
        const rect = scene.placements[i]
        fuzzyCompare(point.x, rect.x, .51, "Visible left edge must equal the packed cell")
        fuzzyCompare(point.y, rect.y, .51, "Visible top edge must equal the packed cell")
        fuzzyCompare(surface.width, rect.width, .01, "Visible width must equal the packed cell")
        fuzzyCompare(surface.height, rect.height, .01, "Visible height must equal the packed cell")
      }
    }
    function test_threeCapturedWindowsUseEqualVisibleGaps() {
      assertFitted()
      const surfaces = [0, 1, 2].map(i => cards.itemAt(i).surface)
      const points = surfaces.map(surface => surface.mapToItem(scene, 0, 0))
      for (let i = 1; i < 3; i++) {
        fuzzyCompare(points[i].y, points[0].y, .51)
        fuzzyCompare(points[i].x - points[i - 1].x - surfaces[i - 1].width, 44, 1)
      }
      fuzzyCompare(points[0].x, scene.width - points[2].x - surfaces[2].width, 1)
    }
    function test_lateCaptureResizeAndMonitorResizeStayFitted() {
      third.sourceSize = Qt.size(0, 0); wait(0); assertFitted()
      third.sourceSize = Qt.size(600, 1000); wait(0); assertFitted()
      second.sourceSize = Qt.size(2200, 1000); wait(0); assertFitted()
      scene.width = 1504; scene.height = 730; wait(0); assertFitted()
      const original = scene.windows
      scene.windows = [original[2], original[0]]; wait(0); assertFitted()
      scene.windows = original; wait(0); assertFitted()
    }
    function test_extremeButValidRatiosDoNotLeaveHoles() {
      first.sourceSize = Qt.size(100, 1000)
      third.sourceSize = Qt.size(8000, 1000)
      wait(0); assertFitted()
    }
  }
}
