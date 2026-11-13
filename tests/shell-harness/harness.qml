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
  function toplevel(address, x) {
    const monitor = { name: "DP-1", id: 1 }
    return toplevelType.createObject(scene, { address: address, title: "Window " + address, monitor: monitor,
      workspace: { id: 1, name: "1", monitor: monitor },
      lastIpcObject: { mapped: true, class: "app-" + address, at: [x, 100], size: [600, 400], monitor: 1 },
      wayland: { activate() { scene.activated = scene.activated.concat([address]) } } })
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
  }
}
