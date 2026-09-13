import QtQuick

// One stable mouse grab for the entire overlay. Thumbnail delegates may be
// recreated when a hover previews another desktop, without cancelling a drag.
MouseArea {
  id: input
  hoverEnabled: true
  acceptedButtons: Qt.LeftButton
  preventStealing: true
  property var hitTest: (x, y) => ({ kind: "background", key: "background" })
  property var hovered: ({ kind: "background", key: "background" })
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
  function refreshHover() {
    hovered = hitTest(mouseX, mouseY)
    if (dragging) updatedDrag(mouseX, mouseY, hovered)
  }

  cursorShape: dragging ? Qt.ClosedHandCursor
    : hovered.kind === "window" || hovered.kind === "desktop" ? Qt.OpenHandCursor
    : ["add", "remove", "exit", "undo", "all"].indexOf(hovered.kind) >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
  onPressed: mouse => {
    pressedZone = hitTest(mouse.x, mouse.y)
    pressPoint = Qt.point(mouse.x, mouse.y)
  }
  onPositionChanged: mouse => {
    hovered = hitTest(mouse.x, mouse.y)
    if (pressedZone && !dragging && ["window", "desktop"].indexOf(pressedZone.kind) >= 0 &&
        Math.hypot(mouse.x - pressPoint.x, mouse.y - pressPoint.y) >= threshold) {
      dragging = true
      startedDrag(pressedZone, mouse.x, mouse.y)
    }
    if (dragging) updatedDrag(mouse.x, mouse.y, hovered)
  }
  onReleased: mouse => {
    const source = pressedZone
    const target = hitTest(mouse.x, mouse.y)
    const wasDragging = dragging
    dragging = false
    pressedZone = null
    if (wasDragging) droppedZone(source, target)
    else if (source && source.key === target.key) clickedZone(target, mouse.modifiers)
  }
  onCanceled: cancelDrag()
  onExited: if (!dragging) hovered = ({ kind: "background", key: "background" })
  onWheel: wheel => {
    if (wheel.y < 150) {
      scrollStrip(-(wheel.angleDelta.x || wheel.angleDelta.y))
      wheel.accepted = true
    } else wheel.accepted = false
  }
}
