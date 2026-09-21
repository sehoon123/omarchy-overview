import QtQuick
import QtQuick.Window
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "Layout.js" as OverviewLayout
import "OverviewLogic.js" as Logic

ShellRoot {
  id: root
  property bool shown: Quickshell.env("OVERVIEW_START_HIDDEN") !== "1"
  property string displayName: ""
  property var filterWorkspace: 1
  property string appFilter: ""
  property int selected: 0
  property bool keyboardSelection: false
  property string selectedAddress: ""
  property string previewAddress: ""
  property bool settingsShown: false
  readonly property string query: search.text
  readonly property var previewWindow: windows.find(w => w.address === previewAddress) || null
  property var themeColors: Logic.palette("")
  property var desktopOrder: []
  property var desktopInfo: ({})
  property bool perMonitor: false
  property var pendingWindow: null
  property bool busy: false
  property bool closeWhenDone: false
  property string actionName: ""
  property string message: ""
  property var undoRecord: null
  property var dragSource: null
  property var dragTarget: null
  property point dragPoint: Qt.point(0, 0)
  property var hoverDesktop: 0
  property int actionTicket: 0
  property bool shutdownRequested: false
  property var pendingUiAction: null
  property int openCount: 0
  property int wallpaperRevision: 0
  property string lastFocusedAddress: ""
  property bool framePresented: false
  property bool coverSettled: false
  property double openedAt: 0
  property real firstFrameMs: -1
  readonly property bool preparing: previews.busy
  // Eager subscriptions make opening independent of CLI context probes.
  readonly property var observedMonitors: Hyprland.monitors.values
  // Hyprland 0.56.2 crashes on window capture while that window has no monitor.
  // Client-side hotplug guards cannot close that race. Keep thumbnails disabled
  // until a compositor-side fix is installed and validated. Window actions work.
  readonly property bool windowCaptureEnabled: false
  // Additional safeguards for eventual re-enablement: no hidden capture, and
  // wait after output transitions before creating any window capture session.
  readonly property var previewScreens: Logic.previewScreens(Quickshell.screens)
  readonly property string previewTopology: JSON.stringify(previewScreens.map(s => [s.name, s.width, s.height]))
  property bool captureTopologyReady: false
  onPreviewTopologyChanged: pauseCaptures()
  readonly property var focusedWindow: Logic.focusedWindow(Hyprland.activeToplevel, Hyprland.toplevels.values)
  onFocusedWindowChanged: if (openCount > 0) focusedChanged()
  readonly property color accent: preferences.values.followTheme ? themeColors.accent : "#76b5ff"
  readonly property color surfaceColor: preferences.values.followTheme ? themeColors.background : "#202633"
  readonly property color textColor: preferences.values.followTheme ? themeColors.foreground : "#ecf0f7"
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"
  readonly property string wallpaper: "file://" + stateHome + "/omarchy/current/background?v=" + wallpaperRevision
  readonly property var allWindows: Hyprland.toplevels.values.filter(w =>
    w.lastIpcObject.mapped !== false && Logic.workspaceKey(w.workspace)
  ).slice().sort((a, b) => a.workspace.id - b.workspace.id || a.address.localeCompare(b.address))
  readonly property var scopeWindows: allWindows.filter(w => (filterWorkspace === 0 || Logic.workspaceKey(w.workspace) === filterWorkspace) &&
    (!appFilter || w.lastIpcObject.class === appFilter) && (!(perMonitor || preferences.values.monitorOnly) ||
      (w.workspace && w.workspace.monitor ? w.workspace.monitor.name === displayName :
        w.lastIpcObject.monitor === (observedMonitors.find(m => m.name === displayName) || {}).id)))
  readonly property var windows: scopeWindows.filter(w => Logic.matches(w, query))
  readonly property var workspaceIds: Logic.workspaceKeys(desktopOrder, Hyprland.workspaces.values, desktopInfo, displayName, perMonitor)
  onWorkspaceIdsChanged: Qt.callLater(revealDesktop)
  // Title/focus metadata churn must not rerun the geometry search.
  readonly property string layoutKey: JSON.stringify(windows.map(w => aspectFor(w)))
  readonly property var placements: OverviewLayout.arrange(JSON.parse(layoutKey), stage.width, stage.height)
  onFilterWorkspaceChanged: { selectedAddress = ""; selected = 0; keyboardSelection = false; if (previewAddress) closePreview() }
  onBusyChanged: if (!busy) Qt.callLater(restoreSearchFocus)
  onSelectedChanged: if (windows[selected]) selectedAddress = windows[selected].address
  onWindowsChanged: {
    selected = Logic.selectionIndex(windows, selectedAddress, selected)
    selectedAddress = windows[selected] ? windows[selected].address : ""
    if (previewAddress && !windows.some(w => w.address === previewAddress)) closePreview()
  }
  onAllWindowsChanged: {
    if (dragSource && dragSource.kind === "window" && !allWindows.some(w => w.address === dragSource.address)) input.cancelDrag()
  }

  Component.onCompleted: {
    pauseCaptures()
    displayName = Quickshell.env("OVERVIEW_INITIAL_MONITOR") || (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "")
    const initialDesktop = Quickshell.env("OVERVIEW_INITIAL_WORKSPACE") || ""
    filterWorkspace = initialDesktop.startsWith("name:") ? initialDesktop : Number(initialDesktop) > 0 ? Number(initialDesktop) : Logic.workspaceKey(Hyprland.focusedWorkspace) || 1
    if (Quickshell.env("OVERVIEW_APP_ONLY") === "1") {
      appFilter = Quickshell.env("OVERVIEW_INITIAL_APP") || (focusedWindow ? focusedWindow.lastIpcObject.class : "") || ""
      filterWorkspace = 0
    }
    if (shown) {
      openedAt = Date.now(); openCount++
      Qt.callLater(search.focusInput)
    }
  }

  function pauseCaptures() {
    captureTopologyReady = false
    captureSettle.restart()
  }
  function aspectFor(w) { return OverviewLayout.aspectFor(w, captureFor(w.address)) }
  function captureFor(address) { return captureBank.lookup(address) }
  function openOverview(mode) {
    if (shutdownRequested || activateTimer.running) return
    search.text = ""; previewAddress = ""; settingsShown = false
    paletteFile.reload(); settingsFile.reloadIfIdle()
    displayName = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : displayName
    filterWorkspace = Logic.workspaceKey(Hyprland.focusedWorkspace) || 1
    appFilter = mode === "app" && focusedWindow ? focusedWindow.lastIpcObject.class || "" : ""
    if (mode === "app") filterWorkspace = 0
    selected = Logic.selectionIndex(windows, focusedWindow ? focusedWindow.address : "", 0)
    selectedAddress = windows[selected] ? windows[selected].address : ""; keyboardSelection = false
    input.cancelDrag(); input.hovered = ({ kind: "background", key: "background" })
    message = ""; undoRecord = null; pendingUiAction = null
    closeWhenDone = false
    desktopFlick.contentX = 0
    openedAt = Date.now(); firstFrameMs = -1; framePresented = false; coverSettled = false
    lastFocusedAddress = focusedWindow ? focusedWindow.address : ""
    shown = true; openCount++
    stateRefresh.restart()
    Qt.callLater(revealDesktop)
    search.focusInput()
  }
  function finishClose() {
    shown = false
    message = ""; undoRecord = null; pendingUiAction = null
    input.cancelDrag(); hoverTimer.stop()
    previewAddress = ""; settingsShown = false
    finishShutdown()
  }
  function finishShutdown() {
    if (!shutdownRequested || busy || preparing || activateTimer.running) return
    preferences.flush()
    if (!preferences.saving) Qt.quit()
  }
  function restoreSearchFocus() {
    if (shown && !busy && !settingsShown && !previewAddress && !input.dragging) search.focusInput()
  }
  function closePreview() { previewAddress = ""; restoreSearchFocus() }
  function togglePreview() {
    if (previewAddress) { closePreview(); return }
    if (!windows[selected] || input.dragging || busy) return
    previewAddress = windows[selected].address
    keyboardSelection = true; hoverTimer.stop(); content.forceActiveFocus()
  }
  function showSettings() {
    if (input.dragging || busy) return
    previewAddress = ""; settingsShown = true; hoverTimer.stop(); previews.cancel()
    Qt.callLater(settingsPanel.focusFirst)
  }
  function handleKey(event, editing) {
    const ctrl = !!(event.modifiers & Qt.ControlModifier)
    if (event.key === Qt.Key_Escape) {
      if (editing && search.compositionGuard) search.clear()
      else if (input.dragging) input.cancelDrag()
      else if (settingsShown) { settingsShown = false; search.focusInput() }
      else if (previewAddress) closePreview()
      else if (query) search.clear()
      else closeOverview()
      event.accepted = true; return
    }
    if (settingsShown) return
    if (busy || input.dragging) { event.accepted = true; return }
    // Enter/Space/arrows first belong to the IME while composing a syllable.
    if (editing && search.compositionGuard) return
    if (ctrl && event.key === Qt.Key_F) { search.focusInput(); search.input.selectAll() }
    else if (event.key === Qt.Key_Space && (ctrl || !editing || !query)) togglePreview()
    else if (ctrl && event.key === Qt.Key_Z && (!editing || !query)) undo()
    else if (ctrl && (event.key === Qt.Key_Left || event.key === Qt.Key_Right))
      navigateDesktop(event.key === Qt.Key_Right ? "next" : "previous")
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (windows.length || !query) choose(selected)
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      const step = event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1
      if (windows.length) selected = (selected + step + windows.length) % windows.length
      keyboardSelection = true
    } else {
      const direction = ({ [Qt.Key_Left]: "left", [Qt.Key_Right]: "right", [Qt.Key_Up]: "up", [Qt.Key_Down]: "down" })[event.key]
      if (!direction || (editing && query && ["left", "right"].includes(direction))) return
      selected = OverviewLayout.neighbor(placements, selected, direction)
      keyboardSelection = true
    }
    if (previewAddress && windows[selected]) previewAddress = windows[selected].address
    event.accepted = true
  }
  function flushPendingAction() {
    const action = pendingUiAction
    pendingUiAction = null
    if (!action) return
    if (action.kind === "choose") {
      const index = windows.findIndex(w => w.address === action.address)
      if (index >= 0) choose(index)
    } else if (action.kind === "command") runAction(action.args, action.exitAfter)
    else if (action.kind === "click") clicked(action.zone)
  }
  function focusedChanged() {
    lastFocusedAddress = focusedWindow ? focusedWindow.address : ""
  }
  function deferForCapture(action) {
    if (!preparing) return false
    pendingUiAction = action
    previews.cancel()
    return true
  }
  function flash(text) { message = text; toastTimer.restart() }
  function closeOverview() {
    input.cancelDrag()
    if (busy || preparing) { closeWhenDone = true; previews.cancel(); return }
    finishClose()
  }
  function runAction(args, exitAfter) {
    if (busy || deferForCapture({ kind: "command", args: args, exitAfter: !!exitAfter })) return
    actionName = args[0]
    closeWhenDone = !!exitAfter
    actionTicket = bridge.request(args, {}, shown ? displayName : "")
    busy = actionTicket !== 0
    if (!busy) { closeWhenDone = false; flash("Overview backend is restarting; please try again") }
  }
  function actionFinished(result) {
    actionTicket = 0; busy = false
    if (!result.ok) {
      if (closeWhenDone) { finishClose(); return }
      flash(result.error || "Could not complete the action")
      flushPendingAction()
      return
    }
    if (result.desktops) desktopInfo = result.desktops
    if (typeof result.perMonitor === "boolean") perMonitor = result.perMonitor
    if (Array.isArray(result.order)) desktopOrder = result.order
    if (result.removed && filterWorkspace === result.removed) filterWorkspace = result.target
    if (result.undo) undoRecord = result.undo
    else if (["state", "switch"].indexOf(actionName) < 0) undoRecord = null
    if (result.message) flash(result.message)
    if (closeWhenDone) finishClose()
    else flushPendingAction()
  }
  function undo() { if (undoRecord && !busy) runAction(["undo", JSON.stringify(undoRecord)]) }
  function desktopLabel(id) { return (desktopInfo[String(id)] || {}).label || "Desktop " + String(id).replace(/^name:/, "") }
  function switchDesktop(id) { if (id) runAction(["switch", String(id)], true) }
  function revealDesktop() {
    if (!shown || input.dragging || input.pressedZone) return
    const item = desktops.itemAt(workspaceIds.indexOf(filterWorkspace))
    if (!item) return
    desktopFlick.contentX = Logic.revealOffset(desktopFlick.contentX, desktopFlick.width,
      desktopFlick.contentWidth, desktopRow.x + item.x, item.width, desktopFlick.edgePadding)
  }
  function navigateDesktop(direction) {
    if (!workspaceIds.length || input.dragging || busy || settingsShown) return
    const i = Math.max(0, workspaceIds.indexOf(filterWorkspace))
    filterWorkspace = workspaceIds[Math.max(0, Math.min(workspaceIds.length - 1, i + (direction === "next" ? 1 : -1)))]
    appFilter = ""
    // Hover preview must not move the strip under the pointer; keyboard navigation may.
    Qt.callLater(revealDesktop)
  }
  function choose(index) {
    if (input.dragging) return
    if (busy) return
    if (index < 0 || index >= windows.length) { switchDesktop(filterWorkspace); return }
    if (deferForCapture({ kind: "choose", address: windows[index].address })) return
    pendingWindow = windows[index]
    shown = false
    activateTimer.start()
  }
  function finishDrag(source, target) {
    dragSource = null; dragTarget = null; hoverTimer.stop()
    if (!source || !target) return
    if (source.kind === "window" && (target.kind === "desktop" || target.kind === "add")) {
      runAction(["move", source.address, target.kind === "add" ? "new" : String(target.id)])
    } else if (source.kind === "desktop" && target.kind === "desktop" && source.id !== target.id) {
      runAction(["reorder", String(source.id), String(target.id)])
    }
  }
  function zone(kind, item, extra) {
    const p = item.mapToItem(content, 0, 0)
    return Object.assign({ kind: kind, key: kind, x: p.x, y: p.y, width: item.width, height: item.height }, extra || {})
  }
  function zones() {
    const out = [zone("exit", exitButton), zone("add", addButton), zone("all", allButton)]
    if (toast.visible && undoRecord) out.unshift(zone("undo", undoButton))
    for (let i = 0; i < desktops.count; i++) {
      const item = desktops.itemAt(i)
      if (!item) continue
      const p = item.mapToItem(content, 0, 0)
      const clip = desktopFlick.mapToItem(content, 0, 0)
      // Hit targets are clipped with the scrollable strip, including close buttons.
      if (p.x + item.width < clip.x || p.x > clip.x + desktopFlick.width) continue
      if (item.removeButton.visible) {
        const close = zone("remove", item.removeButton, { id: item.desktopId, key: "remove:" + item.desktopId })
        const closeRight = Math.min(close.x + close.width, clip.x + desktopFlick.width)
        close.x = Math.max(close.x, clip.x); close.width = Math.max(0, closeRight - close.x)
        out.push(close)
      }
      const z = zone("desktop", item, { id: item.desktopId, key: "desktop:" + item.desktopId })
      const right = Math.min(z.x + z.width, clip.x + desktopFlick.width)
      z.x = Math.max(z.x, clip.x); z.width = Math.max(0, right - z.x)
      out.push(z)
    }
    out.push(zone("strip", strip))
    for (let i = 0; i < windowRepeater.count; i++) {
      const item = windowRepeater.itemAt(i)
      if (item && item.inLayout) out.push(zone("window", item.surface, { index: item.layoutIndex, address: item.modelData.address, key: "window:" + item.modelData.address, window: item.modelData }))
    }
    return out
  }
  function hitTest(x, y) {
    return zones().find(z => x >= z.x && y >= z.y && x < z.x + z.width && y < z.y + z.height) || { kind: "background", key: "background" }
  }
  function clicked(z) {
    if (busy) return
    if (!["all", "exit"].includes(z.kind) && deferForCapture(z.kind === "window"
        ? { kind: "choose", address: z.address } : { kind: "click", zone: z })) return
    if (z.kind === "window") choose(z.index)
    else if (z.kind === "desktop") switchDesktop(z.id)
    else if (z.kind === "all") { filterWorkspace = 0; appFilter = "" }
    else if (z.kind === "add") runAction(["create"])
    else if (z.kind === "remove") runAction(["remove", String(z.id)])
    else if (z.kind === "undo") undo()
    else if (z.kind === "exit") closeOverview()
    else if (z.kind === "background") {
      if (filterWorkspace) switchDesktop(filterWorkspace)
      else closeOverview()
    }
  }

  Preferences {
    id: preferences
    onWriteRequested: text => Qt.callLater(() => settingsFile.setText(text))
    onSavingChanged: if (!saving && root.shutdownRequested && !root.shown) Qt.callLater(root.finishShutdown)
  }
  FileView {
    id: settingsFile
    path: Quickshell.env("OVERVIEW_SETTINGS_PATH") || Quickshell.shellPath("settings.json")
    watchChanges: true; atomicWrites: true; printErrors: false
    function reloadIfIdle() { if (!preferences.saving) reload() }
    onLoaded: preferences.load(text())
    onLoadFailed: error => {
      if (error === FileViewError.FileNotFound) preferences.load("{}")
      else preferences.loadFailed("Cannot read Overview settings")
    }
    onFileChanged: Qt.callLater(reloadIfIdle)
    onSaved: Qt.callLater(() => { preferences.saved(); settingsFile.reloadIfIdle() })
    onSaveFailed: error => preferences.failed("Could not save settings; previous values restored")
  }
  FileView {
    id: paletteFile
    path: root.stateHome + "/omarchy/current/theme/colors.toml"
    watchChanges: true; printErrors: false
    onLoaded: root.themeColors = Logic.palette(text())
    onFileChanged: Qt.callLater(reload)
  }
  FileView {
    path: root.stateHome + "/omarchy/current/theme.name"
    watchChanges: true; preload: false; printErrors: false
    onFileChanged: paletteFile.reload()
  }

  // Refresh topology on demand/events, never poll or restart the worker.
  Timer {
    id: stateRefresh
    interval: 80
    onTriggered: {
      if (!bridge.ready) return
      if (root.busy || root.preparing) { restart(); return }
      root.runAction(["state"])
    }
  }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (["monitoradded", "monitoraddedv2", "monitorremoved", "monitorremovedv2", "configreloaded"].includes(event.name))
        root.pauseCaptures()
      if (["createworkspace", "destroyworkspace", "moveworkspace", "renameworkspace", "monitoradded", "monitorremoved", "configreloaded"].includes(event.name))
        stateRefresh.restart()
      if (["movewindow", "movewindowv2"].includes(event.name)) Hyprland.refreshToplevels()
    }
  }
  BackendClient {
    id: bridge
    workerPath: Quickshell.shellPath("worker.py")
    onReadyChanged: if (ready) root.runAction(["state"])
    onCompleted: (ticket, result) => { if (ticket === root.actionTicket) root.actionFinished(result) }
  }
  PreviewScheduler {
    id: previews
    bank: captureBank; backend: bridge; windows: root.windows
    shown: root.windowCaptureEnabled && root.shown && root.captureTopologyReady
    // The focused monitor may change while this panel remains on its original
    // screen. Never prime an uncovered display after the pointer crosses over.
    covered: root.framePresented && root.coverSettled && !!panel.screen && !!Hyprland.focusedMonitor &&
      panel.screen.name === Hyprland.focusedMonitor.name
    foregroundBusy: root.busy
    suspended: !root.windowCaptureEnabled || !root.captureTopologyReady || root.closeWhenDone || !!root.pendingUiAction || input.dragging || !!input.pressedZone ||
      root.settingsShown || search.settling || search.input.inputMethodComposing
    workspace: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 0
    monitor: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.id : -1
    onSettled: {
      if (root.closeWhenDone && !root.busy) root.finishClose()
      else root.flushPendingAction()
    }
  }
  Connections {
    target: content.Window.window
    function onFrameSwapped() {
      if (root.shown && !root.framePresented) {
        root.firstFrameMs = Date.now() - root.openedAt
        root.framePresented = true; coverTimer.restart()
      }
    }
  }
  Timer { id: coverTimer; interval: 250; onTriggered: root.coverSettled = root.shown }
  Timer { id: toastTimer; interval: 6500; onTriggered: root.message = "" }
  // No hidden/background capture, even if the old keepCache preference is set.
  // The confirmed last-output crash came from the resident Overview client.
  Timer {
    id: captureSettle
    interval: 1000
    onTriggered: root.captureTopologyReady = root.previewScreens.length > 0
  }
  FileView {
    path: root.stateHome + "/omarchy/current/background"
    watchChanges: true; preload: false; printErrors: false
    onFileChanged: root.wallpaperRevision++
  }
  Timer {
    id: hoverTimer
    interval: 550
    onTriggered: {
      if (!root.settingsShown && !root.previewAddress && root.hoverDesktop !== 0 && (!root.dragSource || root.dragSource.kind === "window")) {
        root.filterWorkspace = root.hoverDesktop
        root.appFilter = ""
      }
    }
  }
  Timer {
    id: activateTimer
    interval: 30
    onTriggered: {
      const w = root.pendingWindow
      if (w && w.wayland) w.wayland.activate()
      else if (w && /^(0x)?[0-9a-f]+$/i.test(w.address)) {
        const address = w.address.startsWith("0x") ? w.address : "0x" + w.address
        Hyprland.dispatch('hl.dsp.focus({ window = "address:' + address + '" })')
      }
      root.pendingWindow = null
      root.finishShutdown()
    }
  }

  IpcHandler {
    target: "overview"
    function openOverview(): void { root.openOverview("") }
    function toggle(mode: string): void {
      if (root.shown) root.closeOverview()
      else root.openOverview(mode)
    }
    function shutdown(): void { root.shutdownRequested = true; root.closeOverview() }
    function captureReady(address: string): bool {
      const source = root.captureFor(address.replace(/^0x/, ""))
      return !!source && source.fresh
    }
    function close(): void { root.closeOverview() }
    function showSettings(): void { if (root.shown) root.showSettings() }
    function navigateDesktop(direction: string): string {
      if (!root.shown) {
        if (!bridge.ready || root.busy || activateTimer.running) return "hidden"
        root.runAction(["step", direction])
        return "ok"
      }
      root.navigateDesktop(direction)
      return "ok"
    }
    function status(): string {
      const cards = []
      for (const w of root.windows) {
        const source = root.captureFor(w.address)
        cards.push({ address: w.address, thumbnail: !!source && source.hasContent,
          fresh: !!source && source.fresh, generation: source ? source.generation : 0,
          capturedAt: source ? source.capturedAt : 0 })
      }
      return JSON.stringify({ visible: root.shown, busy: root.busy, desktop: root.filterWorkspace, appFilter: root.appFilter,
        order: root.workspaceIds, perMonitor: root.perMonitor, monitor: root.displayName,
        desktopLabels: root.workspaceIds.map(root.desktopLabel), windows: cards, dragging: input.dragging, message: root.message,
        query: root.query, selectedAddress: root.selectedAddress, previewAddress: root.previewAddress,
        settingsShown: root.settingsShown, settings: preferences.values, settingsError: preferences.error,
        liveAddresses: captureBank.live ? captureBank.liveAddresses : [], delegateCount: windowRepeater.count,
        cachedFrames: Object.values(captureBank.entries).filter(e => e && e.hasFrame).length,
        windowCaptureEnabled: root.windowCaptureEnabled,
        captureTopologyReady: root.captureTopologyReady,
        captureViews: Object.values(captureBank.entries).filter(e => e && (e.front || e.pending)).length,
        accent: String(root.accent), composing: search.input.inputMethodComposing, searchFocused: search.input.activeFocus,
        preparing: root.preparing, primed: Object.keys(previews.attempted), openCount: root.openCount,
        firstFrameMs: root.firstFrameMs, workerPid: bridge.processId, workerRestarts: bridge.restarts,
        completedRequests: bridge.completedCount, lastActionMs: bridge.lastElapsedMs,
        layout: { x: stage.x, y: stage.y, width: stage.width, height: stage.height, rects: root.placements },
        zones: root.zones().map(z => ({ kind: z.kind, id: z.id, address: z.address, x: z.x, y: z.y, width: z.width, height: z.height })) })
    }
  }

  PanelWindow {
    id: panel
    visible: root.shown && root.previewScreens.length > 0
    screen: root.previewScreens.find(s => s.name === root.displayName) || root.previewScreens[0] || null
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "sehun-overview"
    WlrLayershell.keyboardFocus: root.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    color: "#151923"
    Image {
      anchors.fill: parent; source: root.wallpaper
      sourceSize: Qt.size(1920, 1080); fillMode: Image.PreserveAspectCrop; cache: true
      layer.enabled: preferences.values.blur
      layer.effect: MultiEffect { blurEnabled: preferences.values.blur; blur: .45; blurMax: 32 }
    }
    Rectangle { anchors.fill: parent; color: Qt.rgba(.043, .055, .09, preferences.values.dim / 100) }

    Item {
      id: content
      anchors.fill: parent; focus: true
      CaptureBank {
        id: captureBank
        model: Hyprland.toplevels; live: root.windowCaptureEnabled && root.shown && root.captureTopologyReady
        liveAddresses: Logic.liveAddresses(root.previewAddress ? [] : root.windows,
          [root.previewAddress, root.dragSource ? root.dragSource.address : "", root.windows[root.selected] ? root.windows[root.selected].address : ""],
          preferences.values.liveLimit)
        factory: Component {
          CaptureProducer {
            live: captureEnabled && captureBank.wantsLive(modelData.address)
            captureEnabled: root.windowCaptureEnabled && Logic.canCapture(root.shown, root.captureTopologyReady, modelData, root.previewScreens)
          }
        }
      }
      Keys.onPressed: event => root.handleKey(event, search.input.activeFocus)

      Rectangle {
        id: strip
        width: parent.width; height: 140; color: "#600c1019"
        Rectangle {
          id: allButton
          x: 24; width: 46; height: 30; anchors.verticalCenter: parent.verticalCenter; radius: 7
          color: root.filterWorkspace === 0 ? "#45ffffff" : "#18ffffff"
          Text { anchors.centerIn: parent; text: "All"; color: "white"; font.pixelSize: 12 }
        }
        Flickable {
          id: desktopFlick
          anchors.centerIn: parent
          // Space for outlines and the close circles outside the thumbnails.
          readonly property int edgePadding: 16
          width: Math.max(0, Math.min(parent.width - 270, desktopRow.width + edgePadding * 2))
          height: parent.height; contentWidth: desktopRow.width + edgePadding * 2; contentHeight: height
          interactive: false; clip: true
          onWidthChanged: Qt.callLater(root.revealDesktop)
          Row {
            id: desktopRow
            x: desktopFlick.edgePadding; y: 18; spacing: 24
            onPositioningComplete: Qt.callLater(root.revealDesktop)
            Repeater {
              id: desktops
              model: root.workspaceIds
              delegate: DesktopPreview {
                required property var modelData
                desktopId: modelData
                label: root.desktopLabel(modelData)
                members: root.allWindows.filter(w => Logic.workspaceKey(w.workspace) === modelData)
                captureFor: address => root.captureFor(address)
                wallpaper: root.wallpaper; live: root.shown; accent: root.accent
                highlighted: root.filterWorkspace === modelData
                hovered: input.hovered.id === modelData && ["desktop", "remove"].indexOf(input.hovered.kind) >= 0 && !input.dragging
                canRemove: root.workspaceIds.length > 1 && !input.dragging && !(root.desktopInfo[String(modelData)] || {}).pinned
                dropTarget: input.dragging && root.dragTarget && root.dragTarget.kind === "desktop" && root.dragTarget.id === modelData
              }
            }
          }
        }
        Rectangle {
          id: addButton
          anchors.right: parent.right; anchors.rightMargin: 60; anchors.verticalCenter: parent.verticalCenter
          width: 52; height: 70; radius: 7
          color: input.dragging && root.dragTarget && root.dragTarget.kind === "add" ? "#4591e2b1" : input.hovered.kind === "add" ? "#25ffffff" : "transparent"
          Text { anchors.centerIn: parent; text: "+"; color: "white"; font.pixelSize: 32 }
        }
        Item {
          id: exitButton
          anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
          width: 32; height: 44
          Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 25; color: "#bbffffff" }
        }
      }

      SearchBar {
        id: search
        z: 3
        anchors { top: strip.bottom; topMargin: 14; horizontalCenter: parent.horizontalCenter }
        width: Math.min(420, parent.width - 96); height: 34
        accent: root.accent; surfaceColor: root.surfaceColor; textColor: root.textColor
        enabled: !root.busy && !input.dragging && !root.settingsShown && !root.previewAddress
        onKeyPressed: event => root.handleKey(event, true)
        onEdited: { root.previewAddress = ""; root.keyboardSelection = true; previews.cancel() }
      }
      Item {
        id: stage
        anchors { top: search.bottom; bottom: parent.bottom; left: parent.left; right: parent.right; leftMargin: 48; rightMargin: 48; topMargin: 24; bottomMargin: 58 }
        Repeater {
          id: windowRepeater
          // Stable source model: typing/filter changes never rebuild cards or captures.
          model: Hyprland.toplevels
          delegate: WindowPreview {
            required property var modelData
            readonly property int layoutIndex: root.windows.findIndex(w => w.address === modelData.address)
            readonly property bool inLayout: layoutIndex >= 0
            property bool positioned: false
            visible: inLayout
            onInLayoutChanged: { positioned = false; if (inLayout) Qt.callLater(() => positioned = true) }
            readonly property var rect: root.placements[layoutIndex] || ({ x: 0, y: 0, width: 0, height: 0 })
            x: rect.x; y: rect.y; width: rect.width; height: rect.height
            windowInfo: modelData; sharedCapture: root.captureFor(modelData.address); live: root.shown && inLayout
            accent: root.accent; surfaceColor: root.surfaceColor; textColor: root.textColor
            highlighted: !input.dragging && ((input.hovered.kind === "window" && input.hovered.address === modelData.address) ||
              (root.keyboardSelection && root.selected === layoutIndex))
            opacity: root.dragSource && root.dragSource.address === modelData.address ? .25 : 1
            label: (modelData.title || modelData.lastIpcObject.class || "Window") +
              (root.filterWorkspace === 0 ? "  ·  " + root.desktopLabel(Logic.workspaceKey(modelData.workspace)) : "")
            Behavior on x { enabled: positioned && !input.dragging && preferences.values.motion; NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
            Behavior on y { enabled: positioned && !input.dragging && preferences.values.motion; NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
          }
        }
        Text {
          anchors.centerIn: parent; visible: root.windows.length === 0
          text: root.query ? "No windows match your search" : root.appFilter ? "No windows for this app"
            : preferences.values.monitorOnly ? "No windows on this desktop and monitor" : "No open windows"
          color: "#d4dae5"; font.pixelSize: 17
        }
      }

      Rectangle {
        id: toast
        anchors.bottom: parent.bottom; anchors.bottomMargin: 16; anchors.horizontalCenter: parent.horizontalCenter
        width: toastText.implicitWidth + (root.undoRecord ? 98 : 32); height: 36; radius: 9
        color: "#e3202633"; visible: root.message !== ""
        Text { id: toastText; x: 16; anchors.verticalCenter: parent.verticalCenter; text: root.message; color: "#ecf0f7"; font.pixelSize: 13 }
        Item {
          id: undoButton
          anchors.right: parent.right; width: 76; height: parent.height
          Text { anchors.centerIn: parent; text: "Undo"; color: root.accent; font.pixelSize: 13; visible: !!root.undoRecord }
        }
      }
      Text {
        anchors.bottom: parent.bottom; anchors.bottomMargin: 20; anchors.horizontalCenter: parent.horizontalCenter
        visible: !toast.visible && (root.busy || root.preparing || input.hovered.kind === "add" || input.hovered.kind === "remove")
        text: root.busy ? "Updating…" : root.preparing ? "Refreshing previews…" : input.hovered.kind === "add" ? "New desktop · drop a window here" : "Remove desktop · windows will be moved, not closed"
        color: "#e1e7f1"; font.pixelSize: 12; style: Text.Outline; styleColor: "#bb101521"
      }

      Text {
        z: 2
        anchors { left: parent.left; bottom: parent.bottom; leftMargin: 24; bottomMargin: 22 }
        text: root.windows.length + (root.query ? " matches" : " windows") + "  ·  Space to preview  ·  Ctrl+F to search"
        color: "white"; opacity: .6; font.pixelSize: 11
      }
      Rectangle {
        z: 3
        anchors { right: parent.right; bottom: parent.bottom; rightMargin: 24; bottomMargin: 14 }
        width: 84; height: 32; radius: 8
        color: settingsMouse.containsMouse ? "#28ffffff" : "transparent"
        Text { anchors.centerIn: parent; text: "Settings"; color: "white"; opacity: .8; font.pixelSize: 12 }
        MouseArea {
          id: settingsMouse
          anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
          enabled: !root.busy && !input.dragging
          onClicked: root.showSettings()
        }
      }
      Item {
        z: 5; anchors.fill: parent
        visible: !!root.previewWindow
        Rectangle { anchors.fill: parent; color: "#b8000000" }
        MouseArea { anchors.fill: parent; onClicked: root.closePreview() }
        Loader {
          anchors { fill: parent; leftMargin: 80; rightMargin: 80; topMargin: 70; bottomMargin: 90 }
          active: !!root.previewWindow
          sourceComponent: WindowPreview {
            windowInfo: root.previewWindow
            sharedCapture: root.previewWindow ? root.captureFor(root.previewWindow.address) : null
            live: root.shown; highlighted: true
            accent: root.accent; surfaceColor: root.surfaceColor; textColor: root.textColor
          }
        }
        Text {
          anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 22 }
          text: "Quick Look  ·  Arrows / Tab to browse  ·  Enter to open  ·  Space / Esc to return"
          color: "white"; opacity: .8; font.pixelSize: 12
        }
      }
      SettingsPanel {
        id: settingsPanel
        z: 6; anchors.fill: parent; visible: root.settingsShown
        store: preferences; accent: root.accent; surfaceColor: root.surfaceColor; textColor: root.textColor
        onDismissed: { root.settingsShown = false; search.focusInput() }
      }

      DragSurface {
        id: input
        z: 1
        anchors.fill: parent
        enabled: !root.settingsShown && !root.previewAddress
        hitTest: (x, y) => root.hitTest(x, y)
        onClickedZone: (z, modifiers) => root.clicked(z)
        onDraggingChanged: if (!dragging) Qt.callLater(root.restoreSearchFocus)
        onStartedDrag: (z, x, y) => {
          if (root.busy) { input.cancelDrag(); return }
          previews.cancel()
          root.dragSource = z; root.dragPoint = Qt.point(x, y)
          root.keyboardSelection = false
        }
        onUpdatedDrag: (x, y, target) => { root.dragPoint = Qt.point(x, y); root.dragTarget = target }
        onDroppedZone: (source, target) => root.finishDrag(source, target)
        onCancelledDrag: { root.dragSource = null; root.dragTarget = null; hoverTimer.stop() }
        onHoveredChanged: {
          if (hovered.kind === "window" && !input.dragging) { root.selected = hovered.index; root.keyboardSelection = false }
          const id = hovered.kind === "desktop" ? hovered.id : 0
          if (id !== root.hoverDesktop) {
            root.hoverDesktop = id; hoverTimer.stop()
            if (id && (!pressedZone || input.dragging)) hoverTimer.start()
          }
        }
        onScrollStrip: delta => {
          desktopFlick.contentX = Math.max(0, Math.min(desktopFlick.contentWidth - desktopFlick.width, desktopFlick.contentX + delta))
          refreshHover()
        }
      }
      Timer {
        interval: 40; running: input.dragging && root.dragPoint.y < strip.height; repeat: true
        onTriggered: {
          const p = desktopFlick.mapToItem(content, 0, 0)
          const delta = root.dragPoint.x < p.x + 28 ? -14 : root.dragPoint.x > p.x + desktopFlick.width - 28 ? 14 : 0
          if (delta) { desktopFlick.contentX = Math.max(0, Math.min(desktopFlick.contentWidth - desktopFlick.width, desktopFlick.contentX + delta)); input.refreshHover() }
        }
      }
      // A separate ghost survives filtering and never steals the mouse grab.
      Loader {
        z: 4
        active: !!root.dragSource
        x: Math.min(content.width - width - 8, Math.max(8, root.dragPoint.x + 16))
        y: Math.min(content.height - height - 40, Math.max(8, root.dragPoint.y + 16))
        width: 210; height: 145
        sourceComponent: root.dragSource && root.dragSource.kind === "window" ? windowGhost : desktopGhost
        Component {
          id: windowGhost
          WindowPreview {
            windowInfo: root.dragSource ? root.dragSource.window : null
            sharedCapture: root.dragSource ? root.captureFor(root.dragSource.address) : null
            live: root.shown; highlighted: true; showTitle: false
            surfaceColor: root.surfaceColor; textColor: root.textColor
            accent: root.dragTarget && ["desktop", "add"].indexOf(root.dragTarget.kind) >= 0 ? "#91e2b1" : root.accent
          }
        }
        Component {
          id: desktopGhost
          Image { source: root.wallpaper; fillMode: Image.PreserveAspectFit; opacity: .85 }
        }
      }
    }
  }
}
