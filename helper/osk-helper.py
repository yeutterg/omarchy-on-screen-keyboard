#!/usr/bin/env python3
"""Wayland side of the Omarchy on-screen keyboard.

The keyboard is drawn by the plugin inside omarchy-shell. Quickshell can't
speak the input-method or virtual-keyboard protocols, so this helper does:

  * zwp_input_method_v2: hears when a text field gains or loses focus (and its
    content purpose, e.g. a PIN field).
  * zwp_virtual_keyboard_v1: types everything as real key presses: text,
    Backspace, Enter, arrows, Ctrl+C, ...

Commands, one per line on stdin:
  text <utf-8 text>            type text
  key <keysym> [mod,mod...]    press and release a key; mods: shift ctrl alt super
  quit

Events, one per line on stdout:
  ready                        connected and registered
  im 1|0                       a text field is focused / no longer focused
  purpose <n>                  text-input-v3 content purpose of the focused field
  unavailable                  another input method is running (fcitx5, squeekboard...)
  error <message>
"""

import os
import select
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent

MODS = {"shift": 1, "ctrl": 4, "alt": 8, "super": 64}
MOD_KEYSYMS = {"shift": "Shift_L", "ctrl": "Control_L", "alt": "Alt_L", "super": "Super_L"}
MOD_MAP = {"Shift": "Shift_L", "Control": "Control_L", "Mod1": "Alt_L", "Mod4": "Super_L"}

# Keys every keymap has, printable ASCII included so typing rarely changes the
# keymap; other characters are added on demand.
BASE_KEYSYMS = [
    "BackSpace", "Return", "Tab", "Escape", "Delete", "space",
    "Left", "Right", "Up", "Down", "Home", "End", "Prior", "Next", "Insert",
    *[f"F{n}" for n in range(1, 13)],
    *MOD_KEYSYMS.values(),
    *[f"U{c:04X}" for c in range(0x21, 0x7F)],
]


def emit(*parts):
    print(" ".join(str(p) for p in parts), flush=True)


def owned_dir(path, create=False, strict=True):
    """Return path if it's a real directory owned by us and not writable by
    others (with strict, not readable either); create it 0700 if asked.
    Anything else (a symlink, another user's directory) is refused."""
    if create:
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode):
        raise RuntimeError(f"{path} is not a directory (or is a symlink)")
    if info.st_uid != os.getuid():
        raise RuntimeError(f"{path} is owned by another user")
    if info.st_mode & (0o077 if strict else 0o022):
        raise RuntimeError(f"{path} is accessible to other users")
    return path


def cache_base():
    """An owner-only base directory: $XDG_RUNTIME_DIR, else the user's cache
    directory. Never a shared directory like /tmp; with neither, fail closed."""
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        return owned_dir(runtime)
    home = os.path.expanduser("~")
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.join(home, ".cache")
    if not os.path.isabs(cache):
        raise RuntimeError("no safe cache directory (XDG_RUNTIME_DIR unset, XDG_CACHE_HOME not absolute)")
    owned_dir(home, strict=False)
    return owned_dir(cache, create=True, strict=False)


