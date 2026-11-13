import QtQuick
import QtTest
import Quickshell
import Quickshell.Hyprland

// It is not named tst_*.qml because the main qmltestrunner pass over tests/
// runs without these stubs and must not pick it up.
Item {
  id: scene
  width: 1600; height: 900
  readonly property var output: ({ name: "DP-1", id: 1, scale: 1, x: 0, y: 0, width: 1600, height: 900 })
  property var activated: []
  Component {
    id: toplevelType
    QtObject {
      property string address
      property string title
      property var monitor
      property var workspace
      property var lastIpcObject
      property var wayland
    }
  }
  // Assigned after creation: initial properties would turn the objects into
  // QVariantMaps, which lose their identity on every read.
  function toplevel(address, x) {
    const window = toplevelType.createObject(scene, { address: address, title: "Window " + address })
    window.monitor = { name: "DP-1", id: 1 }
    window.workspace = { id: 1, name: "1", monitor: window.monitor }
    window.lastIpcObject = { mapped: true, class: "app-" + address, at: [x, 100], size: [600, 400], monitor: 1 }
    window.wayland = { activate() { scene.activated = scene.activated.concat([address]) } }
    return window
  }
  Loader { id: loader; active: false; source: "app/shell.qml" }
  readonly property var shell: loader.item

  TestCase {
    name: "Shell"; when: windowShown
    property var windows: []
    function init() {
      Quickshell.envMap = { OVERVIEW_START_HIDDEN: "1",
        XDG_STATE_HOME: decodeURIComponent(String(Qt.resolvedUrl("app/state")).replace(/^file:\/\//, "")) }
      Quickshell.screens = [scene.output]
      Quickshell.executed = []; Quickshell.processes = []; Quickshell.screencopies = []
      Quickshell.ipcHandlers = ({})
      Hyprland.monitors = { values: [{ name: "DP-1", id: 1 }] }
      Hyprland.workspaces = { values: [{ id: 1, name: "1", monitor: { name: "DP-1" } },
        { id: 2, name: "2", monitor: { name: "DP-1" } }] }
      Hyprland.focusedMonitor = { name: "DP-1" }
      Hyprland.focusedWorkspace = { id: 1, name: "1" }
      Hyprland.dispatched = []
      scene.activated = []
      windows = [scene.toplevel("a1", 10), scene.toplevel("b2", 700)]
      Hyprland.toplevels.values = windows
      loader.active = true
      tryCompare(scene.shell, "captureTopologyReady", true, 3000)
    }
    function cleanup() {
      wait(0)
      loader.active = false
      for (const w of windows) w.destroy()
      wait(0)
    }
    function process(script) { return Quickshell.processes.filter(p => String(p.command[2]).endsWith(script)).pop() }
    function worker() { return process("worker.py") }
    function requests() { return worker().written.map(line => JSON.parse(line)) }
    function workerSays(packet) { worker().stdout.read(JSON.stringify(packet)) }
    function answer(request, extra) { workerSays(Object.assign({ id: request.id, ok: true }, extra || {})) }
    function ipc() { return Quickshell.ipcHandlers.overview }
    function status() { return JSON.parse(ipc().status()) }
    function card(address) { return status().windows.find(w => w.address === address) }
    function zoneAt(kind, match) {
      return status().zones.find(z => z.kind === kind && Object.keys(match).every(k => z[k] === match[k]))
    }
    function click(kind, match) {
      const z = zoneAt(kind, match)
      verify(z, "no " + kind + " zone " + JSON.stringify(match))
      mouseClick(scene, z.x + z.width / 2, z.y + z.height / 2)
    }
    function grantContext() {
      const helper = process("capture_context.py")
      helper.stdout.read(JSON.stringify({ ok: true, outputs: [scene.output] }))
      helper.exited(0, 0)
    }
    function startWorker() {
      workerSays({ event: "ready", protocol: 1 })
      const startup = requests().pop()
      compare(startup.args[0], "state")
      answer(startup)
    }
    function open() {
      compare(ipc().toggle(""), "ok")
      compare(scene.shell.opening, true)
      grantContext()
      compare(scene.shell.shown, true)
    }
    function openRefresh() {
      const before = requests().length
      tryVerify(() => requests().length === before + 1, 1000, "the open sends a desktop refresh")
      const refresh = requests().pop()
      compare(refresh.args, ["state"])
      return refresh
    }
    function shownSession() {
      startWorker()
      open()
      answer(openRefresh())
      tryCompare(scene.shell, "motionProgress", 1, 1000)
    }

    function test_openPresentsAndToggleCloses() {
      startWorker()
      open()
      answer(openRefresh())
      tryVerify(() => status().searchFocused, 1000, "the search field takes the keyboard")
      compare(ipc().toggle(""), "ok")
      tryCompare(scene.shell, "shown", false, 1000)
      compare(status().captureViews, 0)
    }
    function test_enterOnAnIdleSessionFocusesTheSelectedWindowOnce() {
      startWorker()
      open()
      answer(openRefresh())
      tryVerify(() => status().searchFocused, 1000)
      keyClick(Qt.Key_Return)
      tryCompare(scene.shell, "shown", false, 1000)
      tryVerify(() => scene.activated.length > 0, 1000)
      wait(100)
      compare(scene.activated, ["a1"])
    }

    function test_closeHidesPromptlyWhileTheDesktopRefreshIsOutstanding_data() {
      return [{ tag: "close" }, { tag: "toggle" }, { tag: "escape" }]
    }
    function test_closeHidesPromptlyWhileTheDesktopRefreshIsOutstanding(row) {
      startWorker()
      open()
      const refresh = openRefresh()
      if (row.tag === "close") compare(ipc().close(), "ok")
      else if (row.tag === "toggle") compare(ipc().toggle(""), "ok")
      else keyClick(Qt.Key_Escape)
      tryCompare(scene.shell, "shown", false, 1000)
      answer(refresh, { desktops: { "1": { label: "Mail" } }, order: [1, 2], perMonitor: false })
      compare(scene.shell.shown, false)
      compare(Quickshell.executed, [])
      compare(status().desktopLabels, ["Mail", "Desktop 2"])
    }
    function test_choosingAWindowIsHonouredWhileTheDesktopRefreshIsOutstanding_data() {
      return [{ tag: "enter", chosen: "a1" }, { tag: "click", chosen: "b2" }]
    }
    function test_choosingAWindowIsHonouredWhileTheDesktopRefreshIsOutstanding(row) {
      startWorker()
      open()
      openRefresh()
      tryCompare(scene.shell, "motionProgress", 1, 1000)
      if (row.tag === "enter") keyClick(Qt.Key_Return)
      else click("window", { address: row.chosen })
      tryCompare(scene.shell, "shown", false, 1000)
      tryVerify(() => scene.activated.length > 0, 1000)
      wait(100)
      compare(scene.activated, [row.chosen])
    }
    function notices() {
      return Quickshell.executed.map(args => args[0] + ": " + args[args.length - 1])
    }
    // The worker's error can quote Hyprland, a workspace name included, and a
    // notification outlives the panel in the notification history.
    function test_aHiddenStepTheWorkerFailedIsReportedInAFixedSentence() {
      startWorker()
      compare(ipc().navigateDesktop("next"), "ok")
      const step = requests().pop()
      compare(step.args, ["step", "next"])
      ignoreWarning(/action step failed: Hyprland: invalid workspace "name:Payroll"/)
      workerSays({ id: step.id, ok: false, error: 'Hyprland: invalid workspace "name:Payroll"' })
      compare(notices(), ["notify-send: The action did not complete"])
      verify(!JSON.stringify(Quickshell.executed).includes("Payroll"), "the workspace name stays in the journal")
    }
    function test_aLostRefreshIsJournaledNotReportedAsAFailedAction() {
      startWorker()
      open()
      openRefresh()
      ignoreWarning(/desktop refresh failed/)
      worker().exited(1, 0)
      compare(scene.shell.shown, true)
      compare(status().message, "")
    }
    function openWithAnUnansweredAction(kind, match) {
      startWorker()
      open()
      answer(openRefresh())
      tryCompare(scene.shell, "motionProgress", 1, 1000)
      click(kind, match)
      compare(scene.shell.busy, true)
      return requests().pop()
    }
    function test_aCloseDuringAnUnansweredActionHidesWithinTheCloseWatchdog_data() {
      return [{ tag: "close" }, { tag: "toggle" }, { tag: "escape" }]
    }
    function test_aCloseDuringAnUnansweredActionHidesWithinTheCloseWatchdog(row) {
      const create = openWithAnUnansweredAction("add", {})
      compare(create.args, ["create"])
      if (row.tag === "close") compare(ipc().close(), "ok")
      else if (row.tag === "toggle") compare(ipc().toggle(""), "ok")
      else keyClick(Qt.Key_Escape)
      tryCompare(scene.shell, "shown", false, 400)
      answer(create, { created: 3, message: "Desktop 3 added", order: [1, 2, 3] })
      compare(scene.shell.shown, false)
      compare(notices(), [])
    }
    function clickBackground() {
      const x = 8, y = scene.height - 8
      verify(!status().zones.some(z => x >= z.x && y >= z.y && x < z.x + z.width && y < z.y + z.height),
        "nothing but the background is under the corner")
      mouseClick(scene, x, y)
    }
    function test_theCloseZonesCloseWhileAnActionIsUnanswered_data() {
      return [{ tag: "×" }, { tag: "background of All" }]
    }
    function test_theCloseZonesCloseWhileAnActionIsUnanswered(row) {
      shownSession()
      if (row.tag === "background of All") click("all", {})
      click("add", {})
      const create = requests().pop()
      compare(create.args, ["create"])
      if (row.tag === "×") click("exit", {})
      else clickBackground()
      tryCompare(scene.shell, "shown", false, 400)
      answer(create, { created: 3, message: "Desktop 3 added", order: [1, 2, 3] })
      compare(scene.shell.shown, false)
      compare(notices(), [])
    }
    function test_escapeClosesWhenTheSearchFieldCannotTakeTheKeyboard_data() {
      return [{ tag: "reopened while an action is unanswered" }, { tag: "query cleared while an action is unanswered" },
        { tag: "Ctrl+F in Quick Look" }]
    }
    function test_escapeClosesWhenTheSearchFieldCannotTakeTheKeyboard(row) {
      shownSession()
      tryVerify(() => status().searchFocused, 1000)
      if (row.tag === "Ctrl+F in Quick Look") {
        keyClick(Qt.Key_Space)
        compare(status().previewAddress, "a1")
        keyClick(Qt.Key_F, Qt.ControlModifier)
        keyClick(Qt.Key_Escape)
        compare(status().previewAddress, "", "the first Escape leaves Quick Look")
      } else if (row.tag === "query cleared while an action is unanswered") {
        keyClick("W")
        click("add", {})
        compare(scene.shell.busy, true)
        keyClick(Qt.Key_Escape)
        compare(status().query, "", "the first Escape clears the query")
      } else {
        click("add", {})
        keyClick(Qt.Key_Escape)
        tryCompare(scene.shell, "shown", false, 400)
        open()
        compare(scene.shell.busy, true)
        tryCompare(scene.shell, "motionProgress", 1, 1000)
      }
      keyClick(Qt.Key_Escape)
      tryCompare(scene.shell, "shown", false, 400)
    }
    function test_aLateFailureAfterTheCloseIsNotifiedOnce() {
      const create = openWithAnUnansweredAction("add", {})
      keyClick(Qt.Key_Escape)
      tryCompare(scene.shell, "shown", false, 400)
      ignoreWarning(/action create failed/)
      workerSays({ id: create.id, ok: false, error: "Hyprland did not confirm the change; please try again" })
      compare(notices(), ["notify-send: The action did not complete"])
    }
    function test_aLateReplyInAReopenedSessionDoesNotActOnIt_data() {
      return [{ tag: "ok" }, { tag: "failure" }]
    }
    function test_aLateReplyInAReopenedSessionDoesNotActOnIt(row) {
      const step = openWithAnUnansweredAction("desktop", { id: 2 })
      compare(step.args, ["switch", "2"])
      keyClick(Qt.Key_Escape)
      tryCompare(scene.shell, "shown", false, 400)
      open()
      if (row.tag === "ok") {
        answer(step, { desktops: { "1": { label: "Mail" } }, order: [1, 2], perMonitor: false,
          message: "Moved to Mail", undo: { moves: [], order: [1, 2] } })
      } else {
        ignoreWarning(/action switch failed/)
        workerSays({ id: step.id, ok: false, error: "That desktop is no longer available" })
      }
      wait(100)
      compare(scene.shell.shown, true)
      compare(status().message, "")
      compare(scene.shell.undoRecord, null)
      compare(status().desktop, 1)
      if (row.tag === "ok") {
        compare(status().desktopLabels, ["Mail", "Desktop 2"])
        compare(notices(), [])
      } else {
        compare(notices(), ["notify-send: The action did not complete"])
      }
    }
    function test_aSwitchThatSucceedsClosesThePanelThatSentIt() {
      shownSession()
      click("desktop", { id: 2 })
      const step = requests().pop()
      compare(step.args, ["switch", "2"])
      answer(step, { order: [1, 2] })
      compare(scene.shell.shown, false)
      compare(notices(), [])
    }
    function test_aMoveThatSucceedsShowsItsToastAndAWorkingUndo() {
      shownSession()
      const from = zoneAt("window", { address: "a1" }), to = zoneAt("desktop", { id: 2 })
      mousePress(scene, from.x + from.width / 2, from.y + from.height / 2)
      mouseMove(scene, from.x + from.width / 2 + 40, from.y + from.height / 2)
      mouseMove(scene, to.x + to.width / 2, to.y + to.height / 2)
      mouseRelease(scene, to.x + to.width / 2, to.y + to.height / 2)
      const move = requests().pop()
      compare(move.args, ["move", "a1", "2"])
      const record = { moves: [{ address: "0xa1", source: 1, target: 2 }], order: [1, 2] }
      answer(move, { target: 2, message: "Moved to Desktop 2", undo: record, order: [1, 2] })
      compare(scene.shell.shown, true)
      compare(status().message, "Moved to Desktop 2")
      click("undo", {})
      compare(requests().pop().args, ["undo", JSON.stringify(record)])
    }
    function test_aRefusedOpenLeavesTheActionToTheSessionThatSentIt() {
      shownSession()
      click("add", {})
      const create = requests().pop()
      const session = status().openCount
      compare(ipc().openOverview(), "shown")
      compare(status().openCount, session)
      answer(create, { created: 3, message: "Desktop 3 added", order: [1, 2, 3] })
      compare(status().message, "Desktop 3 added")
    }
    function test_aFailureDuringTheExitMotionIsNotifiedOnce() {
      shownSession()
      click("add", {})
      const create = requests().pop()
      compare(ipc().close(), "ok")
      compare(scene.shell.closing, true)
      ignoreWarning(/action create failed/)
      workerSays({ id: create.id, ok: false, error: "Hyprland did not confirm the change; please try again" })
      compare(notices().length, 1, "the toast of a closing panel cannot be seen")
      tryCompare(scene.shell, "shown", false, 400)
    }
    function test_aHiddenStepThatSucceedsLeavesTheNextSessionAlone() {
      startWorker()
      compare(ipc().navigateDesktop("next"), "ok")
      const step = requests().pop()
      compare(step.args, ["step", "next"])
      open()
      answer(step, { message: "Switched", undo: { moves: [], order: [1, 2] }, order: [1, 2] })
      compare(scene.shell.shown, true)
      compare(status().message, "")
      compare(scene.shell.undoRecord, null)
      compare(notices(), [])
    }
    function test_escapeCancelsADragOnce() {
      startWorker()
      open()
      answer(openRefresh())
      tryCompare(scene.shell, "motionProgress", 1, 1000)
      const z = status().zones.find(z => z.kind === "window")
      const x = z.x + z.width / 2, y = z.y + z.height / 2
      mousePress(scene, x, y)
      mouseMove(scene, x + 40, y + 40)
      mouseMove(scene, x + 80, y + 80)
      compare(status().dragging, true)
      const sent = requests().length
      keyClick(Qt.Key_Escape)
      compare(status().dragging, false)
      compare(scene.shell.shown, true)
      mouseRelease(scene, x + 80, y + 80)
      compare(requests().length, sent)
    }
    function test_aDesktopClickDuringTheRefreshIsRefusedWithTheTrueReason() {
      startWorker()
      open()
      const refresh = openRefresh()
      tryCompare(scene.shell, "motionProgress", 1, 1000)
      const sent = requests().length
      click("desktop", { id: 2 })
      compare(status().message, "Overview is refreshing the desktop list; please try again")
      compare(requests().length, sent)
      compare(scene.shell.shown, true)
      answer(refresh)
      click("desktop", { id: 2 })
      compare(requests().pop().args, ["switch", "2"])
    }
    function test_aStoppedPreviewStaysStoppedForTheRestOfTheSession() {
      const stopped = "Live preview stopped \u00b7 reopen Overview to retry"
      startWorker()
      open()
      answer(openRefresh())
      tryVerify(() => status().windows.every(w => w.thumbnail), 2000, "both cards show an image")
      compare(Quickshell.screencopies.length, 2)
      const a1 = windows[0]
      Quickshell.screencopies.find(view => view.captureSource === a1.wayland).stopped()
      compare(card("a1").reason, stopped)
      compare(status().captureViews, 1)
      a1.lastIpcObject = Object.assign({}, a1.lastIpcObject, { at: [5000, 100] })
      tryVerify(() => card("a1").reason === "Off-screen preview unavailable", 1000)
      a1.lastIpcObject = Object.assign({}, a1.lastIpcObject, { at: [10, 100] })
      tryVerify(() => card("a1").reason !== "Off-screen preview unavailable", 1000)
      wait(100)
      compare(card("a1").reason, stopped)
      compare(status().captureViews, 1)
      compare(Quickshell.screencopies.length, 2)
      compare(ipc().close(), "ok")
      tryCompare(scene.shell, "shown", false, 1000)
      open()
      tryVerify(() => card("a1").thumbnail, 2000)
    }
    function test_aWorkerThatKeepsDyingIsReportedAsStoppedNotRestarting() {
      startWorker()
      worker().exited(1, 0)
      open()
      tryCompare(scene.shell, "motionProgress", 1, 1000)
      click("add", {})
      compare(status().message, "Overview backend is restarting; please try again")
      for (let loss = 2; loss <= 6; loss++) worker().exited(1, 0)
      click("add", {})
      compare(status().message, "Overview backend stopped after repeated failures; restart Overview")
      compare(status().workerRestarts, 6)
    }
  }
}
