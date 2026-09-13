import QtQuick
import QtTest
import ".."

Item {
  width: 600; height: 800
  Preferences { id: store }
  SignalSpy { id: writes; target: store; signalName: "writeRequested" }
  SettingsPanel { id: panel; anchors.fill: parent; store: store }
  TestCase {
    name: "OverviewPreferences"; when: windowShown
    function init() {
      store.failed(""); store.document = ({}); store.load('{"version":1,"future":{"preserve":true}}')
      writes.clear()
    }
    function cleanup() { store.failed("") }
    function test_coalescesAndPreservesUnknownKeys() {
      for (let i = 0; i <= 80; i++) store.set("dim", i)
      store.flush()
      compare(writes.count, 1)
      const saved = JSON.parse(writes.signalArguments[0][0])
      compare(saved.dim, 80); compare(saved.future.preserve, true)
      store.saved(); compare(store.values.dim, 80); compare(store.saving, false)
    }
    function test_serializesRapidEditsAndIgnoresStaleReads() {
      store.set("dim", 15); store.flush()
      store.set("dim", 25); store.flush()
      compare(writes.count, 1); compare(store.values.dim, 25)
      store.load('{"dim":40}')
      compare(store.values.dim, 25)
      store.saved(); wait(0)
      compare(writes.count, 2); compare(JSON.parse(writes.signalArguments[1][0]).dim, 25)
      store.saved(); compare(store.document.dim, 25)
    }
    function test_invalidOrNewerFileIsNeverOverwritten() {
      store.load('{broken')
      compare(store.writable, false); verify(!store.set("dim", 10))
      store.flush(); compare(writes.count, 0)
      store.load('{"version":2}')
      verify(!store.writable)
    }
    function test_failedWriteRollsBackAndDoesNotRetry() {
      store.set("keepCache", false); store.flush()
      compare(store.values.keepCache, false)
      store.failed("Disk full")
      compare(store.values.keepCache, true); compare(store.error, "Disk full")
      wait(170); compare(writes.count, 1); compare(store.saving, false)
    }
    function test_externalChangesAndValidation() {
      store.load('{"dim":20,"keepCache":false,"liveLimit":1}')
      compare(store.values.dim, 20); compare(store.values.keepCache, false)
      verify(!store.set("liveLimit", 100)); verify(!store.set("keepCache", "false"))
      compare(writes.count, 0)
    }
    function test_settingsMouseToggle() {
      const toggle = findChild(panel, "followThemeToggle")
      verify(toggle !== null)
      mouseClick(toggle, toggle.width / 2, toggle.height / 2)
      compare(store.values.followTheme, false)
    }
    function test_settingsKeyboardToggle() {
      panel.focusFirst()
      keyClick(Qt.Key_Space)
      compare(store.values.followTheme, false)
      keyClick(Qt.Key_Space)
      compare(store.values.followTheme, true)
    }
  }
}
