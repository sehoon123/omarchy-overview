# Overview architecture

## Ownership

```
Shortcut -> existing Quickshell IPC -> shell.qml (view + user intentions)
                                  |
                                  +-> BackendClient -> stdin/stdout -> worker.py
                                  |                    one executor + input reader
                                  |                    -> controller.py / preview.py
                                  |                    -> Hyprland local UNIX socket
                                  |
                                  +-> PreviewScheduler (lower-priority viewport lease)
                                  |       ^ fresh-frame events / cancellation
                                  |
                                  +-> CaptureBank (stable window-address registry)
                                          -> CaptureProducer (Wayland adapter)
                                          -> FrameCache (front + pending snapshot)
```

There is one systemd user service, not a collection of microservices. Its child
worker exposes no listening socket or network port. QML already subscribes to
Hyprland's live model; authoritative transaction checks use direct socket queries
rather than starting hyprctl, Python and quickshell IPC clients for each poll.
The CLI controller remains a fallback for startup/busy desktop navigation.

## Freshness is not `hasContent`

Quickshell's native `ScreencopyView.hasContent` only establishes that a buffer
exists. It does not establish that it depicts the current Chromium tab, nor does
it identify a newly completed request. Using that boolean as a cache-validity or
capture-completion signal caused the stale-tab bug.

`FrameCache` instead owns:

- `contentTag`: current window title + dimensions; changed tags invalidate display.
- `confirmedTag`: the tag attached to the committed snapshot.
- `generation`: increases only when a pending capture supplies its first frame.
- `capturedAt`: time of that acknowledged snapshot (not of arbitrary live updates).
- `needsRefresh`: an explicitly invalidated frame, including focus-boundary refresh.
- `front` / `pending`: separate sources; no empty-frame flicker during normal refresh.

A changed tag is debounced for at least 80 ms so an application can commit its
repaint after a title notification. An old-tag capture completing late is rejected.
A new tag never inherits the old frame's validity. Window/source destruction clears
the cache, even if a compositor address is subsequently reused.

While hidden, only the naturally activated window is sampled (400 ms), plus
metadata/focus-boundary events. No background operation scrolls or focuses windows.
While visible, the budget is 6 main/drag streams by default (selectable 1/6/12);
desktop-strip-only windows keep snapshots. Quick Look shares and prioritizes one
existing capture. Pending captures expire after 1.5 seconds. Images are RAM/GPU-only.
`captureEnabled = false` destroys front and pending captures and gates every
refresh entry point, so disabling hidden retention cannot silently refill buffers.
The Qt process and graphics resource pools can still retain memory.

**Limit:** title/size changes are observable, arbitrary off-screen application
pixel changes are not. `fresh` means the last acknowledged capture satisfies known
invalidations, not a universal content-version guarantee. Background content-only
updates can lag the sampling period; inaccessible/protected captures stay as
placeholders. This does not claim macOS WindowServer-level capture parity.

## Viewport lease and action priority

Hyprland 0.56 skips fully off-screen scrolling columns. `PreviewScheduler` may
request one covered recovery, but only after the overlay's first Qt frame and a
short compositor-fade settling period. It never uses the foreground action's
`busy` state. A click or drag cancels that lower-priority request.

The scheduler also requires the panel's actual screen to equal the focused monitor;
otherwise it cancels and cannot start a lease on an uncovered display.
The worker validates the active desktop/monitor, saves reference positions, scrolls
the covered viewport, and emits `frame-needed`. QML requests a new generation;
only its completion acknowledges the worker. No polling of a pre-existing buffer.
The frame wait is at most 750 ms. `finally` restores the **measured** offset and
waits for its return animation before releasing the lease or running queued input.
It refuses other monitors, other desktops, floating windows and untested directions.

The stdin reader stays responsive to cancellation while the executor waits. EOF /
graceful SIGTERM cancels the wait and allows cleanup. Forced process destruction,
compositor failure or external workspace changes can interrupt best-effort recovery;
there is no claim of transactional protection against SIGKILL.

## Request protocol and persistence

- Newline-delimited JSON on inherited pipes, protocol version 1.
- Monotonic request IDs; one in-flight transaction; duplicate/stale replies ignored.
- In-flight duplicates do not emit a premature completion for the original request.
- Frame and cancellation events carry that same request ID.
- Bounded packets, compositor replies, socket deadlines and state-lock waits.
- Worker failure fails the pending operation, backs off, and never replays a mutation.
- Existing address validation, workspace restrictions, confirmation and Undo remain.
- CLI and worker share the same transaction lock; desktop state is written only if
  its order changes. Capture and state queries never rewrite that JSON file.

## View model, search and settings

Main window delegates use the native stable toplevel model, not a newly filtered
JS array. Each maps its address to a filtered layout index; only in-layout cards
participate in hit testing. Search/scope changes do not destroy cards or captures.
Selection is address-stable across metadata updates and reorder. Packing, window
cards and desktop miniatures share `Layout.aspectFor`: captured dimensions first,
IPC dimensions only until a frame is available. Mixing those sources left holes
when IPC sizes lagged a resize. Valid portrait/ultrawide ratios are not clamped.
An aspect-ratio string separates geometry dependencies from title/focus updates.

The always-focused search TextInput handles Unicode/IME composition natively. The
shared key handler yields composition keys and briefly guards forwarded commit
keys. Search text keeps native caret/edit behavior; arrows/Tab otherwise navigate
cards. Modal settings/Quick Look block the drag surface. Focus returns to search
after transactions, drag cancellation and modal dismissal.

`Preferences.qml` is a Qt-only, tested settings state machine. Its FileView adapter
writes only the Overview's own versioned JSON using atomic replacement, with one
in-flight write and a coalesced pending patch. It waits for the actual saved signal,
preserves unknown keys, refuses malformed/newer files and reports write failures
without silent replay. Reloads wait until pending writes drain. Shutdown flushes
settings before quitting. Concurrent external edits are last-writer-wins, not a
multi-process transactional editor.

Palette integration reads three public scalar tokens from current `colors.toml`.
It does not depend on private Omarchy Shell APIs, start another helper, or mutate
compositor blur. The existing separate service/worker remain for fault isolation;
this revision is not an in-process Omarchy plugin migration.

## Verification and observability

Unit coverage includes stale-tab rejection, late frames, double buffering, source
replacement, cancellation/lease lifetime, late replies, protocol duplicates,
fragmented socket replies and measured-offset recovery on success/cancel/error.

A real disposable-window test changed green Tab A to blue Tab B, focused a distant
scrolling column, observed the old cache become invalid, then verified blue pixels
in Overview. The new generation was acknowledged and the viewport restored. User
windows were not closed or moved between desktops.

`overview status` exposes worker PID/restarts, completed requests, last transaction
time, per-window generations/freshness/timestamps, query/selection/Quick Look,
settings, delegate/retained-frame counts, live priorities, target layout rectangles
and actual hit-test surfaces, and `firstFrameMs`. Qt's first
rendered frame is separate from IPC availability and compositor presentation.
`tests/benchmark_open.py` does not claim to measure photons reaching the display.

Restart `sehun-overview.service` after code edits. Before reverting to the older
non-resident version, disable/stop the service as described in README.md.
