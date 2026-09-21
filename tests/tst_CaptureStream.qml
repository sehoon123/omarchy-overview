import QtQuick
import QtTest
import ".."

Item {
  id: scene
  width: 800; height: 600
  property int created: 0
  QtObject { id: first; property color tint: "#ff0000" }
  QtObject { id: second; property color tint: "#0000ff" }
  Component {
    id: fakeStream
    Rectangle {
      property var captureSource: null
      property bool live: false
      readonly property bool hasContent: !!captureSource
      readonly property size sourceSize: Qt.size(400, 300)
      signal stopped()
      color: captureSource ? captureSource.tint : "transparent"
      Component.onCompleted: scene.created++
    }
  }
  CaptureStream { id: capture; factory: fakeStream }
  WindowPreview {
    id: card; x: 40; y: 40; width: 400; height: 300
    windowInfo: ({ title: "Synthetic window", lastIpcObject: { size: [400, 300], class: "fixture" } })
    sharedCapture: capture
  }
  DesktopPreview {
    id: desktop; x: 500; y: 40
    members: [{ address: "fixture", lastIpcObject: { size: [400, 300] } }]
    captureFor: address => capture
  }
  TestCase {
    name: "VisibleCaptureLifecycle"; when: windowShown
    function init() {
      capture.captureEnabled = false; capture.captureSource = null; capture.allowStart = true
      capture.live = true; first.tint = "#ff0000"; wait(0); scene.created = 0
      capture.captureSource = first
    }
    function cleanup() { capture.captureEnabled = false; wait(0) }
    function test_disabledNeverCreatesEvenWithSourceAndLive() {
      wait(30); compare(scene.created, 0); compare(capture.viewCount, 0)
      capture.live = false; capture.live = true
      compare(scene.created, 0)
    }
    function test_singleSourceSharedByMainCardAndDesktop() {
      capture.captureEnabled = true
      tryCompare(card, "hasThumbnail", true)
      compare(scene.created, 1); compare(capture.viewCount, 1)
      compare(findChild(card, "previewTexture").sourceItem, capture.stream)
      compare(findChild(desktop, "desktopTexture").sourceItem, capture.stream)
      const original = capture.stream
      card.width = 600; card.height = 450; wait(0)
      compare(capture.stream, original); compare(scene.created, 1)
      card.width = 400; card.height = 300
    }
    function test_visiblePixelsUpdateWithoutReplacingProducer() {
      capture.captureEnabled = true
      tryCompare(card, "hasThumbnail", true)
      verify(waitForRendering(card))
      const original = capture.stream
      const red = grabImage(card)
      compare(red.red(200, 150), 255); compare(red.blue(200, 150), 0)
      first.tint = "#0000ff"
      verify(waitForRendering(card))
      const blue = grabImage(card)
      compare(blue.red(200, 150), 0); compare(blue.blue(200, 150), 255)
      compare(capture.stream, original); compare(scene.created, 1)
    }
    function test_closeNullsProtocolSourceBeforeDeferredDestruction() {
      capture.captureEnabled = true
      const old = capture.stream
      capture.captureEnabled = false
      compare(old.captureSource, null); compare(old.live, false)
      compare(capture.viewCount, 0); compare(card.hasThumbnail, false)
      wait(0)
      compare(findChild(card, "previewTexture"), null)
      compare(findChild(desktop, "desktopTexture"), null)
      capture.captureEnabled = true
      compare(scene.created, 2); verify(capture.hasContent)
    }
    function test_sourceIdentityReplacementNeverKeepsOldFrame() {
      capture.captureEnabled = true
      const old = capture.stream
      capture.captureSource = second
      compare(old.captureSource, null)
      verify(capture.stream !== old)
      compare(capture.stream.captureSource, second)
      compare(scene.created, 2)
    }
    function test_failureDoesNotCreateRetryStorm() {
      capture.captureEnabled = true
      capture.stream.stopped()
      compare(capture.failed, true); compare(capture.viewCount, 0)
      capture.live = false; capture.live = true
      wait(100); compare(scene.created, 1)
      capture.captureEnabled = false; capture.captureEnabled = true
      compare(scene.created, 2); compare(capture.failed, false)
    }
    function test_closingCanKeepExistingFrameButCannotStartAnother() {
      capture.captureEnabled = true
      capture.allowStart = false; capture.live = false
      verify(capture.hasContent)
      capture.captureSource = second
      compare(capture.viewCount, 0); compare(scene.created, 1)
      capture.captureEnabled = false; capture.allowStart = true
      compare(scene.created, 1)
    }
  }
}
