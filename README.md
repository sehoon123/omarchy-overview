# Omarchy Overview

Mission Control-style window and desktop overview for Omarchy's Lua-based
Hyprland. English UI, Korean-capable search, shared live previews and a resident
user service for fast reopening. No compositor plugin or packaged file changes.

**[Installation](INSTALL.md)** · **[Architecture](ARCHITECTURE.md)** · **[Design research](RESEARCH.md)**

> **Capture safety hold (2026-09-21):** window previews are currently disabled to
> avoid a confirmed Hyprland 0.56.2 output-removal crash. Navigation still works.
> The previously local-only guard is now tracked here. See the
> [compositor patch, validation and activation instructions](integrations/hyprland/README.md).
> Installing the patched package does not replace the running compositor or
> automatically re-enable previews. Capture/cache descriptions below document
> the underlying implementation; the safety hold takes precedence, and the
> `keepCache` setting currently cannot enable hidden capture or retain frames.

This repository contains the working implementation, tests, launcher and service.
It does not include personal preferences, wallpapers, screenshots, desktop state
or local backups. See INSTALL.md for compatibility requirements and setup.

## Search, Quick Look and preferences

- Type to filter the current scope by window title, app class or desktop label.
  Search is literal, case-insensitive, whitespace-separated AND matching with
  Unicode normalization. Click **All** to search across desktops.
- The search field is a real Qt TextInput, including fcitx5 Korean composition,
  selection, paste and caret editing. IME commit/cancel keys never intentionally
  activate a window. Enter with no search results does nothing.
- **Space** with an empty search, or **Ctrl+Space** with a query, opens Quick Look.
  Arrows/Tab browse, Enter activates, Space/Esc returns. It reuses the same capture
  and prioritizes a single stream, not a second set of native captures.
- **Settings** at bottom right controls Omarchy palette colors, wallpaper blur and
  dimming, layout animation, monitor filtering, live stream budget and cache retention.
  English labels and the minimal wallpaper-based desktop strip remain.
- Default live budget is **6**, with selected-only (1) and live (12) alternatives.
  Selection/drag/Quick Look get priority; duplicate addresses do not waste slots.
- Disable **Keep previews in memory when closed** to release capture buffers on
  close and stop hidden sampling. Reopening then requires fresh captures. The Qt
  process/graphics resource pools remain resident; this is not a hard RAM byte cap.
- Settings are atomically saved to `settings.json` beside `shell.qml`. Writes are
  serialized and rapid edits coalesce. Unknown keys survive; malformed or newer
  documents are not overwritten. External edits reload while the writer is idle;
  avoid editing the same file externally during a UI write (last writer wins).
  The shared Omarchy `shell.json` is never changed.
- Palette tokens `accent`, `background`, `foreground` are read from the current
  theme's `colors.toml`, with safe fallbacks. This does not import private Shell
  modules or modify global Hyprland blur settings.
- Window delegates stay attached to Hyprland's stable source model when searching
  or filtering. Geometry is keyed by aspect ratios, not title/focus churn.

## Fast opening and cache lifecycle

`sehun-overview.service` starts hidden with the graphical session. Closing the
UI unmaps its layer and releases keyboard focus. QML stays resident; window frames
stay in memory by default, unless cache retention is disabled. Reopening uses one IPC request rather than restarting Quickshell,
reloading the wallpaper and gathering context through several CLI processes.

- Hidden Overview has no input-capturing layer. With cache retention enabled,
  the naturally activated window is sampled every 400 ms; title/size and focus
  changes also request refreshes.
  This is bounded background work, not a zero-work or full-rate-video design.
- Valid cached frames appear immediately. A changed title/size invalidates the
  old image; `Refreshing preview…` is shown instead of a different tab's pixels.
- Double buffering retains the front frame until a new, generation-tagged capture
  completes. Older in-flight frames cannot satisfy a newer content revision.
- Preview recovery is event-driven and lower priority than user actions. Only
  the main/drag windows receive continuous live updates (6 by default, at most 12).
- Navigation and drag feedback remain available during first-time priming. A
  click/action is queued, requests cancellation of priming, and executes after
  the covered viewport is restored; it is not silently discarded.
- Capture waits are event-driven and bounded to 750 ms; no per-frame CLI polling.
  Changed/uncached off-screen windows may still need preparation. This is not
  compositor-native macOS capture, and off-screen video is not always live.
- Cache is **RAM only**, not image files. Frames are freed when their window
  closes or the service stops/logs out, and on hide if cache retention is disabled.
- Tradeoff: resident native capture buffers consume RAM/GPU memory; usage depends
  on window count and native resolution. The stream cap is not a hard byte limit.
- One resident Python worker handles workspace transactions through Hyprland's
  local socket. UI requests have IDs, cancellation and no mutation replay.
  Read-only state requests no longer rewrite desktop-order files.

