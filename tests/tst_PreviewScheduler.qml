import QtQuick
import QtTest
import ".."

Item {
  width: 400; height: 300
  QtObject { id: windowInfo; property string address: "abc"; property var workspace: ({ id: 1 }) }
  QtObject {
    id: source
    property bool needsRefresh: true
    property bool hasContent: true
    property int generation: 4
    property string contentTag: "Tab A"
    signal refreshed(int generation)
    function refresh(force) { return generation + 1 }
  }
  QtObject { id: bank; function lookup(address) { return address === "abc" ? source : null } }
  QtObject {
    id: backend
    property bool ready: true
    property int sequence: 0
    property int cancelled: 0
    property int acknowledged: 0
    signal frameNeeded(int ticket, string address)
    signal completed(int ticket, var result)
    function request(args, cover) { return ++sequence }
    function cancel(id) { cancelled = id }
    function frameReady(id) { acknowledged = id }
  }
  PreviewScheduler { id: scheduler; bank: bank; backend: backend; windows: [windowInfo]; workspace: 1; monitor: 1 }
  TestCase {
    name: "PreviewLease"; when: windowShown
    function init() {
      backend.cancelled = 0; backend.acknowledged = 0
      source.generation = 4; source.contentTag = "Tab A"; source.needsRefresh = true
      scheduler.covered = true; scheduler.suspended = false; scheduler.shown = true
      scheduler.startNext()
      verify(scheduler.busy)
    }
    function cleanup() {
      scheduler.shown = false
      backend.completed(scheduler.ticket, { ok: true })
    }
    function test_oldHasContentCannotAcknowledgeNewRequest() {
      backend.frameNeeded(scheduler.ticket, "0xabc")
      compare(backend.acknowledged, 0)
      source.generation++
      source.refreshed(source.generation)
      compare(backend.acknowledged, scheduler.ticket)
    }
    function test_cancelHoldsLeaseUntilRestorationCompletes() {
      scheduler.suspended = true
      compare(backend.cancelled, scheduler.ticket)
      verify(scheduler.busy)
      backend.completed(scheduler.ticket, { ok: true })
      verify(!scheduler.busy)
    }
    function test_lateReplyCannotCompleteDifferentTicket() {
      const current = scheduler.ticket
      backend.completed(current + 10, { ok: true })
      compare(scheduler.ticket, current)
    }
    function test_hiddenCannotStartAnotherLease() {
      scheduler.shown = false
      backend.completed(scheduler.ticket, { ok: true })
      scheduler.startNext()
      verify(!scheduler.busy)
    }
  }
}
