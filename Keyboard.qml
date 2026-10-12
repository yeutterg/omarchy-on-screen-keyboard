import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "Layouts.js" as Layouts

// The keys. Sends everything through `service` (Service.qml), which owns the
// helper process and the keyboard's visibility.
Item {
  id: root

  required property var service
  property bool compact: false        // floating: no extra row, smaller text
  property string view: "letters"
  property bool shift: false
  property bool capsLock: false
  property var mods: ({})             // latched ctrl / alt for the next key

  readonly property var rows: {
    var base = Layouts.views[view] || Layouts.views.letters
    return (!compact && view !== "digits") ? [Layouts.extraRow].concat(base) : base
  }
  readonly property real gap: compact ? 4 : 6
  // A key of width w spans w units plus the w-1 gaps it covers, so a row of
  // U units is U * unit + (U - 1) * gap wide. Size the widest row to fit.
  readonly property real unit: {
    var widest = 1
    for (var i = 0; i < rows.length; i++) widest = Math.max(widest, rowUnits(rows[i]))
    return (width - gap * 2 - gap * (widest - 1)) / widest
  }
  readonly property real rowHeight: (height - gap * (rows.length + 1)) / rows.length

  readonly property color surface: Commons.Color.popups.background
  readonly property color text: Commons.Color.popups.text
  readonly property color accent: Commons.Color.accent
  readonly property color keyFill: Qt.alpha(text, 0.07)
  readonly property color modFill: Qt.alpha(text, 0.03)
  readonly property color keyBorder: Qt.alpha(text, 0.15)

  function rowUnits(row) {
    var units = 0
    for (var i = 0; i < row.length; i++) units += row[i].w || 1
    return units
  }

  // Follow the focused field: digits for PIN and number fields.
  Connections {
    target: root.service
    function onPurposeChanged() { root.view = Layouts.digitPurposes.indexOf(root.service.purpose) >= 0 ? "digits" : "letters" }
    function onShownChanged() { if (!root.service.shown) { root.shift = false; root.mods = ({}) } }
  }

  function modList() {
    var list = []
    for (var m in mods) if (mods[m]) list.push(m)
    return list
  }

  function activate(key) {
    var latched = modList()
    switch (key.t) {
    case "char":
      var ch = key.v || key.l
      if (latched.length) {
        service.sendKey("U" + ch.toLowerCase().charCodeAt(0).toString(16).toUpperCase().padStart(4, "0"), latched)
      } else {
        service.sendText((shift || capsLock) ? ch.toUpperCase() : ch)
      }
      break
    case "space":
      latched.length ? service.sendKey("space", latched) : service.sendText(" ")
      break
    case "key":
      service.sendKey(key.v, latched)
      break
    case "mod":
      var next = Object.assign({}, mods)
      next[key.v] = !next[key.v]
      mods = next
      return
    case "shift":
      if (capsLock) { capsLock = false; shift = false }
      else if (shift && shiftTimer.running) { capsLock = true; shift = false }
      else { shift = !shift; shiftTimer.restart() }
      return
    case "view":
      view = key.v
      return
    case "hide":
      service.hide()
      return
    case "mic":
      service.dictate()
      return
    }
    if (shift && !capsLock) shift = false
    if (latched.length) mods = ({})
  }

  // Two shift taps within this window lock caps.
  Timer { id: shiftTimer; interval: 350 }

  Rectangle {
    anchors.fill: parent
    color: root.surface
  }

  Column {
    anchors.fill: parent
    anchors.margins: root.gap
    spacing: root.gap

    Repeater {
      model: root.rows

      Row {
        id: row
        required property var modelData
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: root.gap
        height: root.rowHeight

        Repeater {
          model: row.modelData

          Item {
            id: keyItem
            required property var modelData
            readonly property var key: modelData
            readonly property bool isGap: key.t === "gap"
            readonly property bool isMod: ["key", "mod", "shift", "view", "hide", "mic"].indexOf(key.t) >= 0 && key.v !== "Return"
            readonly property bool lit: (key.t === "shift" && (root.shift || root.capsLock))
              || (key.t === "mod" && root.mods[key.v] === true)
              || (key.t === "mic" && root.service.dictating)
            readonly property string label: key.t === "char" && (root.shift || root.capsLock) ? key.l.toUpperCase() : (key.l || "")

            width: root.unit * (key.w || 1) + root.gap * ((key.w || 1) - 1)
            height: row.height
            visible: key.t !== "mic" || root.service.dictationAvailable

            Rectangle {
              anchors.fill: parent
              visible: !keyItem.isGap
              color: area.pressed ? root.accent
                : keyItem.lit ? (keyItem.key.t === "mic" ? Commons.Color.urgent : Qt.alpha(root.accent, 0.25))
                : keyItem.isMod ? root.modFill : root.keyFill
              border.width: 1
              border.color: keyItem.key.v === "Return" ? Qt.alpha(root.accent, 0.6)
                : keyItem.lit && !area.pressed ? root.accent : root.keyBorder

              Text {
                anchors.centerIn: parent
                text: keyItem.label
                textFormat: Text.PlainText
                color: area.pressed ? root.surface
                  : keyItem.key.v === "Return" ? root.accent
                  : keyItem.isMod && !keyItem.lit ? Qt.alpha(root.text, 0.6) : root.text
                font.family: Style.font.family
                font.pixelSize: Math.round(Math.min(keyItem.height * (keyItem.key.t === "char" ? 0.42 : 0.34),
                                                    keyItem.width * 0.42) * (root.compact ? 0.9 : 1))
                font.capitalization: keyItem.key.t === "char" || keyItem.key.t === "view" ? Font.MixedCase : Font.AllLowercase
              }
            }

            MouseArea {
              id: area
              anchors.fill: parent
              enabled: !keyItem.isGap
              onPressed: { held = false; if (keyItem.key.repeat) repeatDelay.restart() }
              onReleased: {
                var repeated = repeatTimer.running
                repeatDelay.stop()
                repeatTimer.stop()
                if (containsMouse && !repeated && !held) root.activate(keyItem.key)
              }
              onCanceled: { repeatDelay.stop(); repeatTimer.stop() }
              // Long-press the hide key to float or dock the keyboard.
              onPressAndHold: if (keyItem.key.t === "hide") {
                held = true
                root.service.setFloating(!root.service.floating)
              }
              property bool held: false

              // Held backspace repeats, after a pause, like a hardware key.
              Timer {
                id: repeatDelay
                interval: 400
                onTriggered: { root.activate(keyItem.key); repeatTimer.start() }
              }
              Timer {
                id: repeatTimer
                interval: 60
                repeat: true
                onTriggered: root.activate(keyItem.key)
              }
            }
          }
        }
      }
    }
  }
}
