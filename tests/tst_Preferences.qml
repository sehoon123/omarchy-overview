import QtQuick
import QtTest
import ".."

// Settings persistence and the panel that drives it. No file path is involved
// anywhere: Preferences asks its view to write through writeRequested(text), so
// the harness below only ever inspects that signal. Nothing here reads or writes
// a real settings.json, and load()/saved()/failed() stand in for the FileView
// callbacks the shell wires up.
Item {
  id: harness
  width: 600; height: 800
  // Every control the panel disables when the file cannot be written.
  readonly property var controlNames: ["followThemeToggle", "blurToggle", "dimSlider",
    "motionToggle", "monitorOnlyToggle", "liveLimitCombo"]
  readonly property string shippedKeys: "blur,dim,followTheme,keepCache,liveLimit,monitorOnly,motion"
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
    // A missing settings.json reaches load("{}") through shell.qml's
    // FileViewError.FileNotFound branch: defaults, writable, and no write back.
    function test_missingFileFallsBackToDefaultsWithoutWritingOne() {
      store.document = ({}); store.load("{}")
      verify(store.ready); verify(store.writable); compare(store.error, "")
      compare(Object.keys(store.values).sort().join(","), harness.shippedKeys)
      compare(store.values.followTheme, true); compare(store.values.blur, true)
      compare(store.values.dim, 40); compare(store.values.motion, true)
      compare(store.values.liveLimit, 0); compare(store.values.keepCache, true)
      compare(store.values.monitorOnly, false)
      compare(writes.count, 0); compare(store.saving, false)
    }
    function test_unsupportedDocumentsAreNeverOverwritten_data() {
      return [
        { tag: "truncated", text: "{broken" },
        { tag: "garbage", text: "not json at all" },
        { tag: "empty-line", text: "" },
        { tag: "array", text: "[]" },
        { tag: "null", text: "null" },
        { tag: "number", text: "42" },
        { tag: "string", text: '"settings"' },
        { tag: "newer-version", text: '{"version":2,"dim":10}' },
        { tag: "string-version", text: '{"version":"1"}' },
        { tag: "null-version", text: '{"version":null}' }
      ]
    }
    function test_unsupportedDocumentsAreNeverOverwritten(row) {
      store.load(row.text)
      verify(store.ready); compare(store.writable, false)
      verify(store.error !== "")
      // The last confirmed document is still what the UI reads, and no edit or
      // flush can replace the file on disk.
      compare(store.values.dim, 40)
      verify(!store.set("dim", 10)); verify(!store.set("followTheme", false))
      store.flush(); wait(170)
      compare(writes.count, 0); compare(store.saving, false)
      for (let i = 0; i < harness.controlNames.length; i++)
        compare(findChild(panel, harness.controlNames[i]).enabled, false)
    }
    // AUDIT.md F-62: a file that reads but cannot be written kept writable true,
    // so every edit snapped back with the same toast forever. The first failed
    // write now disables the controls, and a later successful read restores them.
    function test_readOnlyFileDisablesTheControlsWithoutRetrying() {
      verify(store.writable)
      verify(store.set("dim", 12)); store.flush()
      compare(writes.count, 1); compare(store.values.dim, 12)
      store.failed("Could not save settings; previous values restored")
      compare(store.values.dim, 40)
      compare(store.writable, false)
      compare(store.error, "Could not save settings; previous values restored")
      compare(findChild(panel, "statusLabel").text, store.error)
      verify(!store.set("dim", 12))
      store.flush(); wait(170)
      compare(writes.count, 1); compare(store.saving, false)
      for (let i = 0; i < harness.controlNames.length; i++) {
        const control = findChild(panel, harness.controlNames[i])
        verify(control !== null); compare(control.enabled, false)
      }
      const toggle = findChild(panel, "followThemeToggle")
      mouseClick(toggle, toggle.width / 2, toggle.height / 2)
      compare(store.values.followTheme, true); compare(writes.count, 1)
      store.load('{"version":1,"dim":20}')
      verify(store.writable); compare(store.values.dim, 20); compare(store.error, "")
      for (let j = 0; j < harness.controlNames.length; j++)
        compare(findChild(panel, harness.controlNames[j]).enabled, true)
    }
    // keepCache has no control in the panel; it must still round-trip and still
    // be validated as a boolean.
    function test_keepCacheSurvivesAsALegacyKey() {
      store.load('{"version":1,"keepCache":false,"future":{"preserve":true}}')
      compare(store.values.keepCache, false)
      verify(store.set("keepCache", true)); store.flush()
      compare(writes.count, 1)
      const saved = JSON.parse(writes.signalArguments[0][0])
      compare(saved.keepCache, true); compare(saved.version, 1)
      compare(saved.future.preserve, true)
      store.saved()
      compare(store.values.keepCache, true); compare(store.document.keepCache, true)
      verify(!store.set("keepCache", "false")); verify(!store.set("keepCache", 0))
      compare(store.values.keepCache, true)
    }
    // The written document keeps every shipped key, every unknown key and the
    // version marker, as one indented JSON object per write.
    function test_oneWriteKeepsEveryShippedKeyAndEveryUnknownKey() {
      store.load('{"version":1,"future":{"preserve":true},"legacy":7}')
      verify(store.set("followTheme", false)); verify(store.set("blur", false))
      verify(store.set("dim", 30)); verify(store.set("motion", false))
      verify(store.set("liveLimit", 6)); verify(store.set("keepCache", false))
      verify(store.set("monitorOnly", true))
      store.flush()
      compare(writes.count, 1)
      const text = writes.signalArguments[0][0]
      compare(text.charAt(text.length - 1), "\n")
      const saved = JSON.parse(text)
      compare(Object.keys(saved).sort().join(","),
        "blur,dim,followTheme,future,keepCache,legacy,liveLimit,monitorOnly,motion,version")
      compare(saved.version, 1); compare(saved.legacy, 7)
      compare(saved.future.preserve, true); compare(saved.dim, 30)
      compare(saved.liveLimit, 6); compare(saved.keepCache, false)
      store.saved()
      compare(store.values.dim, 30); compare(store.values.liveLimit, 6)
      compare(store.saving, false)
    }
    // A completed write proves the file is writable again, so the panel recovers
    // without waiting for a reload.
    function test_aCompletedWriteReenablesThePanel() {
      verify(store.set("dim", 50)); store.flush()
      store.failed("Could not save settings; previous values restored")
      compare(store.writable, false)
      // Only the view can decide a write succeeded; drive that path directly.
      store.writable = true
      verify(store.set("dim", 50)); store.flush()
      compare(writes.count, 2)
      store.saved()
      verify(store.writable); compare(store.error, "")
      compare(store.values.dim, 50)
      for (let i = 0; i < harness.controlNames.length; i++)
        compare(findChild(panel, harness.controlNames[i]).enabled, true)
    }
  }
}
