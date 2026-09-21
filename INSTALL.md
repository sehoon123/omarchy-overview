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

The five globs above cover every application, test and documentation file in the
repository root; `.gitignore` and `integrations/` are deliberately not copied (see
**New installation**). They also copy `Layout.test.js` and `OverviewLogic.test.js`
into the deployment, which is harmless — nothing loads them at runtime.

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

- `windowCaptureEnabled`: `true`; `captureViews` between 1 and 32, bounded by
  whichever of the two budgets binds first. The 64 MP total is normally the one
  that binds — about 15 full-screen streams on a 2560x1600 output at scale 1.6 —
  so a high `captureViews` means many small windows, not a raised cap.
- Per-window `imageReady`: Qt has content for that window's own capture
- `live`: that window's stream is currently updating
- `sourceId`: stable per window for the whole session; unique across windows
- `reason`: why that card has no image. One of nine fixed strings:
  `Waiting for window metadata`, `Window is not captureable`,
  `Display is unavailable`, `Waiting for window geometry`,
  `Window exceeds preview memory budget`, `Off-screen preview unavailable`,
  `Loading window preview…`, `Preview budget reached`,
  `Live preview stopped · reopen Overview to retry`. Two of them are summaries:
  `Window is not captureable` and `Waiting for window metadata` each stand for
  several conditions, so treat the string as a starting point, not a diagnosis.
  A card that has an image reports an empty `reason`.
- `previewError`: the reason the last open was refused, if it was — a missing or
  unsettled display, a refused capture-context check, or the check's own verdict
  (lock, authentication layer, unreadable or unavailable display).
- `primed` is always `[]` and `cachedFrames` counts live streams that currently
  hold content. Both names are historical; nothing is primed or cached.

If a card stays without an image, the window is likely fully outside its display's
viewport on Hyprland 0.56.2. Overview will not scroll the desktop, switch
workspaces or move focus to obtain that frame. Lock/authentication guards may
cancel opening entirely, leaving an existing authentication dialog untouched.

`openOverview`, `toggle`, `close`, `showSettings`, `navigateDesktop` and `shutdown`
answer `ok` when they accepted the request, or one word naming the refusal
(`invalid`, `shutdown`, `closing`, `shown`, `opening`, `hidden`, `busy`,
`dragging`, `settings`, `activating`, `empty`, `unavailable`); `setQuery` and
`togglePreview` answer `true` or `false` the same way. A refusal changes nothing. `status` and
`captureReady` are the two calls that always answer, in every state.

Three isolated checks are opt-in and are **not** part of `./validate`. Each drives
a real, visible Overview or real desktop actions:

```sh
# Stages its own copy of the repository and briefly displays it.
python3 tests/verify_native_previews.py --run

# Against a staging copy under /tmp that is already running; needs wtype + fcitx5.
python3 tests/verify_ui.py --run --config /tmp/<staging-copy>

# Needs a disposable window of class `overview-verification` on desktop 90, which
# you create; it performs real desktop actions and closes that window at the end.
python3 tests/verify_live.py
```

The first two check desktop-state continuity around a staging Overview; the third
checks create/move/undo/remove/reorder and desktop-order persistence through
`controller.py` and asserts that no other window changed desktop. Never point
`verify_ui.py` at your installed Overview — it refuses any config outside `/tmp`.
Offline tests and these checks do not establish physical display-hotplug safety.
