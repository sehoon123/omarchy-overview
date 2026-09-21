import QtQuick

// Worker protocol without a process: request framing, reply routing, worker-loss
// recovery and restart backoff. The process adapter is BackendClient.qml, which
// is the component the shell instantiates; this half holds all of the state and
// is what the offline tests drive. The split exists because `import Quickshell.Io`
// cannot be resolved outside the quickshell binary (the plugin is linked into
// it), so a component that roots a Process can never be loaded by qmltestrunner -
// exactly as OpenRequest.qml is split from OpenGuard.qml.
//
// Protocol for consumers (shell.qml through BackendClient):
//   request(args, cover, monitor) -> ticket id, or 0 when the client is not ready
//     or a reply is still outstanding. One request at a time.
//   completed(ticket, result)     -> emitted exactly once per accepted ticket:
//     from the matching reply, from a worker loss (ok: false), or from the reply
//     watchdog (ok: false). A request is NEVER re-sent, so a mutating action can
//     never be replayed.
//   send(packet)                  -> frames one packet for the worker's stdin.
//   receive(text)                 -> adapter callback for one stdout line. Only a
//     JSON object counts; anything else is dropped without throwing.
//   processExited()               -> adapter callback: the worker is gone.
//   ready                         -> set only by the {"event":"ready","protocol":1}
//     handshake and cleared by a worker loss. No request is framed before it, so
//     a stale or future protocol is never spoken.
//
// Adapter interface (additive, consumed by BackendClient.qml):
//   writeRequested(text) - the adapter writes this to the worker's stdin.
//   startRequested()     - the adapter starts the worker again after a loss.
//   autoStart            - when false the adapter starts no process at all.
//   restartDelayMs       - backoff before the next start request.
//   restarting           - a start request is scheduled.
//   cancelRestart()      - drop a scheduled start request (teardown, tests).
//   replyTimeoutMs       - last-resort watchdog; see the Timer at the bottom.
Item {
  id: flow
  // Consumed by BackendClient.qml, which gates BOTH its Component.onCompleted
  // and its onStartRequested on it. The default MUST stay true: the shell relies
  // on the resident worker starting with it. Offline tests set it to false so no
  // process can ever be started, not even after a simulated worker loss.
  property bool autoStart: true
  property bool ready: false
  property int sequence: 0
  property var pending: ({})
  // Cumulative worker losses, reported as `workerRestarts` by the IPC status and
  // never reset by a later handshake, so the cap below is a per-session ceiling
  // rather than a consecutive-failure one.
  property int restarts: 0
  readonly property int maxRestarts: 5
  property int completedCount: 0
  property real lastElapsedMs: 0
  // Last-resort ceiling for one request (AUDIT.md F-08 residual, F-36 client
  // half). A worker that is wedged but alive never reports an exit, so without
  // this the ticket stays pending, the shell's `busy` latches for the rest of the
  // session and shutdown blocks. It is NOT a latency promise: desktop actions are
  // allowed to be slow, so the interval sits far above any real transaction, the
  // worker is left running, and its arguments are never re-sent.
  property int replyTimeoutMs: 20000
  property int restartDelayMs: Math.min(5000, 250 * Math.pow(2, flow.restarts))
  readonly property bool restarting: restartTimer.running
  readonly property bool outstanding: Object.keys(flow.pending).length > 0
  signal completed(int ticket, var result)
  signal writeRequested(string text)
  signal startRequested

  function send(packet) { writeRequested(JSON.stringify(packet) + "\n") }
  function request(args, cover, monitor) {
    if (!ready || Object.keys(pending).length) return 0
    const id = ++sequence
    pending = Object.assign({}, pending, { [id]: args[0] })
    watchdog.restart()
    send({ type: "request", id: id, args: args, cover: cover || {}, monitor: monitor || "" })
    return id
  }
  function receive(text) {
    let packet
    if (typeof text !== "string") return
    try { packet = JSON.parse(text) } catch (error) { console.warn("Invalid worker reply"); return }
    // A line that is not a JSON object is not a reply; `null` in particular must
    // not throw on the property reads below.
    if (!packet || typeof packet !== "object" || Array.isArray(packet)) return
    if (packet.event === "ready" && packet.protocol === 1) { ready = true; return }
    if (!pending[packet.id]) return  // late/duplicate/unknown replies cannot affect a new request
    const next = Object.assign({}, pending); delete next[packet.id]; pending = next
    if (!Object.keys(pending).length) watchdog.stop()
    completedCount++; lastElapsedMs = packet.elapsedMs || 0
    completed(packet.id, packet)
  }
  function processExited() {
    ready = false
    failPending("Overview worker stopped; action was not replayed")
    restarts++
    if (restarts <= maxRestarts) restartTimer.restart()
    else restartTimer.stop()
  }
  // Internal: fail every outstanding ticket. The arguments are dropped here, so
  // no path can re-send a create/move/switch/step/reorder/remove/undo.
  function failPending(message) {
    watchdog.stop()
    const lost = pending; pending = ({})
    for (const id in lost) completed(Number(id), { ok: false, error: message })
  }
  function cancelRestart() { restartTimer.stop() }
  Timer {
    id: restartTimer
    interval: flow.restartDelayMs
    // A request, not an action: this component roots no process. The adapter
    // decides whether to honour it (BackendClient.qml gates it on autoStart).
    onTriggered: flow.startRequested()
  }
  Timer {
    id: watchdog
    interval: flow.replyTimeoutMs
    onTriggered: flow.failPending("The desktop action did not answer; it was not repeated")
  }
}
