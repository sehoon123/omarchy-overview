import QtQuick
import QtTest
import ".."

// Bare OpenRequest only: OpenGuard roots a Process that runs capture_context.py,
// so it is never instantiated here. receive()/processExited() are driven
// synthetically; no test spawns python3, sleeps, or touches a socket.
Item {
  id: harness
  readonly property string goodReply: '{"ok":true,"outputs":["DP-2"],"frames":[]}'
  property bool pendingWhenStopped: true
  property int completionsWhenStopped: -1
  OpenRequest { id: client }
  // A second guard keeps the wedged-helper timings off the shared instance.
  OpenRequest { id: wedged }
  SignalSpy { id: finished; target: client; signalName: "completed" }
  SignalSpy { id: started; target: client; signalName: "startRequested" }
  SignalSpy { id: stopped; target: client; signalName: "stopRequested" }
  SignalSpy { id: ready; target: client; signalName: "readyToBegin" }
  SignalSpy { id: wedgedFinished; target: wedged; signalName: "completed" }
  SignalSpy { id: wedgedStarted; target: wedged; signalName: "startRequested" }
  SignalSpy { id: wedgedStopped; target: wedged; signalName: "stopRequested" }
  SignalSpy { id: wedgedReady; target: wedged; signalName: "readyToBegin" }
  // Terminating the helper must never precede invalidating the request.
  Connections {
    target: client
    function onStopRequested() {
      harness.pendingWhenStopped = client.pending
      harness.completionsWhenStopped = finished.count
    }
  }
  TestCase {
    name: "OpeningGuardRequest"; when: windowShown
    function init() {
      client.cancel(); client.processExited(); client.timeoutMs = 1000
      wedged.cancel(); wedged.processExited()
      harness.pendingWhenStopped = true; harness.completionsWhenStopped = -1
      finished.clear(); started.clear(); stopped.clear(); ready.clear()
      wedgedFinished.clear(); wedgedStarted.clear(); wedgedStopped.clear(); wedgedReady.clear()
    }
    function cleanup() { client.cancel(); client.processExited() }
    function test_oneReplyAndNoConcurrentHelper() {
      verify(client.begin("TEST")); verify(!client.begin("TEST"))
      compare(started.count, 1)
      client.receive('{"ok":true,"frames":[]}')
      compare(finished.count, 0)
      client.processExited()
      compare(finished.count, 1)
      compare(finished.signalArguments[0][0].ok, true)
      compare(client.pending, false); compare(client.processActive, false)
      client.processExited(); compare(finished.count, 1)
    }
    function test_cancelCannotReopenFromLateCompletion() {
      verify(client.begin("TEST")); client.cancel()
      compare(stopped.count, 1)
      client.receive('{"ok":true,"frames":[]}'); client.processExited()
      compare(finished.count, 0); compare(client.pending, false)
    }
    function test_timeoutCompletesOnceAndNextOpenCanRetry() {
      client.timeoutMs = 20
      verify(client.begin("TEST"))
      tryCompare(finished, "count", 1)
      compare(finished.signalArguments[0][0].ok, false)
      compare(stopped.count, 1)
      // The process is still draining; starting another would accept stale data.
      verify(!client.begin("TEST"))
      client.receive('{"ok":true,"frames":[]}'); client.processExited()
      compare(finished.count, 1)
      client.timeoutMs = 1000
      verify(client.begin("TEST"))
      client.receive('{"ok":true,"frames":[]}'); client.processExited()
      compare(finished.count, 2)
      compare(finished.signalArguments[1][0].ok, true)
    }
    function test_malformedReplyIsFailureNotAStaleFrame() {
      verify(client.begin("TEST")); client.receive('not json'); client.processExited()
      compare(finished.count, 1); compare(finished.signalArguments[0][0].ok, false)
    }
    // A duplicate, late, malformed or oversized line must never erase a reply.
    function test_firstGoodReplyWinsOverLateDuplicateAndGarbageLines() {
      verify(client.begin("TEST"))
      client.receive(harness.goodReply)
      client.receive('{"ok":false,"reason":"stale second line"}')
      client.receive('not json')
      client.receive('{"ok":true,"outputs":[')
      client.receive('{"ok":false,"reason":"' + "x".repeat(client.maxReplyLength) + '"}')
      client.processExited(0, 0)
      compare(finished.count, 1)
      const result = finished.signalArguments[0][0]
      compare(result.ok, true); compare(result.outputs[0], "DP-2")
      verify(result.reason === undefined)
    }
    function test_partialAndNonObjectJsonIsNotAReply_data() {
      return [
        { tag: "null", line: "null" },
        { tag: "number", line: "42" },
        { tag: "string", line: '"Capture context ok"' },
        { tag: "bool", line: "true" },
        { tag: "array", line: '[{"ok":true,"outputs":["DP-2"]}]' },
        { tag: "truncated-object", line: '{"ok":true,"outputs":["DP-2"' },
        { tag: "trailing-garbage", line: '{"ok":true} }' },
        { tag: "empty-line", line: "" }
      ]
    }
    function test_partialAndNonObjectJsonIsNotAReply(row) {
      verify(client.begin("TEST"))
      client.receive(row.line)
      compare(client.reply, null)
      client.processExited(0, 0)
      compare(finished.count, 1)
      compare(finished.signalArguments[0][0].ok, false)
      compare(finished.signalArguments[0][0].reason, "Capture context unavailable")
    }
    function test_oversizedReplyIsIgnoredAndCannotPoisonTheRequest() {
      verify(client.begin("TEST"))
      const flood = '{"ok":true,"outputs":["DP-2"],"pad":"' + "y".repeat(client.maxReplyLength) + '"}'
      verify(flood.length > client.maxReplyLength)
      client.receive(flood)
      compare(client.reply, null)
      client.receive('{"ok":true,"outputs":["DP-1"]}')
      client.processExited(0, 0)
      compare(finished.count, 1)
      compare(finished.signalArguments[0][0].ok, true)
      compare(finished.signalArguments[0][0].outputs[0], "DP-1")
    }
    function test_replyAtTheSizeLimitIsStillAccepted() {
      verify(client.begin("TEST"))
      const envelope = '{"ok":true,"outputs":[],"pad":""}'
      const line = '{"ok":true,"outputs":[],"pad":"'
        + "z".repeat(client.maxReplyLength - envelope.length) + '"}'
      compare(line.length, client.maxReplyLength)
      client.receive(line)
      client.processExited(0, 0)
      compare(finished.count, 1); compare(finished.signalArguments[0][0].ok, true)
    }
    function test_aLineWithNoRequestInFlightIsDropped() {
      client.receive(harness.goodReply)
      compare(client.reply, null)
      verify(client.begin("TEST"))
      client.processExited(0, 0)
      compare(finished.count, 1); compare(finished.signalArguments[0][0].ok, false)
    }
    // F-05/F-19: every refusal names itself, and only a draining helper promises
    // a later readyToBegin() so the caller can retry instead of dead-ending.
    function test_refusalReasonsAreDistinctAndOnlyDrainingInvitesARetry() {
      compare(client.begin(""), false)
      compare(client.lastRefusal, "output")
      compare(started.count, 0); verify(client.canBegin)
      verify(client.begin("TEST"))
      compare(client.lastRefusal, ""); compare(started.signalArguments[0][0], "TEST")
      verify(!client.begin("TEST"))
      compare(client.lastRefusal, "pending")
      compare(client.canBegin, false); compare(client.draining, false)
      client.receive(harness.goodReply); client.processExited(0, 0)
      compare(finished.count, 1); compare(finished.signalArguments[0][0].ok, true)
      // A live request reports its outcome through completed(); no retry hook.
      compare(ready.count, 0)
      compare(client.lastRefusal, "pending")
    }
    function test_aCancelledRequestFreesTheGuardWhenTheHelperExits() {
      verify(client.begin("TEST"))
      client.cancel()
      compare(stopped.count, 1)
      verify(client.draining); compare(client.canBegin, false)
      verify(!client.begin("TEST"))
      compare(client.lastRefusal, "draining"); compare(started.count, 1)
      compare(ready.count, 0)
      client.receive(harness.goodReply)
      client.processExited(0, 0)
      compare(finished.count, 0)            // the abandoned request never completes
      compare(ready.count, 1)
      compare(client.lastRefusal, ""); verify(client.canBegin)
      verify(client.begin("DP-2"))
      client.receive(harness.goodReply); client.processExited(0, 0)
      compare(finished.count, 1); compare(finished.signalArguments[0][0].ok, true)
    }
    // F-19: a helper that never reports its exit must not refuse every later open.
    function test_aWedgedHelperFreesItselfAfterTheDrainWindow() {
      wedged.timeoutMs = 20; wedged.drainMs = 400
      verify(wedged.begin("TEST"))
      tryCompare(wedgedFinished, "count", 1)
      compare(wedgedFinished.signalArguments[0][0].ok, false)
      compare(wedgedFinished.signalArguments[0][0].reason, "Capture context check timed out")
      compare(wedgedStopped.count, 1)
      verify(wedged.draining)
      verify(!wedged.begin("TEST"))
      compare(wedged.lastRefusal, "draining")
      compare(wedgedStarted.count, 1); compare(wedgedReady.count, 0)
      tryCompare(wedged, "canBegin", true)
      compare(wedgedReady.count, 1)
      compare(wedgedStopped.count, 1)       // no terminate storm while draining
      compare(wedged.lastRefusal, "")
      wedged.timeoutMs = 1000
      verify(wedged.begin("DP-2"))
      wedged.receive(harness.goodReply); wedged.processExited(0, 0)
      compare(wedgedFinished.count, 2); compare(wedgedFinished.signalArguments[1][0].ok, true)
    }
    // F-20: "python3 is missing" and "helper crashed" are not "no reply".
    function test_helperFailureReasonsAreSpecific_data() {
      return [
        { tag: "silent-clean-exit", code: 0, status: 0, reason: "Capture context unavailable" },
        { tag: "helper-missing", code: 127, status: 0, reason: "Preview helper could not run" },
        { tag: "helper-error-exit", code: 1, status: 0, reason: "Preview helper could not run" },
        { tag: "helper-crashed", code: 0, status: 1, reason: "Preview helper stopped unexpectedly" },
        { tag: "helper-killed", code: 15, status: 1, reason: "Preview helper stopped unexpectedly" }
      ]
    }
    function test_helperFailureReasonsAreSpecific(row) {
      verify(client.begin("TEST"))
      client.processExited(row.code, row.status)
      compare(finished.count, 1)
      compare(finished.signalArguments[0][0].ok, false)
      compare(finished.signalArguments[0][0].reason, row.reason)
      verify(client.canBegin)
    }
    function test_processExitedWithoutArgumentsStillCompletesOnce() {
      verify(client.begin("TEST"))
      client.processExited()
      compare(finished.count, 1)
      compare(finished.signalArguments[0][0].ok, false)
      compare(finished.signalArguments[0][0].reason, "Capture context unavailable")
      client.processExited()
      compare(finished.count, 1)
    }
    function test_aValidReplySurvivesANonZeroExit() {
      verify(client.begin("TEST"))
      client.receive(harness.goodReply)
      client.processExited(1, 1)
      compare(finished.count, 1)
      compare(finished.signalArguments[0][0].ok, true)
      compare(finished.signalArguments[0][0].outputs[0], "DP-2")
    }
    function test_terminationNeverPrecedesInvalidationOnCancel() {
      verify(client.begin("TEST"))
      client.cancel()
      compare(stopped.count, 1)
      compare(harness.pendingWhenStopped, false)
      compare(harness.completionsWhenStopped, 0)
    }
    function test_terminationNeverPrecedesInvalidationOnTimeout() {
      client.timeoutMs = 20
      verify(client.begin("TEST"))
      tryCompare(stopped, "count", 1)
      compare(harness.pendingWhenStopped, false)
      compare(harness.completionsWhenStopped, 1)
      compare(finished.count, 1)
    }
  }
}
