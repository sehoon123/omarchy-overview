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
- Live updates are prioritized (selection and Quick Look first) and bounded by the
  **Live window previews** setting, 32 concurrent streams, and a scaled-pixel cap.
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
| `Ctrl+F` or typing | Search title, application, and desktop |
| `Space` on an empty search field | Quick Look the selected window |
| `Esc` | Close preview/settings, clear search, then close Overview |
| Drag window → desktop | Move that window |
| Drag window → `+` | Create a desktop and move the window there |
| Drag desktop → desktop | Reorder desktops |
| `Ctrl` + drag desktop → desktop | Move its windows to another desktop |
| Click desktop `×` / drag desktop → remove area | Remove desktop; move, never close, its windows |
| `Ctrl+Z` or Undo | Undo the most recent supported desktop action |
| `Ctrl+,` / gear | Open settings |

With `hyprland-workspace-desktops`, the strip follows the current monitor's named
slots, including empty slots. Named workspaces use `name:<name>` selectors, never
Hyprland's transient negative IDs. Generic named/numeric workspaces remain
supported when that plugin is absent. Capture itself never modifies a desktop.

## Install and run

See [INSTALL.md](INSTALL.md). Existing installations keep their settings and
keybinding. The application files live at `~/.config/omarchy/overview`; its resident
user service is `sehun-overview.service`.

```sh
omarchy-overview           # Toggle
omarchy-overview --app     # Current application
quickshell ipc -p ~/.config/omarchy/overview call overview status
```

Open settings with the gear or `Ctrl+,`. Preferences are in
`~/.config/omarchy/overview/settings.json`. Public theme tokens are read from
`~/.config/omarchy/current/theme/colors.toml`. Existing preference keys are
preserved rather than migrated or overwritten. No custom code is injected into
Omarchy Shell.

## Validation

```sh
./validate
# Opt-in: briefly displays its own staging overlay. Do not interact while running.
python3 tests/verify_native_previews.py --run
```

The default suite is offline: layout/search/settings/controller tests, capture
lifecycle tests against a synthetic stream (creation only while enabled, shared
texture for card/desktop/Quick Look, source nulled before destruction, no retry
storm, identity continuity across search and reorder), read-only lock/output
guard tests, and offscreen Qt/QML rendering tests. It never removes a real output
and never tries to reproduce a compositor crash.

The opt-in check starts an isolated staging copy of this repository, waits for
live native frames, verifies that Quick Look and search reuse the same capture
sources, and that closing releases every capture, then confirms that window
geometry, desktop assignments, focus and the compositor process are unchanged.
`tests/verify_ui.py` covers keyboard/IME and settings behavior the same way.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the implementation and scope boundaries.
