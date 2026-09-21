# Installation and updates

## Requirements

- The distribution's official Hyprland and Quickshell packages.
- Python 3 (standard library only). No `grim` or screenshot tool is needed.
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
cd ~/.config/omarchy/overview
rm -f SnapshotBank.qml SnapshotClient.qml SnapshotRequest.qml FrameCache.qml \
      CaptureProducer.qml PreviewScheduler.qml snapshot.py preview.py
rm -f tests/tst_SnapshotBank.qml tests/tst_SnapshotClient.qml tests/tst_FrameCache.qml \
      tests/tst_PreviewScheduler.qml tests/test_snapshot.py tests/test_preview.py \
      tests/verify_output_snapshots.py tests/verify_freshness.py tests/benchmark_open.py
rm -rf tests/capture-fixture

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
While hidden it holds no capture objects. The existing launcher opens/toggles it
through IPC. A direct `quickshell -p ~/.config/omarchy/overview` invocation without
that environment flag opens after the read-only context check.

## Verify

```sh
quickshell ipc -p ~/.config/omarchy/overview call overview status
omarchy-overview
```

Expected status while **hidden**:

- `captureBackend`: `native-window`
- `windowCaptureEnabled`: `false`
- `captureViews`: `0`, `cachedFrames`: `0`

Expected status while **visible**:

- `windowCaptureEnabled`: `true`, `captureViews` between 1 and 32
- Per-window `imageReady`: Qt has content for that window's own capture
- `live`: that window's stream is currently updating
- `sourceId`: stable per window for the whole session; unique across windows
- `reason`: why a card has no image yet, e.g. an off-viewport window
- `previewError`: an explanation if the read-only opening check failed

If a card stays without an image, the window is likely fully outside its display's
viewport on Hyprland 0.56.2. Overview will not scroll the desktop, switch
workspaces or move focus to obtain that frame. Lock/authentication guards may
cancel opening entirely, leaving an existing authentication dialog untouched.

For isolated, opt-in UI checks, run:

```sh
python3 tests/verify_native_previews.py --run
python3 tests/verify_ui.py --run --config /tmp/<staging-copy>
```

Both briefly display their own staging Overview and check desktop-state continuity.
Offline tests and these checks do not establish physical display-hotplug safety.
