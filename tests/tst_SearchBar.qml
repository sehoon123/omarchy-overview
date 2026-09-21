import QtQuick
import QtTest
import ".."

Item {
  id: scene
  width: 640; height: 400
  // A neighbour that can hold focus: the bar may only ever focus its own TextInput.
  // Wayland keyboard focus belongs to the layer surface shell.qml configures; nothing
  // in this component touches a window, so the whole question stays inside this scene.
  Item { id: neighbour; objectName: "neighbour"; width: 10; height: 10; y: 300; activeFocusOnTab: true }
  SearchBar { id: search; width: 420; height: 34; y: 20 }
  property int keyCount: 0
  property int lastKey: 0
  property bool lastKeyGuard: false
  property int editedCount: 0
  Connections {
    target: search
    function onKeyPressed(event) {
      scene.keyCount++
      scene.lastKey = event.key
      // shell.qml:287 reads exactly this at exactly this moment.
      scene.lastKeyGuard = search.compositionGuard
    }
    function onEdited() { scene.editedCount++ }
  }
  TestCase {
    name: "OverviewSearchInput"; when: windowShown
    function init() {
      search.enabled = true
      search.clear()
      tryCompare(search, "compositionGuard", false)
      scene.keyCount = 0; scene.lastKey = 0; scene.lastKeyGuard = false; scene.editedCount = 0
    }
    function test_realTextInputEditingAndSpaces() {
      keyClick(Qt.Key_A); keyClick(Qt.Key_Space); keyClick(Qt.Key_B)
      compare(search.text, "a b")
      keyClick(Qt.Key_Left); keyClick(Qt.Key_Backspace)
      compare(search.text, "ab")
    }
    function test_unicodeAndClear() {
      search.text = "한글 문서"
      compare(search.input.text, "한글 문서")
      search.clear()
      compare(search.text, ""); verify(search.input.activeFocus)
    }
    function test_searchSettlesAfterTyping() {
      keyClick(Qt.Key_X)
      verify(search.settling)
      tryCompare(search, "settling", false)
    }
    // ---- the IME guard around Enter and Space -------------------------------
    // compositionGuard is field.inputMethodComposing || imeSettled.running. The live
    // half is Qt's own property and an offscreen platform never delivers preedit, so
    // only the post-commit half can be driven here - through noteComposition(), which
    // is the exact function TextInput.onInputMethodComposingChanged calls.
    function test_imeGuardIsDownForPlainTyping() {
      compare(search.compositionGuard, false)
      compare(search.input.inputMethodComposing, false)
      compare(search.input.preeditText, "")
      keyClick(Qt.Key_A)
      compare(scene.keyCount, 1)
      compare(scene.lastKeyGuard, false, "Plain typing must never look like a composition")
      keyClick(Qt.Key_Return)
      compare(scene.keyCount, 2)
      compare(scene.lastKey, Qt.Key_Return)
      compare(scene.lastKeyGuard, false, "Enter after plain typing must reach shell.qml unguarded")
      keyClick(Qt.Key_Space)
      compare(scene.lastKeyGuard, false)
      compare(search.text, "a ")
      // Composition starting does not arm the settle timer; the live half covers it.
      search.noteComposition(true)
      compare(search.compositionGuard, false)
    }
    function test_imeGuardCoversEnterAndSpaceAfterACommit() {
      search.noteComposition(false)
      compare(search.compositionGuard, true, "A commit raises the guard immediately")
      keyClick(Qt.Key_Return)
      compare(scene.keyCount, 1)
      compare(scene.lastKey, Qt.Key_Return)
      compare(scene.lastKeyGuard, true, "The Enter that committed the preedit is reported as guarded")
      search.noteComposition(false)
      keyClick(Qt.Key_Space)
      compare(scene.keyCount, 2)
      compare(scene.lastKey, Qt.Key_Space)
      compare(scene.lastKeyGuard, true, "So is the Space that committed it")
      // The bar reports the guard, it never swallows the key: the space is still typed.
      compare(search.text, " ")
      // The guard is bounded: it lifts on its own, without another event.
      tryCompare(search, "compositionGuard", false, 1000)
      keyClick(Qt.Key_Return)
      compare(scene.keyCount, 3)
      compare(scene.lastKeyGuard, false, "Once settled, Enter is an ordinary Enter again")
      // Re-arming while already armed keeps it armed and still bounded.
      search.noteComposition(false)
      search.noteComposition(false)
      compare(search.compositionGuard, true)
      tryCompare(search, "compositionGuard", false, 1000)
      // The IME guard and the typing settle timer are independent windows.
      search.text = ""
      tryCompare(search, "settling", false)
      search.noteComposition(false)
      verify(search.compositionGuard)
      compare(search.settling, false, "A commit must not look like new typing")
      tryCompare(search, "compositionGuard", false, 1000)
    }
    // ---- queries ------------------------------------------------------------
    function test_emptyQueryNeitherFiltersNorGrows() {
      compare(search.text, "")
      compare(scene.editedCount, 0)
      search.clear()
      compare(scene.editedCount, 0, "Clearing an empty query must not re-filter the grid")
      verify(search.input.activeFocus, "but it still brings the caret back")
      keyClick(Qt.Key_Q)
      compare(scene.editedCount, 1)
      compare(search.text, "q")
      verify(search.settling)
      search.text = ""
      compare(scene.editedCount, 2)
      compare(search.text, "")
      tryCompare(search, "settling", false)
      verify(findChild(search, "searchPlaceholder").visible, "An empty query shows the hint")
      search.text = "x"
      compare(findChild(search, "searchPlaceholder").visible, false)
      // An untrusted title pasted into the query cannot grow the field without bound.
      compare(search.input.maximumLength, 256)
      let long = ""
      for (let i = 0; i < 100; i++) long += "0123456789"
      search.text = long
      compare(search.text.length, 256)
      compare(search.input.text, search.text)
      search.clear()
      compare(search.text, "")
    }
    function test_unicodeQueriesRoundTripAsPlainText() {
      const samples = ["한글 문서", "日本語のウィンドウ", "Ελληνικά", "мир", "مرحبا بالعالم",
                       "café", "e\u0301", "🚀 rocket 🙂", "<b>not markup</b>", "a\tb", "  ", "0"]
      for (let i = 0; i < samples.length; i++) {
        search.text = samples[i]
        compare(search.text, samples[i], "The query is stored verbatim")
        compare(search.input.text, samples[i])
        compare(search.input.preeditText, "")
        compare(findChild(search, "searchPlaceholder").visible, false)
      }
      compare(scene.editedCount, samples.length)
      search.clear()
      compare(search.text, "")
      compare(scene.editedCount, samples.length + 1)
      verify(findChild(search, "searchPlaceholder").visible)
    }
    // ---- focus --------------------------------------------------------------
    function test_focusStaysInsideTheBar() {
      search.focusInput()
      verify(search.input.activeFocus)
      verify(!neighbour.activeFocus)
      // Another item can take the focus back at any time.
      neighbour.forceActiveFocus()
      verify(neighbour.activeFocus)
      compare(search.input.activeFocus, false)
      keyClick(Qt.Key_Z)
      compare(search.text, "", "An unfocused bar must not capture typing")
      compare(scene.keyCount, 0, "and must not forward keys it never received")
      search.focusInput()
      verify(search.input.activeFocus)
      verify(!neighbour.activeFocus)
      keyClick(Qt.Key_Z)
      compare(search.text, "z")
      compare(scene.keyCount, 1)
      // shell.qml disables the bar while an action runs, a drag is in flight, the
      // settings panel is open or Quick Look has the stage.
      search.enabled = false
      compare(search.input.activeFocus, false, "A disabled bar holds no focus")
      keyClick(Qt.Key_Y)
      compare(search.text, "z", "and accepts no typing")
      search.enabled = true
      verify(search.input.activeFocus, "Re-enabling restores the caret it had")
      keyClick(Qt.Key_Y)
      compare(search.text, "zy")
      // clear() is the only other focus path, and it keeps focus in the same field.
      search.clear()
      compare(search.text, "")
      verify(search.input.activeFocus)
      verify(!neighbour.activeFocus)
      compare(search.input.focus, true)
    }
    function test_clearButtonIsTheOnlyPointerAffordance() {
      search.text = "query"
      const glyph = findChild(search, "searchClear")
      verify(glyph.visible)
      mouseClick(search, search.width - 17, search.height / 2)
      compare(search.text, "", "The × clears the query")
      verify(search.input.activeFocus, "and hands the caret back")
      compare(glyph.visible, false, "and then disappears")
      // Clicking the bar itself must not clear or steal anything.
      search.text = "kept"
      mouseClick(search, 40, search.height / 2)
      compare(search.text, "kept")
    }
  }
}
