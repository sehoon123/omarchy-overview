import QtQuick
import QtTest
import ".."

Item {
  width: 640; height: 420
  DragSurface {
    id: surface
    anchors.fill: parent
    hitTest: (x, y) => x < 180 && y > 120 ? { kind: "window", key: "window:a", address: "abc" }
      : x > 300 && x < 480 && y < 100 ? { kind: "desktop", key: "desktop:2", id: 2 }
      : { kind: "background", key: "background" }
  }
  SignalSpy { id: clickSpy; target: surface; signalName: "clickedZone" }
  SignalSpy { id: dragSpy; target: surface; signalName: "droppedZone" }
  SignalSpy { id: startSpy; target: surface; signalName: "startedDrag" }
  SignalSpy { id: cancelSpy; target: surface; signalName: "cancelledDrag" }
  TestCase {
    name: "OverviewDragSurface"
    when: windowShown
    function init() { surface.cancelDrag(); clickSpy.clear(); dragSpy.clear(); startSpy.clear(); cancelSpy.clear() }
    function test_clickDoesNotMove() {
      mouseClick(surface, 80, 200)
      compare(clickSpy.count, 1); compare(dragSpy.count, 0)
      compare(clickSpy.signalArguments[0][0].kind, "window")
    }
    function test_dragWindowToDesktop() {
      mousePress(surface, 80, 200)
      mouseMove(surface, 120, 160, 20)
      compare(surface.dragging, true)
      mouseMove(surface, 360, 50, 20)
      mouseRelease(surface, 360, 50)
      compare(dragSpy.count, 1); compare(clickSpy.count, 0)
      compare(dragSpy.signalArguments[0][0].address, "abc")
      compare(dragSpy.signalArguments[0][1].id, 2)
      compare(surface.dragging, false)
    }
    function test_cancelDoesNotClickOrDrop() {
      mousePress(surface, 80, 200); mouseMove(surface, 120, 160, 20)
      surface.cancelDrag(); mouseRelease(surface, 360, 50)
      compare(cancelSpy.count, 1); compare(dragSpy.count, 0); compare(clickSpy.count, 0)
    }
    function test_invalidDropKeepsTargetExplicit() {
      mousePress(surface, 80, 200); mouseMove(surface, 500, 250, 20); mouseRelease(surface, 500, 250)
      compare(dragSpy.count, 1); compare(dragSpy.signalArguments[0][1].kind, "background")
      compare(clickSpy.count, 0)
    }
    function test_smallMotionStillClick() {
      mousePress(surface, 80, 200); mouseMove(surface, 82, 202, 20); mouseRelease(surface, 82, 202)
      compare(clickSpy.count, 1); compare(startSpy.count, 0)
    }
  }
}
