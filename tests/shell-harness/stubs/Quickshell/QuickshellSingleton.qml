pragma Singleton
import QtQuick

// The registries let a test play every party the shell talks to: the worker and
// the capture-context helper (processes), the IPC caller (ipcHandlers) and the
// compositor's capture streams (screencopies).
QtObject {
  property var envMap: ({})
  property var screens: []
  property var executed: []
  property var processes: []
  property var ipcHandlers: ({})
  property var screencopies: []
  function env(name) { return envMap[name] === undefined ? "" : envMap[name] }
  function shellPath(path) { return "/nonexistent-stub/" + path }
  function execDetached(args) { executed = executed.concat([args]) }
}
