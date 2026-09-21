import QtQuick
import QtTest
import ".."
import "../OverviewLogic.js" as Logic

Item {
  id: scene
  width: 800; height: 600
  property int created: 0
  property int destroyed: 0
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
      Component.onDestruction: scene.destroyed++
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
      capture.live = true
      first.tint = "#ff0000"; wait(0); scene.created = 0; scene.destroyed = 0
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
    function test_releaseIsSynchronousAndTheStreamIsNotLeaked() {
      capture.captureEnabled = true
      const old = capture.stream
      capture.captureEnabled = false
      compare(capture.stream, null)
      compare(old.captureSource, null); compare(old.live, false)
      compare(scene.destroyed, 0)
      compare(capture.viewCount, 0); compare(capture.hasContent, false)
      compare(capture.hasFrame, false); compare(capture.fresh, false)
      compare(capture.sourceSize, Qt.size(0, 0))
      tryCompare(scene, "destroyed", 1)
      compare(scene.created, 1)
    }
    function test_windowVanishingMidRenderReleasesWithoutDanglingTexture() {
      capture.captureEnabled = true
      tryCompare(card, "hasThumbnail", true)
      verify(waitForRendering(card))
      const old = capture.stream
      capture.captureSource = null
      compare(capture.stream, null)
      compare(old.captureSource, null); compare(old.live, false)
      compare(capture.viewCount, 0); compare(capture.hasContent, false)
      compare(card.hasThumbnail, false); compare(capture.failed, false)
      wait(0)
      compare(findChild(card, "previewTexture"), null)
      compare(findChild(desktop, "desktopTexture"), null)
      verify(waitForRendering(card))
      tryCompare(scene, "destroyed", 1)
      compare(scene.created, 1)
    }
    function test_stoppedFromAReleasedStreamCannotStrandTheCard() {
      capture.captureEnabled = true
      const old = capture.stream
      capture.captureEnabled = false
      old.stopped()
      compare(capture.failed, false); compare(capture.stream, null)
      capture.captureEnabled = true
      compare(scene.created, 2); verify(capture.hasContent); compare(capture.failed, false)
      const replaced = capture.stream
      capture.captureSource = second
      replaced.stopped()
      compare(capture.failed, false); verify(capture.hasContent)
      compare(capture.stream.captureSource, second)
      compare(scene.created, 3)
    }
    function test_stoppedIsNeverAutoRetriedWithinTheSession() {
      // The invariant is unconditional: there is no knob that could turn a
      // `stopped` into a re-attempt, because every new stream is a new exposure
      // to the compositor's session lifetime (AGENTS.md, AUDIT.md F-11).
      verify(capture.retryLimit === undefined)
      verify(capture.retries === undefined)
      verify(capture.retryOnce === undefined)
      capture.captureEnabled = true
      capture.stream.stopped()
      compare(capture.failed, true); compare(capture.viewCount, 0); compare(capture.stream, null)
      wait(0); wait(0)
      compare(scene.created, 1)
      capture.live = false; capture.live = true
      capture.allowStart = false; capture.allowStart = true
      wait(0); wait(0)
      compare(scene.created, 1); compare(capture.failed, true)
      compare(capture.hasContent, false); compare(capture.fresh, false)
      // Nothing deferred, timed or re-armed brings it back for the rest of this
      // session: not an event-loop turn, not a real wait, not repeated interest.
      for (let i = 0; i < 4; i++) { capture.live = !capture.live; wait(0) }
      capture.live = true
      capture.allowStart = false; wait(0); capture.allowStart = true
      wait(250)
      compare(scene.created, 1); compare(capture.failed, true)
      compare(capture.stream, null); compare(capture.viewCount, 0)
      compare(capture.hasContent, false); compare(capture.hasFrame, false); compare(capture.fresh, false)
      compare(capture.sourceSize, Qt.size(0, 0))
      // Calling start() directly is still refused while failed, so no caller can
      // reconstruct the removed retry path.
      capture.start()
      wait(0)
      compare(scene.created, 1); compare(capture.stream, null)
    }
    function test_aNewSessionRecoversTheStreamTheCardPointsAt() {
      // The card says "Live preview stopped \u00b7 reopen Overview to retry"
      // (Logic.previewReason), so reopening must be a real cure: a new session
      // rebuilds the capture (captureEnabled cycles per session, and CaptureBank
      // recreates the entry), and so does a replaced source.
      capture.captureEnabled = true
      capture.stream.stopped()
      compare(capture.failed, true); compare(scene.created, 1)
      capture.captureEnabled = false
      compare(capture.failed, false)
      capture.captureEnabled = true
      compare(scene.created, 2); compare(capture.failed, false); verify(capture.hasContent)
      compare(capture.stream.captureSource, first)
      // A second stop in the new session is again final until the session after it.
      capture.stream.stopped()
      wait(0); wait(0)
      compare(scene.created, 2); compare(capture.failed, true)
      capture.captureSource = second
      compare(capture.failed, false); compare(scene.created, 3)
      compare(capture.stream.captureSource, second); verify(capture.hasContent)
    }
    function test_aStoppedStreamsCardSaysWhatActuallyWorks() {
      // shell.qml binds WindowPreview.unavailableText to Logic.previewReason(), so
      // the QML engine - not only node - must reach that policy and the card must
      // show the one thing that works: reopening Overview (AUDIT.md F-11).
      const original = card.unavailableText
      capture.captureEnabled = true
      tryCompare(card, "hasThumbnail", true)
      card.unavailableText = Qt.binding(() => Logic.previewReason({ refusal: "", captureEnabled: true,
        planned: true, hasCapture: true, failed: capture.failed }))
      compare(card.unavailableText, "Loading window preview…")
      compare(findChild(card, "previewPlaceholder").visible, false)
      capture.stream.stopped()
      compare(capture.failed, true); compare(card.hasThumbnail, false)
      verify(findChild(card, "previewPlaceholder").visible)
      const text = findChild(card, "previewUnavailable")
      compare(card.unavailableText, "Live preview stopped · reopen Overview to retry")
      compare(text.text, "Live preview stopped · reopen Overview to retry")
      verify(text.visible); verify(!text.truncated); verify(text.contentWidth <= text.width)
      // Reopening is a real cure, so the sentence is not a dead end.
      capture.captureEnabled = false; capture.captureEnabled = true
      tryCompare(card, "hasThumbnail", true)
      compare(card.unavailableText, "Loading window preview…")
      card.unavailableText = original
    }
    function test_aHeldPlanKeepsTheImageThroughTheCloseAnimation() {
      // shell.qml binds NativeCapture.captureEnabled to the capture plan, so a plan
      // change during the exit animation is exactly what blanks a card mid-motion
      // (AUDIT.md F-13). Logic.capturePlanHold keeps the plan the close inherited.
      const planned = ["synthetic"]
      const enabled = state => Logic.capturePlanHold(state).includes("synthetic")
      capture.captureEnabled = enabled({ closing: false, plan: planned, frozen: [], addresses: planned })
      tryCompare(card, "hasThumbnail", true)
      const producer = capture.stream
      // The close begins: no new stream may be created from here on.
      capture.allowStart = false
      // Unheld, a reordered priority drops this address and blanks the card ...
      compare(enabled({ closing: false, plan: [], frozen: planned, addresses: planned }), false)
      // ... held, it does not.
      compare(enabled({ closing: true, plan: [], frozen: planned, addresses: planned }), true)
      capture.captureEnabled = enabled({ closing: true, plan: [], frozen: planned, addresses: planned })
      wait(50)
      compare(capture.stream, producer); verify(capture.hasContent); verify(card.hasThumbnail)
      compare(scene.created, 1); compare(findChild(card, "previewPlaceholder").visible, false)
      // A window that closed during the animation is not resurrected ...
      compare(enabled({ closing: true, plan: [], frozen: planned, addresses: [] }), false)
      capture.captureEnabled = enabled({ closing: true, plan: [], frozen: planned, addresses: [] })
      compare(capture.stream, null); compare(card.hasThumbnail, false)
      // ... and the held plan cannot start anything while closing.
      capture.captureEnabled = enabled({ closing: true, plan: [], frozen: planned, addresses: planned })
      wait(50)
      compare(scene.created, 1); compare(capture.stream, null)
      verify(findChild(card, "previewPlaceholder").visible)
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
