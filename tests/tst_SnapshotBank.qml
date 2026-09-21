import QtQuick
import QtTest
import ".."

Item {
  id: scene
  width: 600; height: 500
  readonly property string png: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAE0lEQVR4AWNg+M+AQAgWUBSZAwDpPQv1wVLRrAAAAABJRU5ErkJggg=="
  QtObject { id: windows; property var values: [] }
  SnapshotBank { id: bank; model: windows }
  WindowPreview {
    id: card; width: 400; height: 300
    windowInfo: windows.values[0] || null
    sharedCapture: bank.lookup("a")
  }
  DesktopPreview {
    id: desktop
    members: windows.values
    captureFor: address => bank.lookup(address)
  }
  function window(address, title) {
    return { address: address, title: title || "Tab A", lastIpcObject: { class: "fixture", pid: 7, stableId: 10, size: [400, 300] } }
  }
  function frame(address, stamp) {
    return { address: address, title: "Tab A", pid: 7, stableId: 10, windowSize: [400, 300],
      width: 4, height: 3, imageSource: png, capturedAt: stamp || 1, partial: false }
  }
  TestCase {
    name: "OutputSnapshotBank"; when: windowShown
    function init() {
      bank.clear(); bank.shown = true; bank.keepCache = true; bank.maxBytes = 8 * 1024 * 1024
      bank.maxPixels = 12000000; bank.openedAt = 0
      windows.values = [scene.window("a"), scene.window("b")]
      wait(0)
    }
    function test_pngActuallyLoadsAndIsNeverReportedLive() {
      bank.accept({ ok: true, frames: [scene.frame("a")] })
      tryCompare(card, "hasThumbnail", true)
      const miniature = findChild(desktop, "desktopSnapshot")
      verify(miniature)
      tryCompare(miniature, "status", Image.Ready)
      verify(miniature.visible)
      compare(bank.lookup("a").fresh, false)
      compare(card.aspect, 4 / 3)
      verify(bank.retainedBytes > 0)
    }
    function test_changedTabSizeAndReusedAddressDoNotShowOldPixels() {
      bank.accept({ ok: true, frames: [scene.frame("a")] })
      verify(bank.lookup("a"))
      windows.values = [scene.window("a", "Tab B")]
      compare(bank.lookup("a"), null)
      const resized = scene.window("a"); resized.lastIpcObject.size = [800, 300]
      windows.values = [resized]; compare(bank.lookup("a"), null)
      const reused = scene.window("a"); reused.lastIpcObject.stableId = 99
      windows.values = [reused]; compare(bank.lookup("a"), null)
      const otherProcess = scene.window("a"); otherProcess.lastIpcObject.pid = 8
      windows.values = [otherProcess]; compare(bank.lookup("a"), null)
    }
    function test_cacheRetentionIsExplicitAndClosedWindowsAreRemoved() {
      bank.accept({ ok: true, frames: [scene.frame("a"), scene.frame("b")] })
      bank.shown = false
      verify(bank.lookup("a"))
      windows.values = [scene.window("b")]; wait(0)
      compare(Object.keys(bank.entries).length, 1)
      bank.keepCache = false
      compare(bank.retainedBytes, 0)
      bank.shown = true
      bank.accept({ ok: true, frames: [scene.frame("b")] })
      verify(bank.retainedBytes > 0)
      bank.shown = false
      compare(bank.retainedBytes, 0)
    }
    function test_memoryBudgetKeepsNewestSnapshot() {
      bank.maxBytes = scene.png.length
      bank.accept({ ok: true, frames: [scene.frame("a", 1), scene.frame("b", 2)] })
      compare(bank.lookup("a"), null)
      verify(bank.lookup("b"))
      verify(bank.retainedBytes <= bank.maxBytes)
    }
    function test_pixelBudgetBoundsHighlyCompressedImages() {
      bank.maxPixels = 12
      bank.accept({ ok: true, frames: [scene.frame("a", 1), scene.frame("b", 2)] })
      compare(bank.lookup("a"), null); verify(bank.lookup("b"))
      compare(bank.retainedPixels, 12)
    }
    function test_retainedImagesAreMarkedAsPreviousSnapshots() {
      bank.accept({ ok: true, frames: [scene.frame("a", 100)] })
      compare(bank.lookup("a").previous, false)
      bank.openedAt = 200
      compare(bank.lookup("a").previous, true)
    }
    function test_failedRepliesAndUnknownWindowsCannotPopulateCache() {
      bank.accept({ ok: false, frames: [scene.frame("a")] })
      compare(bank.retainedBytes, 0)
      bank.accept({ ok: true, frames: [scene.frame("closed")] })
      compare(bank.retainedBytes, 0)
      const invalid = scene.frame("a"); invalid.imageSource = "file:///not-a-preview"
      bank.accept({ ok: true, frames: [invalid] })
      compare(bank.retainedBytes, 0)
    }
  }
}
