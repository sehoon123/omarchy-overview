import QtQuick
import QtTest
import ".."

Item {
  width: 640; height: 400
  SearchBar { id: search; width: 420; height: 34; y: 20 }
  TestCase {
    name: "OverviewSearchInput"; when: windowShown
    function init() { search.clear() }
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
  }
}
