import QtQuick

// An Item in the test window, so key focus, clicks and frameSwapped behave as
// they do on screen.
Item { property var screen: null; property color color; width: 1600; height: 900 }
