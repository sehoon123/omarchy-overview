import QtQuick

// Encoded output crops only. No native capture handles or Wayland requests.
Item {
  id: bank
  property var model: null
  property bool shown: false
  property bool keepCache: true
  property double openedAt: 0
  property int maxBytes: 8 * 1024 * 1024
  property int maxPixels: 12000000
  property int generation: 0
  property var entries: ({})
  readonly property var windows: model ? model.values : []
  readonly property int retainedBytes: Object.values(entries).reduce((sum, e) => sum + e.imageSource.length, 0)
  readonly property int retainedPixels: Object.values(entries).reduce((sum, e) => sum + e.width * e.height, 0)
  onWindowsChanged: Qt.callLater(prune)
  onShownChanged: if (!shown && !keepCache) clear()
  onKeepCacheChanged: if (!shown && !keepCache) clear()

  function clear() { entries = ({}) }
  function prune() {
    const addresses = windows.map(w => w.address)
    const next = {}
    for (const address in entries) if (addresses.includes(address)) next[address] = entries[address]
    entries = next
  }
  function lookup(address) {
    const frame = entries[address]
    const window = windows.find(w => w.address === address)
    if (!frame || !window) return null
    const ipc = window.lastIpcObject || {}
    // Do not present another window, a prior tab or a prior size as this one.
    if ((frame.pid != null && frame.pid !== ipc.pid) ||
        (frame.stableId != null && frame.stableId !== ipc.stableId) ||
        frame.title !== (window.title || "") || JSON.stringify(frame.windowSize) !== JSON.stringify(ipc.size || [])) return null
    return Object.assign({}, frame, { previous: frame.capturedAt < openedAt })
  }
  function accept(result) {
    if (!result || !result.ok || !Array.isArray(result.frames)) return
    const next = Object.assign({}, entries)
    const addresses = windows.map(w => w.address)
    generation++
    for (const frame of result.frames) {
      if (!addresses.includes(frame.address) || typeof frame.imageSource !== "string" ||
          !frame.imageSource.startsWith("data:image/png;base64,") || frame.imageSource.length > maxBytes ||
          !(frame.width > 0 && frame.height > 0) || frame.width * frame.height > 1800000) continue
      next[frame.address] = Object.assign({}, frame, {
        hasContent: true, hasFrame: true, fresh: false, generation: generation,
        sourceSize: Qt.size(frame.width, frame.height)
      })
    }
    // Oldest first; count and encoded-byte bounds also cover never-visited tabs.
    const ordered = Object.keys(next).filter(a => addresses.includes(a))
      .sort((a, b) => next[b].capturedAt - next[a].capturedAt)
    const bounded = {}
    let bytes = 0, pixels = 0
    for (const address of ordered.slice(0, 128)) {
      const frame = next[address], area = frame.width * frame.height
      if (bytes + frame.imageSource.length > maxBytes || pixels + area > maxPixels) continue
      bounded[address] = frame; bytes += frame.imageSource.length; pixels += area
    }
    entries = bounded
  }
}
