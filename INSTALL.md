# Installation and updates

## Requirements

- The distribution's official Hyprland and Quickshell packages.
- Python 3 (standard library only).
- `grim` for output snapshots. Without it, Overview falls back to title cards.
- Node.js and Qt's QML tools only for local validation.

**Do not build or install a patched Hyprland for this application.** The earlier
`integrations/hyprland` package instructions are withdrawn. Preview changes are
confined to Overview; leave compositor packages, desktop configuration, monitors,
remote-desktop services, and other applications unchanged.

## Updating an existing installation

Validate first, then back up the existing Overview directory, including personal
settings. Stop only `sehun-overview.service` while copying files so Quickshell does
not reload a partially updated configuration.

```sh
cd /path/to/omarchy-overview
./validate

# Choose a private backup location before replacing application files.
cp -a ~/.config/omarchy/overview /your/private/backup/overview
systemctl --user stop sehun-overview.service

cp ./*.qml ./*.js ./*.py ./*.md ./validate ~/.config/omarchy/overview/
cp -a tests/. ~/.config/omarchy/overview/tests/

# Retired Overview components only. Never remove personal settings.json.
rm -f ~/.config/omarchy/overview/{CaptureProducer.qml,PreviewScheduler.qml,preview.py}
rm -f ~/.config/omarchy/overview/tests/{tst_PreviewScheduler.qml,test_preview.py}

systemctl --user start sehun-overview.service
```

Do **not** copy a default `settings.json` over an existing file. Keep the installed
launcher, keybinding, user service definition, desktop-order state, and other
Omarchy components unchanged for this update. No logout/relogin is necessary.

## New installation

Copy the application files and tests into `~/.config/omarchy/overview` as above.
The repository's `integrations/omarchy-overview` launcher and
`integrations/sehun-overview.service` show the optional standalone integration.
Review these and the desired shortcut before installing them; this project does
not automatically rewrite Hyprland or Omarchy Shell configuration.

The service uses `OVERVIEW_START_HIDDEN=1` and keeps metadata subscriptions warm.
The existing launcher opens/toggles it through IPC. A direct
`quickshell -p ~/.config/omarchy/overview` invocation without that environment flag
opens after the pre-display snapshot attempt.

## Verify

```sh
quickshell ipc -p ~/.config/omarchy/overview call overview status
omarchy-overview
```

Expected status:

- `captureBackend`: `output-snapshot`
- `windowCaptureEnabled`: `false`
- `captureViews`: `0`
- `snapshotBytes`: bounded in-memory encoded cache size
- Per-window `imageReady`: whether Qt has decoded the displayed image
- `fresh`: `false` (a snapshot is never reported as a live stream)
- `snapshotError`: an explanation if a capture attempt failed

At least one unobscured window must be visible on the selected output for a new
snapshot. Other windows may have previous snapshots or title cards. If capture
fails, the rest of the UI remains usable; changing `windowCaptureEnabled` is not
a supported workaround. Lock/authentication safety guards may cancel opening
entirely, leaving an existing authentication dialog untouched.

For an isolated, opt-in UI check, run:

```sh
python3 tests/verify_output_snapshots.py --run
```

It briefly displays its own staging Overview and checks desktop-state continuity.
Do not run old native-capture/viewport-priming experiments as acceptance tests for
this backend. Offline tests do not establish physical hotplug safety.
