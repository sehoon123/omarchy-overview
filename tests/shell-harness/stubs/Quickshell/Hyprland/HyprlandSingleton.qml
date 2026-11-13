pragma Singleton
import QtQuick

QtObject {
  property var monitors: ({ values: [] })
  property var workspaces: ({ values: [] })
  readonly property QtObject toplevels: ToplevelModel {}
  property var focusedMonitor: null
  property var focusedWorkspace: null
  property var activeToplevel: null
  property var dispatched: []
  signal rawEvent(var event)
  function refreshMonitors() {}
  function refreshWorkspaces() {}
  function refreshToplevels() {}
  function dispatch(command) { dispatched = dispatched.concat([command]) }
}
