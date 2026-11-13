import QtQuick
import Quickshell

QtObject {
  id: handler
  property string target
  Component.onCompleted: {
    const handlers = Object.assign({}, Quickshell.ipcHandlers)
    handlers[target] = handler
    Quickshell.ipcHandlers = handlers
  }
}
