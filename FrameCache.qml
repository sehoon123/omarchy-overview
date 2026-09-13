import QtQuick

// Double-buffered, generation-tagged snapshots. Generic for offscreen Qt tests.
Item {
  id: cache
  required property Component factory
  property var captureSource: null
  property string contentTag: ""
  property bool live: false
  property bool captureEnabled: true
  property var front: null
  property var pending: null
  property string pendingTag: ""
  property string confirmedTag: ""
  property int generation: 0
  property double capturedAt: 0
  property double metadataChangedAt: 0
  property bool dirty: true
  readonly property bool needsRefresh: dirty || !hasContent
  readonly property var image: front
  readonly property bool hasFrame: !!front && !!front.hasContent
  // A frame of a different tab/size must never masquerade as the current one.
  readonly property bool hasContent: hasFrame && confirmedTag === contentTag
  readonly property bool fresh: hasContent && !needsRefresh
  readonly property bool refreshing: !!pending
  readonly property var sourceSize: hasFrame && front && front.sourceSize ? front.sourceSize : Qt.size(0, 0)
  signal refreshed(int generation)

  onContentTagChanged: { metadataChangedAt = Date.now(); dirty = true; debounce.restart() }
  onCaptureSourceChanged: {
    release(pending); pending = null
    release(front); front = null
    confirmedTag = ""; capturedAt = 0; dirty = true
    debounce.restart()
  }
  onLiveChanged: if (live) refresh(false)
  onCaptureEnabledChanged: {
    if (captureEnabled) debounce.restart()
    else clear()
  }
  Component.onCompleted: debounce.restart()

  function release(item) {
    if (!item) return
    item.captureSource = null
    item.destroy()
  }
  function clear() {
    debounce.stop(); expiry.stop()
    release(pending); pending = null
    release(front); front = null
    confirmedTag = ""; capturedAt = 0; dirty = true
  }
  function invalidate() { dirty = true; if (captureEnabled) debounce.restart() }
  function refresh(force) {
    if (!captureEnabled || !captureSource || !factory) return generation + 1
    const remaining = 80 - (Date.now() - metadataChangedAt)
    if (remaining > 0) { debounce.interval = remaining; debounce.restart(); return generation + 1 }
    if (pending && !force && pendingTag === contentTag) return generation + 1
    release(pending); pending = null
    pendingTag = contentTag
    const view = factory.createObject(cache, { captureSource: captureSource })
    if (!view) return generation + 1
    view.live = Qt.binding(() => cache.live && cache.front === view)
    pending = view
    expiry.restart()
    if (view.hasContent) commit()
    return generation + (pending ? 1 : 0)
  }
  function commit() {
    if (!pending || !pending.hasContent) return
    if (pendingTag !== contentTag) {
      release(pending); pending = null; debounce.restart(); return
    }
    const old = front
    confirmedTag = pendingTag
    front = pending; pending = null
    generation++; capturedAt = Date.now(); dirty = false
    expiry.stop(); release(old)
    refreshed(generation)
  }
  Connections {
    target: cache.pending
    function onHasContentChanged() { cache.commit() }
  }
  // Let Chromium commit its tab repaint after the title notification.
  Timer { id: debounce; interval: 80; onTriggered: cache.refresh(false) }
  Timer {
    id: expiry; interval: 1500
    onTriggered: { cache.release(cache.pending); cache.pending = null }
  }
}
