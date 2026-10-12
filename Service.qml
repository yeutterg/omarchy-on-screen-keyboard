import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons

// On-screen keyboard service: runs the Wayland helper, decides when the
// keyboard shows, and draws it docked along the bottom or floating.
//
// IPC (omarchy-shell onscreen-keyboard <method>):
//   show | hide | toggle | float | dock | status
//   setTabletMode true|false   (called by the switch binds this plugin adds)
Item {
  id: root

  property var shell: null
  property string omarchyPath: ""
  property var manifest: null

  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string stateFile: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy-onscreen-keyboard/state.json"

  // What the helper reports
  property bool helperReady: false
  property bool imActive: false
  property int purpose: 0
  property string problem: ""         // shown to the user when the helper can't work

  // Visibility
  property bool tabletMode: false
  property bool shown: false
  property bool autoShown: false      // shown because a text field got focus
  property bool dismissed: false      // hidden by hand while that field stays focused

  // Floating keyboard, remembered across restarts
  property bool floating: false
  property real floatX: -1
  property real floatY: -1
  property real floatWidth: 440

  property bool dictationAvailable: false
  property bool dictating: false

  readonly property var screen: {
    var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (screens[i].name === name) return screens[i]
    return screens.length ? screens[0] : null
  }

  function show() { shown = true; autoShown = false; dismissed = false }
  function hide() { shown = false; if (imActive) dismissed = true }
  function toggle() { shown ? hide() : show() }
  function setFloating(on) { floating = on; saveState() }

  onImActiveChanged: {
    if (imActive) {
      if (tabletMode && !shown && !dismissed) { shown = true; autoShown = true }
    } else {
      if (autoShown) shown = false
      autoShown = false
      dismissed = false
    }
  }
  onTabletModeChanged: {
    if (!tabletMode) { shown = false; autoShown = false }
    else if (imActive && !dismissed) { shown = true; autoShown = true }
  }

  function sendText(text) { send("text " + text) }
  function sendKey(keysym, mods) { send("key " + keysym + (mods && mods.length ? " " + mods.join(",") : "")) }
  function send(line) { if (helper.running && helperReady) helper.write(line + "\n") }

  // Tap the mic to start dictating, tap again to stop (voxtype).
  function dictate() {
    Quickshell.execDetached(["voxtype", "record", "toggle"])
    dictating = !dictating
  }

  // ---- helper process ------------------------------------------------------

  Process {
    id: helper
    command: ["python3", root.pluginDir + "/helper/osk-helper.py"]
    running: true
    stdinEnabled: true

    stdout: SplitParser {
      onRead: function(line) {
        var space = line.indexOf(" ")
        var event = space < 0 ? line : line.slice(0, space)
        var arg = space < 0 ? "" : line.slice(space + 1)
        if (event === "ready") { root.helperReady = true; root.problem = "" }
        else if (event === "im") root.imActive = arg === "1"
        else if (event === "purpose") root.purpose = parseInt(arg) || 0
        else if (event === "unavailable") root.problem = "Another input method (fcitx5 or squeekboard) is running, so the keyboard can't pop up on text fields."
        else if (event === "error") root.problem = arg
      }
    }
    stderr: SplitParser { onRead: function(line) { console.warn("onscreen-keyboard helper:", line) } }

    onExited: function(code) {
      root.helperReady = false
      root.imActive = false
      // Missing dependency (exit 2): don't spin; anything else: retry.
      if (code !== 2) restartTimer.start()
    }
  }

  Timer {
    id: restartTimer
    interval: 3000
    onTriggered: helper.running = true
  }

  Component.onDestruction: if (helper.running) helper.write("quit\n")

  // ---- tablet-mode switch --------------------------------------------------
  // Any input device whose switch bitmap has SW_TABLET_MODE (bit 1). Binds are
  // added at runtime with hyprctl eval, so no Hyprland config is edited; they
  // are added again whenever Hyprland reloads its config.

  property var tabletSwitches: []

  Process {
    id: findSwitches
    command: ["cat", "/proc/bus/input/devices"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        var names = [], name = ""
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var n = lines[i].match(/^N: Name="(.*)"$/)
          if (n) name = n[1]
          var sw = lines[i].match(/^B: SW=(.*)$/)
          if (sw) {
            var words = sw[1].trim().split(/\s+/)
            var low = parseInt(words[words.length - 1], 16)
            if (Math.floor(low / 2) % 2 === 1) names.push(name)
          }
        }
        root.tabletSwitches = names
        root.registerBinds()
      }
    }
  }

  function luaString(s) { return "'" + String(s).replace(/\\/g, "\\\\").replace(/'/g, "\\'") + "'" }

  function registerBinds() {
    if (!tabletSwitches.length) return
    var lua = ""
    for (var i = 0; i < tabletSwitches.length; i++) {
      var sw = tabletSwitches[i]
      lua += "hl.bind(" + luaString("switch:on:" + sw) + ", hl.dsp.exec_cmd('omarchy-shell -q onscreen-keyboard setTabletMode true'), { locked = true, description = 'On-screen keyboard: detached' })\n"
      lua += "hl.bind(" + luaString("switch:off:" + sw) + ", hl.dsp.exec_cmd('omarchy-shell -q onscreen-keyboard setTabletMode false'), { locked = true, description = 'On-screen keyboard: attached' })\n"
    }
    bindProc.command = ["hyprctl", "eval", lua]
    bindProc.running = true
  }

  Process { id: bindProc }

  Connections {
    target: Hyprland
    function onRawEvent(event) { if (event.name === "configreloaded") root.registerBinds() }
  }

  // ---- dictation -----------------------------------------------------------

  Process {
    id: voxtypeCheck
    command: ["sh", "-c", "command -v voxtype"]
    running: true
    onExited: function(code) { root.dictationAvailable = code === 0 }
  }

  // Keep the mic key honest if dictation stops on its own.
  Process {
    id: voxtypeStatus
    command: ["voxtype", "status"]
    stdout: StdioCollector {
      onStreamFinished: root.dictating = /record/i.test(text)
    }
  }
  Timer {
    interval: 1000
    repeat: true
    running: root.dictating && root.shown
    onTriggered: voxtypeStatus.running = true
  }

  // ---- state ---------------------------------------------------------------

  FileView {
    id: stateView
    path: root.stateFile
    blockLoading: true
    printErrors: false
    onLoaded: {
      try {
        var s = JSON.parse(text())
        root.floating = !!s.floating
        root.floatX = s.floatX ?? -1
        root.floatY = s.floatY ?? -1
        root.floatWidth = s.floatWidth ?? 440
      } catch (e) {}
    }
  }

  function saveState() {
    mkState.running = true
    stateView.setText(JSON.stringify({ floating: floating, floatX: floatX, floatY: floatY, floatWidth: floatWidth }))
  }
  Process { id: mkState; command: ["mkdir", "-p", root.stateFile.replace(/\/[^/]*$/, "")] }

  // ---- IPC -----------------------------------------------------------------

  IpcHandler {
    target: "onscreen-keyboard"
    function show(): string { root.show(); return "ok" }
    function hide(): string { root.hide(); return "ok" }
    function toggle(): string { root.toggle(); return "ok" }
    function float(): string { root.setFloating(true); return "ok" }
    function dock(): string { root.setFloating(false); return "ok" }
    function setTabletMode(on: string): string { root.tabletMode = on === "true" || on === "1"; return "ok" }
    function status(): string {
      return JSON.stringify({ shown: root.shown, floating: root.floating, tabletMode: root.tabletMode,
                              textField: root.imActive, purpose: root.purpose, helper: root.helperReady,
                              switches: root.tabletSwitches, problem: root.problem })
    }
  }

  // ---- windows -------------------------------------------------------------

  readonly property real screenW: screen ? screen.width : 1280
  readonly property real screenH: screen ? screen.height : 800
  readonly property real dockHeight: Math.round(Math.min(screenH * (screenW > screenH ? 0.38 : 0.3), 380))

  // Docked: full width along the bottom; windows make room above it.
  PanelWindow {
    id: dock
    screen: root.screen
    visible: root.shown && !root.floating
    anchors { left: true; right: true; bottom: true }
    implicitHeight: root.dockHeight
    color: "transparent"
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: root.dockHeight
    WlrLayershell.namespace: "omarchy-onscreen-keyboard"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    Keyboard {
      id: dockKeys
      anchors.fill: parent
      service: root
    }

    Rectangle {
      anchors { left: parent.left; right: parent.right; top: parent.top }
      height: 2
      color: Commons.Color.accent
    }

    // Pinch in to float (like squeezing the iPad keyboard).
    PinchHandler {
      target: null
      onActiveChanged: if (!active && activeScale < 0.8) root.setFloating(true)
    }
  }

  // Floating: a small keyboard that can be dragged anywhere.
  readonly property real floatHeight: Math.round(floatWidth * 0.62)
  readonly property real floatLeft: floatX < 0 ? (screenW - floatWidth) / 2 : Math.max(0, Math.min(floatX, screenW - floatWidth))
  readonly property real floatTop: floatY < 0 ? screenH - floatHeight - 80 : Math.max(0, Math.min(floatY, screenH - floatHeight - handleHeight))
  readonly property real handleHeight: 22

  PanelWindow {
    id: floater
    screen: root.screen
    visible: root.shown && root.floating
    anchors { left: true; top: true }
    margins { left: root.floatLeft; top: root.floatTop }
    implicitWidth: root.floatWidth
    implicitHeight: root.floatHeight + root.handleHeight
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-onscreen-keyboard"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.popups.background
      border.width: 2
      border.color: Commons.Color.accent
    }

    // Drag handle. The window moves under the finger, so the press point stays
    // put in window coordinates: each move adds its offset from that point.
    Item {
      id: handle
      anchors { left: parent.left; right: parent.right; top: parent.top }
      height: root.handleHeight

      Rectangle {
        anchors.centerIn: parent
        width: 48
        height: 4
        color: Qt.alpha(Commons.Color.popups.text, 0.4)
      }

      MouseArea {
        anchors.fill: parent
        property real pressX: 0
        property real pressY: 0
        onPressed: function(m) {
          pressX = m.x; pressY = m.y
          root.floatX = root.floatLeft; root.floatY = root.floatTop
        }
        onPositionChanged: function(m) {
          root.floatX = Math.max(0, Math.min(root.floatX + m.x - pressX, root.screenW - root.floatWidth))
          root.floatY = Math.max(0, Math.min(root.floatY + m.y - pressY, root.screenH - root.floatHeight - root.handleHeight))
        }
        onReleased: root.saveState()
        // Double tap the handle to dock again.
        onDoubleClicked: root.setFloating(false)
      }
    }

    Keyboard {
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom; top: handle.bottom; margins: 2; topMargin: 0 }
      service: root
      compact: true
    }

    // Spread two fingers to dock it again; pinch further to shrink.
    PinchHandler {
      target: null
      onActiveChanged: if (!active) {
        if (activeScale > 1.3) root.setFloating(false)
        else if (activeScale < 0.9 || activeScale > 1.05) { root.floatWidth = Math.max(320, Math.min(root.floatWidth * activeScale, root.screenW * 0.7)); root.saveState() }
      }
    }
  }
}
