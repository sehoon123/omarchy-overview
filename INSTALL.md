# Installation

This is a standalone, user-owned Overview for **Omarchy's Lua-based Hyprland**,
not an in-process Omarchy Shell plugin. The runtime code is a snapshot of the
working desktop implementation.

## Requirements

- An active Omarchy/Wayland session and systemd user services.
- Hyprland with the Lua `hl.dsp` API and horizontal scrolling support (tested on
  0.56.2). Older text-dispatcher Hyprland versions are not supported by this snapshot.
- Quickshell with Qt 6, `Quickshell.Hyprland`, `Quickshell.Wayland`,
  `Quickshell.Io`, Qt Quick Controls Basic and Qt Quick Effects.
- Python 3, Bash, `timeout` and `flock`.
- Omarchy's `omarchy-hyprland-session-locked` helper on PATH.
- Tests additionally use Node.js (with `node:test`) and Qt's `qmltestrunner` and
  `qmlformat`. Visible checks may require `grim`, `wtype`, fcitx5/Hangul and Pillow.

No Python packages are required by the runtime. Installation below uses the
standard `$HOME/.config` and `$HOME/.local/bin` paths; the bundled unit must be
adjusted if you use different XDG directories.

## Copy the snapshot

Run from the repository root. **If updating an existing installation**, first
stop `sehun-overview.service` and back up the existing Overview directory,
`~/.local/bin/omarchy-overview` and its user service. Do not stop your other apps.
The copy preserves existing `settings.json` and the separate desktop-order state.

```sh
systemctl --user stop sehun-overview.service  # existing installations only

target="$HOME/.config/omarchy/overview"
mkdir -p "$target" "$HOME/.local/bin" "$HOME/.config/systemd/user"
cp ./*.qml ./*.js ./*.py ./*.md "$target/"
cp -R tests "$target/"
install -m 755 validate "$target/validate"
install -m 755 integrations/omarchy-overview "$HOME/.local/bin/omarchy-overview"
install -m 644 integrations/sehun-overview.service "$HOME/.config/systemd/user/"

systemctl --user daemon-reload
systemctl --user enable --now sehun-overview.service
omarchy-overview
```

The service keeps its original `sehun-overview` identifier for compatibility with
existing launchers, IPC, layer rules and tests. It is not a hardcoded home directory.
No files under `/usr/share/omarchy` are modified.

## Optional shortcuts

Review `integrations/bindings.example.lua` and copy only the desired lines into
`~/.config/hypr/bindings.lua`; never replace the entire file. Check conflicts with
`omarchy menu keybindings --print` first. Call `hl.unbind` before overriding an
existing binding.

Ctrl+Left/Right desktop navigation is optional because it replaces normal word
navigation inside applications. No gestures or hot corners are installed.

After editing bindings:

```sh
hyprctl reload
hyprctl configerrors
```

## Validate

```sh
./validate
```

This runs headless checks only. The separate visible integration tests described
in README.md must be opted into; some temporarily change workspace state or take
diagnostic screenshots. Do not run those while working on the desktop.

## Update or remove

Stop the service before replacing code; start it again afterward. Restarting drops
memory-only preview frames but does not reset your settings or desktop order.

For removal, disable/stop the user service, remove only the bindings you added,
and remove the installed Overview directory, launcher and service file. Run
`systemctl --user daemon-reload` and validate any Hyprland binding edits as above.
Desktop-order state lives separately in `~/.local/state/omarchy/overview/`; do not
remove it unless you also want to discard saved ordering/placeholders.
