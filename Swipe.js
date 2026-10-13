.pragma library

// Swipe typing: turn a finger path over the letter keys into words.
//
// For each candidate word the ideal path runs through the centres of its
// letters (repeated letters count once). Both paths are resampled to the same
// number of points and compared point by point; closer shapes and more common
// words score better. Candidates must start near where the finger went down
// and end near where it lifted, and have a path length in the right range.
// Coordinates are in key units (one key width), so keyboard size doesn't
// matter.

var byFirst = null      // letter -> [{ w, f }]  (f: Zipf frequency, 3..8)
var loaded = false
var SAMPLES = 24

// text: "word count" per line (FrequencyWords). Counts become Zipf
// frequencies (log10 of uses per billion words), so the scoring is independent
// of the corpus size. Only plain a-z words are kept.
function load(text) {
  if (loaded) return
  byFirst = {}
  var lines = String(text || "").split("\n")
  var entries = [], total = 0
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^([a-z]+) (\d+)$/)
    if (!m || (m[1].length === 1 && m[1] !== "a" && m[1] !== "i")) continue
    var count = parseInt(m[2])
    entries.push({ w: m[1], count: count })
    total += count
  }
  for (var j = 0; j < entries.length; j++) {
    var w = entries[j].w
    var entry = { w: w, f: Math.log10(entries[j].count / total * 1e9) }
    if (!byFirst[w[0]]) byFirst[w[0]] = []
    byFirst[w[0]].push(entry)
  }
  loaded = entries.length > 0
}

function unload() { byFirst = null; loaded = false }

function dist(a, b) { return Math.hypot(a.x - b.x, a.y - b.y) }

function pathLength(points) {
  var total = 0
  for (var i = 1; i < points.length; i++) total += dist(points[i - 1], points[i])
  return total
}

function resample(points, n) {
  if (points.length === 1) {
    var single = []
    for (var k = 0; k < n; k++) single.push(points[0])
    return single
  }
  var total = pathLength(points)
  var step = total / (n - 1)
  var out = [points[0]]
  var carried = 0
  var prev = points[0]
  for (var i = 1; i < points.length && out.length < n; i++) {
    var cur = points[i]
    var seg = dist(prev, cur)
    while (seg > 0 && carried + seg >= step && out.length < n) {
      var t = (step - carried) / seg
      var p = { x: prev.x + t * (cur.x - prev.x), y: prev.y + t * (cur.y - prev.y) }
      out.push(p)
      prev = p
      seg = dist(prev, cur)
      carried = 0
    }
    carried += seg
    prev = cur
  }
  while (out.length < n) out.push(points[points.length - 1])
  return out
}

function idealPath(word, centers) {
  var pts = []
  var last = ""
  for (var i = 0; i < word.length; i++) {
    var ch = word[i]
    if (ch === last) continue
    var c = centers[ch]
    if (!c) return null
    pts.push(c)
    last = ch
  }
  return pts
}

function nearestLetters(point, centers, radius) {
  var found = []
  for (var ch in centers) {
    var d = dist(point, centers[ch])
    if (d <= radius) found.push({ ch: ch, d: d })
  }
  found.sort(function(a, b) { return a.d - b.d })
  return found.slice(0, 3).map(function(f) { return f.ch })
}

// path: [{x, y}] in pixels; centers: { letter: {x, y} } in pixels; pitchX and
// pitchY: distance between neighbouring keys across and down, in pixels.
// Returns up to `count` words, best first.
function decode(path, centers, pitchX, pitchY, count) {
  if (!loaded || path.length < 2 || pitchX <= 0 || pitchY <= 0) return []
  var scale = function(p) { return { x: p.x / pitchX, y: p.y / pitchY } }
  var p = path.map(scale)
  var c = {}
  for (var ch in centers) c[ch] = scale(centers[ch])

  var starts = nearestLetters(p[0], c, 0.9)
  var ends = nearestLetters(p[p.length - 1], c, 0.9)
  if (!starts.length || !ends.length) return []

  var swipe = resample(p, SAMPLES)
  var swipeLength = pathLength(p)
  var scored = []
  for (var s = 0; s < starts.length; s++) {
    var list = byFirst[starts[s]] || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      var w = entry.w
      if (w.length < 2 || ends.indexOf(w[w.length - 1]) < 0) continue
      var ideal = idealPath(w, c)
      if (!ideal || ideal.length < 2) continue
      var idealLength = pathLength(ideal)
      if (Math.abs(idealLength - swipeLength) > Math.max(1.5, idealLength * 0.6)) continue
      var sample = resample(ideal, SAMPLES)
      var total = 0
      for (var k = 0; k < SAMPLES; k++) total += dist(swipe[k], sample[k])
      var shape = total / SAMPLES
      scored.push({ w: w, score: shape + 0.12 * (7 - entry.f) })
    }
  }
  scored.sort(function(a, b) { return a.score - b.score })
  var words = []
  for (var j = 0; j < scored.length && words.length < (count || 3); j++)
    if (words.indexOf(scored[j].w) < 0) words.push(scored[j].w)
  return words
}
