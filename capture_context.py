#!/usr/bin/env python3
"""Read-only opening/security check. No pixels, dispatchers, or capture subprocess.

Fails **closed** on anything it cannot read with certainty: a field of an
unexpected type refuses the open (or drops that one output) instead of reaching
`main()`'s blanket `except` as a traceback, and instead of emitting a
plausible-looking geometry (AUDIT F-32/F-33). Unreadable lock state still
refuses, but it no longer claims the session is locked (AUDIT F-52).

Reasons are distinguishable on purpose — `shell.qml` shows them verbatim:
  * "Display state unavailable"          — the reply's shape is not a display list
  * "Display state could not be verified" — a field this check needs is unreadable
  * "Session locked or lock state unavailable" — Hyprland reports LOCK
  * "Authentication or lock dialog is open"    — a lock/auth layer on any output
  * "Selected display is unavailable"    — the requested output is not usable
  * the transport's own bounded message  — Hyprland unreachable/late/unreadable

Worst case is two read-only queries, each with its own 0.3 s wall-clock budget
(`hypr_ipc.call` spends one budget per call), so ~0.6 s of socket waiting plus
`python3` start-up; the caller's deadline lives with the `OpenGuard` instance.
"""
import json
import math
import sys

import hypr_ipc

LOCK_NAMESPACES = ('omarchy-polkit', 'hyprlock', 'swaylock', 'gtklock', 'omarchy-lockscreen')
TRANSFORMS = range(8)


def refuse(reason):
    return {'ok': False, 'reason': reason}


def number(value):
    """A real number from JSON. `True` is not a scale, a size or a position."""
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def whole(value):
    """A real integer from JSON; `bool` is an `int` in Python but not an id here."""
    return isinstance(value, int) and not isinstance(value, bool)


def usable(monitor):
    """Can this output be described to the shell exactly, or not at all?

    `id` is required because `OverviewLogic.captureReason()` matches the helper's
    outputs on name **and** id: an output emitted with `id: null` matches nothing
    and silently kills every preview for the whole session (AUDIT F-33).
    """
    name = monitor.get('name')
    transform = monitor.get('transform', 0)
    return (isinstance(name, str) and bool(name) and not name.startswith(('HEADLESS-', 'FALLBACK'))
            and not monitor.get('disabled') and bool(monitor.get('dpmsStatus'))
            and whole(monitor.get('id')) and whole(transform) and transform in TRANSFORMS
            and all(number(v) and v > 0 for v in [monitor.get('scale', 0),
                                                  monitor.get('width', 0), monitor.get('height', 0)])
            and all(number(monitor.get(axis)) for axis in ('x', 'y')))


def blocked(monitor):
    """Lock verdict for one output, or '' when nothing blocks the open."""
    blockers = monitor.get('solitaryBlockedBy')
    if not isinstance(blockers, list) or not all(isinstance(value, str) for value in blockers):
        # Still fail closed, but do not call an unreadable field a locked session.
        return 'Display state could not be verified'
    if 'LOCK' in blockers:
        return 'Session locked or lock state unavailable'
    # Hyprland's direct-scanout diagnostic, not a lock API: refuse, do not diagnose.
    return 'Display state could not be verified' if 'WORKSPACE' in blockers else ''


def lock_layer(layers):
    """'' unless a visible lock/auth surface exists on ANY output, or the reply
    cannot be read — an unreadable layer list must never read as "no lock"."""
    for output in layers.values():
        if not isinstance(output, dict):
            return 'Display state could not be verified'
        levels = output.get('levels', {})
        if not isinstance(levels, dict):
            return 'Display state could not be verified'
        for level in levels.values():
            if not isinstance(level, list):
                return 'Display state could not be verified'
            for layer in level:
                if not isinstance(layer, dict) or not isinstance(layer.get('namespace', ''), str):
                    return 'Display state could not be verified'
                alpha = layer.get('alpha', 1)
                # An alpha this check cannot read counts as opaque, never as hidden.
                if number(alpha) and alpha <= .001:
                    continue
                if layer.get('namespace', '') in LOCK_NAMESPACES:
                    return 'Authentication or lock dialog is open'
    return ''


def check(monitors, layers, name):
    if not isinstance(monitors, list) or not monitors or not isinstance(layers, dict):
        return refuse('Display state unavailable')
    outputs = []
    for monitor in monitors:
        if not isinstance(monitor, dict):
            return refuse('Display state unavailable')
        lock = blocked(monitor)
        if lock:
            return refuse(lock)
        if not usable(monitor):
            continue
        # Hyprland reports x/y logically and width/height physically; rotation is
        # applied before the scale division (2560x1600 @1.6 -> 1600x1000).
        size = [monitor['width'], monitor['height']]
        if monitor.get('transform', 0) % 2: size.reverse()
        scale = monitor['scale']
        outputs.append({'name': monitor['name'], 'id': monitor['id'], 'scale': scale,
                        'x': monitor['x'], 'y': monitor['y'],
                        'width': size[0] / scale, 'height': size[1] / scale})
    lock = lock_layer(layers)
    if lock:
        return refuse(lock)
    if not any(output['name'] == name for output in outputs):
        return refuse('Selected display is unavailable')
    return {'ok': True, 'outputs': outputs}


def inspect(name, call=None):
    # Late-bound on purpose: `inspect.__defaults__` must not pin `hypr_ipc.call`,
    # so a test can inject a mock and never reach a live compositor.
    call = call or hypr_ipc.call
    return check(call('monitors', json_output=True, timeout=.3),
                 call('layers', json_output=True, timeout=.3), name)


def main():
    try:
        result = inspect(sys.argv[1]) if len(sys.argv) == 2 else refuse('Display name required')
    except (hypr_ipc.Unreachable, hypr_ipc.Unreadable, hypr_ipc.ReplyTimeout) as error:
        # These messages are fixed literals: no path, no errno, no reply content.
        result = refuse(str(error))
    except Exception:
        # Last resort only: a traceback must never be the user's only signal.
        result = refuse('Cannot verify capture context')
    print(json.dumps(result, separators=(',', ':')), flush=True)


if __name__ == '__main__': main()
