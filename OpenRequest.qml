import QtQuick

// Qt-only request lifecycle. The process adapter is separate for offline tests.
Item {
  id: flow
  property int timeoutMs: 700
  property bool pending: false
  property bool processActive: false
  property string outputName: ""
  property var reply: null
  signal startRequested(string name)
  signal stopRequested()
  signal completed(var result)

  function begin(name) {
    if (pending || processActive || !name) return false
    outputName = name; reply = null; pending = true; processActive = true
    deadline.restart(); startRequested(name)
    return true
  }
  function cancel() {
    pending = false; reply = null; deadline.stop()
    if (processActive) stopRequested()
  }
  function receive(data) {
    if (!pending) return
    if (data.length > 32768) { reply = null; return }
    try { reply = JSON.parse(data) } catch (error) { reply = null }
  }
  function processExited() {
    processActive = false
    finish(reply || { ok: false, reason: "Capture context unavailable" })
  }
  function finish(result) {
    if (!pending) return
    pending = false; reply = null; deadline.stop()
    completed(result)
  }
  Timer {
    id: deadline
    interval: flow.timeoutMs
    onTriggered: {
      // Invalidate before terminating: late stdout/exit cannot reopen the UI.
      flow.finish({ ok: false, reason: "Capture context check timed out" })
      if (flow.processActive) flow.stopRequested()
    }
  }
}
