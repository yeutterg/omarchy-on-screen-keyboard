#!/usr/bin/python3
"""Tray icon for the on-screen keyboard: a StatusNotifierItem whose click shows
or hides the keyboard. The plugin's service runs it while the button belongs
in the tray (options "barButton"), and stops it otherwise. Uses the system
Python's PyGObject, which Omarchy ships."""

import signal
import subprocess

from gi.repository import Gio, GLib

BUS_NAME = "io.github.yeutterg.OnscreenKeyboard"
ITEM_PATH = "/StatusNotifierItem"

INTERFACE = """
<node>
  <interface name="org.kde.StatusNotifierItem">
    <property name="Category" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="Title" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconName" type="s" access="read"/>
    <property name="ItemIsMenu" type="b" access="read"/>
    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
  </interface>
</node>
"""

PROPERTIES = {
    "Category": GLib.Variant("s", "Hardware"),
    "Id": GLib.Variant("s", "io.github.yeutterg.onscreen-keyboard"),
    "Title": GLib.Variant("s", "On-Screen Keyboard"),
    "Status": GLib.Variant("s", "Active"),
    "IconName": GLib.Variant("s", "input-keyboard-symbolic"),
    "ItemIsMenu": GLib.Variant("b", False),
    "ToolTip": GLib.Variant("(sa(iiay)ss)", ("", [], "On-Screen Keyboard", "Show or hide the keyboard")),
}


def ipc(*args):
    subprocess.Popen(["omarchy-shell", "-q", "onscreen-keyboard", *args],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def on_call(_conn, _sender, _path, _iface, method, _params, invocation):
    if method in ("Activate", "ContextMenu"):
        ipc("toggle")
    elif method == "SecondaryActivate":
        ipc("cycle")
    invocation.return_value(None)


def on_get_property(_conn, _sender, _path, _iface, name):
    return PROPERTIES.get(name)


def register(bus):
    bus.call("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
             "RegisterStatusNotifierItem", GLib.Variant("(s)", (BUS_NAME,)),
             None, Gio.DBusCallFlags.NONE, -1, None, None)


def main():
    loop = GLib.MainLoop()
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    node = Gio.DBusNodeInfo.new_for_xml(INTERFACE)
    bus.register_object(ITEM_PATH, node.interfaces[0], on_call, on_get_property, None)
    # One icon only; a second copy (another bar) exits.
    reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                          "RequestName", GLib.Variant("(su)", (BUS_NAME, 4)),  # DO_NOT_QUEUE
                          GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, -1, None)
    if reply.unpack()[0] != 1:
        return
    # Register now, and again whenever the tray (watcher) restarts.
    Gio.bus_watch_name_on_connection(bus, "org.kde.StatusNotifierWatcher", Gio.BusNameWatcherFlags.NONE,
                                     lambda *_: register(bus), None)
    for sig in (signal.SIGTERM, signal.SIGINT):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, loop.quit)
    loop.run()


if __name__ == "__main__":
    main()
