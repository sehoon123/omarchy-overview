import QtQuick

// An event-driven, lower-priority viewport lease. Never shares UI action state.
Item {
  id: scheduler
  required property var bank
  required property var backend
  property var windows: []
  property bool shown: false
  property bool covered: false
  property bool suspended: false
  property bool foregroundBusy: false
  property int workspace: 0
  property int monitor: -1
  property var attempted: ({})
  property int ticket: 0
  property var watched: null
  property int wantedGeneration: 0
  readonly property bool busy: ticket !== 0
  readonly property bool allowed: shown && covered && !suspended && !foregroundBusy && backend.ready
  readonly property var candidates: windows.filter(w => {
    const source = bank.lookup(w.address)
    return source && source.needsRefresh && w.workspace && w.workspace.id === workspace &&
      attempted[w.address] !== source.contentTag
  })
  signal settled()

  onShownChanged: {
    if (shown) { attempted = ({}); schedule() }
    else cancel()
  }
  onAllowedChanged: { if (!allowed) cancel(); schedule() }
  onCandidatesChanged: schedule()
  onBusyChanged: schedule()
  function schedule() {
    if (allowed && !busy && candidates.length && !startTimer.running) startTimer.start()
  }
  function cancel() { if (ticket) backend.cancel(ticket) }
  function startNext() {
    if (!allowed || busy || !candidates.length) return
    const w = candidates[0], source = bank.lookup(w.address)
    ticket = backend.request(["prime", w.address], { visible: covered && shown, workspace: workspace, monitor: monitor })
    if (ticket) attempted = Object.assign({}, attempted, { [w.address]: source.contentTag })
  }
  function acknowledge() {
    if (ticket && watched && watched.hasContent && watched.generation >= wantedGeneration && wantedGeneration > 0)
      backend.frameReady(ticket)
  }
  Connections {
    target: scheduler.backend
    function onFrameNeeded(id, address) {
      if (id !== scheduler.ticket) return
      if (!scheduler.allowed) { scheduler.cancel(); return }
      scheduler.watched = scheduler.bank.lookup(address.replace(/^0x/, ""))
      if (!scheduler.watched) { scheduler.cancel(); return }
      scheduler.wantedGeneration = scheduler.watched.generation + 1
      scheduler.watched.refresh(true)
      scheduler.acknowledge()
    }
    function onCompleted(id, result) {
      if (id !== scheduler.ticket) return
      scheduler.watched = null; scheduler.wantedGeneration = 0; scheduler.ticket = 0
      scheduler.settled()
    }
  }
  Connections {
    target: scheduler.watched
    function onRefreshed(generation) { scheduler.acknowledge() }
  }
  Timer { id: startTimer; interval: 60; onTriggered: scheduler.startNext() }
}
