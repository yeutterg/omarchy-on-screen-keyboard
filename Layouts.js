.pragma library

// Each view is a list of rows; each key is { t: type, l: label, v: value, w: width }.
// Widths are in key units (a letter key is 1). Types:
//   char   types v (or l), shifted when shift is on
//   key    presses the keysym v (BackSpace, Return, Left, ...)
//   mod    latches a modifier v (ctrl, alt) for the next key
//   shift  one tap: next letter upper case; double tap: caps lock
//   view   switches to view v
//   space, mic, hide  special actions
//   layout cycles full width -> narrow -> floating -> mic button
//   gap    empty space of width w

function c(chars) {
  return chars.split(" ").map(function(ch) { return { t: "char", l: ch } })
}

// Ten units wide, like the letter rows.
var extraRow = [
  { t: "key", l: "esc", v: "Escape", w: 1.25 },
  { t: "key", l: "tab", v: "Tab", w: 1.25 },
  { t: "mod", l: "ctrl", v: "ctrl", w: 1.25 },
  { t: "mod", l: "alt", v: "alt", w: 1.25 },
  { t: "key", l: "←", v: "Left", w: 1.25 },
  { t: "key", l: "↓", v: "Down", w: 1.25 },
  { t: "key", l: "↑", v: "Up", w: 1.25 },
  { t: "key", l: "→", v: "Right", w: 1.25 },
]

function bottomRow(viewKey, viewLabel) {
  return [
    { t: "view", l: viewLabel, v: viewKey, w: 1.25 },
    { t: "hide", l: "󰌐", w: 1 },
    { t: "layout", l: "󰘖", w: 1 },
    { t: "mic", l: "󰍬", w: 1 },
    { t: "space", l: "", w: 3.5 },
    { t: "char", l: ".", w: 1 },
    { t: "key", l: "󰌑", v: "Return", w: 1.25 },
  ]
}

var backspace = { t: "key", l: "󰁮", v: "BackSpace", w: 1.5, repeat: true }

var views = {
  letters: [
    c("q w e r t y u i o p"),
    [{ t: "gap", w: 0.5 }].concat(c("a s d f g h j k l"), [{ t: "gap", w: 0.5 }]),
    [{ t: "shift", l: "󰘲", w: 1.5 }].concat(c("z x c v b n m"), [backspace]),
    bottomRow("numbers", "123"),
  ],
  numbers: [
    c("1 2 3 4 5 6 7 8 9 0"),
    c("- / : ; ( ) $ & @ \""),
    [{ t: "view", l: "#+=", v: "symbols", w: 1.5 }].concat(c(", ? ! ' * _ %"), [backspace]),
    bottomRow("letters", "ABC"),
  ],
  symbols: [
    c("[ ] { } # % ^ * + ="),
    c("_ \\ | ~ < > € £ ¥ •"),
    [{ t: "view", l: "123", v: "numbers", w: 1.5 }].concat(c("` , ? ! ' \" °"), [backspace]),
    bottomRow("letters", "ABC"),
  ],
  // For fields that ask for digits (PINs, phone numbers, numeric inputs).
  digits: [
    c("1 2 3"),
    c("4 5 6"),
    c("7 8 9"),
    [{ t: "view", l: "ABC", v: "letters" }, { t: "char", l: "0" }, backspace],
    [{ t: "hide", l: "󰌐" }, { t: "char", l: "." }, { t: "key", l: "󰌑", v: "Return" }],
  ],
}

// text-input-v3 content purposes that want the digit pad.
var digitPurposes = [2, 3, 4, 9]  // digits, number, phone, pin