The earlier residency revision measured 94–102 ms warm IPC readiness versus
1,579 ms per cold launch. Those were not physical display-presentation timings.
`status.firstFrameMs` now separately measures the first Qt-rendered frame since
opening; it still excludes compositor presentation/animation latency.
See **ARCHITECTURE.md** for ownership, freshness guarantees and limitations.

```sh
systemctl --user restart sehun-overview.service  # reload code / clear cache
systemctl --user stop sehun-overview.service    # release all cached images
# The normal shortcut starts it again if stopped.
```

## Controls

| Control | Action |
| --- | --- |
| Super + backtick / Ctrl + Up | Toggle Mission Control |
| Ctrl + Down | Toggle App Expose for the previously focused application |
| Ctrl + Left / Right | Previous / next desktop in the saved order |
| Hover a desktop for 550 ms | Preview its windows without leaving Overview |
| Click a desktop | Switch to it and exit Overview |
| Click All | Show windows from all normal desktops |
| Click a window / Enter | Focus the window and exit |
| Type / Ctrl + F | Search windows in the current scope |
| Arrow keys / Tab | Select windows; Left/Right edit the caret when a query is present |
| Space / Ctrl + Space | Quick Look; Ctrl + Space also works with a search query |
| Settings (bottom right) | Appearance, monitor scope, live budget and cache retention |
| Drag a window onto a desktop | Move it there, without leaving Overview |
| Drag a window onto + | Create a desktop and move the window there |
| Click + | Create an empty desktop; remain in Overview |
| Drag a desktop onto another desktop | Move it to that position in the strip |
| Hover a desktop, click its small x | Remove desktop; move its windows to a neighbor |
| Click Undo / Ctrl + Z inside Overview | Undo the last window move or desktop removal |
| Esc while dragging | Cancel drag without moving anything |
| Esc | Cancel composition/drag, close settings/Quick Look, clear search, then exit |
| Top-right x | Exit Overview |
| Click empty background | Open the currently previewed desktop and exit |
| Wheel over desktop strip | Scroll the strip; dragging near its ends also scrolls |

**Ctrl + Left/Right are global desktop shortcuts**, replacing application-level
word navigation with those chords, like macOS. Remove those two bindings from
`~/.config/hypr/bindings.lua` if you prefer Linux text-editing shortcuts.
Within Overview they preview adjacent desktops without closing the overview.

Overview opens on the current desktop, or on the current application's windows
when using App Expose. Initial keyboard selection prefers the previously focused
window, so Enter/Quick Look start where you were working. The desktop strip
reveals the current desktop on opening and keeps Ctrl+Left/Right destinations
visible, even in long lists. Hover-preview and All are convenience extensions.
Window titles remain in the language supplied by applications.

## Per-monitor workspaces

The `mmsbrggr.per-monitor-workspaces` widget is detected from Omarchy's
`shell.json`; no extra Overview setting or keybinding change is needed.
The strip, All/App Expose and previous/next navigation stay on the opening
monitor (the focused monitor when Overview is closed). Empty configured slots
are included and labelled Desktop 1…N. Parked desktops remain reachable.

Window moves, Undo and saved ordering use stable workspace names, not Hyprland's
recycled negative IDs. **+** adds an extra slot on this monitor. Configured slots
cannot be removed here; change the widget's `count` setting instead. Extra slots
can be removed normally. Numbered and other named workspaces still work without
the widget; existing numbered desktop order is preserved.

## Safety and semantics

- Dragging uses a stable mouse grab and an independent ghost. Hovering another
  desktop can rebuild its thumbnails without losing the dragged window.
- Drops outside a destination and Esc cancel the drag. No movement occurs until drop.
- Actions target an explicit window address, never whichever window happens to be focused.
- The controller confirms changes with Hyprland before reporting success.
- Removing a desktop **never closes its applications**. Its windows move to the
  previous desktop (or the next when removing the first). At least one is kept.
- Desktops pinned by a Hyprland persistent rule cannot be removed here.
- Undo skips windows closed or manually moved again outside Overview. Undo restores
  desktop membership, not exact tiling positions or column widths.
- Hyprland's native grouping behavior still applies: moving a grouped window can
  move its group. The moved group members are included in Undo.
- Desktop order and empty desktop placeholders survive restarts in
  `~/.local/state/omarchy/overview/desktops.json`. Empty placeholders become real
  Hyprland workspaces when visited or when a window is dropped there.
- Reordering does not renumber Hyprland workspaces or change Super + number bindings.
- Special/scratchpad workspaces are excluded by name, not by the sign of their ID.
  Without the per-monitor widget, normal desktops on other monitors remain accessible.
- Capture producers are shared and keyed by window address, so desktop previews,
  the main view and drag ghosts retain the same last frame across model resets.
- Hyprland 0.56 skips captures of fully off-screen scrolling windows. For the
  current horizontal scrolling desktop, Overview briefly scrolls the viewport
  behind its opaque overlay to seed a missing frame, then restores the measured
  scroll offset. The exclusive keyboard layer remains focused throughout.
