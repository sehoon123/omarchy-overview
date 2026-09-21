# Omarchy Overview

A standalone Quickshell overview for Hyprland: an Exposé-style window spread, a
desktop strip, search, Quick Look, and explicit drag-and-drop desktop actions. It
uses Omarchy's public theme files without changing Omarchy Shell or the compositor.

## Preview behavior

**Previews are real window images.** While Overview is visible, each card owns one
native Wayland capture of its own window (`ScreencopyView`), so cards show the
actual window content at its real aspect ratio — not a screenshot of the display
cropped into rectangles.

- Cards expand from each window's position on the current display and shrink back
  when you leave, so selection stays spatial like macOS Exposé.
- The window grid, desktop strip and Quick Look share **one** capture per window.
  Searching, reordering or opening Quick Look never rebuilds capture objects.
- Captures exist only in a validated, visible session. Closing Overview disables
  every source, destroys the objects and drops the images; nothing captures in
  the background, and there is no cross-session image cache.
- How many captures a session creates is bounded by whichever limit binds first:
  32 concurrent streams or 64 million scaled pixels in total. A single window
  whose own scaled area is above 16 million pixels is not captured at all. In
  practice the pixel budget is what binds — about 15 full-screen windows on a
  2560x1600 display at scale 1.6 — and the 32-stream cap is never reached. The
  budget is filled in priority order (Quick Look, the dragged window, the
  selection, then the grid), and a window that does not fit the remaining budget
  is skipped, so a smaller window behind it may take its place. Skipped cards say
  `Preview budget reached`.
- The **Live window previews** setting limits how many of those captures keep
  *updating*, not how many exist. Its default is every displayed window.
- Windows on other desktops or behind other windows still get their own image.
- Images stay in RAM only: no screenshot files, logs, clipboard or external
  services.

### Known limitation

On Hyprland 0.56.2 a window that is entirely outside its display's viewport, e.g.
scrolled far out of a scrolling layout, may never produce a frame. Those cards
stay selectable and say so instead of showing a substitute image. Overview does
**not** scroll the viewport, switch desktops, or move focus to obtain a preview.

Native window capture on this version is also associated with a compositor crash
when a captured window loses its monitor. Overview limits exposure by capturing
only while visible and releasing sources on monitor/topology changes, but this is
a client-side lifecycle guard, **not** a compositor fix and not a guarantee for
display hotplug.

## Controls

| Input | Action |
| --- | --- |
| `Super` + backtick (existing integration) | Toggle Overview |
| Click a window / `Enter` | Activate that window and close |
| Arrow keys / `Tab` / `Shift+Tab` | Navigate windows spatially |
| `Ctrl+F` or typing | Search title, application class, and desktop name |
| `Space` on an empty search field, or `Ctrl+Space` | Quick Look the selected window |
| `Esc` | Cancel a drag, close settings, close Quick Look, clear search, then close Overview — in that order |
| `Ctrl+Left` / `Ctrl+Right` | Show the previous/next desktop in this Overview session |
| Drag window → desktop | Move that window |
| Drag window → `+` | Create a desktop and move the window there |
| Drag desktop → desktop | Reorder desktops |
| Click a desktop | Switch to it and close |
| Click desktop `×` (appears on hover) | Remove desktop; move, never close, its windows |
| Click `All` | Show every desktop's windows |
| Click the background | Close Overview, switching to the filtered desktop if one is selected |
| Click `×` at the right of the strip | Close Overview |
| Wheel over the desktop strip | Scroll the strip |
| `Ctrl+Z` or the toast's Undo | Undo the most recent supported desktop action |
| Click **Settings** (bottom right) | Open settings |

There is no keyboard shortcut for settings, and no drag target that removes a
desktop. A desktop drag only reorders: moving one desktop's windows in bulk is not
an action Overview offers. While the search field holds text, `Left`/`Right` stay
with the text cursor; `Ctrl+Left`/`Ctrl+Right` and `Ctrl+Space` are unaffected by
it. Keys other than `Esc` are ignored while settings are open, a desktop action is
running, or a drag is in progress. `showSettings` is also available over IPC.

