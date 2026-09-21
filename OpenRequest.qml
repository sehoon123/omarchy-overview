import QtQuick

// Qt-only request lifecycle. The process adapter is separate for offline tests.
//
// Protocol for consumers (shell.qml through OpenGuard):
//   begin(name) / request(name) -> true when a helper run started, false when
//     refused. One run at a time; the verdict arrives as completed(result).
//   cancel()                    -> abandons the current run. A late line or a
//     late exit can never complete an abandoned or timed-out run.
//   completed(result)           -> emitted exactly once per accepted begin().
//   processExited(exitCode, exitStatus) -> adapter callback. Both arguments are
//     optional; omitting them means "exited normally with no verdict".
//
// Refusal and retry contract (additive, consumed by shell.qml):
//   lastRefusal - why the most recent begin() returned false:
//     "output"   no output name was supplied; nothing here will change that.
//     "pending"  this run is still in flight; wait for completed().
//     "draining" the previous helper has not confirmed its exit yet.
//     ""         the most recent begin() was accepted (or a "draining" refusal
//                has since been answered by readyToBegin()).
//   canBegin    - true exactly when begin() would accept a non-empty name.
//   draining    - true while a helper is believed alive with no live run.
//   readyToBegin() - emitted once after a "draining" refusal, as soon as the
//     guard is free again (confirmed exit, or drainMs elapsed). A consumer that
//     still wants to open should retry begin() from this signal instead of
//     failing the open with a misleading reason.
//   drainMs     - upper bound on how long a stopped helper blocks the next run.
//     After it elapses the helper is assumed gone. If it does exit later, the
//     next run fails once with a generic reason and the guard is free again,
//     which is preferable to refusing every open for the rest of the session.
Item {
  id: flow
  property int timeoutMs: 700
  property int drainMs: 1500
  readonly property int maxReplyLength: 32768
  property bool pending: false
  property bool processActive: false
  readonly property bool draining: processActive && !pending
  readonly property bool canBegin: !pending && !processActive
  property string lastRefusal: ""
  property string outputName: ""
  property var reply: null
  signal startRequested(string name)
  signal stopRequested()
  signal completed(var result)
  signal readyToBegin()

  function begin(name) {
    if (!name) { lastRefusal = "output"; return false }
    if (pending) { lastRefusal = "pending"; return false }
    if (processActive) { lastRefusal = "draining"; return false }
    lastRefusal = ""
    outputName = name; reply = null; pending = true; processActive = true
    drain.stop(); deadline.restart(); startRequested(name)
    return true
  }
  function cancel() {
    pending = false; reply = null; deadline.stop()
    if (processActive) { stopRequested(); armDrain() }
  }
  // First valid reply wins: a duplicate, late, oversized, partial or non-object
  // line can never erase it, and only a JSON object counts as a verdict.
  function receive(data) {
    if (!pending || reply || typeof data !== "string") return
    if (data.length > maxReplyLength) return
    try {
      const parsed = JSON.parse(data)
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) reply = parsed
    } catch (error) {
      // A partial or non-JSON line proves nothing; keep waiting for the deadline.
    }
  }
  function processExited(exitCode, exitStatus) {
    const crashed = Number(exitStatus) === 1  // QProcess.CrashExit
    const code = (exitCode === undefined || exitCode === null) ? 0 : Number(exitCode)
    releaseProcess()
    finish(reply || { ok: false, reason: crashed ? "Preview helper stopped unexpectedly"
      : (code !== 0 ? "Preview helper could not run" : "Capture context unavailable") })
    notifyReady()
  }
  function finish(result) {
    if (!pending) return
    pending = false; reply = null; deadline.stop()
    completed(result)
  }
  // Internal: a stopped helper is only ever given one bounded drain window.
  function armDrain() { if (!drain.running) drain.restart() }
  function releaseProcess() { processActive = false; drain.stop() }
  function notifyReady() {
    if (pending || processActive || lastRefusal !== "draining") return
    lastRefusal = ""; readyToBegin()
  }
  Timer {
    id: deadline
    interval: flow.timeoutMs
    onTriggered: {
      // Invalidate before terminating: late stdout/exit cannot reopen the UI.
      flow.finish({ ok: false, reason: "Capture context check timed out" })
      if (flow.processActive) { flow.stopRequested(); flow.armDrain() }
    }
  }
  // Armed only after a stop request, so no run is in flight while it waits.
  Timer {
    id: drain
    interval: flow.drainMs
    onTriggered: { flow.releaseProcess(); flow.notifyReady() }
  }
}
