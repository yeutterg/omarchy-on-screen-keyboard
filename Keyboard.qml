import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "Layouts.js" as Layouts
import "Swipe.js" as Swipe

// The keys. Sends everything through `service` (Service.qml), which owns the
// helper process and the keyboard's visibility.
Item {
  id: root

  required property var service
  property bool compact: false        // floating: no extra row, smaller text
  property bool extraRow: true        // esc/tab/ctrl/alt/arrows row when docked
  property string view: "letters"
  property bool shift: false
  property bool capsLock: false
  property var mods: ({})             // latched ctrl / alt for the next key

  readonly property var rows: {
    var base = (Layouts.views[view] || Layouts.views.letters).map(function(row) { return withLayoutKeys(row) })
    return (extraRow && !compact && view !== "digits") ? [Layouts.extraRow].concat(base) : base
  }
  // Shrink and grow keys only where the layout can step that way (full width
  // can't grow); a dropped key's width goes to the space bar.
  function withLayoutKeys(row) {
    var spare = 0
    var kept = row.filter(function(k) {
      var drop = (k.t === "shrink" && !service.canShrink) || (k.t === "grow" && !service.canGrow)
      if (drop) spare += k.w || 1
      return !drop
    })
    if (!spare) return row
    return kept.map(function(k) {
      return k.t === "space" ? Object.assign({}, k, { w: (k.w || 1) + spare }) : k
    })
  }
  readonly property real gap: compact ? 4 : 6
  // A key of width w spans w units plus the w-1 gaps it covers, so a row of
  // U units is U * unit + (U - 1) * gap wide. Size the widest row to fit.
  readonly property real unit: {
    var widest = 1
    for (var i = 0; i < rows.length; i++) widest = Math.max(widest, rowUnits(rows[i]))
    return (width - gap * 2 - gap * (widest - 1)) / widest
  }
  readonly property real rowHeight: (height - stripHeight - gap * (rows.length + 1)) / rows.length

  // ---- swipe typing --------------------------------------------------------
  // Slide one finger from letter to letter; on lift the path is matched
  // against the word list (Swipe.js) and the best word is typed, with a space
  // before it unless one was just typed. The strip above the keys offers the
  // next best words; tapping one replaces the word.
  readonly property bool swipeOn: service.swipeReady && view === "letters"
  readonly property real stripHeight: service.swipeReady ? Math.round(Math.max(24, height * 0.11)) : 0
  property var suggestions: []
  property string swipedWord: ""      // the last swiped word, as typed
  property bool afterSpace: true      // last thing typed ends a word
  property var trail: []

  function isLetterKey(item) { return !!item && item.key.t === "char" && /^[a-z]$/i.test(item.key.l) }

  function letterCenters() {
    var centers = {}
    for (var r = 0; r < keys.children.length; r++) {
      var row = keys.children[r]
      for (var k = 0; k < row.children.length; k++) {
        var item = row.children[k]
        if (item.isKey && isLetterKey(item)) {
          var c = item.mapToItem(root, item.width / 2, item.height / 2)
          centers[item.key.l.toLowerCase()] = { x: c.x, y: c.y }
        }
      }
    }
    return centers
  }

  function cased(word) {
    if (capsLock) return word.toUpperCase()
    if (shift) return word[0].toUpperCase() + word.slice(1)
    return word
  }

  function finishSwipe(path) {
    trail = []
    var words = Swipe.decode(path, letterCenters(), unit + gap, rowHeight + gap, 3)
    if (!words.length) return
    words = words.map(cased)
    var text = (afterSpace ? "" : " ") + words[0]
    service.sendText(text)
    swipedWord = words[0]
    suggestions = words
    afterSpace = false
    if (shift && !capsLock) shift = false
  }

  function replaceSwiped(word) {
    if (!swipedWord || word === swipedWord) return
    for (var i = 0; i < swipedWord.length; i++) service.sendKey("BackSpace", [])
    service.sendText(word)
    swipedWord = word
  }

  Connections {
    target: root.service
    function onImActiveChanged() { root.afterSpace = true; root.suggestions = []; root.swipedWord = "" }
  }

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
    if (["char", "space", "key"].indexOf(key.t) >= 0) {
      afterSpace = key.t === "space" || key.v === "Return" || key.v === "Tab"
      suggestions = []
      swipedWord = ""
    }
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
    case "shrink":
      service.shrinkLayout()
      return
    case "grow":
      service.growLayout()
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

  // Suggestions after a swipe: the typed word in the middle, alternatives on
  // either side. Taps are handled by the touch controller below.
  Row {
    id: strip
    visible: root.stripHeight > 0
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: root.gap; bottomMargin: 0 }
    height: root.stripHeight - root.gap

    Repeater {
      model: 3
      Item {
        required property int index
        // Show order: alternative, chosen word, alternative.
        readonly property string word: {
          var s = root.suggestions
          var order = [1, 0, 2]
          return s.length > order[index] ? s[order[index]] : ""
        }
        readonly property bool isStripCell: true
        width: strip.width / 3
        height: strip.height

        Text {
          anchors.centerIn: parent
          width: parent.width - 8
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
          text: parent.word
          textFormat: Text.PlainText
          color: parent.word === root.swipedWord ? root.accent : root.text
          font.family: Style.font.family
          font.pixelSize: Math.round(strip.height * 0.5)
        }
        Rectangle {
          visible: index < 2
          anchors { right: parent.right; verticalCenter: parent.verticalCenter }
          width: 1
          height: parent.height * 0.5
          color: root.keyBorder
        }
      }
    }
  }

  Column {
    id: keys
    anchors.fill: parent
    anchors.margins: root.gap
    anchors.topMargin: root.gap + root.stripHeight
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
            readonly property bool isKey: true
            readonly property bool isGap: key.t === "gap"
            property bool down: false
            readonly property bool isMod: ["key", "mod", "shift", "view", "hide", "mic", "shrink", "grow"].indexOf(key.t) >= 0 && key.v !== "Return"
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
              color: keyItem.down ? root.accent
                : keyItem.lit ? (keyItem.key.t === "mic" ? Commons.Color.urgent : Qt.alpha(root.accent, 0.25))
                : keyItem.isMod ? root.modFill : root.keyFill
              border.width: 1
              border.color: keyItem.key.v === "Return" ? Qt.alpha(root.accent, 0.6)
                : keyItem.lit && !keyItem.down ? root.accent : root.keyBorder

              Text {
                anchors.centerIn: parent
                text: keyItem.label
                textFormat: Text.PlainText
                color: keyItem.down ? root.surface
                  : keyItem.key.v === "Return" ? root.accent
                  : keyItem.isMod && !keyItem.lit ? Qt.alpha(root.text, 0.6) : root.text
                font.family: Style.font.family
                font.pixelSize: Math.round(Math.min(keyItem.height * (keyItem.key.t === "char" ? 0.42 : 0.34),
                                                    keyItem.width * 0.42) * (root.compact ? 0.9 : 1))
                font.capitalization: keyItem.key.t === "char" || keyItem.key.t === "view" ? Font.MixedCase : Font.AllLowercase
              }
            }

          }
        }
      }
    }
  }

  // ---- touch -------------------------------------------------------------
  // One controller sees every finger, so keys and pinch don't fight over the
  // first touch. Each finger types the key under it when it lifts (fast
  // typists can overlap presses). Two fingers that spread or close by more
  // than 15% are a pinch instead: no key is typed, and the service steps the
  // keyboard between full width, narrow and floating.

  signal pinched(real scale)

  function keyAt(x, y) {
    var p = root.mapToItem(keys, x, y)
    var row = keys.childAt(p.x, p.y)
    if (!row) return null
    var q = keys.mapToItem(row, p.x, p.y)
    var key = row.childAt(q.x, q.y)
    return key && key.isKey && !key.isGap && key.visible ? key : null
  }

  Canvas {
    id: trailCanvas
    anchors.fill: parent
    property var points: root.trail
    onPointsChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (points.length < 2) return
      ctx.strokeStyle = Qt.alpha(root.accent, 0.55)
      ctx.lineWidth = Math.max(4, root.unit * 0.12)
      ctx.lineCap = "round"
      ctx.lineJoin = "round"
      ctx.beginPath()
      ctx.moveTo(points[0].x, points[0].y)
      for (var i = 1; i < points.length; i++) ctx.lineTo(points[i].x, points[i].y)
      ctx.stroke()
    }
  }

  function stripWordAt(x, y) {
    if (!strip.visible) return ""
    var p = root.mapToItem(strip, x, y)
    var cell = strip.childAt(p.x, p.y)
    return cell && cell.isStripCell ? cell.word : ""
  }

  MultiPointTouchArea {
    id: touch
    anchors.fill: parent
    mouseEnabled: true
    maximumTouchPoints: 2

    property var points: ({})        // pointId -> { x, y, key }
    property bool pinching: false
    property real startDistance: 0
    property real scale: 1
    property bool consumed: false    // the primary press already acted (repeat, hold)

    function ids() { return Object.keys(points) }
    function distance() {
      var list = ids()
      if (list.length < 2) return 0
      var a = points[list[0]], b = points[list[1]]
      return Math.hypot(a.x - b.x, a.y - b.y)
    }
    function setKey(state, key) {
      if (state.key === key) return
      if (state.key) state.key.down = false
      state.key = key
      if (key && !pinching) key.down = true
    }
    function stopTimers() { holdTimer.stop(); repeatDelay.stop(); repeatTimer.stop() }
    function primary() { var list = ids(); return list.length ? points[list[0]] : null }

    onPressed: function(touchPoints) {
      for (var i = 0; i < touchPoints.length; i++) {
        var tp = touchPoints[i]
        var state = { x: tp.x, y: tp.y, key: null, startX: tp.x, startY: tp.y,
                      path: [{ x: tp.x, y: tp.y }], swiping: false, startKey: null }
        points[tp.pointId] = state
        setKey(state, root.keyAt(tp.x, tp.y))
        state.startKey = state.key
      }
      if (ids().length === 1) {
        consumed = false
        var first = primary()
        holdTimer.restart()
        if (first.key && first.key.key.repeat) repeatDelay.restart()
      } else {
        stopTimers()
        startDistance = distance()
        scale = 1
      }
    }

    onUpdated: function(touchPoints) {
      for (var i = 0; i < touchPoints.length; i++) {
        var tp = touchPoints[i]
        var state = points[tp.pointId]
        if (!state) continue
        state.x = tp.x
        state.y = tp.y
        // One finger sliding from a letter onto another letter is a swipe.
        if (!pinching && !consumed && ids().length === 1 && root.swipeOn && root.isLetterKey(state.startKey)) {
          state.path.push({ x: tp.x, y: tp.y })
          if (!state.swiping) {
            var over = root.keyAt(tp.x, tp.y)
            var moved = Math.hypot(tp.x - state.startX, tp.y - state.startY)
            if (root.isLetterKey(over) && over !== state.startKey && moved > root.unit * 0.5) {
              state.swiping = true
              stopTimers()
              setKey(state, null)
            }
          }
          if (state.swiping) { root.trail = state.path.slice(); continue }
        }
        // Sliding onto another key types that one instead, as on a phone.
        if (!pinching && !consumed) setKey(state, root.keyAt(tp.x, tp.y))
      }
      if (ids().length >= 2 && startDistance > 0) {
        scale = distance() / startDistance
        if (!pinching && Math.abs(scale - 1) > 0.15) {
          pinching = true
          stopTimers()
          var list = ids()
          for (var j = 0; j < list.length; j++) setKey(points[list[j]], null)
        }
      }
    }

    onReleased: function(touchPoints) {
      for (var i = 0; i < touchPoints.length; i++) {
        var tp = touchPoints[i]
        var state = points[tp.pointId]
        if (!state) continue
        var key = state.key
        setKey(state, null)
        delete points[tp.pointId]
        if (state.swiping) { if (!pinching) root.finishSwipe(state.path); continue }
        if (!key && !pinching && !consumed) {
          var word = root.stripWordAt(tp.x, tp.y)
          if (word) root.replaceSwiped(word)
          continue
        }
        if (key && !pinching && !consumed) root.activate(key.key)
      }
      if (ids().length === 0) {
        if (pinching) root.pinched(scale)
        pinching = false
        consumed = false
        stopTimers()
      }
    }

    onCanceled: function() {
      var list = ids()
      for (var i = 0; i < list.length; i++) setKey(points[list[i]], null)
      points = ({})
      pinching = false
      root.trail = []
      stopTimers()
    }

    // Hold the hide key to float or dock.
    Timer {
      id: holdTimer
      interval: 500
      onTriggered: {
        var first = touch.primary()
        if (first && first.key && first.key.key.t === "hide") {
          touch.consumed = true
          first.key.down = false
          root.service.setFloating(!root.service.floating)
        }
      }
    }
    // Held backspace repeats, after a pause, like a hardware key.
    Timer {
      id: repeatDelay
      interval: 400
      onTriggered: {
        var first = touch.primary()
        if (!first || !first.key) return
        touch.consumed = true
        root.activate(first.key.key)
        repeatTimer.start()
      }
    }
    Timer {
      id: repeatTimer
      interval: 60
      repeat: true
      onTriggered: {
        var first = touch.primary()
        if (first && first.key) root.activate(first.key.key)
        else stop()
      }
    }
  }
}
