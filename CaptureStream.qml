import QtQuick

// Exactly one stream per window during an open session. No double buffering,
// title-triggered reconnect, periodic retry, or retained stream after close.
Item {
  id: capture
  required property Component factory
  property var captureSource: null
  property bool captureEnabled: false
  property bool allowStart: true
  property bool live: true
  property bool initialized: false
  property bool failed: false
  property var stream: null
  property int serial: 0
  property int generation: 0
  property double capturedAt: 0
  readonly property var image: stream
  readonly property bool hasContent: captureEnabled && !!stream && stream.hasContent
  readonly property bool hasFrame: hasContent
  readonly property bool fresh: hasContent && live && !failed
  readonly property size sourceSize: hasContent ? stream.sourceSize : Qt.size(0, 0)
  readonly property int viewCount: stream ? 1 : 0

  onAllowStartChanged: if (allowStart) start()
  onCaptureEnabledChanged: {
    if (!captureEnabled) { release(); failed = false }
    else start()
  }
  onCaptureSourceChanged: { release(); failed = false; start() }
  Component.onCompleted: { initialized = true; start() }
  Component.onDestruction: release()

  function release() {
    if (!stream) return
    const old = stream
    stream = null
    // Null the actual protocol source synchronously, before deferred deletion.
    old.live = false; old.captureSource = null
    old.destroy()
  }
  function start() {
    if (!initialized || !captureEnabled || !allowStart || !captureSource || stream || failed) return
    const view = factory.createObject(capture)
    if (!view) { failed = true; return }
    stream = view; generation++
    view.live = Qt.binding(() => capture.captureEnabled && capture.live)
    view.width = Qt.binding(() => Math.max(1, view.sourceSize.width))
    view.height = Qt.binding(() => Math.max(1, view.sourceSize.height))
    view.captureSource = captureSource
  }
  Connections {
    target: capture.stream
    function onHasContentChanged() { if (capture.hasContent) capture.capturedAt = Date.now() }
    function onStopped() {
      // Never auto-retried, with no knob to make it one (AGENTS.md): every new
      // stream is a new exposure to the compositor's session lifetime, so a
      // `stopped` is final until an explicit new Overview session builds a fresh
      // stream. The card says exactly that (Logic.previewReason, AUDIT.md F-11).
      capture.failed = true
      capture.release()
    }
  }
}
