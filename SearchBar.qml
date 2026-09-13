import QtQuick

Rectangle {
  id: bar
  property alias text: field.text
  property alias input: field
  property color accent: "#76b5ff"
  property color surfaceColor: "#202633"
  property color textColor: "#ecf0f7"
  property bool settling: settle.running
  readonly property bool compositionGuard: field.inputMethodComposing || imeSettled.running
  signal keyPressed(var event)
  signal edited()
  function focusInput() { field.forceActiveFocus() }
  function clear() { field.clear(); field.forceActiveFocus() }
  radius: height / 2
  color: Qt.rgba(surfaceColor.r, surfaceColor.g, surfaceColor.b, .92)
  border.width: 1
  border.color: field.activeFocus && text.length ? accent : Qt.rgba(textColor.r, textColor.g, textColor.b, .16)
  onTextChanged: { settle.restart(); edited() }
  Timer { id: settle; interval: 160 }
  // Some IMEs commit preedit before forwarding the same Enter/Space key.
  Timer { id: imeSettled; interval: 100 }
  // A real TextInput is essential: a Keys-only search cannot compose Korean.
  TextInput {
    id: field
    anchors { left: parent.left; right: clearButton.left; verticalCenter: parent.verticalCenter; leftMargin: 18; rightMargin: 4 }
    height: 24
    verticalAlignment: TextInput.AlignVCenter
    color: bar.textColor; font.pixelSize: 13
    selectionColor: bar.accent; selectedTextColor: bar.surfaceColor
    selectByMouse: true; clip: true
    maximumLength: 256
    onInputMethodComposingChanged: if (!inputMethodComposing) imeSettled.restart()
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: event => bar.keyPressed(event)
    Text {
      anchors.fill: parent; verticalAlignment: Text.AlignVCenter
      text: "Search windows"; textFormat: Text.PlainText
      color: bar.textColor; opacity: .55; font: field.font
      visible: !field.text && !field.preeditText
    }
  }
  Item {
    id: clearButton
    anchors.right: parent.right; width: 34; height: parent.height
    Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 18; color: bar.textColor; visible: !!bar.text }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: bar.clear() }
  }
}
