#!/usr/bin/env python3
"""Read-only OUTPUT snapshots for stock Hyprland; never capture a toplevel.

One bounded grim process before Overview maps. Crop only visible, unobscured
window regions. No files, focus/viewport changes, background polling or third-
party Python packages. Images are returned as bounded, in-memory PNG data URLs.
"""
import base64
import json
import math
import os
import selectors
import signal
import struct
import subprocess
import sys
import time
import zlib

import hypr_ipc

MAX_PIXELS = 1_800_000
MAX_PPM = MAX_PIXELS * 3 + 1024
MAX_URL_BYTES = 6 * 1024 * 1024
MAX_FRAMES = 24


class Unavailable(Exception):
    def __init__(self, reason, blocked=False):
        super().__init__(reason)
        self.blocked = blocked


def read_scene():
    return {key: hypr_ipc.call(key, json_output=True, timeout=.35)
            for key in ('monitors', 'clients', 'layers')}


def monitor_context(scene, name):
    monitors = scene['monitors']
    if not monitors or any('LOCK' in (m.get('solitaryBlockedBy') or []) for m in monitors):
        raise Unavailable('Session locked or outputs unavailable', blocked=True)
    monitor = next((m for m in monitors if m.get('name') == name), None)
    if (not monitor or not name or name.startswith(('HEADLESS-', 'FALLBACK'))
            or monitor.get('disabled') or not monitor.get('dpmsStatus', False)):
        raise Unavailable('Output unavailable')
    blockers = monitor.get('solitaryBlockedBy')
    if not isinstance(blockers, list) or 'WORKSPACE' in blockers:
        raise Unavailable('Session lock state unavailable', blocked=True)
    scale = monitor.get('scale', 0)
    if not isinstance(scale, (int, float)) or not math.isfinite(scale) or scale <= 0:
        raise Unavailable('Invalid output scale')
    width, height = monitor['width'], monitor['height']
    if monitor.get('transform', 0) % 2:
        width, height = height, width
    bounds = (monitor['x'], monitor['y'], width / scale, height / scale)
    if not all(math.isfinite(v) for v in bounds) or min(bounds[2:]) <= 0:
        raise Unavailable('Invalid output geometry')
    return monitor, bounds


def intersection(a, b):
    x, y = max(a[0], b[0]), max(a[1], b[1])
    right, bottom = min(a[0] + a[2], b[0] + b[2]), min(a[1] + a[3], b[1] + b[3])
    return (x, y, right - x, bottom - y) if right > x and bottom > y else None


def geometry(window):
    at, size = window.get('at', []), window.get('size', [])
    values = [*at, *size]
    if len(values) != 4 or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in values):
        return None
    return tuple(values) if min(size) > 0 else None


def overlays(scene, name):
    levels = scene['layers'].get(name, {}).get('levels', {})
    return [layer for level in ('2', '3') for layer in levels.get(level, [])
            if layer.get('alpha', 1) > .001]


def above(other, window):
    # Fullscreen/pinned stacking is not reliably described by IPC focus history.
    # For an overlapping fullscreen pair, omit both rather than mislabel pixels.
    if other.get('fullscreen') or window.get('fullscreen'):
        return True
    # Floating windows stay above ordinary tiles even when a tile is focused.
    if bool(other.get('floating')) != bool(window.get('floating')):
        return bool(other.get('floating'))
    a, b = other.get('focusHistoryID', -1), window.get('focusHistoryID', -1)
    return a < 0 or b < 0 or a <= b


def candidates(scene, name):
    monitor, bounds = monitor_context(scene, name)
    if any(layer.get('namespace') == 'omarchy-polkit'
           for output in scene['layers'] for layer in overlays(scene, output)):
        raise Unavailable('Authentication dialog is open', blocked=True)
    layers = overlays(scene, name)
    if any(str(layer.get('namespace', '')).startswith('sehun-overview') for layer in layers):
        raise Unavailable('Overview is already on screen', blocked=True)
    if monitor.get('specialWorkspace', {}).get('id', 0):
        return []
    active = monitor['activeWorkspace']['id']
    visible = [w for w in scene['clients'] if w.get('mapped') and w.get('visible', True)
               and not w.get('hidden') and w.get('monitor') == monitor['id']
               and (w.get('workspace', {}).get('id') == active or w.get('pinned')) and geometry(w)]
    result = []
    for window in sorted(visible, key=lambda w: w.get('focusHistoryID', 999)):
        rect = geometry(window)
        crop = intersection(rect, bounds)
        if not crop or min(crop[2:]) < 32 or crop[2] * crop[3] < rect[2] * rect[3] * .25:
            continue
        if any(intersection(crop, (l['x'], l['y'], l['w'], l['h'])) for l in layers):
            continue
        if any(other is not window and above(other, window) and intersection(crop, geometry(other)) for other in visible):
            continue
        result.append((window, crop, crop != rect))
    return result[:MAX_FRAMES]


