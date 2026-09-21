# Architecture

## Scope

This is a standalone Overview, not a Hyprland patch or Omarchy Shell extension.
Only Overview's repository and deployed application are changed. Compositor
packages, monitor configuration, remote desktop, and unrelated services are not
part of the preview work. The former custom compositor integration is withdrawn.

## Ownership

| Component | Responsibility |
| --- | --- |
| `shell.qml` | Visibility, motion, selection, capture policy, input routing, IPC |
| `OverviewLogic.js` | Pure search, desktop projection, capture eligibility/planning |
| `Layout.js` | Aspect-preserving rows, spatial navigation, animation origins |
| `OpenGuard.qml` | Short-lived Quickshell process adapter for the opening check |
| `OpenRequest.qml` | Qt-only request, deadline, cancellation state machine |
| `capture_context.py` | Read-only lock/output/layer validation; no pixels at all |
| `CaptureBank.qml` | Session-owned producers keyed by address *and* window object |
| `CaptureStream.qml` | One stream per window; synchronous release, no retry loop |
| `NativeCapture.qml` | Cursor-free `ScreencopyView` bound to a window's Wayland handle |
| `WindowPreview.qml`, `DesktopPreview.qml` | Cards, labels and desktop thumbnails |
| `BackendClient.qml`, `worker.py`, `controller.py` | Serialized explicit desktop actions |
| `workspaces.py` | Stable workspace selectors and per-monitor slot projection |
| `Preferences.qml`, `SettingsPanel.qml` | Validated, atomically written local settings |

There is no output screenshot helper, no viewport priming, no frame cache and no
resident-worker `prime` protocol. `preview.py`, `snapshot.py`, `CaptureProducer`,
`PreviewScheduler`, `FrameCache` and `SnapshotBank` have all been removed.

## Opening and capture flow

1. Select the output and initial window from subscribed metadata, keeping the
   panel unmapped. A cold start may wait for the bounded topology-settle timer.
2. Run `capture_context.py`, a separate read-only process: it queries `monitors`
   and `layers`, fails closed on locks or unknown lock state, rejects disabled,
   DPMS-off, headless/fallback and malformed outputs, and refuses to open while an
   Omarchy authentication or lock layer is visible on **any** display. It returns
   validated output IDs, names, scales and rotation-corrected logical geometry.
3. Map the panel. `windowCaptureEnabled` becomes true only when the panel is
   shown, its first frame is presented, the context check passed and topology is
   settled — so no capture object can exist before that.
4. `CaptureBank` creates one `NativeCapture` per eligible window, ordered by
   selection/Quick Look/drag priority and capped at 32 streams and 64 million
   scaled pixels. Eligibility uses the window's own monitor (not its workspace's
   remembered monitor), a Wayland handle, mapped/non-hidden state, valid geometry
   and per-window pixel bounds.
5. Cards animate from each window's real desktop rectangle on this output to the
   grid slot; other displays and off-viewport windows fade in at their slot.
6. Quick Look and the desktop strip render the *same* stream through
   `ShaderEffectSource`, so no second capture is created for any presentation.
7. Closing reverses the motion, blocks new capture objects, releases every
   stream, destroys the producers and unloads the textures. Re-opening always
   builds fresh sources.

An already-visible Overview is not captured. A late context reply cannot reopen a
cancelled panel: cancellation invalidates the request before stopping the process,
and a new request cannot start until the old process exits. A visible session
rechecks lock/output state once per second, read-only, and an authentication or
lock layer appearing while open closes Overview immediately.

## Capture limits and correctness

- One stream per window, created only while visible; `viewCount` is observable
  through IPC (`captureViews`) and must be `0` whenever Overview is hidden.
- Release nulls the protocol `captureSource` and clears `live` synchronously
  *before* the deferred `destroy()`, so a stream cannot outlive its card.
- A stopped/failed stream is not silently retried. It is released, marked failed,
  and only a new explicit Overview session may try again.
- Address reuse is not identity: an entry survives only while both the address and
  the window object match, so a recycled address cannot inherit another window's
  image. Search, filtering and reordering keep the same producers alive.
- Monitor/topology changes and hide both clear the whole bank. There is no
  cross-session cache, so `keepCache` is retained only as a preserved setting key.
- Textures are unloaded with their `Loader` when a stream has no content, and
  sampled at twice the presented size to keep small text readable.
- Cards use the real captured aspect ratio; without an image, IPC ratios are
  clamped to a readable range so odd scrolling geometry cannot collapse a card.

Client-side lifecycle guards reduce exposure; they are not an atomic compositor
transaction. Hyprland 0.56.2's missing-monitor defect in window capture sessions
remains. A window fully outside its viewport may never produce a frame, and
Overview reports that instead of substituting other pixels.

## Desktop actions remain explicit

Window activation uses the Wayland activation path at a cold start and the
address-targeted Hyprland dispatcher when metadata is ready; it runs after the
closing animation, not during capture. User-requested move, create, reorder,
group, remove and undo actions use the resident Python worker and its serial
action lock. Mutating requests are not replayed after worker loss. Preview
capture never invokes these actions and never scrolls a viewport.

Workspace identity is a positive numeric selector or `name:<name>`, not a named
workspace's temporary negative ID. Removal moves windows rather than closing
applications. Undo skips windows changed by later user actions. Read-only state
queries do not rewrite saved desktop order.

## Validation boundaries

`./validate` parses QML, tests pure JS layout/search/planning, runs mocked Python
controller and read-only context tests, and runs offscreen/software Qt tests. The
capture tests use a synthetic stream component: disabled sessions never create
producers, visible pixels update without replacing the producer, card/desktop
presentations share one source, closing nulls the source before destruction and
drops textures, failures do not loop, and identity survives search/reset.

`tests/verify_native_previews.py --run` and `tests/verify_ui.py --run` are opt-in.
They start an isolated staging copy, verify live native frames, one shared source
per window across Quick Look and search, and zero captures while hidden, then
check unchanged user-window geometry, desktop assignments, focus and compositor
process. They do not create/move user windows, write screenshots, restart
Hyprland or remove outputs.

Neither the offline suite nor these UI checks establish physical hotplug crash
immunity, and they must not be read as evidence that the compositor defect is
fixed.
