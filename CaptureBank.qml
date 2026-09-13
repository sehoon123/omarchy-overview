import QtQuick

// Stable address-keyed producers. A Repeater would discard cached frames when
// the window model resets/reorders during focus changes. Generic for Qt tests.
Item {
  id: bank
  property var model: null
  property bool live: true
  property var liveAddresses: []
  property var entries: ({})
  property int revision: 0
  required property Component factory
  readonly property var windows: model ? model.values : []
  onWindowsChanged: Qt.callLater(reconcile)
  Component.onCompleted: Qt.callLater(reconcile)

  function wantsLive(address) { return live && liveAddresses.includes(address) }
  function lookup(address) {
    const revisionDependency = revision
    return entries[address] || null
  }
  function reconcile() {
    if (!factory) return
    const next = {}
    for (const w of windows) {
      const existing = entries[w.address]
      if (existing) {
        if (existing.modelData !== w) existing.modelData = w
        next[w.address] = existing
      } else {
        next[w.address] = factory.createObject(bank, { modelData: w })
      }
    }
    for (const address in entries) {
      if (!next[address] && entries[address]) entries[address].destroy()
    }
    entries = next
    revision++
  }
}
