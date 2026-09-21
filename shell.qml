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
  property bool shown: false
  property bool opening: false
  property bool closing: false
  property real motionProgress: 0
  property var animationOrigins: ({})
  property string previewError: ""
  property bool contextAllowed: false
  property var allowedOutputs: []
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
  // A requested shutdown always terminates: the watchdog deadline below outranks
  // every latch that finishShutdown() waits on (AUDIT.md F-03).
  property bool shutdownExpired: false
  property int openCount: 0
  // The openCount a running close animation belongs to (AUDIT.md F-07).
  property int closeSession: 0
  property int wallpaperRevision: 0
  property bool framePresented: false
  property double openedAt: 0
  property real firstFrameMs: -1
  readonly property bool preparing: opening
  // Eager subscriptions make opening independent of CLI context probes.
  readonly property var observedMonitors: Hyprland.monitors.values
  // Capture objects exist only in a mapped, validated Overview session.
  // This avoids hidden capture; it is NOT a compositor monitor-lifetime fix.
  readonly property bool windowCaptureEnabled: Logic.captureEnabled({ shown: shown, framePresented: framePresented,
    contextAllowed: contextAllowed, topologyReady: captureTopologyReady })
  readonly property var captureScreens: allowedOutputs.filter(output => previewScreens.some(s => s.name === output.name))
  readonly property var captureMembers: allWindows.filter(w => workspaceIds.includes(Logic.workspaceKey(w.workspace)))
  readonly property var capturePriority: [previewAddress, dragSource ? dragSource.address : "", selectedAddress]
    .concat(windows.map(w => w.address))
  // The plan the current state asks for, and the plan the session actually runs:
  // while the exit animation is on screen the latter is held at what the close
  // inherited, so a reordered priority (cancelDrag() nulls dragSource) cannot push
  // a card past the pixel budget and blank it mid-animation (AUDIT.md F-13).
  readonly property var plannedCaptureAddresses: windowCaptureEnabled ? Logic.capturePlan(captureMembers, capturePriority, captureScreens) : []
  property var closingPlan: []
  readonly property var captureAddresses: Logic.capturePlanHold({ closing: closing,
    plan: plannedCaptureAddresses, frozen: closingPlan, addresses: allWindows.map(w => w.address) })
  readonly property var liveCaptureAddresses: Logic.liveSelection({ windows: windows, priority: capturePriority,
    limit: preferences.values.liveLimit, previewAddress: previewAddress, closing: closing, planned: captureAddresses })
  // Monitor/output transitions invalidate the entire visible capture session.
  readonly property var previewScreens: Logic.previewScreens(Quickshell.screens)
  readonly property string previewTopology: JSON.stringify(previewScreens.map(s => [s.name, s.x, s.y, s.width, s.height]))
  property bool captureTopologyReady: false
  // A requested open outlives topology churn; the settle timer resumes or fails it.
  property bool resumeOpen: false
  property int settleAttempts: 0
  property int contextAttempts: 0
  // Which session asked the capture-context guard: "open", "recheck" or none.
  property string guardPurpose: ""
  onPreviewTopologyChanged: pauseCaptures()
  readonly property var focusedWindow: Logic.focusedWindow(Hyprland.activeToplevel, Hyprland.toplevels.values)
  // Qt key codes stay in QML; Logic.keyIntent() decides policy on plain names.
  readonly property var keyNames: ({ [Qt.Key_Escape]: "escape", [Qt.Key_Space]: "space", [Qt.Key_F]: "f", [Qt.Key_Z]: "z",
    [Qt.Key_Left]: "left", [Qt.Key_Right]: "right", [Qt.Key_Up]: "up", [Qt.Key_Down]: "down",
    [Qt.Key_Tab]: "tab", [Qt.Key_Backtab]: "backtab", [Qt.Key_Return]: "enter", [Qt.Key_Enter]: "enter" })
  readonly property color accent: preferences.values.followTheme ? themeColors.accent : "#76b5ff"
  readonly property color surfaceColor: preferences.values.followTheme ? themeColors.background : "#202633"
  readonly property color textColor: preferences.values.followTheme ? themeColors.foreground : "#ecf0f7"
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"
  readonly property string wallpaper: "file://" + stateHome + "/omarchy/current/background?v=" + wallpaperRevision
  readonly property var allWindows: Hyprland.toplevels.values.filter(w =>
    w && w.lastIpcObject && w.lastIpcObject.mapped !== false && Logic.workspaceKey(w.workspace)
  ).slice().sort(Logic.spatialCompare)
  readonly property var scopeWindows: allWindows.filter(w => (filterWorkspace === 0 || Logic.workspaceKey(w.workspace) === filterWorkspace) &&
    (!appFilter || w.lastIpcObject.class === appFilter) && (!(perMonitor || preferences.values.monitorOnly) ||
      (w.workspace && w.workspace.monitor ? w.workspace.monitor.name === displayName :
        w.lastIpcObject.monitor === (observedMonitors.find(m => m.name === displayName) || {}).id)))
  readonly property var windows: scopeWindows.filter(w => Logic.matches(w, query))
  readonly property var workspaceIds: Logic.workspaceKeys(desktopOrder, Hyprland.workspaces.values, desktopInfo, displayName, perMonitor)
  onWorkspaceIdsChanged: { Qt.callLater(repairDesktopFilter); Qt.callLater(revealDesktop) }
  // Title/focus metadata churn must not rerun the geometry search.
  readonly property string layoutKey: JSON.stringify(windows.map(w => aspectFor(w)))
  readonly property var placements: OverviewLayout.arrange(JSON.parse(layoutKey), stage.width, stage.height)
  onFilterWorkspaceChanged: { selectedAddress = ""; selected = 0; keyboardSelection = false; if (previewAddress) closePreview() }
  // A reply that clears `busy` must re-arm the quit, or a shutdown queued behind
  // an in-flight action never happens; finishShutdown() self-guards (F-03).
  onBusyChanged: if (!busy) {
    Qt.callLater(restoreSearchFocus)
    Qt.callLater(finishShutdown)
  }
  onSelectedChanged: if (windows[selected]) selectedAddress = windows[selected].address
  onWindowsChanged: {
    // A momentarily empty collection (refreshToplevels() republishing on every
    // open and on movewindow) is a transient, not a decision: the selection
    // stays anchored to its address and Quick Look stays open (AUDIT.md F-17).
    const anchor = Logic.selectionAnchor({ windows: windows, allWindows: allWindows, selected: selected,
      selectedAddress: selectedAddress, previewAddress: previewAddress })
    selected = anchor.selected
    selectedAddress = anchor.selectedAddress
    if (anchor.dismissPreview) closePreview()
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
    if (Quickshell.env("OVERVIEW_START_HIDDEN") !== "1")
      Qt.callLater(() => openOverview(Quickshell.env("OVERVIEW_APP_ONLY") === "1" ? "app" : ""))
  }

  function pauseCaptures() {
    // A monitor/config event must not discard a requested open silently.
    const resume = opening || resumeOpen
    captureTopologyReady = false
    contextAllowed = false; allowedOutputs = []
    // Output churn invalidates captures, not the window the user just clicked:
    // the close that owns it still runs (AUDIT.md F-04).
    if (Logic.activationHandoff({ pendingWindow: !!pendingWindow, source: "pause",
      shutdownRequested: shutdownRequested }).action === "discard")
      pendingWindow = null
    if (openGuard) openGuard.cancel()
    if (captureBank) captureBank.clear()
    if (shown) finishClose()
    opening = false
    resumeOpen = resume && !shutdownRequested
    settleAttempts = 0
    captureSettle.restart()
  }
  // Every refused open ends here: one truthful reason in status() and the journal.
  function failOpen(reason) {
    previewError = reason
    console.warn("Overview:", reason)
    resumeOpen = false
    finishClose()
  }
  // One sentence per refusal, decided in OverviewLogic so it stays unit-tested:
  // a stopped stream says so and names the only cure, reopening Overview (F-11).
  function previewReason(w) {
    const capture = captureFor(w.address)
    return Logic.previewReason({ refusal: Logic.captureReason(w, captureScreens),
      captureEnabled: windowCaptureEnabled, planned: captureAddresses.includes(w.address),
      hasCapture: !!capture, failed: !!capture && capture.failed })
  }
  function aspectFor(w) { return OverviewLayout.aspectFor(w, captureFor(w.address)) }
  function captureFor(address) { return captureBank.lookup(address) }
  function openOverview(mode) {
    if (Logic.openBlocked({ shutdownRequested: shutdownRequested, activating: activateTimer.running, shown: shown, opening: opening })) return
    search.text = ""; previewAddress = ""; settingsShown = false
    paletteFile.reload(); settingsFile.reloadIfIdle()
    displayName = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : displayName
    filterWorkspace = Logic.workspaceKey(Hyprland.focusedWorkspace) || 1
    appFilter = mode === "app" && focusedWindow ? focusedWindow.lastIpcObject.class || "" : ""
    if (mode === "app") filterWorkspace = 0
    selected = Logic.selectionIndex(windows, focusedWindow ? focusedWindow.address : "", 0)
    selectedAddress = windows[selected] ? windows[selected].address : ""; keyboardSelection = true
    input.cancelDrag(); input.hovered = ({ kind: "background", key: "background" })
    message = ""; undoRecord = null
    closeWhenDone = false
    desktopFlick.contentX = 0
    openedAt = Date.now(); firstFrameMs = -1; framePresented = false
    opening = true; openCount++; previewError = ""; contextAllowed = false
    resumeOpen = false; settleAttempts = 0; contextAttempts = 0
    // A new session recomputes its own plan; nothing is inherited from the close.
    closingPlan = []
    Hyprland.refreshMonitors(); Hyprland.refreshWorkspaces(); Hyprland.refreshToplevels()
    // No capture-context check before the output list has settled.
    if (!captureTopologyReady) { if (!captureSettle.running) captureSettle.restart(); return }
    checkOpeningContext()
  }
  function checkOpeningContext() {
    if (!opening) return
    // An output name that exists beats a refusal that blames the wrong thing.
    if (!displayName && previewScreens.length > 0) displayName = previewScreens[0].name
    if (openGuard.request(displayName)) { guardPurpose = "open"; contextAttempts = 0; return }
    const refusal = Logic.contextRefusal({ refusal: openGuard.lastRefusal, attempts: contextAttempts,
      purpose: guardPurpose })
    // "wait": the run already serving this open answers with completed().
    // "retry": OpenGuard.onReadyToBegin calls back once the helper is gone.
    if (refusal.action === "wait") return
    if (refusal.action === "retry") { contextAttempts++; return }
    failOpen(Logic.openFailure(refusal.reason))
  }
  function presentOverview() {
    // Never become visible without a panel, a context and a settled topology.
    const blocked = Logic.presentBlocked({ opening: opening, shutdownRequested: shutdownRequested,
      screens: previewScreens.length, topologyReady: captureTopologyReady, contextAllowed: contextAllowed })
    if (blocked === "ignore") return
    if (blocked) { failOpen(Logic.openFailure(blocked)); return }
    opening = false; closing = false
    // Exactly one animation owns motionProgress: a close motion left over from
    // the previous session must never fade out this one (AUDIT.md F-07).
    enterMotion.stop(); exitMotion.stop(); closeWatchdog.stop()
    motionProgress = preferences.values.motion ? 0 : 1
    const output = captureScreens.find(s => s.name === displayName), origins = {}
    for (let i = 0; i < windows.length; i++)
      origins[windows[i].address] = OverviewLayout.animationOrigin(windows[i], output, { x: stage.x, y: stage.y }, placements[i])
    animationOrigins = origins
    shown = true
    if (preferences.values.motion) enterMotion.restart()
    stateRefresh.restart()
    Qt.callLater(revealDesktop)
    Qt.callLater(search.focusInput)
  }
  function finishClose() {
    enterMotion.stop(); exitMotion.stop(); closeWatchdog.stop()
    contextAllowed = false; opening = false; closing = false; openGuard.cancel()
    resumeOpen = false; contextAttempts = 0; guardPurpose = ""; closingPlan = []
    captureBank.clear()
    shown = false; motionProgress = 0
    message = ""; undoRecord = null
    input.cancelDrag(); hoverTimer.stop()
    previewAddress = ""; settingsShown = false
    // The chosen window is focused exactly once, by activateTimer, or the loss
    // is reported; nothing else may consume it (AUDIT.md F-04).
    const handoff = Logic.activationHandoff({ pendingWindow: !!pendingWindow, source: "close",
      shutdownRequested: shutdownRequested, activating: activateTimer.running })
    if (handoff.action === "discard") {
      pendingWindow = null
      console.warn("Overview:", handoff.reason)
    } else if (handoff.action === "activate") {
      activateTimer.start()
    }
    finishShutdown()
  }
  // A close animation and the watchdog that bounds it may only finish the
  // session they were started for, never the one a newer open owns (F-07).
  function closeSettled(source) {
    const verdict = Logic.closeVerdict({ closing: closing, session: closeSession,
      openCount: openCount, source: source })
    if (verdict.action !== "finish") return
    if (verdict.reason) console.warn("Overview:", verdict.reason)
    finishClose()
  }
  function finishShutdown() {
    const state = { shutdownRequested: shutdownRequested, busy: busy, preparing: preparing,
      activating: activateTimer.running, saving: preferences.saving, expired: shutdownExpired }
    if (Logic.shutdownReady(state) === "wait") return
    preferences.flush()
    state.saving = preferences.saving
    if (Logic.shutdownReady(state) === "quit") Qt.quit()
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
    previewAddress = ""; settingsShown = true; hoverTimer.stop()
    Qt.callLater(settingsPanel.focusFirst)
  }
  function handleKey(event, editing) {
    const intent = Logic.keyIntent({ key: keyNames[event.key] || "",
      modifiers: { ctrl: !!(event.modifiers & Qt.ControlModifier), shift: !!(event.modifiers & Qt.ShiftModifier) },
      editing: editing, composing: search.compositionGuard,
      flags: { settingsShown: settingsShown, dragging: input.dragging, busy: busy, query: query,
        previewAddress: previewAddress, windowCount: windows.length } })
    if (intent.action === "clearSearch") search.clear()
    else if (intent.action === "cancelDrag") input.cancelDrag()
    else if (intent.action === "closeSettings") { settingsShown = false; search.focusInput() }
    else if (intent.action === "closePreview") closePreview()
    else if (intent.action === "closeOverview") closeOverview()
    else if (intent.action === "focusSearch") { search.focusInput(); search.input.selectAll() }
    else if (intent.action === "togglePreview") togglePreview()
    else if (intent.action === "undo") undo()
    else if (intent.action === "navigateDesktop") navigateDesktop(intent.direction)
    else if (intent.action === "choose") choose(selected)
    else if (intent.action === "cycleSelection") {
      if (windows.length) selected = (selected + intent.step + windows.length) % windows.length
      keyboardSelection = true
    } else if (intent.action === "moveSelection") {
      selected = OverviewLayout.neighbor(placements, selected, intent.direction)
      keyboardSelection = true
    }
    if (intent.sync && previewAddress && windows[selected]) previewAddress = windows[selected].address
    if (intent.accept) event.accepted = true
  }
  function flash(text) { message = text; toastTimer.restart() }
  function closeOverview() {
    // Hold the plan before cancelDrag() reorders capturePriority: the exit
    // animation must show the images it started with (AUDIT.md F-13).
    closingPlan = captureAddresses
    input.cancelDrag()
    const mode = Logic.closeMode({ opening: opening, shutdownRequested: shutdownRequested, busy: busy,
      closing: closing, shown: shown, motion: preferences.values.motion })
    if (mode === "deferToBusy") closeWhenDone = true
    else if (mode === "animate") {
      closing = true; closeSession = openCount
      enterMotion.stop(); openGuard.cancel(); exitMotion.restart(); closeWatchdog.restart()
    }
    else if (mode === "immediate") finishClose()
  }
  function runAction(args, exitAfter) {
    if (busy) return
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
  }
  function undo() { if (undoRecord && !busy) runAction(["undo", JSON.stringify(undoRecord)]) }
  function desktopLabel(id) { return (desktopInfo[String(id)] || {}).label || "Desktop " + String(id).replace(/^name:/, "") }
  function switchDesktop(id) { if (id) runAction(["switch", String(id)], true) }
  // A renamed or removed desktop must not strand the grid on a key that no longer
  // exists (AUDIT.md F-55). Deferred on purpose: an action that already knows
  // where its windows went (actionFinished's `removed`/`target`) remaps first,
  // and an empty list is a transient - no `state` reply yet - never "no desktops
  // left". This only ever changes the filter, never the compositor's workspace.
  function repairDesktopFilter() {
    if (!workspaceIds.length) return
    const target = Logic.reselectDesktop(filterWorkspace, workspaceIds)
    if (target !== filterWorkspace) filterWorkspace = target
  }
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
    pendingWindow = windows[index]
    closeOverview()
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
    const origin = desktopFlick.mapToItem(content, 0, 0)
    const clip = { x: origin.x, width: desktopFlick.width }
    for (let i = 0; i < desktops.count; i++) {
      const item = desktops.itemAt(i)
      if (!item) continue
      // Hit targets are clipped with the scrollable strip, including close buttons.
      if (!Logic.zoneVisible({ x: item.mapToItem(content, 0, 0).x, width: item.width }, clip)) continue
      if (item.removeButton.visible)
        out.push(Logic.clipZone(zone("remove", item.removeButton, { id: item.desktopId, key: "remove:" + item.desktopId }), clip))
      out.push(Logic.clipZone(zone("desktop", item, { id: item.desktopId, key: "desktop:" + item.desktopId }), clip))
    }
    out.push(zone("strip", strip))
    for (let i = 0; i < windowRepeater.count; i++) {
      const item = windowRepeater.itemAt(i)
      if (!item || !item.inLayout) continue
      // A delegate whose modelData was republished away is skipped, never
      // dereferenced (AUDIT.md F-14).
      const address = Logic.delegateAddress(item)
      if (!address) continue
      // The zone is the letterboxed surface, grown to a hittable size inside its
      // own card when an extreme ratio makes it a sliver.
      out.push(Logic.hittableZone(zone("window", item.surface, { index: item.layoutIndex, address: address,
        key: "window:" + address, window: item.modelData }), zone("card", item)))
    }
    return out
  }
  function hitTest(x, y) { return Logic.hitZone(zones(), x, y) }
  // Every IPC handler answers from this one snapshot, so the guard matrix below
  // cannot drift between handlers.
  function ipcState() {
    return { shown: shown, opening: opening, closing: closing, busy: busy, settingsShown: settingsShown,
      dragging: input.dragging, activating: activateTimer.running, shutdownRequested: shutdownRequested,
      pendingWindow: !!pendingWindow, ready: bridge.ready, desktops: workspaceIds.length,
      previewAddress: previewAddress, hasSelection: !!windows[selected] }
  }
  function clicked(z) {
    if (busy) return
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
      // Deferring is what keeps actionName/closeWhenDone with the single
      // in-flight action, including a close queued behind it (F-08, refuted).
      const action = Logic.refreshAction({ ready: bridge.ready, busy: root.busy, preparing: root.preparing })
      if (action === "defer") { restart(); return }
      if (action === "run") root.runAction(["state"])
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
      if (event.name === "openlayer" && /omarchy-polkit|hyprlock|swaylock|gtklock|omarchy-lockscreen/.test(event.data)) {
        // A window is never focused into a lock/polkit session; the discarded
        // activation is reported instead of vanishing (AUDIT.md F-04).
        const handoff = Logic.activationHandoff({ pendingWindow: !!root.pendingWindow, source: "lock" })
        if (handoff.action === "discard") console.warn("Overview:", handoff.reason)
        root.pendingWindow = null
        root.finishClose()
      }
    }
  }
  BackendClient {
    id: bridge
    workerPath: Quickshell.shellPath("worker.py")
    onReadyChanged: if (ready) root.runAction(["state"])
    onCompleted: (ticket, result) => { if (ticket === root.actionTicket) root.actionFinished(result) }
  }
  OpenGuard {
    id: openGuard
    helperPath: Quickshell.shellPath("capture_context.py")
    // The helper's own worst case is two 0.3 s socket budgets plus interpreter
    // start-up, so a 700 ms frontend deadline could fail an open on a cold page
    // cache (AUDIT.md F-21/F-31). The panel stays unmapped meanwhile; a warm
    // check measures ~12 ms, so this ceiling is only ever paid on a bad day.
    timeoutMs: 1200
    // A check refused only because the previous helper has not exited yet is
    // retried here instead of dead-ending the open.
    onReadyToBegin: if (root.opening) root.checkOpeningContext()
    onCompleted: result => {
      const ok = !!result && !!result.ok && Array.isArray(result.outputs)
      const verdict = Logic.guardVerdict({ purpose: root.guardPurpose, ok: ok,
        reason: ok ? "" : (result ? result.reason : ""), opening: root.opening, shown: root.shown,
        closing: root.closing, shutdownRequested: root.shutdownRequested })
      root.guardPurpose = ""
      if (verdict.action === "ignore") return
      if (verdict.action === "fail") { root.pendingWindow = null; root.failOpen(verdict.reason); return }
      root.allowedOutputs = result.outputs
      root.contextAllowed = true
      if (verdict.action === "present") root.presentOverview()
    }
  }
  // Read-only security recheck for a mapped, visible session only; never
  // captures pixels and never runs while an open or a close is in flight.
  Timer {
    interval: 1000; repeat: true
    running: panel.visible && root.shown && !root.opening && !root.closing && !root.shutdownRequested
    onTriggered: {
      if (!Logic.recheckAllowed({ panelVisible: panel.visible, shown: root.shown, opening: root.opening,
        closing: root.closing, shutdownRequested: root.shutdownRequested, canBegin: openGuard.canBegin })) return
      if (openGuard.request(root.displayName)) root.guardPurpose = "recheck"
    }
  }
  Connections {
    target: content.Window.window
    function onFrameSwapped() {
      if (root.shown && !root.framePresented) {
        root.firstFrameMs = Date.now() - root.openedAt
        root.framePresented = true
      }
    }
  }
  NumberAnimation { id: enterMotion; target: root; property: "motionProgress"; to: 1; duration: 190; easing.type: Easing.OutCubic }
  NumberAnimation { id: exitMotion; target: root; property: "motionProgress"; to: 0; duration: 130; easing.type: Easing.InCubic; onFinished: root.closeSettled("motion") }
  Timer { id: toastTimer; interval: 6500; onTriggered: root.message = "" }
  // `closing` is cleared only by finishClose(), which the animated path reaches
  // from exitMotion.onFinished. 400 ms is far past the 130 ms motion, so this
  // only ever fires when that never happened, and never latches the UI (F-07).
  Timer { id: closeWatchdog; interval: 400; onTriggered: root.closeSettled("watchdog") }
  // The service's graceful stop waits six seconds: a latch may delay the quit,
  // never cancel it (AUDIT.md F-03).
  Timer {
    id: shutdownWatchdog
    interval: 3000
    onTriggered: {
      const blocker = Logic.shutdownBlocker({ shutdownRequested: root.shutdownRequested, busy: root.busy,
        preparing: root.preparing, activating: activateTimer.running, saving: preferences.saving })
      if (blocker) console.warn("Overview: forcing shutdown while", blocker)
      root.shutdownExpired = true
      root.finishShutdown()
    }
  }
  // A new session must wait for settled output metadata; an open paused by
  // topology churn is resumed or failed here, never dropped.
  Timer {
    id: captureSettle
    interval: 1000
    onTriggered: {
      const outcome = Logic.settleOutcome({ screens: root.previewScreens.length, opening: root.opening,
        resumeOpen: root.resumeOpen, shown: root.shown, shutdownRequested: root.shutdownRequested,
        attempts: root.settleAttempts })
      root.captureTopologyReady = outcome.topologyReady
      root.settleAttempts = outcome.attempts
      if (outcome.action === "retry") { captureSettle.restart(); return }
      if (outcome.action === "fail") { root.failOpen(Logic.openFailure(outcome.reason)); return }
      if (outcome.action === "resume") { root.resumeOpen = false; root.openOverview(root.appFilter ? "app" : ""); return }
      if (outcome.action === "context") root.checkOpeningContext()
    }
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
      const w = root.pendingWindow, target = Logic.activationTarget(w)
      if (target.mode === "wayland") w.wayland.activate()
      else if (target.mode === "dispatch") Hyprland.dispatch('hl.dsp.focus({ window = "address:' + target.address + '" })')
      root.pendingWindow = null
      root.finishShutdown()
    }
  }

  // ---- IPC guard matrix (AUDIT.md F-44, F-45, F-46, F-47, F-50) ------------
  // Logic.ipcGuard() is the single policy and OverviewLogic.test.js pins every
  // cell. 'ok' means the request was ACCEPTED (a close queued behind a busy
  // action is an acceptance); every other reply names a deterministic refusal
  // that has NO side effect; no reply at all can only mean the process is gone.
  // `preparing` is `opening`. Precedence is always: invalid argument,
  // shutdownRequested, closing, then the call's own state. Only
  // navigateDesktop's 'unavailable' invites integrations/omarchy-overview's
  // `controller.py step` fallback.
  //
  // openOverview()     -> string  ok | shutdown | closing | activating | shown | opening
  // toggle(mode)       -> string  ok (opens, closes, cancels an in-flight open, or queues
  //                               the close while busy) | invalid (mode not in {"", app}) |
  //                               shutdown | closing | activating
  // shutdown()         -> string  ok, always: latches the request, re-arms the 3 s watchdog
  //                               that guarantees the quit, then closes
  // captureReady(addr) -> bool    unguarded; true only while a capture object for that
  //                               address holds content, so false while hidden, while
  //                               opening, after the teardown, and for an unknown address
  // close()            -> string  ok (also when already hidden; queued while busy) |
  //                               shutdown | closing
  // setQuery(text)     -> bool    true | false = invalid (over 200 chars), shutdown,
  //                               closing, hidden, busy or settings. A drag does not
  //                               refuse it: the drag ghost survives filtering
  // togglePreview()    -> bool    true = previewAddress changed; false = refused
  //                               (shutdown, closing, hidden, settings, dragging, busy,
  //                               no card) or nothing changed. Dismissing Quick Look is
  //                               never refused
  // showSettings()     -> string  ok (idempotent) | shutdown | closing | hidden | busy |
  //                               dragging
  // navigateDesktop(d) -> string  invalid (direction not in {next, previous}) | shutdown |
  //                               closing, and then:
  //     visible: ok (moves this session's desktop filter, never the compositor's
  //              workspace) | busy | dragging | settings | empty
  //     opening: opening - the open is NEVER aborted any more (F-09), and the launcher
  //              must not switch a desktop under the session about to appear
  //     hidden:  ok (the worker accepted the step) | unavailable (no worker, an action in
  //              flight, or the request was refused - only then may the launcher dispatch)
  //              | activating (a chosen window is being focused right now)
  // status()           -> string  unguarded: it is the launcher's liveness probe, so it
  //                               answers the full payload in every state
  IpcHandler {
    target: "overview"
    function openOverview(): string {
      const verdict = Logic.ipcGuard({ call: "openOverview", state: root.ipcState() })
      if (verdict.action === "open") root.openOverview("")
      return verdict.reply
    }
    function toggle(mode: string): string {
      const verdict = Logic.ipcGuard({ call: "toggle", arg: mode, state: root.ipcState() })
      if (verdict.action === "open") root.openOverview(mode)
      else if (verdict.action === "close") root.closeOverview()
      return verdict.reply
    }
    function shutdown(): string {
      root.shutdownRequested = true
      shutdownWatchdog.restart()
      root.closeOverview()
      return "ok"
    }
    function captureReady(address: string): bool {
      const source = root.captureFor(address.replace(/^0x/, ""))
      return !!source && source.hasContent
    }
    function close(): string {
      const verdict = Logic.ipcGuard({ call: "close", state: root.ipcState() })
      if (verdict.action === "close") root.closeOverview()
      return verdict.reply
    }
    function setQuery(text: string): bool {
      if (Logic.ipcGuard({ call: "setQuery", arg: text, state: root.ipcState() }).action !== "run") return false
      root.closePreview(); search.text = text; root.keyboardSelection = true
      return true
    }
    function togglePreview(): bool {
      if (Logic.ipcGuard({ call: "togglePreview", state: root.ipcState() }).action !== "run") return false
      const before = root.previewAddress
      root.togglePreview()
      return before !== root.previewAddress
    }
    function showSettings(): string {
      const verdict = Logic.ipcGuard({ call: "showSettings", state: root.ipcState() })
      if (verdict.action === "run") root.showSettings()
      return verdict.reply
    }
    function navigateDesktop(direction: string): string {
      const verdict = Logic.ipcGuard({ call: "navigateDesktop", arg: direction, state: root.ipcState() })
      if (verdict.action === "filter") { root.navigateDesktop(direction); return verdict.reply }
      if (verdict.action !== "step") return verdict.reply
      // Hidden: the worker owns the step. "ok" only once runAction() accepted it,
      // so the launcher's CLI fallback runs exactly when nothing happened (F-46).
      root.runAction(["step", direction])
      return root.busy ? "ok" : "unavailable"
    }
    function status(): string {
      const cards = []
      for (const w of root.windows) {
        const source = root.captureFor(w.address)
        let imageReady = false
        for (let i = 0; i < windowRepeater.count; i++) {
          const item = windowRepeater.itemAt(i)
          // Same F-14 guard as zones(): a delegate with no modelData has no
          // address, and no address ever matches a window.
          const address = Logic.delegateAddress(item)
          if (address && address === String(w.address)) { imageReady = item.hasThumbnail; break }
        }
        cards.push(Logic.statusCard(w, source, imageReady, source && source.hasContent ? "" : root.previewReason(w)))
      }
      return JSON.stringify(Logic.statusPayload({ shown: root.shown, busy: root.busy, desktop: root.filterWorkspace,
        appFilter: root.appFilter, order: root.workspaceIds, perMonitor: root.perMonitor, monitor: root.displayName,
        desktopLabels: root.workspaceIds.map(root.desktopLabel), dragging: input.dragging, message: root.message,
        query: root.query, selectedAddress: root.selectedAddress, previewAddress: root.previewAddress,
        previewSource: root.captureFor(root.previewAddress),
        settingsShown: root.settingsShown, settings: preferences.values, settingsError: preferences.error,
        liveAddresses: root.liveCaptureAddresses, delegateCount: windowRepeater.count,
        cachedFrames: captureBank.frameCount,
        windowCaptureEnabled: root.windowCaptureEnabled,
        captureTopologyReady: root.captureTopologyReady,
        captureViews: captureBank.viewCount, opening: root.opening,
        closing: root.closing, motionProgress: root.motionProgress,
        previewError: root.previewError,
        accent: String(root.accent), composing: search.input.inputMethodComposing, searchFocused: search.input.activeFocus,
        preparing: root.preparing, openCount: root.openCount,
        firstFrameMs: root.firstFrameMs, workerPid: bridge.processId, workerRestarts: bridge.restarts,
        completedRequests: bridge.completedCount, lastActionMs: bridge.lastElapsedMs,
        layout: { x: stage.x, y: stage.y, width: stage.width, height: stage.height, rects: root.placements },
        zones: root.zones() }, cards))
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
    HyprlandWindow.opacity: root.motionProgress
    Image {
      anchors.fill: parent; source: root.wallpaper
      sourceSize: Qt.size(1920, 1080); fillMode: Image.PreserveAspectCrop; cache: true
      layer.enabled: preferences.values.blur
      layer.effect: MultiEffect { blurEnabled: preferences.values.blur; blur: .45; blurMax: 32 }
    }
    Rectangle { anchors.fill: parent; color: Qt.rgba(.043, .055, .09, preferences.values.dim / 100) }

    Item {
      id: content
      anchors.fill: parent; focus: true; enabled: !root.closing
      CaptureBank {
        id: captureBank
        model: Hyprland.toplevels
        active: root.windowCaptureEnabled
        allowNew: !root.closing
        addresses: root.captureAddresses
        liveAddresses: root.liveCaptureAddresses
        factory: Component {
          NativeCapture {
            allowStart: !root.closing
            captureEnabled: root.windowCaptureEnabled && root.captureAddresses.includes(modelData.address) &&
              Logic.canCapture(root.shown, root.captureTopologyReady, modelData, root.captureScreens)
            live: captureBank.wantsLive(modelData.address)
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
        onEdited: { root.previewAddress = ""; root.keyboardSelection = true }
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
            readonly property var origin: root.animationOrigins[modelData.address] || rect
            x: origin.x + (rect.x - origin.x) * root.motionProgress
            y: origin.y + (rect.y - origin.y) * root.motionProgress
            width: origin.width + (rect.width - origin.width) * root.motionProgress
            height: origin.height + (rect.height - origin.height) * root.motionProgress
            windowInfo: modelData; sharedCapture: root.captureFor(modelData.address); live: root.shown && inLayout
            unavailableText: root.previewReason(modelData)
            accent: root.accent; surfaceColor: root.surfaceColor; textColor: root.textColor
            highlighted: !input.dragging && ((input.hovered.kind === "window" && input.hovered.address === modelData.address) ||
              (root.keyboardSelection && root.selected === layoutIndex))
            opacity: root.dragSource && root.dragSource.address === modelData.address ? .25 : 1
            label: (modelData.title || modelData.lastIpcObject.class || "Window") +
              (root.filterWorkspace === 0 ? "  ·  " + root.desktopLabel(Logic.workspaceKey(modelData.workspace)) : "")
            Behavior on x { enabled: positioned && root.motionProgress === 1 && !input.dragging && preferences.values.motion; NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
            Behavior on y { enabled: positioned && root.motionProgress === 1 && !input.dragging && preferences.values.motion; NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
          }
        }
        Text {
          // A layout that refuses a stage it cannot fill reads as a message, never
          // as invisible zero-size cards; a stage with no size yet is not a refusal.
          readonly property string notice: Logic.stageMessage({ windows: root.windows.length,
            placements: root.placements.length, stageReady: stage.width > 0 && stage.height > 0,
            query: root.query, appFilter: root.appFilter, monitorOnly: preferences.values.monitorOnly })
          anchors.centerIn: parent; visible: notice !== ""
          text: notice
          color: "#d4dae5"; font.pixelSize: 17
        }
      }

      Rectangle {
        id: toast
        // A message is bounded by the panel, not by its own length: an unbounded
        // compositor error must not grow the toast off-screen (AUDIT.md F-29).
        readonly property int textPadding: root.undoRecord ? 98 : 32
        anchors.bottom: parent.bottom; anchors.bottomMargin: 16; anchors.horizontalCenter: parent.horizontalCenter
        width: Math.max(0, Math.min(parent.width - 48, toastText.implicitWidth + textPadding)); height: 36; radius: 9
        color: "#e3202633"; visible: root.message !== ""
        Text {
          id: toastText
          x: 16; width: Math.max(0, toast.width - toast.textPadding)
          anchors.verticalCenter: parent.verticalCenter
          text: root.message; elide: Text.ElideRight; color: "#ecf0f7"; font.pixelSize: 13
        }
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
            id: quickLook
            windowInfo: root.previewWindow
            sharedCapture: root.previewWindow ? root.captureFor(root.previewWindow.address) : null
            unavailableText: root.previewWindow ? root.previewReason(root.previewWindow) : ""
            live: root.shown; highlighted: true
            accent: root.accent; surfaceColor: root.surfaceColor; textColor: root.textColor
            Component.onCompleted: if (preferences.values.motion) zoomIn.start()
            ParallelAnimation {
              id: zoomIn
              NumberAnimation { target: quickLook; property: "scale"; from: .94; to: 1; duration: 140; easing.type: Easing.OutCubic }
              NumberAnimation { target: quickLook; property: "opacity"; from: 0; to: 1; duration: 140 }
            }
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
