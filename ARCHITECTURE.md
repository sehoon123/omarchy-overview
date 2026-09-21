# Architecture

## Scope

This is a standalone Overview, not a Hyprland patch or Omarchy Shell extension.
Only Overview's repository and deployed application are changed. Compositor
packages, monitor configuration, remote desktop, and unrelated services are not
part of the preview fix. The former custom compositor integration is withdrawn.

## Ownership

| Component | Responsibility |
| --- | --- |
| `shell.qml` | Visibility, selection, topology cancellation, input routing, IPC |
| `OverviewLogic.js` | Pure search, desktop projection, focus/selection helpers |
| `Layout.js` | Aspect-preserving rows and spatial navigation |
| `SnapshotClient.qml` | Short-lived Quickshell process adapter |
| `SnapshotRequest.qml` | Qt-only request, deadline, cancellation state machine |
| `snapshot.py` | Read-only scene validation, output screenshot, PNG window crops |
| `SnapshotBank.qml` | Bounded memory-only cache, identity validation, pruning |
| `WindowPreview.qml`, `DesktopPreview.qml` | Snapshot/title cards and desktop thumbnails |
| `BackendClient.qml`, `worker.py`, `controller.py` | Serialized explicit desktop actions |
| `workspaces.py` | Stable workspace selectors and per-monitor slot projection |
| `Preferences.qml`, `PreferenceStore.qml`, `SettingsPanel.qml` | Validated local settings |

The older generic `CaptureBank.qml`/`FrameCache.qml` utilities and their isolated
regressions remain for compatibility. They are **not instantiated by the shell**.
The native `CaptureProducer`, viewport `PreviewScheduler`, Python priming helper,
and resident-worker `prime` protocol have been removed. There is no native
`ScreencopyView` in the application.

## Opening and capture flow

1. Select the output and initial window from subscribed metadata. Keep the panel
   unmapped. A cold start may wait for the bounded topology-settle timer.
2. Launch a separate read-only Python helper. It queries `monitors`, `clients`, and
   `layers`; verifies lock state, usable output, active workspace, geometry, and
   occlusion; and rejects an already-visible Overview or an Omarchy authentication
   dialog on any output.
3. Use `grim -o <output> -s <scale> -t ppm -`. **Never use toplevel export (`-T`).**
   Read bounded stdout with a deadline and terminate/reap the helper's child on
   cancellation, failure, or timeout. No images are written to disk.
4. Re-read scene metadata. If lock state or relevant geometry/identity/occlusion
   changed, discard the pixels. Otherwise crop visible regions and encode PNG
   data URLs with Python's standard library.
5. The bank accepts only images matching the current window identity, title, and
   dimensions. Then map the panel. A regular failure shows existing snapshots or
   title cards with a brief message; explicit lock/authentication/output-blocked results cancel
   opening instead.
6. Quick Look and the desktop strip use those same images. Nothing captures in
   the background or while the Overview panel is shown.

A panel already on screen must never capture itself. A late process completion
must never reopen a cancelled panel. Cancellation marks the request invalid
before terminating the process; another request cannot start until the old
process exits. The frontend deadline is 700 ms, independent of the serialized
desktop-action worker. The helper has its own bounded reads and child cleanup.

## Snapshot limits and correctness

- Output images are downsampled, with raw PPM input bounded to 1.8 million pixels.
- A reply contains at most 24 frames, 1.8 million cropped pixels, and 6 MiB of
  encoded image data. The bank retains at most 128 entries, 8 MiB encoded data,
  and 12 million image pixels. Qt may keep multiple decoded textures; Python
  buffers and Qt overhead are additional memory.
- The cache is RAM-only. Images are not persisted or logged. `Image.cache` is
  disabled; dropping a source does not intentionally populate Qt's global image
  cache. `keepCache=false` clears on hide.
- Closed windows are pruned; monitor topology changes clear images. Lookup checks
  address, PID, stable ID, title, and original window dimensions.
- Snapshot badges distinguish older retained frames and partial visible regions.
  A snapshot always has `fresh=false`; same-title content changes are not live.
- Overlap handling is conservative. Floating/stacked windows and layers can cause
  a lower window to be omitted rather than showing another application's pixels
  as its preview. Hidden/offscreen windows have no new full-window image.
- Real snapshot aspect ratios are preserved. Without an image, IPC ratios are
  clamped to a readable range and title/app labels remain visible.

Metadata checks are not an atomic compositor transaction. They reduce mismatched
crops but cannot prove that an arbitrary mid-frame scene transition is impossible.
Output screenshots avoid the known missing-monitor *window-session* path; they do
not repair the compositor or prove every physical output-removal scenario safe.

## Desktop actions remain explicit

Window activation uses the Wayland activation path at a cold start and the
address-targeted Hyprland dispatcher when metadata is ready. User-requested move,
create, reorder, group, remove, and undo actions use the resident Python worker
and its serial action lock. Mutating requests are not replayed after worker loss.
Preview capture never invokes these actions and never scrolls a viewport.

Workspace identity is a positive numeric selector or `name:<name>`, not a named
workspace's temporary negative ID. Removal moves windows rather than closing
applications. Undo skips windows changed by later user actions. Read-only state
queries do not rewrite saved desktop order.

## Validation boundaries

`./validate` parses QML, tests pure JS layout/search, runs mocked Python controller
and snapshot tests, and runs offscreen/software Qt tests. It covers actual PNG
decoding, cropped-pixel correctness, lock/scene invalidation, cache bounds and
identity, cancellation, timeout, late responses, input, settings, and layout.

`tests/verify_output_snapshots.py --run` is opt-in. It starts an isolated staging
copy, checks decoded visible snapshots, Quick Look, settings, zero native capture
views, and no background captures, then verifies unchanged user-window geometry,
desktop assignments, focus, and compositor version. It does not create/move user
windows, change settings, save screenshots, restart Hyprland, or remove outputs.

Historical native-capture experiments/full-window benchmarks do not define the
snapshot backend's acceptance criteria. Neither offline tests nor the normal
output-snapshot UI check establish real hotplug crash immunity.
