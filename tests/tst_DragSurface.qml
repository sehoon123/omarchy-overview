import QtQuick
import QtTest
import ".."

Item {
  id: scene
  width: 640; height: 420
  // Stand-ins for the things a drop must never touch by itself. The input layer only
  // reports zones; every mutation is an explicit user action routed through shell.qml.
  Item { id: victim; objectName: "victim"; x: 20; y: 300; width: 60; height: 40 }
  Item { id: desktopItem; objectName: "desktopItem"; x: 320; y: 10; width: 120; height: 80 }
  property int mutations: 0
  // Overridable so malformed hit tests can be injected; null keeps the map below.
  property var zoneOverride: null
  function baseZone(x, y) {
    return x < 180 && y > 120 ? { kind: "window", key: "window:a", address: "abc", window: victim,
                                 activate: () => scene.mutations++, move: () => scene.mutations++ }
      : x > 300 && x < 480 && y < 100 ? { kind: "desktop", key: "desktop:2", id: 2, item: desktopItem,
                                         switchTo: () => scene.mutations++ }
      : { kind: "background", key: "background" }
  }
  DragSurface {
    id: surface
    anchors.fill: parent
    hitTest: (x, y) => scene.zoneOverride ? scene.zoneOverride(x, y) : scene.baseZone(x, y)
  }
  SignalSpy { id: clickSpy; target: surface; signalName: "clickedZone" }
  SignalSpy { id: dragSpy; target: surface; signalName: "droppedZone" }
  SignalSpy { id: startSpy; target: surface; signalName: "startedDrag" }
  SignalSpy { id: cancelSpy; target: surface; signalName: "cancelledDrag" }
  SignalSpy { id: updateSpy; target: surface; signalName: "updatedDrag" }
  SignalSpy { id: scrollSpy; target: surface; signalName: "scrollStrip" }
  TestCase {
    name: "OverviewDragSurface"
    when: windowShown
    function init() {
      // A failing expectation must not leave the button down for the next case.
      mouseRelease(surface, 0, 0)
      surface.cancelDrag(); clickSpy.clear(); dragSpy.clear(); startSpy.clear(); cancelSpy.clear()
      scene.zoneOverride = null
      scene.mutations = 0
      updateSpy.clear(); scrollSpy.clear()
      victim.x = 20; victim.y = 300; victim.width = 60; victim.height = 40
      desktopItem.x = 320; desktopItem.y = 10
    }
    function assertNothingMoved() {
      compare(scene.mutations, 0, "The input layer must never call into a zone")
      compare(victim.x, 20, "A drop must not move the window it reported")
      compare(victim.y, 300)
      compare(victim.width, 60)
      compare(victim.height, 40)
      compare(victim.parent, scene, "A drop must not reparent anything")
      compare(desktopItem.x, 320, "A drop must not move the desktop it reported")
      compare(desktopItem.y, 10)
      compare(surface.dragging, false, "The grab must be released after every gesture")
      compare(surface.pressedZone, null)
      compare(surface.drag.target, null, "The MouseArea itself never repositions an item")
      compare(surface.drag.active, false)
    }
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
    // ---- the drag threshold -------------------------------------------------
    function test_dragThresholdBoundaryIsExact() {
      compare(surface.threshold, 10)
      // One pixel short of the threshold is still a click on the same zone.
      mousePress(surface, 80, 200); mouseMove(surface, 80, 209, 20)
      compare(surface.dragging, false, "9 px must not start a drag")
      compare(startSpy.count, 0)
      mouseRelease(surface, 80, 209)
      compare(clickSpy.count, 1); compare(dragSpy.count, 0)
      // Exactly the threshold starts one, and only one, drag.
      init()
      mousePress(surface, 80, 200); mouseMove(surface, 80, 210, 20)
      compare(surface.dragging, true, "10 px must start a drag")
      compare(startSpy.count, 1)
      compare(startSpy.signalArguments[0][0].address, "abc")
      mouseMove(surface, 80, 215, 20)
      compare(startSpy.count, 1, "A drag starts once, no matter how far it travels")
      mouseRelease(surface, 80, 215)
      compare(dragSpy.count, 1); compare(clickSpy.count, 0)
      // The threshold is radial: 7 px on both axes is 9.9 px away, 8 px is 11.3 px.
      init()
      mousePress(surface, 80, 200); mouseMove(surface, 87, 207, 20)
      compare(surface.dragging, false)
      mouseRelease(surface, 87, 207)
      compare(clickSpy.count, 1)
      init()
      mousePress(surface, 80, 200); mouseMove(surface, 88, 208, 20)
      compare(surface.dragging, true)
      mouseRelease(surface, 88, 208)
      compare(dragSpy.count, 1)
      // Only draggable kinds ever reach the threshold at all.
      init()
      mousePress(surface, 250, 250); mouseMove(surface, 600, 300, 20)
      compare(surface.dragging, false, "The background is not draggable")
      compare(startSpy.count, 0)
      mouseRelease(surface, 600, 300)
      // A press and release on the same non-draggable zone stays the dismiss click
      // shell.qml routes to closeOverview(); it moves nothing.
      compare(clickSpy.count, 1)
      compare(clickSpy.signalArguments[0][0].kind, "background")
      compare(dragSpy.count, 0)
      assertNothingMoved()
    }
    function test_pressThatSlidesOffItsZoneDoesNothing() {
      // Below the threshold and no longer over the pressed zone: not a click, not a drop.
      mousePress(surface, 178, 200); mouseMove(surface, 182, 200, 20); mouseRelease(surface, 182, 200)
      compare(clickSpy.count, 0, "A click must land on the zone it started on")
      compare(dragSpy.count, 0)
      compare(startSpy.count, 0)
      assertNothingMoved()
    }
    // ---- cancelling ---------------------------------------------------------
    function test_cancelIsIdempotentAndOnlyReportsARealDrag() {
      surface.cancelDrag()
      compare(cancelSpy.count, 0, "Cancelling when idle reports nothing")
      mousePress(surface, 80, 200)
      surface.cancelDrag()
      compare(cancelSpy.count, 0, "A press that never became a drag reports nothing")
      compare(surface.pressedZone, null, "but the press is forgotten")
      mouseRelease(surface, 80, 200)
      compare(clickSpy.count, 0); compare(dragSpy.count, 0)
      // A real drag, cancelled twice, reports exactly one cancellation.
      init()
      mousePress(surface, 80, 200); mouseMove(surface, 120, 160, 20)
      compare(surface.dragging, true)
      surface.cancelDrag(); surface.cancelDrag()
      compare(cancelSpy.count, 1)
      compare(surface.dragging, false)
      compare(surface.cursorShape, Qt.OpenHandCursor, "The closed hand goes away with the drag")
      verify(surface.cursorShape !== Qt.ClosedHandCursor)
      mouseRelease(surface, 360, 50)
      compare(dragSpy.count, 0, "A cancelled drag never drops")
      compare(clickSpy.count, 0)
      assertNothingMoved()
      // The surface is not wedged: the next gesture behaves normally.
      mouseClick(surface, 80, 200)
      compare(clickSpy.count, 1)
      compare(clickSpy.signalArguments[0][0].kind, "window")
    }
    // ---- drops that are not over a zone ------------------------------------
    function test_dropOutsideAnyZoneIsAnExplicitBackgroundTarget() {
      const spots = [[-40, -40], [5000, 5000], [500, 250], [639, 419]]
      for (let i = 0; i < spots.length; i++) {
        init()
        mousePress(surface, 80, 200); mouseMove(surface, 120, 160, 20)
        compare(surface.dragging, true)
        mouseRelease(surface, spots[i][0], spots[i][1])
        compare(dragSpy.count, 1, "A drop off every zone is still reported once")
        compare(dragSpy.signalArguments[0][0].address, "abc", "with the source it started from")
        compare(dragSpy.signalArguments[0][1].kind, "background", "and an explicit background target")
        compare(clickSpy.count, 0, "A drop is never also a click")
        assertNothingMoved()
      }
      // Dropping a card back onto itself reports a window-to-window drop, which
      // shell.qml's finishDrag ignores, and never an activating click.
      init()
      mousePress(surface, 80, 200); mouseMove(surface, 100, 220, 20); mouseRelease(surface, 100, 220)
      compare(dragSpy.count, 1)
      compare(dragSpy.signalArguments[0][0].key, "window:a")
      compare(dragSpy.signalArguments[0][1].key, "window:a")
      compare(clickSpy.count, 0, "Dragging a card onto itself must not activate it")
      assertNothingMoved()
      // Dropping a desktop on itself is reported too; finishDrag needs distinct ids.
      init()
      mousePress(surface, 320, 50); mouseMove(surface, 340, 70, 20); mouseRelease(surface, 340, 70)
      compare(dragSpy.count, 1)
      compare(dragSpy.signalArguments[0][0].id, 2)
      compare(dragSpy.signalArguments[0][1].id, 2)
      compare(clickSpy.count, 0)
      assertNothingMoved()
    }
    function test_noDropPathMovesAnythingByItself() {
      const gestures = [[80, 200, 360, 50], [80, 200, 500, 250], [80, 200, -20, -20],
                        [320, 50, 80, 200], [320, 50, 360, 60], [250, 250, 360, 50]]
      for (let i = 0; i < gestures.length; i++) {
        init()
        const g = gestures[i]
        mousePress(surface, g[0], g[1])
        mouseMove(surface, g[0] + 20, g[1] + 20, 20)
        mouseMove(surface, g[2], g[3], 20)
        mouseRelease(surface, g[2], g[3])
        assertNothingMoved()
      }
      // The zone object handed back on a drop is the object the hit test produced,
      // untouched: the receiver decides, the surface only carries it.
      init()
      mousePress(surface, 80, 200)
      const pressed = surface.pressedZone
      compare(pressed.kind, "window")
      mouseMove(surface, 120, 160, 20)
      compare(startSpy.signalArguments[0][0], pressed, "The drag starts from the pressed zone itself")
      mouseRelease(surface, 360, 50)
      compare(dragSpy.signalArguments[0][0], pressed, "and drops with that same object")
      compare(pressed.address, "abc")
      compare(pressed.window, victim)
      compare(pressed.key, "window:a")
      assertNothingMoved()
    }
    function test_onlyTheLeftButtonDrivesTheOverlay() {
      compare(surface.acceptedButtons, Qt.LeftButton)
      mouseClick(surface, 80, 200, Qt.RightButton)
      compare(clickSpy.count, 0, "A right click must not choose a window")
      compare(dragSpy.count, 0)
      mouseClick(surface, 80, 200, Qt.MiddleButton)
      compare(clickSpy.count, 0, "Neither must a middle click")
      mousePress(surface, 80, 200, Qt.RightButton); mouseMove(surface, 360, 50, 20)
      compare(surface.dragging, false, "A right drag must not move a window")
      mouseRelease(surface, 360, 50, Qt.RightButton)
      compare(dragSpy.count, 0)
      assertNothingMoved()
      mouseClick(surface, 80, 200)
      compare(clickSpy.count, 1, "The left button still works")
    }
    // ---- the wheel over the desktop strip -----------------------------------
    function test_wheelOnlyScrollsTheStripBand() {
      mouseWheel(surface, 100, 50, 0, 120)
      compare(scrollSpy.count, 1, "A wheel over the strip scrolls it")
      compare(scrollSpy.signalArguments[0][0], -120, "and reports the inverted delta")
      scrollSpy.clear()
      mouseWheel(surface, 100, 50, 0, -120)
      compare(scrollSpy.signalArguments[0][0], 120)
      scrollSpy.clear()
      // A horizontal wheel or trackpad swipe takes precedence over the vertical one.
      mouseWheel(surface, 100, 50, 40, 120)
      compare(scrollSpy.count, 1)
      compare(scrollSpy.signalArguments[0][0], -40)
      scrollSpy.clear()
      // Below the strip band the wheel is left alone for the stage.
      const below = [150, 151, 200, 419]
      for (let i = 0; i < below.length; i++) {
        mouseWheel(surface, 100, below[i], 0, 120)
        compare(scrollSpy.count, 0, "A wheel at y=" + below[i] + " is not the strip's")
      }
      mouseWheel(surface, 100, 149, 0, 120)
      compare(scrollSpy.count, 1, "y=149 is the last strip row")
      scrollSpy.clear()
      // The wheel is not a gesture: it never presses, drags, drops or clicks.
      compare(surface.dragging, false)
      compare(clickSpy.count, 0); compare(dragSpy.count, 0); compare(startSpy.count, 0)
      assertNothingMoved()
    }
    function test_wheelDuringADragKeepsTheDrag() {
      mousePress(surface, 80, 200); mouseMove(surface, 120, 160, 20)
      compare(surface.dragging, true)
      mouseWheel(surface, 100, 50, 0, 120)
      compare(scrollSpy.count, 1)
      compare(surface.dragging, true, "Scrolling the strip must not cancel the drag")
      compare(cancelSpy.count, 0)
      compare(dragSpy.count, 0)
      // shell.qml calls refreshHover() after scrolling; it re-reports the drag target
      // from the current pointer position and moves nothing.
      updateSpy.clear()
      surface.refreshHover()
      compare(updateSpy.count, 1)
      compare(surface.dragging, true)
      mouseRelease(surface, 360, 50)
      compare(dragSpy.count, 1)
      assertNothingMoved()
    }
    // ---- a hit test that cannot name a zone ---------------------------------
    function test_malformedZonesReadAsTheBackground() {
      const bad = [() => null, () => undefined, () => ({}), () => 7, () => "desktop:2",
                   () => ({ kind: "window" }), () => ({ key: "window:a" })]
      for (let i = 0; i < bad.length; i++) {
        init()
        scene.zoneOverride = bad[i]
        mouseMove(surface, 80, 200, 20)
        compare(surface.hovered.kind, "background", "A zone with no shape must read as the background")
        compare(surface.hovered.key, "background")
        compare(surface.cursorShape, Qt.ArrowCursor)
        mousePress(surface, 80, 200)
        compare(surface.pressedZone.kind, "background")
        mouseMove(surface, 160, 260, 20)
        compare(surface.dragging, false, "The background is never draggable, however it was reported")
        mouseRelease(surface, 160, 260)
        compare(dragSpy.count, 0)
        compare(clickSpy.count, 1)
        compare(clickSpy.signalArguments[0][0].kind, "background", "and shell.qml gets a kind it can route")
        assertNothingMoved()
      }
      // A zone that is merely unknown to shell.qml is still passed through verbatim.
      init()
      scene.zoneOverride = () => ({ kind: "future", key: "future:1" })
      mouseClick(surface, 80, 200)
      compare(clickSpy.count, 1)
      compare(clickSpy.signalArguments[0][0].kind, "future")
      compare(surface.cursorShape, Qt.ArrowCursor)
      assertNothingMoved()
    }
    function test_aThrowingHitTestNeverLatchesTheGrab() {
      mousePress(surface, 80, 200); mouseMove(surface, 120, 160, 20)
      compare(surface.dragging, true)
      scene.zoneOverride = () => { throw new Error("zones are unavailable") }
      ignoreWarning(new RegExp("zones are unavailable"))
      mouseRelease(surface, 360, 50)
      compare(surface.dragging, false, "A hit test that throws must not leave the overlay in a drag")
      compare(surface.pressedZone, null, "or holding a stale press")
      compare(dragSpy.count, 0, "The drop is lost, but nothing is fabricated")
      compare(clickSpy.count, 0)
      assertNothingMoved()
      // And the surface still works once the hit test recovers.
      scene.zoneOverride = null
      mouseClick(surface, 80, 200)
      compare(clickSpy.count, 1)
      compare(clickSpy.signalArguments[0][0].kind, "window")
    }
  }
}
