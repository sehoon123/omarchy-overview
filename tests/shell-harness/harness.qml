import QtQuick
import QtTest
import Quickshell
import Quickshell.Hyprland

// shell.qml end to end, offline. ./build copies the shell into ./app, and the
// stubs on the import path stand in for Quickshell, so this file plays the
// worker, the capture-context helper, the IPC caller and the compositor.
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
    function click(kind, match) {
      const z = status().zones.find(z => z.kind === kind && Object.keys(match).every(k => z[k] === match[k]))
      verify(z, "no " + kind + " zone " + JSON.stringify(match))
      mouseClick(scene, z.x + z.width / 2, z.y + z.height / 2)
    }
    function grantContext() {
      const helper = process("capture_context.py")
      helper.stdout.read(JSON.stringify({ ok: true, outputs: [scene.output] }))
      helper.exited(0, 0)
    }
    // The worker greets the shell, which reads the desktop state once.
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
    // Every open reads the desktop state again shortly after it is shown.
    function openRefresh() {
      const before = requests().length
      tryVerify(() => requests().length === before + 1, 1000, "the open sends a desktop refresh")
      const refresh = requests().pop()
      compare(refresh.args, ["state"])
      return refresh
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

    // The refresh that every open sends is a background read: a slow or wedged
    // worker must not keep the overlay, and its keyboard grab, on screen.
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
      // Its late reply still updates the desktop list, and nothing else.
      answer(refresh, { desktops: { "1": { label: "Mail" } }, order: [1, 2], perMonitor: false })
      compare(scene.shell.shown, false)
      compare(Quickshell.executed, [])
      compare(status().desktopLabels, ["Mail", "Desktop 2"])
    }
    // Focusing a window never needs the worker, so the refresh cannot hold it up.
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
    // A refresh the user never asked for does not fail as an action they took.
    function test_aLostRefreshIsJournaledNotReportedAsAFailedAction() {
      startWorker()
      open()
      openRefresh()
      ignoreWarning(/desktop refresh failed/)
      worker().exited(1, 0)
      compare(scene.shell.shown, true)
      compare(status().message, "")
    }
    // A desktop switch does need the worker, which answers one request at a time:
    // the click is refused with the true reason, and works once the refresh is in.
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
    // A stopped stream is final until a new Overview session, even when its
    // window leaves the capture plan and comes back within this one.
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
      // Reopening is the cure the card names.
      compare(ipc().close(), "ok")
      tryCompare(scene.shell, "shown", false, 1000)
      open()
      tryVerify(() => card("a1").thumbnail, 2000)
    }
  }
}
