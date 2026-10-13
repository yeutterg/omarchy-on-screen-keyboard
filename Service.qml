import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import "Swipe.js" as Swipe

// On-screen keyboard service: runs the Wayland helper, decides when the
// keyboard shows, and draws it docked along the bottom (full width or narrow)
// or floating. Pinch in steps full -> narrow -> floating; spread steps back.
//
// Options live in ~/.config/omarchy/onscreen-keyboard.json (read live):
//   { "dictationCommand": "voxtype record toggle",
//     "autoShow": "tablet" | "always" | "never",
//     "narrowWidth": 0.6, "extraRow": true,
//     "detachableDevice": "detachable touchpad",
//     "lockBarInTabletMode": true,
//     "swipe": true }
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
  // "full" | "narrow" | "floating" | "mic" (just a floating dictation button)
  property string layoutMode: "full"
  readonly property bool floating: layoutMode === "floating"
  readonly property bool narrow: layoutMode === "narrow"
  property real floatX: -1
  property real floatY: -1
  property real floatWidth: 440

  property bool voxtypeInstalled: false
  readonly property bool dictationAvailable: customDictation || voxtypeInstalled
  property bool dictating: false
  // Set by the bar widget once it has found the bar to lock in tablet mode.
  property bool barLockReady: false

  readonly property var screen: {
    var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (screens[i].name === name) return screens[i]
    return screens.length ? screens[0] : null
  }

  function show() { shown = true; autoShown = false; dismissed = false }
  function hide() { shown = false; if (imActive) dismissed = true }
  function toggle() { shown ? hide() : show() }
  function setFloating(on) { setLayoutMode(on ? "floating" : "full") }
  function setLayoutMode(mode) { layoutMode = mode; saveState() }

  // Pinch in: full -> narrow -> floating -> mic. Spread steps back. The mic
  // step only exists when dictation is available.
  readonly property var layoutSteps: dictationAvailable ? ["full", "narrow", "floating", "mic"] : ["full", "narrow", "floating"]
  readonly property bool micOnly: layoutMode === "mic"
  function cycleLayout() {
    var at = layoutSteps.indexOf(layoutMode)
    setLayoutMode(layoutSteps[(at + 1) % layoutSteps.length])
  }
  function pinch(scale) {
    var at = layoutSteps.indexOf(layoutMode)
    if (scale < 0.85 && at < layoutSteps.length - 1) setLayoutMode(layoutSteps[at + 1])
    else if (scale > 1.15 && at > 0) setLayoutMode(layoutSteps[at - 1])
  }

  // ---- options (text file) -------------------------------------------------

  readonly property string configFile: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy/onscreen-keyboard.json"
  property var options: ({})
  readonly property string dictationCommand: typeof options.dictationCommand === "string" && options.dictationCommand !== ""
    ? options.dictationCommand : "voxtype record toggle"
  readonly property bool customDictation: typeof options.dictationCommand === "string" && options.dictationCommand !== ""
  readonly property string autoShow: ["tablet", "always", "never"].indexOf(options.autoShow) >= 0 ? options.autoShow : "tablet"
  readonly property real narrowFraction: typeof options.narrowWidth === "number" ? Math.max(0.3, Math.min(options.narrowWidth, 0.95)) : 0.6
  readonly property bool extraRow: options.extraRow !== false

  // ---- swipe typing ----------------------------------------------------------
  // On by default. The word list is a download (see helper/osk-helper.py
  // --words), fetched when swipe is on and deleted when it's turned off.
  readonly property bool swipeEnabled: options.swipe !== false
  property bool swipeReady: false
  property bool optionsLoaded: false

  onSwipeEnabledChanged: if (optionsLoaded) syncWords()
  onOptionsLoadedChanged: if (optionsLoaded) syncWords()

  function syncWords() {
    swipeReady = false
    Swipe.unload()
    wordsProc.command = ["python3", root.pluginDir + "/helper/osk-helper.py", "--words", swipeEnabled ? "fetch" : "remove"]
    wordsProc.running = true
  }

  Process {
    id: wordsProc
    stdout: SplitParser {
      onRead: function(line) {
        if (line.indexOf("ready ") === 0) {
          var path = line.slice(6)
          // Same file as before (turned off and on again): reload it.
          if (wordsView.path === path) wordsView.reload()
          else wordsView.path = path
        }
        else if (line.indexOf("error ") === 0) console.warn("onscreen-keyboard:", line)
      }
    }
  }

  FileView {
    id: wordsView
    printErrors: false
    onLoaded: {
      Swipe.load(text())
      root.swipeReady = root.swipeEnabled && Swipe.loaded
    }
  }

  FileView {
    id: configView
    path: root.configFile
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.options = JSON.parse(text()) || ({}) }
      catch (e) { root.options = ({}); console.warn("onscreen-keyboard: bad JSON in", root.configFile) }
      root.optionsLoaded = true
    }
    onLoadFailed: { root.options = ({}); root.optionsLoaded = true }
  }

  onImActiveChanged: {
    if (imActive) {
      if (wantsAutoShow && !shown && !dismissed) { shown = true; autoShown = true }
    } else {
      if (autoShown) shown = false
      autoShown = false
      dismissed = false
    }
  }
  readonly property bool wantsAutoShow: autoShow === "always" || (autoShow === "tablet" && tabletMode)

  onTabletModeChanged: {
    if (!tabletMode) { shown = false; autoShown = false }
    else if (imActive && !dismissed) { shown = true; autoShown = true }
  }

  function sendText(text) { send("text " + text) }
  function sendKey(keysym, mods) { send("key " + keysym + (mods && mods.length ? " " + mods.join(",") : "")) }
  function send(line) { if (helper.running && helperReady) helper.write(line + "\n") }

  // Tap the mic to start dictating, tap again to stop (voxtype).
  // The command comes from the options file; voxtype by default.
  function dictate() {
    Quickshell.execDetached(["sh", "-c", dictationCommand])
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

  // ---- tablet mode -----------------------------------------------------------
  // Two sources, checked every few seconds from /proc/bus/input/devices:
  //  * Tablet-mode switches: any input device whose switch bitmap has
  //    SW_TABLET_MODE (bit 1). Their on/off events arrive through Hyprland
  //    binds added at runtime with hyprctl eval (no Hyprland config is
  //    edited), added again whenever Hyprland reloads its config. Some drivers
  //    (intel-hid) only create the switch device on its first change, so the
  //    list is rescanned and a switch that turns up later counts as that first
  //    change: detached.
  //  * Options "detachableDevice": a piece of the name of an input device that
  //    only exists while the keyboard is attached (its touchpad, say). When
  //    set, attached/detached follows that device and also works at login.

  property var tabletSwitches: []
  property bool scannedOnce: false
  readonly property string detachableDevice: typeof options.detachableDevice === "string" ? options.detachableDevice.toLowerCase() : ""

  Process {
    id: findSwitches
    command: ["cat", "/proc/bus/input/devices"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        var names = [], name = "", deviceNames = []
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var n = lines[i].match(/^N: Name="(.*)"$/)
          if (n) { name = n[1]; deviceNames.push(name.toLowerCase()) }
          var sw = lines[i].match(/^B: SW=(.*)$/)
          if (sw) {
            var words = sw[1].trim().split(/\s+/)
            var low = parseInt(words[words.length - 1], 16)
            if (Math.floor(low / 2) % 2 === 1) names.push(name)
          }
        }
        if (root.detachableDevice !== "") {
          var attached = deviceNames.some(function(d) { return d.indexOf(root.detachableDevice) >= 0 })
          if (root.tabletMode === attached) root.tabletMode = !attached
        }
        if (names.join("\n") !== root.tabletSwitches.join("\n")) {
          var appeared = root.scannedOnce && names.length > root.tabletSwitches.length
          root.tabletSwitches = names
          root.registerBinds()
          if (appeared && root.detachableDevice === "") root.tabletMode = true
        }
        root.scannedOnce = true
      }
    }
  }

  Timer {
    interval: 3000
    repeat: true
    running: true
    onTriggered: if (!findSwitches.running) findSwitches.running = true
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
    onExited: function(code) { root.voxtypeInstalled = code === 0 }
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
    running: root.dictating && root.shown && !root.customDictation
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
        root.layoutMode = ["full", "narrow", "floating", "mic"].indexOf(s.layoutMode) >= 0 ? s.layoutMode : (s.floating ? "floating" : "full")
        root.floatX = s.floatX ?? -1
        root.floatY = s.floatY ?? -1
        root.floatWidth = s.floatWidth ?? 440
        root.micX = s.micX ?? -1
        root.micY = s.micY ?? -1
      } catch (e) {}
    }
  }

  function saveState() {
    mkState.running = true
    stateView.setText(JSON.stringify({ layoutMode: layoutMode, floatX: floatX, floatY: floatY, floatWidth: floatWidth, micX: micX, micY: micY }))
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
    function narrow(): string { root.setLayoutMode("narrow"); return "ok" }
    function mic(): string { root.setLayoutMode("mic"); return "ok" }
    function cycle(): string { root.cycleLayout(); return root.layoutMode }
    function setTabletMode(on: string): string { root.tabletMode = on === "true" || on === "1"; return "ok" }
    function status(): string {
      return JSON.stringify({ shown: root.shown, layout: root.layoutMode, tabletMode: root.tabletMode,
                              textField: root.imActive, purpose: root.purpose, helper: root.helperReady,
                              switches: root.tabletSwitches, barLock: root.barLockReady, swipe: root.swipeReady, problem: root.problem })
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
    visible: root.shown && !root.floating && !root.micOnly
    // Narrow: only the bottom edge is anchored, so the compositor centres it.
    anchors { left: !root.narrow; right: !root.narrow; bottom: true }
    implicitWidth: root.narrow ? Math.round(root.screenW * root.narrowFraction) : root.screenW
    implicitHeight: root.narrow ? Math.round(root.dockHeight * 0.85) : root.dockHeight
    color: "transparent"
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: implicitHeight
    WlrLayershell.namespace: "omarchy-onscreen-keyboard"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    Keyboard {
      id: dockKeys
      anchors.fill: parent
      service: root
      extraRow: root.extraRow
      onPinched: function(scale) { root.pinch(scale) }
    }

    Rectangle {
      anchors { left: parent.left; right: parent.right; top: parent.top }
      height: 2
      color: Commons.Color.accent
    }

    // Narrow: accent edges on the sides too, so it reads as a card.
    Rectangle {
      visible: root.narrow
      anchors.fill: parent
      color: "transparent"
      border.width: 2
      border.color: Commons.Color.accent
    }
  }

  // Floating keyboard and mic button. Both live in one full-screen overlay
  // whose input region is only the visible card, so touches elsewhere reach
  // the apps below. Dragging moves the card inside this window rather than
  // moving a window under the finger, which races the compositor and made the
  // card jump to the screen edges.
  readonly property real floatHeight: Math.round(floatWidth * 0.62)
  readonly property real handleHeight: 22
  readonly property real floatLeft: floatX < 0 ? (screenW - floatWidth) / 2 : Math.max(0, Math.min(floatX, screenW - floatWidth))
  readonly property real floatTop: floatY < 0 ? screenH - floatHeight - handleHeight - 80 : Math.max(0, Math.min(floatY, screenH - floatHeight - handleHeight))

  property real micX: -1
  property real micY: -1
  readonly property real micSize: 56
  readonly property real micLeft: micX < 0 ? screenW - micSize - 24 : Math.max(0, Math.min(micX, screenW - micSize))
  readonly property real micTop: micY < 0 ? screenH - micSize - 96 : Math.max(0, Math.min(micY, screenH - micSize))

  PanelWindow {
    id: overlay
    screen: root.screen
    visible: root.shown && (root.floating || root.micOnly)
    anchors { left: true; right: true; top: true; bottom: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-onscreen-keyboard"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region { item: root.micOnly ? micCard : card }

    Item {
      id: space
      anchors.fill: parent

      // ---- floating keyboard ----
      Rectangle {
        id: card
        visible: root.floating
        x: root.floatLeft
        y: root.floatTop
        width: root.floatWidth
        height: root.floatHeight + root.handleHeight
        color: Commons.Color.popups.background
        border.width: 2
        border.color: Commons.Color.accent

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
            property real grabX: 0
            property real grabY: 0
            onPressed: function(m) {
              var p = mapToItem(space, m.x, m.y)
              grabX = p.x - root.floatLeft
              grabY = p.y - root.floatTop
            }
            onPositionChanged: function(m) {
              var p = mapToItem(space, m.x, m.y)
              root.floatX = Math.max(0, Math.min(p.x - grabX, root.screenW - root.floatWidth))
              root.floatY = Math.max(0, Math.min(p.y - grabY, root.screenH - root.floatHeight - root.handleHeight))
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
          onPinched: function(scale) { root.pinch(scale) }
        }
      }

      // ---- mic only: tap to dictate, drag to move, hold for the keyboard ----
      Rectangle {
        id: micCard
        visible: root.micOnly
        x: root.micLeft
        y: root.micTop
        width: root.micSize
        height: root.micSize
        color: micArea.pressed && !micArea.dragging ? Commons.Color.accent
          : root.dictating ? Commons.Color.urgent : Commons.Color.popups.background
        border.width: 2
        border.color: root.dictating ? Commons.Color.urgent : Commons.Color.accent

        Text {
          anchors.centerIn: parent
          text: "󰍬"
          color: micArea.pressed && !micArea.dragging || root.dictating ? Commons.Color.popups.background : Commons.Color.popups.text
          font.family: Style.font.family
          font.pixelSize: 26
        }

        MouseArea {
          id: micArea
          anchors.fill: parent
          property real grabX: 0
          property real grabY: 0
          property real startX: 0
          property real startY: 0
          property bool dragging: false
          property bool held: false
          pressAndHoldInterval: 500
          onPressed: function(m) {
            var p = mapToItem(space, m.x, m.y)
            grabX = p.x - root.micLeft; grabY = p.y - root.micTop
            startX = p.x; startY = p.y
            dragging = false; held = false
          }
          onPositionChanged: function(m) {
            var p = mapToItem(space, m.x, m.y)
            if (!dragging && Math.abs(p.x - startX) + Math.abs(p.y - startY) < 8) return
            dragging = true
            root.micX = Math.max(0, Math.min(p.x - grabX, root.screenW - root.micSize))
            root.micY = Math.max(0, Math.min(p.y - grabY, root.screenH - root.micSize))
          }
          onPressAndHold: if (!dragging) { held = true; root.setLayoutMode("floating") }
          onReleased: {
            if (dragging) root.saveState()
            else if (!held) root.dictate()
          }
        }
      }
    }
  }
}
