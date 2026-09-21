import QtQuick

// One stable mouse grab for the entire overlay. Thumbnail delegates may be
// recreated when a hover previews another desktop, without cancelling a drag.
MouseArea {
  id: input
  hoverEnabled: true
  acceptedButtons: Qt.LeftButton
  preventStealing: true
  // The hit test is injected (shell.qml:973 -> zones()); a zone it cannot name must
  // read as the background, never as a missing object every binding here dereferences
  // (cursorShape, shell.qml:984-990) and never as a fabricated drop target.
  readonly property var noZone: ({ kind: "background", key: "background" })
  property var hitTest: (x, y) => noZone
  property var hovered: noZone
  property var pressedZone: null
  property point pressPoint: Qt.point(0, 0)
  property bool dragging: false
  property real threshold: 10
  signal clickedZone(var zone, int modifiers)
  signal startedDrag(var source, real x, real y)
  signal updatedDrag(real x, real y, var target)
  signal droppedZone(var source, var target)
  signal cancelledDrag()
  signal scrollStrip(real delta)

  function cancelDrag() {
    if (dragging) cancelledDrag()
    dragging = false
    pressedZone = null
  }
  function probe(x, y) {
    const zone = hitTest(x, y)
    return zone && zone.kind !== undefined && zone.key !== undefined ? zone : noZone
  }
  function refreshHover() {
    hovered = probe(mouseX, mouseY)
    if (dragging) updatedDrag(mouseX, mouseY, hovered)
  }

  cursorShape: dragging ? Qt.ClosedHandCursor
    : hovered.kind === "window" || hovered.kind === "desktop" ? Qt.OpenHandCursor
    : ["add", "remove", "exit", "undo", "all"].indexOf(hovered.kind) >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
  onPressed: mouse => {
    pressedZone = probe(mouse.x, mouse.y)
    pressPoint = Qt.point(mouse.x, mouse.y)
  }
  onPositionChanged: mouse => {
    hovered = probe(mouse.x, mouse.y)
    if (pressedZone && !dragging && ["window", "desktop"].indexOf(pressedZone.kind) >= 0 &&
        Math.hypot(mouse.x - pressPoint.x, mouse.y - pressPoint.y) >= threshold) {
      dragging = true
      startedDrag(pressedZone, mouse.x, mouse.y)
    }
    if (dragging) updatedDrag(mouse.x, mouse.y, hovered)
  }
  // The grab is released before the zone is resolved: a hit test that throws may cost
  // this one drop, but it must never stay latched in a drag with the ghost on screen.
  onReleased: mouse => {
    const source = pressedZone
    const wasDragging = dragging
    dragging = false
    pressedZone = null
    const target = probe(mouse.x, mouse.y)
    if (wasDragging) droppedZone(source, target)
    else if (source && source.key === target.key) clickedZone(target, mouse.modifiers)
  }
  onCanceled: cancelDrag()
  onExited: if (!dragging) hovered = noZone
  onWheel: wheel => {
    if (wheel.y < 150) {
      scrollStrip(-(wheel.angleDelta.x || wheel.angleDelta.y))
      wheel.accepted = true
    } else wheel.accepted = false
  }
}
