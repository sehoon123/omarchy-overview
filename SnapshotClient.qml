import QtQuick
import Quickshell.Io

// A separate, short-lived read-only helper must not block desktop transactions.
SnapshotRequest {
  id: client
  required property string helperPath
  function request(name) { return begin(name) }
  onStartRequested: helper.running = true
  onStopRequested: helper.running = false
  Process {
    id: helper
    command: ["python3", "-u", client.helperPath, client.outputName]
    stdout: SplitParser { onRead: data => client.receive(data) }
    // The helper deliberately emits no pixels or titles on stderr.
    onExited: client.processExited()
  }
}
