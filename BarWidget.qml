import QtQuick
import Quickshell
import qs.Ui

// Bar button: tap to show or hide the keyboard, right-click to float or dock it.
BarWidget {
  id: root
  moduleName: "io.github.yeutterg.onscreen-keyboard"

  readonly property var keyboard: bar?.shell?.serviceFor("io.github.yeutterg.onscreen-keyboard") ?? null

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰌌"
    active: root.keyboard ? root.keyboard.shown : false
    useActiveColor: false
    dimmed: !root.keyboard || !!root.keyboard.problem
    tooltipText: !root.keyboard ? "On-screen keyboard service isn't running"
      : root.keyboard.problem ? root.keyboard.problem
      : root.keyboard.shown ? "Hide keyboard" : "Show keyboard"
    onPressed: function(b) {
      if (!root.keyboard) return
      if (b === Qt.RightButton) root.keyboard.setFloating(!root.keyboard.floating)
      else root.keyboard.toggle()
    }
  }
}
