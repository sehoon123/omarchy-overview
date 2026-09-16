import QtQuick
import Quickshell.Io

// One resident child, request IDs and framed replies; never replay mutations.
Item {
  id: client
  required property string workerPath
  property bool ready: false
  property int sequence: 0
  property var pending: ({})
  property int restarts: 0
  property int completedCount: 0
  property real lastElapsedMs: 0
  readonly property var processId: worker.processId
  signal completed(int ticket, var result)
  signal frameNeeded(int ticket, string address)

  function send(packet) { worker.write(JSON.stringify(packet) + "\n") }
  function request(args, cover, monitor) {
    if (!ready || Object.keys(pending).length) return 0
    const id = ++sequence
    pending = Object.assign({}, pending, { [id]: args[0] })
    send({ type: "request", id: id, args: args, cover: cover || {}, monitor: monitor || "" })
    return id
  }
  function cancel(id) { if (ready && pending[id]) send({ type: "cancel", id: id }) }
  function frameReady(id) { if (ready && pending[id] === "prime") send({ type: "frame", id: id }) }
  function receive(text) {
    let packet
    try { packet = JSON.parse(text) } catch (error) { console.warn("Invalid worker reply"); return }
    if (packet.event === "ready" && packet.protocol === 1) { ready = true; return }
    if (!pending[packet.id]) return  // late/duplicate replies cannot affect a new request
    if (packet.event === "frame-needed") { frameNeeded(packet.id, packet.address); return }
    const next = Object.assign({}, pending); delete next[packet.id]; pending = next
    completedCount++; lastElapsedMs = packet.elapsedMs || 0
    completed(packet.id, packet)
  }
  Process {
    id: worker
    command: ["python3", "-u", client.workerPath]
    stdinEnabled: true
    stdout: SplitParser { onRead: data => client.receive(data) }
    stderr: SplitParser { onRead: data => console.warn("Overview worker:", data) }
    onExited: {
      client.ready = false
      const lost = client.pending; client.pending = ({})
      for (const id in lost) client.completed(Number(id), { ok: false, error: "Overview worker stopped; action was not replayed" })
      client.restarts++
      if (client.restarts <= 5) restartTimer.restart()
    }
  }
  Timer {
    id: restartTimer
    interval: Math.min(5000, 250 * Math.pow(2, client.restarts))
    onTriggered: worker.running = true
  }
  Component.onCompleted: worker.running = true
}
