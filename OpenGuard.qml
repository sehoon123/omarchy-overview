import QtQuick
import Quickshell.Io

// Check lock/output state without invoking any capture API or desktop action.
OpenRequest {
  id: client
  required property string helperPath
  function request(name) { return begin(name) }
  onStartRequested: helper.running = true
  onStopRequested: helper.running = false
  Process {
    id: helper
    command: ["python3", "-u", client.helperPath, client.outputName]
    stdout: SplitParser { onRead: data => client.receive(data) }
    // Metadata-only protocol; the helper never handles window pixels or titles.
    onExited: client.processExited()
  }
}
