# Omarchy Overview

A standalone Quickshell overview for Hyprland: a window grid, desktop strip,
search, Quick Look, and explicit drag-and-drop desktop actions. It uses Omarchy's
public theme files without changing Omarchy Shell or the compositor.

## Preview behavior

**Previews are snapshots, not live window streams.** Before showing the panel,
Overview takes one `grim` screenshot of the selected **output**, in memory, and
crops unobscured visible window regions. It does not use `ScreencopyView`, native
toplevel export, automatic focus changes, workspace switching, or viewport
scrolling to obtain previews.

- Visible, unobscured windows get a new snapshot when Overview opens.
- Partly offscreen windows may show their visible portion, labeled accordingly.
- Covered/offscreen windows and other desktops show a matching previous snapshot
  or a readable title/app placeholder. **Not every window will have an image.**
- Snapshots retain their real aspect ratio. Placeholder cards use bounded ratios
  so unusual scrolling-layout geometry cannot collapse them into thin strips.
- Quick Look enlarges the same snapshot; it does not start a live stream.
- Images are kept only in memory, not screenshot files. The encoded cache is
  bounded to 8 MiB and 12 million image pixels. Disabling **Keep preview cache**
  releases it on close.
- Title, window size, process/identity changes invalidate mismatched images;
  topology changes clear the cache. A snapshot cannot track same-title content
  changes while Overview remains open.
- Snapshot errors/timeouts leave usable title cards. Lock/output safety failures
  or an open Omarchy authentication dialog cancel opening instead. Late helper replies cannot reopen a closed Overview.

### Why output snapshots?

Native **window** capture on Hyprland 0.56.2 was associated with a compositor crash
when a captured window lost its monitor. Merely enabling the old capture path or
checking monitor state on the client cannot remove that race.

This project now avoids that path. The earlier custom Hyprland patch/build files
have been removed, and their installation instructions are withdrawn. **No custom
Hyprland build, package replacement, or compositor restart is required.** Output
capture is a different path, not a claim that all compositor/hotplug bugs are fixed.

## Controls

| Input | Action |
| --- | --- |
| `Super` + backtick (existing integration) | Toggle Overview |
| Click a window / `Enter` | Activate that window and close |
| Arrow keys / `Tab` / `Shift+Tab` | Navigate windows spatially |
| `Ctrl+F` or typing | Search title, application, and desktop |
| `Space` on an empty search field | Quick Look snapshot |
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
`~/.config/omarchy/overview/settings.json`. Public theme tokens are
read from `~/.config/omarchy/current/theme/colors.toml`. Existing preference keys,
including the now-unused live-preview budget, are preserved rather than migrated
or overwritten. No custom code is injected into Omarchy Shell.

## Validation

```sh
./validate
# Opt-in: briefly displays its own staging overlay. Do not interact while running.
python3 tests/verify_output_snapshots.py --run
```

The default suite is offline: layout/search/settings/controller tests, synthetic
PPM→PNG crop and occlusion tests, lock/topology guards, actual PNG loading in Qt,
bounded-cache/identity tests, and mocked asynchronous cancellation/timeout tests.
It never removes a real output or tries to reproduce a compositor crash.

The opt-in check starts an isolated copy in this repository, verifies decoded PNG
previews, Quick Look, settings, and zero native capture views, then checks that
application geometry, desktop assignments, focus, and compositor version are
unchanged. It writes no screenshot files. Older native-capture experiments and
full-window-readiness benchmarks are not valid acceptance tests for snapshots.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the implementation and scope boundaries.
