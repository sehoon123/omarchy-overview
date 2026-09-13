import QtQuick
import QtTest
import ".."

Item {
  width: 640; height: 400
  QtObject { id: first; property string address: "first" }
  QtObject { id: second; property string address: "second" }
  QtObject { id: sourceModel; property var values: [] }
  Component { id: fakeProducer; Item { property var modelData; property int cachedFrame: 0; property bool live: bank.live } }
  CaptureBank { id: bank; model: sourceModel; factory: fakeProducer }
  TestCase {
    name: "CaptureBankContinuity"
    when: windowShown
    function init() { bank.live = true; sourceModel.values = [first, second]; wait(0) }
    function test_hideAndReopenRetainPausedFrames() {
      const saved = bank.lookup("first")
      saved.cachedFrame = 42
      bank.live = false
      wait(0)
      compare(saved.live, false)
      compare(bank.lookup("first"), saved)
      compare(saved.cachedFrame, 42)
      bank.live = true
      wait(0)
      compare(saved.live, true)
      compare(bank.lookup("first"), saved)
      compare(saved.cachedFrame, 42)
    }
    function test_reorderingKeepsCachedFrame() {
      const saved = bank.lookup("first")
      verify(saved !== null)
      saved.cachedFrame = 42
      sourceModel.values = [second, first]
      wait(0)
      compare(bank.lookup("first"), saved)
      compare(bank.lookup("first").cachedFrame, 42)
    }
    function test_transientResetIsCoalesced() {
      const saved = bank.lookup("first")
      sourceModel.values = []
      sourceModel.values = [first, second]
      wait(0)
      compare(bank.lookup("first"), saved)
    }
    function test_closedWindowIsRemoved() {
      sourceModel.values = [second]
      wait(0)
      compare(bank.lookup("first"), null)
      verify(bank.lookup("second") !== null)
    }
  }
}
