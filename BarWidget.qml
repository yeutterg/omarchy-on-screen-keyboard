import QtQuick
import Quickshell
import qs.Ui

// Bar button: tap to show or hide the keyboard, right-click to float or dock it.
// Shown where the "barButton" option puts it (default: on the bar while
// detached, in the tray while attached); the widget also stays loaded when
// hidden, for the tablet-mode bar lock below.
BarWidget {
  id: root
  moduleName: "io.github.yeutterg.onscreen-keyboard"

  readonly property var keyboard: bar?.shell?.serviceFor("io.github.yeutterg.onscreen-keyboard") ?? null

  // Where the button goes is the service's "barButton" option; by default on
  // the bar while detached and in the tray while attached.
  readonly property bool wanted: !!root.keyboard && root.keyboard.buttonPlacement === "bar"

  visible: wanted
  implicitWidth: wanted ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  // In tablet mode, turn off dragging the bar to another edge: Omarchy starts
  // a bar move when the middle of the bar is held and dragged, which a finger
  // does by accident, and it has no setting for that. This widget sits in the
  // bar's window, so it finds the bar's drag area there (a MouseArea with
  // dragThreshold and suppressClick) and disables it while detached. Options:
  // "lockBarInTabletMode": false keeps dragging on.
  readonly property bool lockBar: !!root.keyboard && root.keyboard.tabletMode
    && root.keyboard.options.lockBarInTabletMode !== false
  property var dragAreas: []

  function findDragAreas() {
    var top = root
    while (top.parent) top = top.parent
    var found = []
    var stack = [top]
    while (stack.length) {
      var item = stack.pop()
      if (item !== root && item.dragThreshold !== undefined && item.suppressClick !== undefined
          && item.pressAndHoldInterval !== undefined) found.push(item)
      var kids = item.children || []
      for (var i = 0; i < kids.length; i++) stack.push(kids[i])
    }
    dragAreas = found
    if (root.keyboard) root.keyboard.barLockReady = found.length > 0
    applyLock()
  }

  function applyLock() {
    for (var i = 0; i < dragAreas.length; i++) dragAreas[i].enabled = !lockBar
  }

  onLockBarChanged: findDragAreas()
  Component.onCompleted: Qt.callLater(findDragAreas)

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
