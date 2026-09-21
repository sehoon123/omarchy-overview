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
| `OverviewLogic.js` | Pure search, desktop projection, capture eligibility/planning, lifecycle and IPC guard verdicts, keyboard intents, `status` assembly |
| `Layout.js` | Aspect-preserving rows, spatial navigation, animation origins |
| `OpenGuard.qml` | Short-lived Quickshell process adapter for the opening check |
| `OpenRequest.qml` | Qt-only request, deadline, cancellation, drain and refusal-reason state machine |
| `capture_context.py` | Read-only lock/output/layer validation; no pixels at all |
| `CaptureBank.qml` | Session-owned producers keyed by address *and* window object |
| `CaptureStream.qml` | One stream per window; synchronous release, no retry path |
| `NativeCapture.qml` | Cursor-free `ScreencopyView` bound to a window's Wayland handle |
| `WindowPreview.qml`, `DesktopPreview.qml` | Cards, labels and desktop thumbnails |
| `DragSurface.qml` | The only pointer grab over the grid and strip: hover, click, drag threshold, drop, wheel |
| `SearchBar.qml` | Query field, clear affordance and the IME composition guard |
| `BackendProtocol.qml` | Qt-only worker request/reply, restart backoff and reply-timeout state machine |
| `BackendClient.qml` | Quickshell `Process` adapter for `worker.py`, over `BackendProtocol` |
| `worker.py`, `controller.py` | Serialized explicit desktop actions |
| `hypr_ipc.py` | One bounded, read-only Hyprland socket call per request; no subprocess |
| `workspaces.py` | Stable workspace selectors and per-monitor slot projection |
| `Preferences.qml`, `SettingsPanel.qml` | Validated, atomically written local settings |

The two split pairs (`OpenGuard`/`OpenRequest`, `BackendClient`/`BackendProtocol`)
exist so the protocol half can be instantiated by `qmltestrunner`, which cannot
resolve `Quickshell.Io` and therefore cannot load anything that roots a `Process`.

There is no output screenshot helper, no viewport priming, no frame cache and no
resident-worker `prime` protocol. `preview.py`, `snapshot.py`, `CaptureProducer`,
`PreviewScheduler`, `FrameCache` and `SnapshotBank` have all been removed. Two
names outlive them and are kept only because the `status` payload is a contract:
`prime` exists solely to refuse (`controller.py`; it is not in the worker's
supported command set at all), `primed` is a permanently empty list, and
`cachedFrames` counts live streams that currently hold content — nothing is
cached anywhere.

## Opening and capture flow

1. Select the output and initial window from subscribed metadata, keeping the
   panel unmapped. An open that arrives before the output list has settled waits
   for the bounded topology-settle timer (1 s, at most three attempts) instead of
   asking for a context check; if no usable output appears, the open fails with a
   reason rather than being dropped.
2. Run `capture_context.py`, a separate read-only process: it queries `monitors`
   and `layers`, fails closed on locks or unknown lock state, rejects disabled,
   DPMS-off, headless/fallback and malformed outputs, and refuses to open while an
   Omarchy authentication or lock layer is visible on **any** display. It emits an
   output only when that output's `name`, integer `id`, positive finite `scale`,
   `width`/`height`, finite `x`/`y` and known `transform` are all readable; a
   field it cannot read drops that output or refuses the open, never a
   plausible-looking substitute. Geometry is rotation-corrected and divided by the
   scale. An unreadable lock field refuses without claiming the session is locked.
   The helper's own budget is two socket calls of 0.3 s each, so its worst case is
   ~0.6 s of socket waiting plus `python3` start-up; a warm check measures about
   12 ms. The caller's deadline is set on the `OpenGuard` instance in `shell.qml`
   at 1200 ms, above that worst case, so a cold page cache does not fail an open;
   `OpenRequest`'s own default stays 700 ms for callers that set nothing. The panel
   remains unmapped for the whole check. If the deadline is reached anyway the open
   fails with `Capture context check timed out` in `previewError` and the journal,
   rather than hanging or opening unvalidated.
