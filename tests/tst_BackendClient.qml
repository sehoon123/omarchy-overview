import QtQuick
import QtTest
import ".."

// Worker-protocol coverage. This file NEVER instantiates BackendClient: that
// component roots a Process running `python3 -u worker.py`, and a worker request
// such as ["move", ...] or ["step", ...] reaches `hyprctl dispatch` through
// controller.py. It also cannot be loaded here at all - `import Quickshell.Io`
// resolves only inside the quickshell binary, so qmltestrunner reports
// `plugin "quickshell-ioplugin" not found`.
//
// Bare BackendProtocol is tested instead: it holds the whole protocol and roots
// no process, so writeRequested/startRequested are captured by SignalSpy and
// nothing is ever spawned, written to a pipe or dispatched. Every instance also
// sets autoStart: false as belt and braces (test_autoStartDefaultIsTrue pins the
// production default that BackendClient.qml gates its Component.onCompleted and
// its onStartRequested on).
Item {
  id: harness
  readonly property string handshake: '{"event":"ready","protocol":1}'
  // Arguments for the "a lost worker never replays a mutation" case. They reach
  // no process: the only listener for writeRequested in this file is a SignalSpy.
  readonly property var mutatingArgs: ["move", "0x0", "2"]
  function reply(id, extra) {
    return JSON.stringify(Object.assign({ id: id, ok: true }, extra || {}))
  }
  BackendProtocol { id: client; autoStart: false }
  // A short restart delay, so "the adapter is asked to start a new worker" is
  // observable without waiting out the production backoff.
  BackendProtocol { id: fast; autoStart: false; restartDelayMs: 20 }
  // A worker that accepts a request and then never answers or exits.
  BackendProtocol { id: wedgedWorker; autoStart: false; replyTimeoutMs: 40 }
  // Keeps the production backoff binding intact so the delays can be measured.
  BackendProtocol { id: backoff; autoStart: false }
  // No property is overridden here: it pins the shipped defaults.
  BackendProtocol { id: defaults }
  SignalSpy { id: finished; target: client; signalName: "completed" }
  SignalSpy { id: writes; target: client; signalName: "writeRequested" }
  SignalSpy { id: starts; target: client; signalName: "startRequested" }
  SignalSpy { id: fastFinished; target: fast; signalName: "completed" }
  SignalSpy { id: fastWrites; target: fast; signalName: "writeRequested" }
  SignalSpy { id: fastStarts; target: fast; signalName: "startRequested" }
  SignalSpy { id: wedgedFinished; target: wedgedWorker; signalName: "completed" }
  SignalSpy { id: wedgedWrites; target: wedgedWorker; signalName: "writeRequested" }
  SignalSpy { id: wedgedStarts; target: wedgedWorker; signalName: "startRequested" }
  SignalSpy { id: backoffStarts; target: backoff; signalName: "startRequested" }
  TestCase {
    name: "OverviewBackendProtocol"; when: windowShown
    function resetClient(bridge) {
      bridge.processExited()   // the documented loss path clears pending and ready
      bridge.cancelRestart()
      bridge.restarts = 0; bridge.sequence = 0
      bridge.completedCount = 0; bridge.lastElapsedMs = 0
    }
    function init() {
      resetClient(client); resetClient(fast); resetClient(wedgedWorker); resetClient(backoff)
      finished.clear(); writes.clear(); starts.clear()
      fastFinished.clear(); fastWrites.clear(); fastStarts.clear()
      wedgedFinished.clear(); wedgedWrites.clear(); wedgedStarts.clear()
      backoffStarts.clear()
    }
    function cleanup() {
      client.cancelRestart(); fast.cancelRestart()
      wedgedWorker.cancelRestart(); backoff.cancelRestart()
    }
    // The shipped defaults BackendClient.qml depends on. autoStart must stay true
    // there or the shell would come up with no worker at all.
    function test_autoStartDefaultIsTrue() {
      compare(defaults.autoStart, true)
      compare(defaults.ready, false)
      compare(defaults.restarts, 0)
      compare(defaults.maxRestarts, 5)
      compare(defaults.restartDelayMs, 250)
      compare(defaults.replyTimeoutMs, 20000)
      compare(defaults.outstanding, false)
      compare(defaults.restarting, false)
      // ... and every client in this file opted out of starting a process.
      compare(client.autoStart, false); compare(fast.autoStart, false)
      compare(wedgedWorker.autoStart, false); compare(backoff.autoStart, false)
    }
    // No request is framed before the protocol-1 handshake, so a worker speaking
    // a different protocol is never given a ticket.
    function test_noRequestIsFramedBeforeTheProtocol1Handshake() {
      compare(client.ready, false)
      compare(client.request(["state"], {}, ""), 0)
      compare(client.outstanding, false); compare(writes.count, 0)
      client.receive('{"event":"ready","protocol":2}')
      compare(client.ready, false)
      client.receive('{"event":"ready"}')
      compare(client.ready, false)
      client.receive('{"event":"ready","protocol":"1"}')
      compare(client.ready, false)
      client.receive('{"event":"hello","protocol":1}')
      compare(client.ready, false)
      compare(client.request(["state"], {}, ""), 0)
      compare(writes.count, 0)
      client.receive(harness.handshake)
      compare(client.ready, true)
      verify(client.request(["state"], {}, "") > 0)
      compare(writes.count, 1)
    }
    function test_requestFramesExactlyOnePacketWithItsTicket() {
      client.receive(harness.handshake)
      const id = client.request(["state"], { "0x1": "cover" }, "DP-2")
      compare(writes.count, 1)
      const line = writes.signalArguments[0][0]
      compare(line.charAt(line.length - 1), "\n")
      compare(line.indexOf("\n"), line.length - 1)
      const packet = JSON.parse(line)
      compare(packet.type, "request"); compare(packet.id, id)
      compare(JSON.stringify(packet.args), JSON.stringify(["state"]))
      compare(packet.cover["0x1"], "cover"); compare(packet.monitor, "DP-2")
      // Absent cover/monitor are normalised, never left undefined on the wire.
      client.receive(harness.reply(id))
      const second = client.request(["state"])
      const bare = JSON.parse(writes.signalArguments[1][0])
      compare(bare.id, second)
      compare(JSON.stringify(bare.cover), "{}"); compare(bare.monitor, "")
    }
    // send() is the raw framing primitive; only request() is gated.
    function test_sendFramesOneLinePerPacket() {
      client.send({ type: "request", id: 7 })
      compare(writes.count, 1)
      compare(JSON.parse(writes.signalArguments[0][0]).id, 7)
      compare(writes.signalArguments[0][0].charAt(writes.signalArguments[0][0].length - 1), "\n")
    }
    function test_onlyOneRequestIsInFlightAtATime() {
      client.receive(harness.handshake)
      const first = client.request(["state"], {}, "")
      verify(first > 0); compare(client.outstanding, true)
      compare(client.request(["state"], {}, ""), 0)
      compare(client.request(harness.mutatingArgs, {}, ""), 0)
      compare(writes.count, 1)
      client.receive(harness.reply(first, { elapsedMs: 4 }))
      compare(finished.count, 1)
      compare(finished.signalArguments[0][0], first)
      compare(finished.signalArguments[0][1].ok, true)
      compare(client.outstanding, false)
      compare(client.completedCount, 1); compare(client.lastElapsedMs, 4)
      const second = client.request(["state"], {}, "")
      compare(second, first + 1)
      compare(writes.count, 2)
    }
    // A late, duplicate, unknown or id-0 line can never complete a ticket that it
    // does not belong to - including the next one.
    function test_lateDuplicateAndUnknownRepliesAreIgnored() {
      client.receive(harness.handshake)
      const id = client.request(["state"], {}, "")
      client.receive(harness.reply(id + 99))
      compare(finished.count, 0); compare(client.outstanding, true)
      client.receive('{"id":0,"ok":false,"error":"Protocol packet is too large"}')
      compare(finished.count, 0); compare(client.outstanding, true)
      client.receive(harness.reply(id, { message: "first" }))
      compare(finished.count, 1)
      compare(finished.signalArguments[0][1].message, "first")
      compare(client.completedCount, 1)
      client.receive(JSON.stringify({ id: id, ok: false, error: "late duplicate" }))
      compare(finished.count, 1); compare(client.completedCount, 1)
      const next = client.request(["state"], {}, "")
      client.receive(harness.reply(id, { message: "stale" }))
      compare(finished.count, 1); compare(client.outstanding, true)
      client.receive(harness.reply(next, { message: "second" }))
      compare(finished.count, 2)
      compare(finished.signalArguments[1][0], next)
      compare(finished.signalArguments[1][1].message, "second")
    }
    function test_malformedOrNonObjectLinesAreIgnoredWithoutThrowing_data() {
      return [
        { tag: "garbage", line: "not json" },
        { tag: "truncated-object", line: '{"id":1,"ok":true' },
        { tag: "trailing-garbage", line: '{"id":1,"ok":true} }' },
        { tag: "empty", line: "" },
        { tag: "whitespace", line: "   " },
        { tag: "null", line: "null" },
        { tag: "number", line: "42" },
        { tag: "bool", line: "true" },
        { tag: "string", line: '"ready"' },
        { tag: "array", line: '[{"id":1,"ok":true}]' },
        { tag: "handshake-in-array", line: '[{"event":"ready","protocol":1}]' }
      ]
    }
    function test_malformedOrNonObjectLinesAreIgnoredWithoutThrowing(row) {
      client.receive(harness.handshake)
      const id = client.request(["state"], {}, "")
      client.receive(row.line)
      compare(finished.count, 0)
      compare(client.outstanding, true)
      compare(client.completedCount, 0)
      verify(client.ready)
      // The ticket survives the bad line and still completes normally.
      client.receive(harness.reply(id))
      compare(finished.count, 1)
      compare(finished.signalArguments[0][1].ok, true)
    }
    function test_nonStringLinesAreIgnored() {
      client.receive(harness.handshake)
      const id = client.request(["state"], {}, "")
      client.receive(null); client.receive(undefined); client.receive(42)
      client.receive({ id: id, ok: true })
      compare(finished.count, 0); compare(client.outstanding, true)
      client.receive(harness.reply(id))
      compare(finished.count, 1)
    }
    // A lost worker fails the outstanding ticket and NEVER re-sends its
    // arguments: replaying ["move", ...] would move a user's window twice.
    function test_workerLossFailsThePendingTicketAndNeverReplaysTheMutation() {
      client.receive(harness.handshake)
      const id = client.request(harness.mutatingArgs, {}, "DP-2")
      verify(id > 0); compare(writes.count, 1)
      client.processExited()
      compare(finished.count, 1)
      compare(finished.signalArguments[0][0], id)
      compare(finished.signalArguments[0][1].ok, false)
      compare(finished.signalArguments[0][1].error, "Overview worker stopped; action was not replayed")
      compare(client.outstanding, false)
      compare(client.ready, false)
      compare(writes.count, 1)              // nothing was re-sent
      compare(client.completedCount, 0)     // no reply was ever received
      compare(client.restarts, 1)
      verify(client.restarting)             // a new worker is scheduled...
      compare(starts.count, 0)              // ...but not started yet
      // A reply that arrives after the loss completes nothing, and no request is
      // framed until the replacement worker greets us.
      client.receive(harness.reply(id))
      compare(finished.count, 1)
      compare(client.request(["state"], {}, ""), 0)
      compare(writes.count, 1)
      // A second exit with nothing outstanding stays quiet.
      client.processExited()
      compare(finished.count, 1); compare(client.restarts, 2)
    }
    function test_idsStayMonotonicAcrossARestart() {
      fast.receive(harness.handshake)
      const first = fast.request(harness.mutatingArgs, {}, "")
      verify(first > 0)
      fast.processExited()
      compare(fastFinished.count, 1)
      compare(fastFinished.signalArguments[0][1].ok, false)
      tryCompare(fastStarts, "count", 1)    // the adapter is asked for a new worker
      compare(fastWrites.count, 1)          // the mutation is not replayed by the restart
      fast.receive(harness.handshake)
      verify(fast.ready)
      const second = fast.request(["state"], {}, "")
      compare(second, first + 1)
      // The dead worker's id cannot complete the new ticket.
      fast.receive(harness.reply(first))
      compare(fastFinished.count, 1); compare(fast.outstanding, true)
      fast.receive(harness.reply(second))
      compare(fastFinished.count, 2)
      compare(fastFinished.signalArguments[1][0], second)
      compare(fastFinished.signalArguments[1][1].ok, true)
    }
    // Restarts back off and stop after maxRestarts, so a worker that cannot run
    // is retried a bounded number of times instead of forever.
    function test_restartBackoffIsCappedAtFiveAttempts() {
      compare(backoff.maxRestarts, 5)
      compare(backoff.restartDelayMs, 250)
      const delays = []
      for (let loss = 1; loss <= 7; loss++) {
        backoff.processExited()
        compare(backoff.restarts, loss)
        compare(backoff.restarting, loss <= backoff.maxRestarts)
        delays.push(backoff.restartDelayMs)
      }
      compare(JSON.stringify(delays), JSON.stringify([500, 1000, 2000, 4000, 5000, 5000, 5000]))
      verify(!backoff.restarting)
      compare(backoffStarts.count, 0)       // nothing fired inside this synchronous loop
    }
    // AUDIT.md F-08 residual / F-36 client half: a worker that is wedged but
    // alive reports no exit, so without a ceiling the ticket stays pending and
    // the shell's `busy` latches for the rest of the session.
    function test_aWedgedWorkerCannotLatchTheTicketForever() {
      wedgedWorker.receive(harness.handshake)
      const id = wedgedWorker.request(["state"], {}, "")
      verify(id > 0); compare(wedgedWrites.count, 1)
      tryCompare(wedgedFinished, "count", 1)
      compare(wedgedFinished.signalArguments[0][0], id)
      compare(wedgedFinished.signalArguments[0][1].ok, false)
      compare(wedgedFinished.signalArguments[0][1].error,
        "The desktop action did not answer; it was not repeated")
      compare(wedgedWrites.count, 1)        // the request is failed, never repeated
      compare(wedgedWorker.outstanding, false)
      compare(wedgedWorker.completedCount, 0)
      // The worker is left running: no exit is faked, no restart is scheduled.
      compare(wedgedWorker.restarts, 0)
      compare(wedgedWorker.restarting, false)
      compare(wedgedStarts.count, 0)
      verify(wedgedWorker.ready)
      // A very late reply for the abandoned ticket changes nothing, and the retry
      // gets a fresh id.
      wedgedWorker.receive(harness.reply(id))
      compare(wedgedFinished.count, 1); compare(wedgedWorker.completedCount, 0)
      const retry = wedgedWorker.request(["state"], {}, "")
      compare(retry, id + 1)
    }
    function test_theWatchdogNeverFiresWhileTheWorkerAnswers() {
      wedgedWorker.receive(harness.handshake)
      const id = wedgedWorker.request(["state"], {}, "")
      wedgedWorker.receive(harness.reply(id, { elapsedMs: 3 }))
      compare(wedgedFinished.count, 1)
      compare(wedgedFinished.signalArguments[0][1].ok, true)
      wait(wedgedWorker.replyTimeoutMs * 3)
      compare(wedgedFinished.count, 1)      // the disarmed watchdog stays quiet
      compare(wedgedWorker.completedCount, 1)
      compare(wedgedWorker.lastElapsedMs, 3)
      compare(wedgedWorker.restarts, 0)
    }
  }
}