With `hyprland-workspace-desktops`, the strip follows the current monitor's named
slots, including empty slots. Named workspaces use `name:<name>` selectors, never
Hyprland's transient negative IDs. Generic named/numeric workspaces remain
supported when that plugin is absent. Capture itself never modifies a desktop.

## Install and run

See [INSTALL.md](INSTALL.md). Existing installations keep their settings and
keybinding. The application files live at `~/.config/omarchy/overview`; its resident
user service is `sehun-overview.service`.

```sh
omarchy-overview               # Toggle
omarchy-overview --app         # Current application
omarchy-overview --next        # Next desktop (Overview's filter if it is open)
omarchy-overview --previous    # Previous desktop
quickshell ipc -p ~/.config/omarchy/overview call overview status
```

Every IPC call answers: `ok` when the request was accepted, otherwise a one-word
reason it was refused (`invalid`, `shutdown`, `closing`, `shown`, `opening`,
`hidden`, `busy`, `dragging`, `settings`, `activating`, `empty`, `unavailable`).
A refusal has no side effect, so the launcher only falls back to a real workspace
switch when Overview is not running or answered `unavailable`.

Open settings with the **Settings** button at the bottom right of the window grid.
Preferences are in `~/.config/omarchy/overview/settings.json`. Public theme tokens are read from
`~/.config/omarchy/current/theme/colors.toml`. Existing preference keys are
preserved rather than migrated or overwritten. No custom code is injected into
Omarchy Shell.

## Validation

```sh
./validate
```

`./validate` is the whole default suite and is entirely offline: it parses every
QML file, runs two Node suites, the Python unit tests and the offscreen/software
Qt test cases. It opens no window, starts no worker or helper process, and talks
to neither Hyprland nor Quickshell. It currently covers:

- open/close/shutdown/activation guards, including a shutdown that always
  terminates and a close animation that can only finish its own session;
- the IPC guard-return matrix — every handler's reply in every state, and that a
  reply other than `ok` never has a side effect;
- the `status` payload's exact shape and key order, and that it carries no window
  title, application class, file path, URL or pixel data;
- capture eligibility and the stream/pixel budget, including the greedy fill and
  the per-window bound;
- capture object lifecycle and identity against a synthetic stream: nothing is
  created while disabled, card/desktop/Quick Look share one source, release nulls
  the source before destruction, a stopped stream is never retried, and a reused
  address never inherits another window's image;
- opening-helper protocol failures: late, duplicate, oversized and malformed
  replies, distinct refusal reasons, and a helper that never reports its exit;
- the worker protocol client: framing, one request in flight, no replay after
  worker loss, capped restart backoff, and a per-request reply timeout;
- settings validation and persistence, including unreadable and newer documents,
  a read-only file, and preserved unknown keys;
- the Python guard paths — malformed or missing compositor fields, transport
  failures, corrupt saved desktop order, and bounded error text;
- layout geometry at degenerate and extreme sizes and aspect ratios, plus the
  card, desktop-strip and input components.

It never removes a real output and never tries to reproduce a compositor crash.

Three further checks are **opt-in only** and are **not** part of `./validate`.
Each one drives a real, visible Overview or real desktop actions, so run them
deliberately and do not interact with the desktop while they run:

```sh
# Stages its own copy of this repository, displays it briefly, then stops it.
python3 tests/verify_native_previews.py --run

# Needs a staging copy under /tmp that is already running, plus wtype and fcitx5.
python3 tests/verify_ui.py --run --config /tmp/<staging-copy>

# Needs a disposable window of class `overview-verification` on desktop 90,
# which you create; it performs real desktop actions and closes that window.
python3 tests/verify_live.py
```

`verify_native_previews.py` waits for live native frames, verifies that Quick
Look and search reuse the same capture sources and that closing releases every
capture, then confirms that window geometry, desktop assignments, focus and the
compositor process are unchanged. `verify_ui.py` covers keyboard/IME and settings
behavior the same way against an already-staged copy. `verify_live.py` exercises
create/move/undo/remove/reorder and desktop-order persistence through
`controller.py` and asserts that no other window changed desktop.

Neither the offline suite nor the three opt-in checks can establish display
hotplug or crash safety, and they must not be read as evidence that the
compositor defect described under **Known limitation** is fixed.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the implementation and scope boundaries.
