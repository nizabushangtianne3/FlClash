# proxy

FlClash's desktop system-proxy integration.

- Windows uses a Flutter method channel and WinINet settings.
- macOS uses `/usr/sbin/networksetup` for each active network service.
- Linux uses GNOME/MATE `gsettings` or KDE `kwriteconfig` based on the active
  desktop environment.

The public `Proxy` API validates the port, applies HTTP, HTTPS, and SOCKS
settings to `127.0.0.1`, and returns `false` when the selected platform backend
is unavailable or a command fails.

`clearStaleProxy` undoes a proxy that a killed run left behind. It only acts on
a proxy that is enabled, points at `127.0.0.1`, and whose port has no listener,
so a proxy that points somewhere else or still has a live server stays as it
is. A probe that fails counts as a live server.

Linux is left out: its backends write their settings through `gsettings` and
`kwriteconfig`, and neither reports what is stored in a form that can be
compared with a port.
