# On-Screen Keyboard for Omarchy

A touch keyboard drawn by Omarchy's own shell, in your theme's colors and font.
On a tablet or detachable it pops up when a text field is focused while the
keyboard is detached. Pinch it like the iPad's keyboard: from full width to a
narrower docked keyboard, to a small floating keyboard you can drag anywhere,
to just a floating dictation button.

![On-screen keyboard docked](preview.png)

- **Pops up on text fields** while in tablet mode, and hides again when the
  field loses focus or the keyboard is reattached.
- **Four layouts.** Full width, narrow (docked, centred), floating, and a
  floating mic button. Pinch in to step down, spread to step back up, or tap
  the layout key (󰘖) to cycle. Drag the floating keyboard by its handle;
  double-tap the handle to dock it. The mic button drags anywhere; hold it to
  bring the keyboard back.
- **Dictation key** for [voxtype](https://github.com/peteonrails/voxtype), which
  Omarchy sets up with `omarchy-voxtype-install`: tap to start, tap to stop.
  voxtype transcribes locally with a Whisper model (`omarchy-voxtype-model`
  picks it; settings in `~/.config/voxtype/config.toml`) and types the text.
  The key only appears when voxtype is installed or another dictation command
  is set (see Options).
- **A digit pad** for PIN, phone and number fields.
- **Esc, Tab, Ctrl, Alt and arrows** on an extra row for terminals.
- **Bar button** to show or hide the keyboard. It appears only while the
  keyboard is detached (or the on-screen keyboard is open).
- Follows theme and font changes live.

## Install

```bash
sudo pacman -S --needed python-pywayland
omarchy plugin add https://github.com/yeutterg/omarchy-on-screen-keyboard --enable
```

To put the show/hide button in the bar:

```bash
omarchy bar put io.github.yeutterg.onscreen-keyboard --section right
```

### Make it the only input method

Only one program can be the Wayland input method, and Omarchy starts fcitx5
for that role. While fcitx5 (or another keyboard like squeekboard) holds it,
this keyboard still works from the bar button but can't pop up on text fields;
the bar button's tooltip says so. To hand the role over, stop fcitx5 and keep
it from starting:

```bash
systemctl --user mask --now omarchy-fcitx5.service
```

Undo with `systemctl --user unmask omarchy-fcitx5.service` and a re-login. fcitx5
is what turns CapsLock compose sequences into text, so those stop working
while it's masked.

### Chromium and Electron apps

Chromium only tells the keyboard about text fields with Wayland IME enabled.
Add these two lines to `~/.config/chromium-flags.conf` and restart Chromium:

```
--enable-wayland-ime
--wayland-text-input-version=3
```

Electron apps take the same flags. You can still type into them without the
flags; the keyboard just won't pop up by itself.

## Options

Optional, in `~/.config/omarchy/onscreen-keyboard.json`; changes apply as soon
as the file is saved. Every key can be left out.

```json
{
  "dictationCommand": "voxtype record toggle",
  "autoShow": "tablet",
  "narrowWidth": 0.6,
  "extraRow": true
}
```

- `dictationCommand`: run (with `sh -c`) by the mic key; tap starts, the next
  tap runs it again. Default: voxtype's toggle.
- `autoShow`: pop up on text fields in `"tablet"` mode only (default),
  `"always"`, or `"never"` (bar button and commands only).
- `narrowWidth`: width of the narrow docked keyboard, as a fraction of the
  screen (0.3 to 0.95).
- `extraRow`: the esc/tab/ctrl/alt/arrows row on docked layouts.

## Remove

```bash
omarchy plugin remove io.github.yeutterg.onscreen-keyboard
```

It leaves nothing behind except its remembered position in
`~/.local/state/omarchy-onscreen-keyboard/`. If you masked fcitx5, unmask it
as shown above.

## How it works

- `Service.qml` draws the keyboard inside `omarchy-shell` as a layer-shell
  surface that never takes keyboard focus, so the app you're typing into keeps
  it. The floating keyboard and mic button sit in a full-screen overlay whose
  input region is only the visible card, so they drag anywhere and touches
  elsewhere reach the apps below.
- `helper/osk-helper.py` is a small Python program the service starts. It
  registers as the Wayland input method (`zwp_input_method_v2`) to learn when a
  text field is focused and what it wants (digits, text), and commits typed
  text into it. Keys like Backspace, Enter, arrows and Ctrl+C go through a
  virtual keyboard (`zwp_virtual_keyboard_v1`). It generates Python bindings
  for those protocols once per pywayland version into
  `$XDG_RUNTIME_DIR/omarchy-onscreen-keyboard/` (or `~/.cache/` without a
  runtime directory, never `/tmp`). Every directory on that path must be a
  real directory owned by you and closed to other users, or the helper refuses
  to start, so nobody else can plant code for it to import.
- Tablet mode comes from the kernel's tablet-mode switch: the service finds
  devices reporting `SW_TABLET_MODE` in `/proc/bus/input/devices` and adds
  Hyprland switch binds at runtime with `hyprctl eval`. Nothing in your
  Hyprland config is changed, and the binds are added again after a config
  reload. Devices without that switch get no automatic pop-up; use the bar
  button.
- The switch's current position can't be read without access to
  `/dev/input` (the `input` group), so the plugin assumes the keyboard is
  attached until the switch first changes. After logging in detached, attach
  and detach once, or run `omarchy-shell onscreen-keyboard setTabletMode true`.
- Layout and floating positions are saved to
  `~/.local/state/omarchy-onscreen-keyboard/state.json`.

### Commands

```bash
omarchy-shell onscreen-keyboard show|hide|toggle
omarchy-shell onscreen-keyboard float|dock|narrow|mic|cycle
omarchy-shell onscreen-keyboard status
omarchy-shell onscreen-keyboard setTabletMode true|false
```

`status` prints JSON including any problem the helper reported.

## Requirements

- Omarchy with the Quattro shell (Hyprland 0.56 or later)
- `python-pywayland`
- Optional: voxtype for dictation

## License

MIT. `helper/protocols/` holds the `input-method-unstable-v2` and
`virtual-keyboard-unstable-v1` protocol definitions from wlroots, under their
own MIT-style licenses (in each file).
