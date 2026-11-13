import QtQuick
import Quickshell

QtObject {
  id: process
  property var command: []
  property bool running: false
  property bool stdinEnabled: false
  property QtObject stdout: null
  property QtObject stderr: null
  property var processId: 0
  property var written: []
  signal exited(int exitCode, int exitStatus)
  function write(text) { written = written.concat([text]) }
  Component.onCompleted: Quickshell.processes = Quickshell.processes.concat([process])
}
