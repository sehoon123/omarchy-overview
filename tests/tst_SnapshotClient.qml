import QtQuick
import QtTest
import ".."

Item {
  SnapshotRequest { id: client }
  SignalSpy { id: finished; target: client; signalName: "completed" }
  SignalSpy { id: started; target: client; signalName: "startRequested" }
  SignalSpy { id: stopped; target: client; signalName: "stopRequested" }
  TestCase {
    name: "OutputSnapshotRequest"; when: windowShown
    function init() {
      client.cancel(); client.processExited(); client.timeoutMs = 1000
      finished.clear(); started.clear(); stopped.clear()
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
  }
}
