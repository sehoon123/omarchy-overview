pragma Singleton
import QtQuick

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
