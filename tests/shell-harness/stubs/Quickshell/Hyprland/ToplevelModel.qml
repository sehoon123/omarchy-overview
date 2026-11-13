import QtQuick

// Quickshell's ObjectModel is a model for the shell's Repeater and a `values`
// list for everything else; a ListModel row per window keeps both views.
ListModel {
  property var values: []
  onValuesChanged: {
    clear()
    for (const window of values) append({ modelData: window })
  }
}
