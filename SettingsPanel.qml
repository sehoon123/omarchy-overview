import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as Controls

FocusScope {
  id: panel
  required property var store
  property color accent: "#76b5ff"
  property color surfaceColor: "#202633"
  property color textColor: "#ecf0f7"
  signal dismissed()
  function focusFirst() { themeToggle.forceActiveFocus() }
  Keys.onEscapePressed: event => { dismissed(); event.accepted = true }
  Rectangle { anchors.fill: parent; color: "#40000000" }
  MouseArea { anchors.fill: parent; onClicked: panel.dismissed() }
  Controls.Pane {
    id: card
    anchors { right: parent.right; bottom: parent.bottom; margins: 32 }
    width: Math.min(390, parent.width - 32)
    height: Math.min(implicitHeight, parent.height - 32)
    padding: 24
    palette {
      window: panel.surfaceColor; base: panel.surfaceColor; button: panel.surfaceColor
      windowText: panel.textColor; text: panel.textColor; buttonText: panel.textColor
      highlight: panel.accent; highlightedText: panel.surfaceColor; light: panel.textColor
      mid: Qt.rgba(panel.textColor.r, panel.textColor.g, panel.textColor.b, .3)
    }
    background: Rectangle {
      color: panel.surfaceColor; radius: 14; border.width: 1; border.color: "#40ffffff"
      // Behind the controls, not a sibling covering their pointer input.
      MouseArea { anchors.fill: parent }
    }
    contentItem: Flickable {
      implicitHeight: rows.implicitHeight
      contentHeight: rows.implicitHeight; clip: true
      ColumnLayout {
        id: rows
        width: parent.width; spacing: 10
        RowLayout {
          Layout.fillWidth: true
          Controls.Label { text: "Overview settings"; font.pixelSize: 18; font.bold: true; Layout.fillWidth: true }
          Controls.Button { text: "Done"; onClicked: panel.dismissed() }
        }
        Controls.CheckBox {
          id: themeToggle
          objectName: "followThemeToggle"
          text: "Follow Omarchy colors"; checked: panel.store.values.followTheme
          enabled: panel.store.writable
          onToggled: panel.store.set("followTheme", checked)
        }
        Controls.CheckBox {
          text: "Blur wallpaper"; checked: panel.store.values.blur
          enabled: panel.store.writable
          onToggled: panel.store.set("blur", checked)
        }
        RowLayout {
          Controls.Label { text: "Wallpaper dimming"; Layout.fillWidth: true }
          Controls.Label { text: panel.store.values.dim + "%" }
        }
        Controls.Slider {
          Layout.fillWidth: true
          from: 0; to: 80; stepSize: 1; value: panel.store.values.dim
          enabled: panel.store.writable
          onMoved: panel.store.set("dim", value)
        }
        Controls.CheckBox {
          text: "Animate window layout"; checked: panel.store.values.motion
          enabled: panel.store.writable
          onToggled: panel.store.set("motion", checked)
        }
        Controls.CheckBox {
          text: "Only this monitor's windows"; checked: panel.store.values.monitorOnly
          enabled: panel.store.writable
          onToggled: panel.store.set("monitorOnly", checked)
        }
        Controls.Label { text: "Output snapshots"; font.bold: true; Layout.topMargin: 8 }
        Controls.Label {
          Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12; opacity: .7
          text: "Visible window regions are captured once before opening. These are not live previews. Covered/off-screen windows show their last matching snapshot or a titled card. No window capture or automatic desktop scrolling."
        }
        Controls.CheckBox {
          text: "Keep previews in memory when closed"; checked: panel.store.values.keepCache
          enabled: panel.store.writable
          onToggled: panel.store.set("keepCache", checked)
        }
        Controls.Label {
          Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12; opacity: .7
          text: "Keep previous snapshots for off-screen windows. Turn this off to release them when closed. No background capture or image files; the encoded cache is bounded to 8 MiB."
        }
        Controls.Label {
          Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12; opacity: .8
          text: "Search: type or Ctrl+F\nQuick Look: Space (empty search) or Ctrl+Space\nEsc: close preview, clear search, then exit"
        }
        Controls.Label {
          Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12
          text: panel.store.error || (panel.store.saving ? "Saving…" : "Changes are saved automatically")
          color: panel.store.error ? "#ea6962" : panel.textColor
        }
      }
    }
  }
}