- Recovery is permitted only when the actually covered screen is still the focused
  monitor. Moving the pointer to another monitor cannot start an uncovered lease.
- This recovery is bounded, attempted once per window/content tag per opening, and
  never changes desktop membership or deliberately focuses applications. Other
  monitors and untested scrolling directions are not disturbed.
- Off-screen previews retain their last frame; they are not necessarily live
  until visible on the real desktop again. Frames exist only in this process's
  memory until the window closes or the resident service stops; never on disk.
- Capture support still depends on the compositor and application; genuinely
  unavailable thumbnails use a placeholder. Private/protected restrictions are
  not bypassed.

## Not implemented

This is not a replacement compositor. macOS-specific fullscreen Spaces, dragging
onto a fullscreen Space to create Split View, Dock assignment menus, native
trackpad/hot-corner integration, and dragging a real desktop window to the screen
top to enter Mission Control are not reproduced. Existing Hyprland fullscreen,
scrolling/dwindle layouts, groups, and gestures remain in control.

## Files

- `shell.qml`: overview, shared input policy, stable window delegates and interactions
- `SearchBar.qml`, `SettingsPanel.qml`: IME-capable search and local preferences UI
- `Preferences.qml`, `OverviewLogic.js`: serialized settings state, filtering and palette policy
- `WindowPreview.qml`, `DesktopPreview.qml`: shared thumbnail visuals
- `CaptureBank.qml`, `CaptureProducer.qml`, `FrameCache.qml`: stable, double-buffered captures
- `PreviewScheduler.qml`: cancellable, event-driven preview leases
- `BackendClient.qml`, `worker.py`: resident request/response transport
- `hypr_ipc.py`, `preview.py`: direct compositor IPC and covered viewport recovery
- `DragSurface.qml`: stable pointer/drag state machine
- `Layout.js`: aspect-preserving layout and spatial keyboard navigation
- `controller.py`: validated workspace actions, persistence, confirmation, Undo
- `workspaces.py`: stable selectors and optional per-monitor slot/monitor catalog
- `integrations/omarchy-overview`: launcher installed to `~/.local/bin/`
- `integrations/sehun-overview.service`: session-scoped user service
- `integrations/bindings.example.lua`: optional shortcuts; not a full desktop config
- `RESEARCH.md`: Apple references and implementation decisions

After editing QML, restart `sehun-overview.service`; closing the UI no longer
exits the process. The next opening rebuilds its memory cache.

## Tests

Run `~/.config/omarchy/overview/validate` for all headless checks (no compositor
changes), or run them individually:

```sh
node ~/.config/omarchy/overview/Layout.test.js
node ~/.config/omarchy/overview/OverviewLogic.test.js
python -m unittest discover -s ~/.config/omarchy/overview/tests -p 'test_*.py' -v
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner \
  -input ~/.config/omarchy/overview/tests -o -,txt
```

`tests/verify_ui.py --run --config /tmp/<staging-config>` is a visible, opt-in UI
smoke test against a separately running staging copy, never the installed config.
It checks real fcitx5 Korean composition/cancellation, stable search delegates,
Quick Look, settings persistence and cache release/rebuild. It saves diagnostic
screenshots only in that temporary directory and verifies that application focus,
positions, sizes and desktop membership remain unchanged. Do not interact with
the desktop while it runs.

`python tests/benchmark_open.py --cold` is an opt-in visible benchmark. It restarts
the service and opens/closes Overview four times. Do not interact with the desktop
while measuring. It reports IPC/readiness and the first Qt frame, not actual
compositor presentation.

`python tests/verify_freshness.py --run` is a visible, opt-in pixel regression test.
It requires an unused workspace 90, briefly switches desktops, creates only its
own four test windows, changes a green Tab A to a blue Tab B, moves it off-screen,
and verifies actual preview pixels. Cleanup closes only the fixture, restores the
original desktop, and reloads Hyprland to clear its temporary workspace rule.
Do not run it while interacting with the desktop or editing Hyprland settings.

`tests/verify_live.py` is an opt-in compositor integration test. It requires a
disposable window with app ID `overview-verification` on workspace 90 and unused
workspaces 91/92. It follows the active numeric/per-monitor mode when creating
destinations, uses isolated state, checks that other windows stay on their
original desktops, and closes only its disposable test window in cleanup.

## Rollback / removal

See [INSTALL.md](INSTALL.md#update-or-remove). Stop the service before restoring a
backup or an earlier Git revision. Preserve your own `settings.json` and the
separate desktop-order state unless you intentionally want to reset them. Named
orders use state version 2 (version 1 numeric state is still read); rolling back
to a pre-named-workspace release also requires restoring its state backup. Never
replace your entire Hyprland bindings file to remove this application's shortcuts.
