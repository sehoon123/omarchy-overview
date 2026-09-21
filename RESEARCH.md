# Mission Control interaction research

> Historical design notes. The background sampling, frame caching and viewport
> priming described below have been removed, and the measurements no longer match
> the shipped code. They are not current instructions or safety guarantees. The
> supported implementation captures each window natively, only while Overview is
> visible; see README.md and ARCHITECTURE.md. Do not restore the withdrawn
> compositor patch or the output-snapshot backend.

Reviewed Apple’s current Mac User Guide and the installed Hyprland 0.56.2 API
before implementation. This is an approximation, not an assertion of macOS parity.

## Apple sources

1. [View open windows and spaces in Mission Control](https://support.apple.com/guide/mac-help/see-open-windows-and-spaces-in-mission-control-mh35798/mac)
2. [Work in multiple spaces](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/mac)

Observed behavior in the guides:

- Mission Control presents windows from the current desktop in one layer, with
  Spaces and fullscreen/Split View applications along the top.
- Control-Up opens Mission Control; Control-Down shows an application's windows.
- Control-Left/Right moves between Spaces.
- Add a desktop with the Spaces bar's plus control, then select its thumbnail.
- Move a window by dragging it onto the desired Space's thumbnail.
- Removing a Space moves its windows elsewhere rather than closing them.
- macOS uses display-local Spaces, supports trackpad gestures and app assignments,
  and can create Split View by dropping onto fullscreen Space thumbnails.

## Applied here

The first six interactions above are implemented, keeping the requested compact,
wallpaper-backed UI. Added explicit drag cancellation, address-targeted moves,
confirmation polling, Undo, and persistent desktop ordering/empty placeholders.
A 550 ms hover previews another desktop; All keeps cross-desktop discovery available.
Desktop dragging changes the overview's saved order without renumbering Hyprland IDs.
To preserve orientation, opening prefers the previously focused window and reveals
its desktop in a long Spaces strip. Keyboard desktop navigation also reveals its
target; hover-preview does not unexpectedly scroll the strip beneath the pointer.

## Intentional boundaries

Fullscreen Spaces / Split View are compositor-specific, not just overview widgets.
This implementation leaves Hyprland's tiling, fullscreen and grouping semantics alone.
It does not install compositor plugins, repurpose existing gestures, or add hot corners.
Without a per-monitor plugin, normal desktops from multiple monitors remain
accessible. With Per-monitor Workspaces, the overview follows the opening display's
slots. See README.md for keyboard tradeoffs, persistence, and remaining limitations.

## Hyprland sources

- [Dispatchers](https://wiki.hypr.land/configuring/core/dispatchers/):
  `hl.dsp.window.move({ window, workspace, follow = false })` and
  `hl.dsp.focus({ workspace })`.
- [Window rules](https://wiki.hypr.land/configuring/core/rules/window-rules/):
  transient `exec_cmd` workspace rule for the disposable verification window.
- Installed Lua definitions: `/usr/share/hypr/stubs/hl.meta.lua`.

## Historical off-screen capture attempt (retired)

Hyprland 0.56.2's `CScreenshareManager::onOutputCommit` skips a window whose
current geometry has no intersection with its monitor. This explains blank
thumbnails for off-screen columns, including the Chromium window observed here:
https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/managers/screenshare/ScreenshareManager.cpp

Focusing a client while a keyboard-exclusive layer owns focus does not solve it.
The working correction scrolls the covered viewport through the documented
`hl.dsp.layout("move …")` interface and restores the measured offset in `finally`.
A stable address-keyed producer keeps the resulting frame after the column is
back off-screen. Real checks confirmed both Chromium previews, unchanged focus,
unchanged client positions and unchanged workspace membership after recovery.

The desktop strip also reserves 16 px at both ends for the outlines and close
buttons drawn outside the thumbnail bounds; hit testing respects the same clip.

## Historical resident/native-capture path (retired)

The initial design deliberately exited on close. Profiling showed this discarded
all captured frames and repeated both GUI setup and covered-viewport priming.
The performance revision uses a graphical-session user service, hides/unmaps the
UI on close, pauses continuous capture, and keeps frames until their windows close
or the process exits. A single IPC toggle reads the already-subscribed Hyprland
context. Natural focus changes can request one background frame without scrolling.

The residency revision first shortened the priming timer. The subsequent
architecture revision replaced periodic capture polling with an event-driven
PreviewScheduler, a resident stdio worker and direct local Hyprland IPC.
A queued UI action cancels the frame wait before viewport restoration. The
service's graceful stop waits for that restoration.

The stale-Chromium-tab report exposed a second issue: `hasContent` is not a frame
revision. Double-buffered, generation-tagged captures now invalidate changed
window titles/sizes and acknowledge a genuinely new frame. Metadata events,
focus boundaries and bounded active-window sampling keep the cache updated.
A disposable native-window test verified the change from green old-tab pixels to
blue new-tab pixels after moving the window fully off-screen. See ARCHITECTURE.md
for the exact validity contract and remaining compositor limitations.

No packaged files were modified.