def protocol_modules():
    """Generate pywayland bindings for the vendored protocols (cached per version)."""
    import pywayland
    from pywayland import scanner  # noqa: F401  (fails early if missing)

    # The generated modules import each other relatively, so they live in a
    # package (osk_protocols) under a per-version directory. Every directory
    # down to it is checked to be ours alone before anything is imported.
    top = owned_dir(os.path.join(cache_base(), "omarchy-onscreen-keyboard"), create=True)
    root = os.path.join(top, f"protocols-{pywayland.__version__}")
    if not os.path.lexists(root):
        # Generate into a private temporary directory, then rename it into
        # place, so a half-written cache is never used.
        work = tempfile.mkdtemp(prefix=".generate-", dir=top)
        out = os.path.join(work, "osk_protocols")
        os.mkdir(out, 0o700)
        open(os.path.join(out, "__init__.py"), "w").close()
        xmls = [
            "/usr/share/wayland/wayland.xml",
            "/usr/share/wayland-protocols/unstable/text-input/text-input-unstable-v3.xml",
            str(HERE / "protocols" / "input-method-unstable-v2.xml"),
            str(HERE / "protocols" / "virtual-keyboard-unstable-v1.xml"),
        ]
        subprocess.run(
            [sys.executable, "-m", "pywayland.scanner", "-o", out, "-i", *xmls],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            os.rename(work, root)
        except OSError:
            shutil.rmtree(work, ignore_errors=True)  # another helper got there first
    owned_dir(root)
    owned_dir(os.path.join(root, "osk_protocols"))
    sys.path.insert(0, root)


class Keyboard:
    def __init__(self):
        from pywayland.client import Display

        protocol_modules()
        from osk_protocols.wayland import WlSeat
        from osk_protocols.input_method_unstable_v2 import ZwpInputMethodManagerV2
        from osk_protocols.virtual_keyboard_unstable_v1 import ZwpVirtualKeyboardManagerV1

        self.display = Display()
        self.display.connect()
        self.seat = self.im_manager = self.vk_manager = None

        def on_global(registry, name, interface, version):
            if interface == "wl_seat" and self.seat is None:
                self.seat = registry.bind(name, WlSeat, 1)
            elif interface == "zwp_input_method_manager_v2":
                self.im_manager = registry.bind(name, ZwpInputMethodManagerV2, 1)
            elif interface == "zwp_virtual_keyboard_manager_v1":
                self.vk_manager = registry.bind(name, ZwpVirtualKeyboardManagerV1, 1)

        registry = self.display.get_registry()
        registry.dispatcher["global"] = on_global
        self.display.roundtrip()

        if not self.seat or not self.vk_manager:
            raise RuntimeError("compositor lacks wl_seat or zwp_virtual_keyboard_manager_v1")

        self.vk = self.vk_manager.create_virtual_keyboard(self.seat)
        self.keysyms = list(BASE_KEYSYMS)
        self.upload_keymap()

        # Input method state is double-buffered: events set pending values,
        # `done` applies them. It only tells the keyboard when to pop up.
        self.im = None
        self.active = False
        self.pending_active = False
        self.purpose = 0
        self.pending_purpose = 0
        if self.im_manager:
            self.im = self.im_manager.get_input_method(self.seat)
            d = self.im.dispatcher
            d["activate"] = lambda *_: self._set_pending(True)
            d["deactivate"] = lambda *_: self._set_pending(False)
            d["content_type"] = self._on_content_type
            d["done"] = self._on_done
            d["unavailable"] = lambda *_: emit("unavailable")
        else:
            emit("error", "compositor lacks zwp_input_method_manager_v2; no auto-show")

        self.display.roundtrip()

    # -- input method --------------------------------------------------------

    def _set_pending(self, active):
        self.pending_active = active
        if active:
            self.pending_purpose = 0

    def _on_content_type(self, _im, _hint, purpose):
        self.pending_purpose = purpose

    def _on_done(self, *_):
        if self.pending_purpose != self.purpose:
            self.purpose = self.pending_purpose
            emit("purpose", self.purpose)
        if self.pending_active != self.active:
            self.active = self.pending_active
            emit("im", 1 if self.active else 0)

    # -- virtual keyboard ----------------------------------------------------

    def upload_keymap(self):
        """A keymap with one keysym per keycode, like wtype builds."""
        codes = "\n".join(f"<K{i}> = {i + 8};" for i in range(len(self.keysyms)))
        symbols = "\n".join(f"key <K{i}> {{[ {ks} ]}};" for i, ks in enumerate(self.keysyms))
        modmap = "\n".join(
            f"modifier_map {mod} {{ <K{self.keysyms.index(ks)}> }};" for mod, ks in MOD_MAP.items()
        )
        keymap = (
            "xkb_keymap {\n"
            f'xkb_keycodes "osk" {{ minimum = 8; maximum = {max(255, len(self.keysyms) + 8)};\n{codes}\n}};\n'
            'xkb_types "osk" { include "complete" };\n'
            'xkb_compat "osk" { include "complete" };\n'
            f'xkb_symbols "osk" {{\n{symbols}\n{modmap}\n}};\n'
            "};\n"
        ).encode() + b"\0"
        fd = os.memfd_create("osk-keymap")
        os.write(fd, keymap)
        os.lseek(fd, 0, os.SEEK_SET)
        self.vk.keymap(1, fd, len(keymap))  # 1 = WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1
        os.close(fd)

    def keycode(self, keysym):
        if keysym not in self.keysyms:
            self.keysyms.append(keysym)
            self.upload_keymap()
        return self.keysyms.index(keysym)

    def press(self, keysym, mods=()):
        mask = 0
        for mod in mods:
            mask |= MODS.get(mod, 0)
        code = self.keycode(keysym)
        now = int(time.monotonic() * 1000) & 0xFFFFFFFF
        if mask:
            self.vk.modifiers(mask, 0, 0, 0)
        self.vk.key(now, code, 1)
        self.vk.key(now, code, 0)
        if mask:
            self.vk.modifiers(0, 0, 0, 0)

    # -- commands ------------------------------------------------------------

    def type_text(self, text):
        # Always as key presses, never the input method's commit_string:
        # Chromium (text-input-v3) acknowledges commits but can drop the text,
        # while key presses reach every app, like wtype.
        for char in text:
            if char == "\n":
                self.press("Return")
            elif char == "\t":
                self.press("Tab")
            elif char == " ":
                self.press("space")
            else:
                self.press(f"U{ord(char):04X}")

    def handle(self, line):
        cmd, _, arg = line.partition(" ")
        if cmd == "text":
            self.type_text(arg)
        elif cmd == "key":
            keysym, _, mods = arg.partition(" ")
            self.press(keysym, [m for m in mods.split(",") if m])
        elif cmd == "quit":
            return False
        else:
            emit("error", f"unknown command {cmd!r}")
        return True

    def run(self):
        emit("ready")
        display_fd = self.display.get_fd()
        stdin_fd = sys.stdin.fileno()
        buffer = b""
        while True:
            self.display.dispatch(block=False)
            self.display.flush()
            readable, _, _ = select.select([display_fd, stdin_fd], [], [])
            if display_fd in readable:
                self.display.dispatch(block=True)
            if stdin_fd in readable:
                chunk = os.read(stdin_fd, 65536)
                if not chunk:
                    return
                buffer += chunk
                while b"\n" in buffer:
                    raw, buffer = buffer.split(b"\n", 1)
                    if not self.handle(raw.decode("utf-8", "replace")):
                        return
                self.display.flush()


# ---- swipe word list ----------------------------------------------------------
# Swipe typing needs English words ranked by frequency. Rather than ship one,
# the plugin downloads hermitdave/FrequencyWords' 50k English list (from
# OpenSubtitles 2018, CC BY-SA 4.0) from a pinned commit, checks its SHA-256
# and keeps it in ~/.local/share/omarchy-onscreen-keyboard/. Turning swipe
# off ("swipe": false) deletes it.

WORDS_URL = ("https://raw.githubusercontent.com/hermitdave/FrequencyWords/"
             "525f9b560de45753a5ea01069454e72e9aa541c6/content/2018/en/en_50k.txt")
WORDS_SHA256 = "5351ff405b1126ef555791dd4d9798a48e3e9a501a9fc481a9da957752cfb458"
WORDS_FILE = "words-en.txt"


def words_dir():
    home = os.path.expanduser("~")
    data = os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
    if not os.path.isabs(data):
        raise RuntimeError("XDG_DATA_HOME is not absolute")
    owned_dir(home, strict=False)
    owned_dir(data, create=True, strict=False)
    return owned_dir(os.path.join(data, "omarchy-onscreen-keyboard"), create=True)


def words(action):
    import hashlib
    import urllib.request

    target = os.path.join(words_dir(), WORDS_FILE)
    if action == "remove":
        if os.path.lexists(target):
            os.remove(target)
        emit("removed")
        return
    if os.path.lexists(target):
        if not stat.S_ISREG(os.lstat(target).st_mode):
            raise RuntimeError(f"{target} is not a regular file")
        emit("ready", target)
        return
    with urllib.request.urlopen(WORDS_URL, timeout=30) as response:
        data = response.read(4 * 1024 * 1024)
    if hashlib.sha256(data).hexdigest() != WORDS_SHA256:
        raise RuntimeError("downloaded word list failed its checksum")
    fd, tmp = tempfile.mkstemp(prefix=".words-", dir=os.path.dirname(target))
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.rename(tmp, target)
    emit("ready", target)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--words":
        try:
            words(sys.argv[2])
        except Exception as error:
            emit("error", f"word list: {error}".replace("\n", " "))
            sys.exit(1)
        return
    try:
        keyboard = Keyboard()
        keyboard.run()
        # Skip interpreter teardown: garbage-collecting pywayland proxies after
        # the connection is gone segfaults. The compositor cleans up for us.
        keyboard.display.flush()
        sys.stdout.flush()
        os._exit(0)
    except ModuleNotFoundError as error:
        emit("error", f"missing {error.name}: install python-pywayland")
        sys.exit(2)
    except Exception as error:  # report to the shell instead of a silent exit
        emit("error", str(error).replace("\n", " "))
        sys.exit(1)


if __name__ == "__main__":
    main()
