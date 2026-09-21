import QtQuick
import Quickshell.Io

// Process adapter for BackendProtocol: one resident child, framed replies, never a
// replayed mutation. It holds no protocol state.
//
// tests/ must NEVER instantiate this component. It roots a Process that runs
// worker.py, and a request such as ["move", ...] or ["step", ...] reaches
// `hyprctl dispatch` through controller.py. The offline tests drive
// BackendProtocol directly (tests/tst_BackendClient.qml); autoStart is the
// additive belt-and-braces gate that keeps even an accidental instantiation from
// starting a process.
BackendProtocol {
  id: client
  required property string workerPath
  readonly property var processId: worker.processId
  onWriteRequested: text => worker.write(text)
  // The only restart path, gated so autoStart: false starts no process at all,
  // including after a worker loss.
  onStartRequested: if (client.autoStart) worker.running = true
  Process {
    id: worker
    command: ["python3", "-u", client.workerPath]
    stdinEnabled: true
    stdout: SplitParser { onRead: data => client.receive(data) }
    stderr: SplitParser { onRead: data => console.warn("Overview worker:", data) }
    onExited: client.processExited()
  }
  // The default autoStart is true, so the shell's resident worker still starts here.
  Component.onCompleted: if (client.autoStart) worker.running = true
}