3. Map the panel. `windowCaptureEnabled` becomes true only when the panel is
   shown, its first frame is presented, the context check passed and topology is
   settled — so no capture object can exist before that. Becoming visible
   additionally requires at least one mappable output: with no panel to map, the
   open fails with a reason instead of entering a visible-but-unmapped state.
4. `CaptureBank` creates one `NativeCapture` per eligible window, in priority
   order: Quick Look, the dragged window, the selection, then the grid.
   Eligibility uses the window's own monitor (not its workspace's remembered
   monitor), a Wayland handle, mapped/non-hidden state, valid geometry, the
   per-window pixel bound and the off-viewport test. The plan then fills the
   session budget greedily: a window whose scaled area does not fit the remaining
   budget is **skipped and the walk continues**, so a smaller, lower-priority
   window may take the place of a larger one. Skipped windows report
   `Preview budget reached`.
5. Cards animate from each window's real desktop rectangle on this output to the
   grid slot; other displays and off-viewport windows fade in at their slot.
6. Quick Look and the desktop strip render the *same* stream through
   `ShaderEffectSource`, so no second capture is created for any presentation.
7. Closing reverses the motion, blocks new capture objects, releases every
   stream, destroys the producers and unloads the textures. Re-opening always
   builds fresh sources. The exit animation keeps the capture plan it started
   with, so cancelling the drag (which reorders the priority list) cannot push a
   card past the budget and blank it mid-animation; a held address whose window is
   gone is still dropped, and nothing new is ever started while closing.

An already-visible Overview is not captured. A late context reply cannot reopen a
cancelled panel: cancellation invalidates the request before stopping the process,
and a verdict is applied only to the session that asked for it — a recheck verdict
arriving during an open, or an open verdict arriving after that open ended, is
ignored. The guard admits one helper at a time and, when the previous helper has
not confirmed its exit, refuses with a distinct reason and re-offers the run as
soon as it is free or a bounded drain window (1.5 s) elapses; the open is retried
twice from that signal rather than dead-ending. Each refusal has its own sentence,
visible in `previewError` and the journal. A visible session rechecks lock/output
state once per second, read-only, never while an open, close or shutdown is in
flight, and an authentication or lock layer appearing while open closes Overview
immediately.

A monitor add/remove or a compositor `configreloaded` event invalidates the whole
capture session: a visible Overview closes, and an open that was still in flight
is resumed once the topology settles instead of being silently discarded. An
explicit close, a lock layer or a shutdown cancels that resume.

A requested shutdown always terminates. `shutdown` latches the request, closes,
and arms a 3 s watchdog that outranks every latch it would otherwise wait on (an
in-flight action, an unfinished open, a pending activation, a queued settings
write), naming the blocker in the journal; the queued settings write is still
attempted before quitting. The close animation is bounded the same way by a 400 ms
watchdog tagged with the session it belongs to, so `closing` — which disables
input and refuses IPC — cannot latch, and a motion that lands after a newer open
cannot close it. A window chosen for activation is focused exactly once, after the
close, and a discarded activation is reported rather than dropped.

## Capture limits and correctness

- One stream per window, created only while visible; `viewCount` is observable
  through IPC (`captureViews`) and must be `0` whenever Overview is hidden.
- The session budget is 32 streams or 64 million scaled pixels, whichever binds
  first, plus a 16 million scaled-pixel bound on any single window. Measured on
  this machine's 2560x1600 output at scale 1.6: a full-screen window is 1600x1000
  logical and costs 4.10 MP scaled, so the total budget binds at 15 such streams
  (64 / 4.10 = 15.6) and the 32-stream cap is never reached; the per-window bound
  would need a window ~3.9x the area of the whole screen, so it is a safety net,
  not an operating limit. The fill is greedy, not first-fit-stop: an over-budget
  window is skipped and smaller windows behind it still get streams.
- Release nulls the protocol `captureSource` and clears `live` synchronously
  *before* the deferred `destroy()`, so a stream cannot outlive its card.
- A stopped/failed stream is not retried, and there is no option to retry it: the
  stream is released, marked failed, and only a new explicit Overview session
  builds a fresh one. Its card says exactly that.
