import QtQuick
import QtTest
import ".."

Item {
  width: 400; height: 300
  QtObject { id: source }
  FrameCache {
    id: cache
    width: 200; height: 160
    factory: Component {
      Item {
        property var captureSource: null
        property bool live: false
        property bool hasContent: false
        property size sourceSize: Qt.size(600, 400)
      }
    }
  }
  TestCase {
    name: "FrameCacheFreshness"; when: windowShown
    function init() {
      cache.captureSource = null
      cache.captureEnabled = true
      cache.contentTag = "Tab A"
      cache.captureSource = source
      wait(90)
      cache.refresh(true)
      cache.pending.hasContent = true
      verify(cache.hasContent)
    }
    function cleanup() { cache.captureSource = null }
    function test_titleChangeNeverExposesOldTabAsCurrent() {
      const old = cache.image
      cache.contentTag = "Tab B"
      verify(!cache.hasContent)
      verify(cache.needsRefresh)
      compare(cache.image, old) // Retained, but explicitly invalid, not displayed.
      cache.refresh(true)
      wait(90)
      cache.pending.hasContent = true
      compare(cache.confirmedTag, "Tab B")
      verify(cache.hasContent)
      verify(cache.fresh)
    }
    function test_lateOldTabFrameIsRejected() {
      cache.refresh(true)
      cache.contentTag = "Tab B"
      cache.pending.hasContent = true
      verify(!cache.hasContent)
      compare(cache.pending, null)
      compare(cache.confirmedTag, "Tab A")
    }
    function test_refreshIsDoubleBuffered() {
      const old = cache.image, revision = cache.generation
      cache.refresh(true)
      compare(cache.image, old)
      compare(cache.generation, revision)
      cache.pending.hasContent = true
      verify(cache.image !== old)
      compare(cache.generation, revision + 1)
    }
    function test_sameAddressNewSourceClearsOldFrame() {
      cache.captureSource = null
      verify(!cache.hasContent)
      compare(cache.image, null)
    }
    function test_endedStreamBecomesRefreshCandidate() {
      cache.image.hasContent = false
      verify(!cache.hasContent)
      verify(cache.needsRefresh)
    }
    function test_disabledCacheReleasesBothBuffersAndCannotRepopulate() {
      cache.refresh(true)
      cache.captureEnabled = false
      compare(cache.front, null); compare(cache.pending, null)
      verify(!cache.hasFrame); compare(cache.capturedAt, 0)
      cache.contentTag = "Tab B"; cache.invalidate(); cache.refresh(true)
      wait(100)
      compare(cache.pending, null); compare(cache.front, null)
      cache.captureEnabled = true
      wait(100)
      verify(cache.pending !== null)
      cache.pending.hasContent = true
      verify(cache.fresh); compare(cache.confirmedTag, "Tab B")
    }
    function test_refreshRequestsAreCoalesced() {
      cache.refresh(false)
      const pending = cache.pending
      cache.refresh(false)
      compare(cache.pending, pending)
    }
  }
}
