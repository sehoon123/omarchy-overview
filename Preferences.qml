import QtQuick
import "OverviewLogic.js" as Logic

// The view supplies an atomic file writer. One write at a time, rapid edits
// coalesce, unknown keys survive, and malformed/newer files are never replaced.
QtObject {
  id: store
  property var document: ({})
  property var pending: ({})
  property var inFlight: null
  property bool ready: false
  property bool writable: false
  property string error: ""
  readonly property var values: Logic.settings(Object.assign({}, document, inFlight || {}, pending))
  readonly property bool saving: !!inFlight || Object.keys(pending).length > 0
  signal writeRequested(string text)
  property Timer debounce: Timer { interval: 150; onTriggered: store.flush() }

  function load(text) {
    if (inFlight) return // A stale read must not roll back an unacknowledged write.
    try {
      const next = JSON.parse(text)
      if (!next || Array.isArray(next) || typeof next !== "object" ||
          (next.version !== undefined && next.version !== 1)) throw new Error("Unsupported settings document")
      document = next; ready = true; writable = true; error = ""
    } catch (e) { loadFailed("Settings file is invalid or uses a newer version; it has not been overwritten") }
  }
  function loadFailed(message) {
    ready = true; writable = false; error = message
    pending = ({}); debounce.stop()
  }
  function set(name, value) {
    const next = Logic.setting(name, value)
    if (!writable || next === undefined || values[name] === next) return false
    pending = Object.assign({}, pending, { [name]: next })
    debounce.restart()
    return true
  }
  function flush() {
    if (!writable || inFlight || !Object.keys(pending).length) return
    inFlight = Object.assign({}, document, pending, { version: 1 })
    pending = ({})
    writeRequested(JSON.stringify(inFlight, null, 2) + "\n")
  }
  function saved() {
    if (!inFlight) return
    document = inFlight; inFlight = null; error = ""
    Qt.callLater(flush)
  }
  function failed(message) {
    inFlight = null; pending = ({}); debounce.stop()
    error = message // Restore the last confirmed values; never silently retry.
  }
}