def scene_tag(scene, name):
    monitor, bounds = monitor_context(scene, name)
    # Ignore screencast bookkeeping introduced by our own output capture.
    clients = [{k: w.get(k) for k in ('address', 'pid', 'stableId', 'title', 'at', 'size', 'workspace',
                'monitor', 'mapped', 'visible', 'hidden', 'floating', 'fullscreen', 'focusHistoryID', 'pinned')}
               for w in scene['clients'] if w.get('monitor') == monitor['id']]
    clients.sort(key=lambda w: str(w['address']))
    return json.dumps([bounds, monitor.get('transform'), monitor.get('scale'), monitor.get('activeWorkspace'),
                       monitor.get('specialWorkspace'), clients, overlays(scene, name)], sort_keys=True)


def grab_output(name, scale):
    # Explicit -o and stdout only. NEVER use grim -T (toplevel capture).
    process = subprocess.Popen(['grim', '-o', name, '-s', str(scale), '-t', 'ppm', '-'],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 1.0
        data = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise Unavailable('Output snapshot timed out')
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                data.extend(chunk)
                if len(data) > MAX_PPM:
                    raise Unavailable('Output snapshot exceeds memory limit')
        if process.wait(timeout=max(.001, deadline - time.monotonic())):
            raise Unavailable('Output snapshot unavailable')
        return bytes(data)
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdout.close()


def parse_ppm(data):
    # P6 header: allow comments/whitespace between tokens, but never strip pixels.
    tokens, i = [], 0
    while len(tokens) < 4:
        while i < len(data) and data[i] in b' \t\r\n':
            i += 1
        if i < len(data) and data[i] == ord('#'):
            end = data.find(b'\n', i)
            if end < 0:
                raise Unavailable('Invalid snapshot header')
            i = end + 1
            continue
        start = i
        while i < len(data) and data[i] not in b' \t\r\n':
            i += 1
        if i == start or i >= len(data) or i > 1024:
            raise Unavailable('Invalid snapshot header')
        tokens.append(data[start:i])
    if tokens[0] != b'P6' or tokens[3] != b'255':
        raise Unavailable('Unsupported snapshot format')
    width, height = int(tokens[1]), int(tokens[2])
    i += 2 if data[i:i + 2] == b'\r\n' else 1
    if min(width, height) <= 0 or width * height > MAX_PIXELS or len(data) - i != width * height * 3:
        raise Unavailable('Invalid snapshot dimensions')
    return width, height, memoryview(data)[i:]


def png_crop(pixels, width, box):
    x, y, w, h = box
    rows = b''.join(b'\0' + pixels[((y + row) * width + x) * 3:((y + row) * width + x + w) * 3].tobytes()
                    for row in range(h))
    def chunk(kind, content):
        return struct.pack('!I', len(content)) + kind + content + struct.pack('!I', zlib.crc32(kind + content))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows, 1)) + chunk(b'IEND', b''))


def capture(name, scene=read_scene, grab=grab_output):
    before = scene()
    monitor, bounds = monitor_context(before, name)
    planned = candidates(before, name)
    if not planned:
        return {'ok': True, 'frames': [], 'reason': 'No unobscured windows on this output'}
    tag = scene_tag(before, name)
    scale = min(.5, 1600 / bounds[2], 1000 / bounds[3])
    raw = grab(name, scale)
    after = scene()
    # Recheck protected layers too: never map over a newly opened auth dialog.
    candidates(after, name)
    if scene_tag(after, name) != tag:
        raise Unavailable('Desktop changed during snapshot')
    width, height, pixels = parse_ppm(raw)
    sx, sy = width / bounds[2], height / bounds[3]
    if abs(sx - scale) > .01 or abs(sy - scale) > .01:
        raise Unavailable('Snapshot geometry does not match output')
    frames, used = [], 0
    stamp = round(time.time() * 1000)
    for window, rect, partial in planned:
        left, top = math.ceil((rect[0] - bounds[0]) * sx), math.ceil((rect[1] - bounds[1]) * sy)
        right = min(width, math.floor((rect[0] + rect[2] - bounds[0]) * sx))
        bottom = min(height, math.floor((rect[1] + rect[3] - bounds[1]) * sy))
        w, h = right - left, bottom - top
        if min(w, h) <= 0:
            continue
        image = 'data:image/png;base64,' + base64.b64encode(png_crop(pixels, width, (left, top, w, h))).decode('ascii')
        if used + len(image) > MAX_URL_BYTES:
            break
        used += len(image)
        frames.append({'address': str(window['address']).removeprefix('0x'), 'pid': window.get('pid'),
                       'stableId': window.get('stableId'), 'title': window.get('title', ''),
                       'windowSize': window['size'], 'width': w, 'height': h, 'partial': partial,
                       'capturedAt': stamp, 'imageSource': image})
    return {'ok': True, 'frames': frames}


def main():
    def cancelled(signum, frame):
        raise InterruptedError('Snapshot cancelled')
    signal.signal(signal.SIGTERM, cancelled)
    try:
        if len(sys.argv) != 2:
            raise Unavailable('An output name is required')
        result = capture(sys.argv[1])
    except Unavailable as error:
        result = {'ok': False, 'frames': [], 'reason': str(error), 'blocked': error.blocked}
    except (Exception, KeyboardInterrupt):
        # Never log raw pixels, client titles, or subprocess output.
        result = {'ok': False, 'frames': [], 'reason': 'Output snapshot unavailable'}
    print(json.dumps(result, separators=(',', ':')), flush=True)


if __name__ == '__main__':
    main()
