import QtQuick

// Stable native producers, owned by one visible Overview session. Search,
// selection, desktop thumbnails and Quick Look share these same instances.
Item {
  id: bank
  property var model: null
  property bool active: false
  property bool allowNew: true
  property var addresses: []
  property var liveAddresses: []
  property var entries: ({})
  property int revision: 0
  property int nextSerial: 0
  required property Component factory
  readonly property var windows: model ? model.values : []
  readonly property int viewCount: Object.values(entries).reduce((n, e) => n + e.viewCount, 0)
  readonly property int frameCount: Object.values(entries).filter(e => e.hasContent).length
  onWindowsChanged: Qt.callLater(reconcile)
  onAddressesChanged: Qt.callLater(reconcile)
  onActiveChanged: { if (active) Qt.callLater(reconcile); else clear() }
  onAllowNewChanged: if (allowNew && active) Qt.callLater(reconcile)
  Component.onCompleted: if (active) Qt.callLater(reconcile)

  function wantsLive(address) { return active && liveAddresses.includes(address) }
  function lookup(address) { const dependency = revision; return entries[address] || null }
  function release(entry) {
    if (!entry) return
    entry.captureEnabled = false
    entry.destroy()
  }
  function clear() {
    const old = entries
    entries = ({}); revision++
    for (const address in old) release(old[address])
  }
  function reconcile() {
    if (!active || !factory) { clear(); return }
    const next = {}
    for (const window of windows) {
      if (next[window.address]) continue
      const old = entries[window.address]
      // Address reuse is not identity continuity. Never inherit another source.
      const keep = !!old && old.modelData === window
      // While new sources are forbidden (closing), a capture-plan change must
      // not release a producer this bank is not allowed to recreate.
      if (!addresses.includes(window.address) && !(keep && !allowNew)) continue
      const entry = keep ? old : allowNew
        ? factory.createObject(bank, { modelData: window, serial: ++nextSerial }) : null
      if (entry) next[window.address] = entry
    }
    for (const address in entries)
      if (entries[address] !== next[address]) release(entries[address])
    entries = next; revision++
  }
}
