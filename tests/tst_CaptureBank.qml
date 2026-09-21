import QtQuick
import QtTest
import ".."

Item {
  width: 640; height: 400
  QtObject { id: first; property string address: "first" }
  QtObject { id: second; property string address: "second" }
  QtObject { id: replacement; property string address: "first" }
  QtObject { id: sourceModel; property var values: [] }
  Component {
    id: fakeProducer
    Item {
      property var modelData
      property int serial: 0
      property bool captureEnabled: true
      property int cachedFrame: 0
      readonly property bool live: modelData && bank.wantsLive(modelData.address)
      readonly property int viewCount: captureEnabled ? 1 : 0
      readonly property bool hasContent: captureEnabled
    }
  }
  CaptureBank { id: bank; model: sourceModel; factory: fakeProducer }
  TestCase {
    name: "CaptureSessionOwnership"; when: windowShown
    function init() {
      bank.active = false; bank.allowNew = true
      sourceModel.values = [first, second]
      bank.addresses = ["first", "second"]; bank.liveAddresses = ["first"]
      bank.active = true; wait(0)
    }
    function cleanup() { bank.active = false; wait(0) }
    function test_hideReleasesEverythingAndReopenCreatesFreshSources() {
      const old = bank.lookup("first"), serial = old.serial
      old.cachedFrame = 42
      bank.active = false
      compare(old.captureEnabled, false)
      compare(bank.lookup("first"), null); compare(bank.viewCount, 0); compare(bank.frameCount, 0)
      bank.active = true; wait(0)
      verify(bank.lookup("first").serial > serial)
      compare(bank.lookup("first").cachedFrame, 0)
    }
    function test_searchSelectionAndReorderReuseProducer() {
      const saved = bank.lookup("first")
      saved.cachedFrame = 42
      sourceModel.values = [second, first]
      bank.addresses = ["second", "first"]
      bank.liveAddresses = ["second"]; wait(0)
      compare(bank.lookup("first"), saved); compare(saved.cachedFrame, 42); compare(saved.live, false)
      bank.liveAddresses = ["first"]; compare(saved.live, true)
    }
    function test_transientCollectionResetDoesNotRebuildTheSession() {
      const saved = bank.lookup("first")
      sourceModel.values = []; sourceModel.values = [first, second]; wait(0)
      compare(bank.lookup("first"), saved)
    }
    function test_queuedModelChangeCannotRepopulateHiddenBank() {
      sourceModel.values = [first]
      bank.active = false; wait(0)
      compare(bank.viewCount, 0); compare(Object.keys(bank.entries).length, 0)
    }
    function test_closedOrDisallowedWindowIsReleased() {
      sourceModel.values = [second]; wait(0)
      compare(bank.lookup("first"), null); verify(bank.lookup("second"))
      bank.addresses = []; wait(0)
      compare(bank.lookup("second"), null)
    }
    function test_recycledAddressDoesNotReuseAnotherWindowObject() {
      const serial = bank.lookup("first").serial
      sourceModel.values = [replacement, second]; wait(0)
      verify(bank.lookup("first").serial > serial)
      compare(bank.lookup("first").modelData, replacement)
    }
    function test_closingNeverAddsNewSources() {
      bank.addresses = ["first"]; wait(0)
      bank.allowNew = false; bank.addresses = ["first", "second"]; wait(0)
      verify(bank.lookup("first")); compare(bank.lookup("second"), null)
    }
  }
}