- Address reuse is not identity: an entry survives only while both the address and
  the window object match, so a recycled address cannot inherit another window's
  image. Search, filtering and reordering keep the same producers alive. While a
  close is in progress the bank keeps a producer it would not be allowed to
  recreate, instead of releasing it for the length of the animation.
- Monitor/topology changes and hide both clear the whole bank. There is no
  cross-session cache, so `keepCache` is retained only as a preserved setting key.
- Textures are unloaded with their `Loader` when a stream has no content, and
  sampled at twice the presented size, rounded up to a 64 px grid and clamped to
  the source, so an animating card reuses one framebuffer instead of reallocating
  per frame.
- Cards use the real captured aspect ratio; without an image, IPC ratios are
  clamped to a readable range so odd scrolling geometry cannot collapse a card.
- A card with no image always names one of nine distinct reasons: six eligibility
  refusals (`Waiting for window metadata`, `Window is not captureable`,
  `Display is unavailable`, `Waiting for window geometry`,
  `Window exceeds preview memory budget`, `Off-screen preview unavailable`) and
  three session states (`Loading window preview…`, `Preview budget reached`,
  `Live preview stopped · reopen Overview to retry`). Two of those strings are
  summaries rather than diagnoses: `Window is not captureable` covers not mapped,
  hidden, no monitor object and a window whose reported monitor disagrees with its
  monitor object, and `Waiting for window metadata` covers a missing window, a
  missing Wayland handle and a special/unusable workspace.

Client-side lifecycle guards reduce exposure; they are not an atomic compositor
transaction. Hyprland 0.56.2's missing-monitor defect in window capture sessions
remains. A window fully outside its viewport may never produce a frame, and
Overview reports that instead of substituting other pixels.

## Layout

`Layout.arrange()` returns one cell per window or an empty array — there is no
third answer, and never a sliver, an off-stage or an overlapping card. It refuses
with `[]` exactly when the model is empty or unusable, the stage width/height is
not a positive finite number, or the best shared cell height would fall below
8 px (4 px for the unlabelled desktop strip). The count that trips this depends on
the ratios and the stage, so it is not a fixed number: with uniform 16:10 windows
it is 280 cards on this machine's 1504x730 stage, and 118 members on one desktop's
132x68 strip tile. When
the stage is sized and the model is not empty but `arrange()` refuses, the grid
says `Not enough room to show these windows`; while the stage has no size yet it
stays silent, so nothing flashes during the open.

For *packing* only, a ratio is bounded to `[.005, 20]`, because all cards share
one scale and a single pathological ratio otherwise shrank every other card or
erased the grid. `aspectFor()` still reports the true native ratio and the card
letterboxes inside its cell, so nothing is distorted; a card whose letterboxed
surface is thinner than 24 px on an axis has its *hit target* grown to 24 px
inside its own cell, never into a neighbour's.

## Desktop actions remain explicit

Window activation uses the Wayland activation path at a cold start and the
address-targeted Hyprland dispatcher when metadata is ready; it runs after the
closing animation, not during capture. User-requested state, create, move,
switch, step, reorder, remove and undo actions use the resident Python worker and
its serial action lock; a move carries a grouped window's members in its undo
record, but there is no bulk "move this desktop's windows" action. Mutating
requests are not replayed after worker loss, and a request that never answers is
failed by the client after 20 s so the UI cannot stay busy forever. Preview
capture never invokes these actions and never scrolls a viewport.

Workspace identity is a positive numeric selector or `name:<name>`, not a named
workspace's temporary negative ID. Removal moves windows rather than closing
applications. Undo skips windows changed by later user actions. Read-only state
queries do not rewrite saved desktop order.

## IPC surface

All ten handlers answer from one state snapshot through a single pure guard, so
they cannot drift apart, and `OverviewLogic.test.js` pins every cell of the
matrix. The matrix itself is documented in `shell.qml` immediately above
`IpcHandler`. Five handlers return a string, two return a bool, and the contract
is the same in all of them:

- `ok` means the request was **accepted** (a close queued behind an in-flight
  action counts as accepted). Any other reply is a refusal with **no side
  effect**. No reply at all can only mean the process is gone.
