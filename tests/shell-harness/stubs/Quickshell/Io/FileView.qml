import QtQuick

QtObject {
  property string path
  property bool watchChanges
  property bool atomicWrites
  property bool printErrors
  property bool preload: true
  property var writes: []
  signal loaded()
  signal loadFailed(int error)
  signal fileChanged()
  signal saved()
  signal saveFailed(int error)
  function text() { return "" }
  function reload() { loadFailed(FileViewError.FileNotFound) }
  function setText(text) { writes = writes.concat([text]) }
  Component.onCompleted: if (preload) Qt.callLater(reload)
}
