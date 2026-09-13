import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io

ShellRoot {
  id: fixture
  property string tab: "Tab A"
  property color tabColor: "#23b45a"
  property bool shown: false
  Window {
    id: testWindow
    visible: fixture.shown
    width: 1000; height: 760
    title: "OVERVIEW CACHE FIXTURE - " + fixture.tab
    color: fixture.tabColor
    Text { anchors.centerIn: parent; text: fixture.tab; color: "white"; font.pixelSize: 80 }
  }
  Window { visible: fixture.shown; width: 1000; height: 760; title: "OVERVIEW CACHE SPACER 1"; color: "#30343d" }
  Window { visible: fixture.shown; width: 1000; height: 760; title: "OVERVIEW CACHE SPACER 2"; color: "#30343d" }
  Window { visible: fixture.shown; width: 1000; height: 760; title: "OVERVIEW CACHE SPACER 3"; color: "#30343d" }
  IpcHandler {
    target: "fixture"
    function openFixture(): void { fixture.shown = true }
    function change(): void { fixture.tab = "Tab B"; fixture.tabColor = "#2757df" }
    function status(): string { return JSON.stringify({ pid: Quickshell.processId, visible: testWindow.visible, title: testWindow.title }) }
    function close(): void { Qt.quit() }
  }
}