- Precedence is always: invalid argument, then `shutdownRequested`, then
  `closing`, then the call's own state. `preparing` answers as `opening`.
- `openOverview`, `toggle`, `close`, `showSettings` and `navigateDesktop` return
  a reason from a fixed vocabulary; `setQuery` and `togglePreview` return `false`
  for the same refusals. `shutdown` always returns `ok` and is idempotent.
- `status` and `captureReady` are deliberately **unguarded**: `status` is the
  launcher's liveness probe and must answer in every state, and `captureReady`
  answers for a capture object rather than for the session.
- `navigateDesktop` moves only this Overview session's desktop filter while
  visible — never the compositor's workspace — answers `opening` without aborting
  an open in flight, and answers `ok` while hidden only once the worker accepted
  the step. `unavailable` is the single reply that invites
  `integrations/omarchy-overview` to dispatch a real workspace switch.

`status` is a diagnostic payload with a fixed key set and key order. What it
deliberately exposes: window addresses, capture source serials, stage geometry and
hit zones, the current search query, the settings document, the output name, and
desktop selectors and labels — which, with the per-monitor plugin, embed the
monitor's `description` and therefore its model and serial on outputs that report
one. What it does not contain, asserted by test against hostile input: window
titles, application classes, file paths, URLs, image data, texture sizes or
pixels. Because the payload is a contract for the opt-in checks, keys are not
renamed even when their names are historical (`primed`, `cachedFrames`; see
Ownership).

Known ceilings that are stated rather than enforced: `controller.act()` has no
internal deadline of its own, so a pathological multi-window action could in
theory outlast the client's 20 s reply timeout. The UI then reports that the action
did not answer, the late reply is dropped, and the next event-driven state refresh
corrects the display; nothing is replayed.

## Validation boundaries

`./validate` is offline in the strict sense: it parses every QML file, runs two
Node suites and the Python unit tests, and runs the Qt test cases under the
offscreen platform with the software backend. It opens no window, spawns neither
`worker.py` nor `capture_context.py`, and makes no Hyprland or Quickshell call —
nothing under `tests/` instantiates a component that roots a `Process`. The QML
capture tests drive synthetic stream objects instead.

What it covers today: lifecycle guard predicates (open, present, settle, close,
shutdown, activation handoff, recheck) and the full IPC guard-return matrix; the
`status` payload's shape, key order and insensitivity to hostile input; capture
eligibility, the session budget and the greedy fill; capture object lifecycle and
identity (nothing while disabled, one shared source per window, synchronous
release before destruction, no retry, no address-reuse inheritance, plan held
while closing); the opening-helper protocol (late/duplicate/oversized/malformed
replies, five distinct failure reasons, bounded drain); the worker protocol client
(framing, single flight, no replay after loss, capped restart backoff, reply
timeout); settings validation and persistence (defaults, rejected values,
unreadable and newer documents, a read-only file, preserved unknown keys); the
Python guard paths (transport failures and bounded error text, malformed monitor,
workspace, client and layer fields, corrupt saved desktop order, undo-record
validation, worker protocol errors); `Layout.js` at degenerate and extreme sizes
and ratios; and the card, desktop-strip, search and drag components, including
that the preview components take no pointer grab and load no file.

`tests/verify_native_previews.py`, `tests/verify_ui.py` and `tests/verify_live.py`
are **opt-in and not part of `./validate`**. `verify_native_previews.py --run`
stages its own copy of the repository, briefly displays it, verifies live native
frames, one shared source per window across Quick Look and search, and zero
captures while hidden, then checks unchanged user-window geometry, desktop
assignments, focus and compositor process. `verify_ui.py --run --config
/tmp/<staging-copy>` drives real keyboard, IME and settings interaction against an
already-running staging copy under `/tmp` and refuses any other config path.
`verify_live.py` needs a disposable window of class `overview-verification` on
desktop 90 that you create yourself; it performs **real** desktop actions through
`controller.py`, asserts that no other window changed desktop, and closes that one
window at the end. None of the three writes screenshots, restarts Hyprland or
removes an output.

Neither the offline suite nor these opt-in checks establish physical hotplug crash
immunity, and they must not be read as evidence that the compositor defect is
fixed.
