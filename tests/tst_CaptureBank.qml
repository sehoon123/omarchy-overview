import QtQuick
import QtTest
import ".."

Item {
  id: scene
  width: 640; height: 400
  property int created: 0
  property int destroyed: 0
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
      property bool failed: false
      property int cachedFrame: 0
      readonly property bool live: modelData && bank.wantsLive(modelData.address)
      readonly property int viewCount: captureEnabled ? 1 : 0
      readonly property bool hasContent: captureEnabled && !failed
      Component.onCompleted: scene.created++
      Component.onDestruction: scene.destroyed++
    }
  }
  CaptureBank { id: bank; model: sourceModel; factory: fakeProducer }
  // A binding through the public lookup() API: it must re-evaluate whenever the
  // session rebuilds, which is what the revision dependency inside lookup() buys.
  QtObject { id: probe; property var entry: bank.lookup("first") }
  TestCase {
    name: "CaptureSessionOwnership"; when: windowShown
    function init() {
      bank.active = false; bank.allowNew = true
      sourceModel.values = [first, second]
      bank.addresses = ["first", "second"]; bank.liveAddresses = ["first"]
      bank.active = true; wait(0)
      scene.created = 0; scene.destroyed = 0
    }
    function cleanup() { bank.active = false; bank.allowNew = true; wait(0) }
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
    function test_inactiveBankCreatesNothingAndOwnsNothing() {
      bank.active = false; wait(0)
      scene.created = 0
      sourceModel.values = [first]; sourceModel.values = [first, second]
      bank.addresses = ["first", "second"]; bank.liveAddresses = ["second"]
      bank.allowNew = false; bank.allowNew = true; wait(0); wait(0)
      compare(scene.created, 0)
      compare(Object.keys(bank.entries).length, 0)
      compare(bank.viewCount, 0); compare(bank.frameCount, 0)
      compare(bank.lookup("first"), null); compare(bank.wantsLive("second"), false)
    }
    function test_queuedTriggersCannotRepopulateAfterDeactivation() {
      sourceModel.values = [first]
      bank.addresses = ["first"]
      bank.allowNew = false; bank.allowNew = true
      bank.active = false
      wait(0); wait(0)
      compare(scene.created, 0)
      compare(Object.keys(bank.entries).length, 0)
      compare(bank.viewCount, 0); compare(bank.frameCount, 0)
    }
    function test_clearDisablesCaptureSynchronouslyThenDestroysNothingLeaked() {
      const saved = bank.lookup("first")
      compare(saved.captureEnabled, true)
      bank.clear()
      compare(saved.captureEnabled, false)
      compare(scene.destroyed, 0)
      compare(bank.lookup("first"), null); compare(probe.entry, null)
      compare(bank.viewCount, 0); compare(bank.frameCount, 0)
      tryCompare(scene, "destroyed", 2)
    }
    function test_lookupBindingTracksSessionRebuilds() {
      const saved = bank.lookup("first")
      compare(probe.entry, saved)
      sourceModel.values = [replacement, second]; wait(0)
      verify(probe.entry !== saved); compare(probe.entry, bank.lookup("first"))
      bank.addresses = ["second"]; wait(0)
      compare(probe.entry, null)
      bank.addresses = ["first", "second"]; wait(0)
      compare(probe.entry, bank.lookup("first"))
    }
    function test_recycledAddressReleasesTheStaleProducer() {
      const saved = bank.lookup("first")
      sourceModel.values = [replacement, second]; wait(0)
      verify(bank.lookup("first") !== saved)
      compare(bank.lookup("first").modelData, replacement)
      tryCompare(scene, "destroyed", 1)
      compare(bank.viewCount, 2); compare(bank.frameCount, 2)
    }
    function test_viewAndFrameCountsStayExactAcrossChurn() {
      compare(bank.viewCount, 2); compare(bank.frameCount, 2)
      for (let i = 0; i < 3; i++) {
        sourceModel.values = [second]; bank.addresses = ["second"]; wait(0)
        compare(bank.viewCount, 1); compare(bank.frameCount, 1)
        compare(Object.keys(bank.entries).length, 1)
        sourceModel.values = [first, second]; bank.addresses = ["first", "second"]; wait(0)
        compare(bank.viewCount, 2); compare(bank.frameCount, 2)
        compare(Object.keys(bank.entries).length, 2)
      }
      bank.lookup("first").failed = true
      compare(bank.frameCount, 1); compare(bank.viewCount, 2)
      bank.lookup("second").captureEnabled = false
      compare(bank.frameCount, 0); compare(bank.viewCount, 1)
    }
    function test_failedProducerRecoversInTheNextSession() {
      const stranded = bank.lookup("first")
      stranded.failed = true
      compare(bank.frameCount, 1)
      bank.active = false; wait(0)
      bank.active = true; wait(0)
      const revived = bank.lookup("first")
      verify(revived); verify(revived !== stranded)
      compare(revived.failed, false); compare(revived.modelData, first)
      compare(bank.frameCount, 2); compare(bank.viewCount, 2)
    }
    function test_closingKeepsSourcesItCouldNotRecreate() {
      const saved = bank.lookup("first")
      saved.cachedFrame = 7
      bank.allowNew = false
      bank.addresses = ["second"]; wait(0)
      compare(bank.lookup("first"), saved); compare(saved.cachedFrame, 7)
      compare(saved.captureEnabled, true)
      verify(bank.lookup("second")); compare(bank.viewCount, 2)
      bank.addresses = ["second", "first"]; wait(0)
      compare(bank.lookup("first"), saved)
      bank.allowNew = true; wait(0)
      compare(bank.lookup("first"), saved)
      bank.addresses = ["second"]; wait(0)
      compare(bank.lookup("first"), null)
      tryCompare(scene, "destroyed", 1)
    }
    function test_closingStillReleasesVanishedWindows() {
      const saved = bank.lookup("first")
      bank.allowNew = false
      sourceModel.values = [second]; wait(0)
      compare(bank.lookup("first"), null)
      verify(bank.lookup("second"))
      compare(bank.viewCount, 1); compare(bank.frameCount, 1)
      tryCompare(scene, "destroyed", 1)
    }
  }
}
