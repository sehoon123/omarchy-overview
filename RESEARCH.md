# Mission Control interaction research

> **Historical design notes. Nothing in this file is an instruction.**
>
> The sections below record what was investigated and, from "Historical
> off-screen capture attempt" onward, what was **built, measured and then
> removed**. Those approaches — output snapshots and screen crops, covered-viewport
> scrolling/priming, background sampling outside a visible session, cross-session
> frame caches, double-buffered generation-tagged frames, the resident-worker
> `prime` protocol and the custom compositor patch — **must not be reintroduced**.
> The measurements in them no longer match any shipped code, and no statement here
> is a safety guarantee.
>
> The supported implementation captures each window natively, only while Overview
> is visible. For current behavior read README.md and ARCHITECTURE.md; for the
> scope rules read AGENTS.md.

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
The desktop strip reserves 16 px at both ends for the outlines and close buttons
drawn outside the thumbnail bounds, and hit testing is clipped to the same
viewport. (That last detail is **still current**. It was previously filed under a
retired heading below; it is stated here so it cannot be read as part of the
removed work.)

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

## Historical off-screen capture attempt — REMOVED, do not reintroduce

One finding from this section is still current and is the reason today's
off-viewport cards say so instead of showing a substitute image: Hyprland 0.56.2's
`CScreenshareManager::onOutputCommit` skips a window whose current geometry has no
intersection with its monitor, which explains blank thumbnails for off-screen
columns, including the Chromium window observed here:
https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/managers/screenshare/ScreenshareManager.cpp

Everything that was built on top of that finding has been removed. Focusing a
client while a keyboard-exclusive layer owned focus did not solve it. The
correction that was tried scrolled the covered viewport through
`hl.dsp.layout("move …")` and restored the measured offset in `finally`, and an
address-keyed producer kept the resulting frame after the column went back
off-screen. Those checks did confirm both Chromium previews with unchanged focus,
positions and workspace membership — but moving a viewport to obtain a preview is
exactly what the current scope rules forbid, so **the scrolling/priming path, its
timer and its restore-in-`finally` handling no longer exist and must not come
back**. Overview now reports the missing frame instead.

## Historical resident/native-capture path — partly REMOVED

What survived from this revision: Overview is a resident graphical-session user
service that hides/unmaps its UI on close instead of exiting, a single IPC call
toggles it, and it reads already-subscribed Hyprland metadata rather than shelling
out for context.

What was removed and must not be reintroduced: the initial design exited on close,
and profiling that decision is what motivated keeping captured frames alive across
sessions and re-running covered-viewport priming — both gone. Capture now exists
**only** while a validated session is visible; nothing is kept after close, and a
natural focus change can no longer request a background frame. The event-driven
`PreviewScheduler`, the `prime` protocol on the resident worker, the queued-action
cancellation of a frame wait and the service stop that waited for a viewport
restoration have all been deleted; today's graceful stop only waits for Overview's
own shutdown handshake, which is bounded by a watchdog.

Also removed: the double-buffered, generation-tagged frame cache added after the
stale-Chromium-tab report (the observation behind it — that `hasContent` is not a
frame revision — was accurate), along with bounded active-window sampling and the
disposable off-screen native-window test that verified old-tab to new-tab pixels.
There is no cache to invalidate any more: each visible session builds fresh
streams and drops them on close. `keepCache` survives only as a preserved settings
key, and the `status` payload's `primed` and `cachedFrames` names are historical.
See ARCHITECTURE.md for the current contract and the remaining compositor
limitations.

No packaged files were modified.
