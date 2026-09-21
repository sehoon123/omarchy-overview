#!/usr/bin/env python3
"""Read-only opening/security check. No pixels, dispatchers, or capture subprocess."""
import json
import math
import sys

import hypr_ipc


def check(monitors, layers, name):
    if not isinstance(monitors, list) or not monitors or not isinstance(layers, dict):
        return {'ok': False, 'reason': 'Display state unavailable'}
    outputs = []
    for monitor in monitors:
        blockers = monitor.get('solitaryBlockedBy')
        if not isinstance(blockers, list) or 'LOCK' in blockers or 'WORKSPACE' in blockers:
            return {'ok': False, 'reason': 'Session locked or lock state unavailable'}
        output = str(monitor.get('name', ''))
        scale = monitor.get('scale', 0)
        size = [monitor.get('width', 0), monitor.get('height', 0)]
        if (not output or output.startswith(('HEADLESS-', 'FALLBACK'))
                or monitor.get('disabled') or not monitor.get('dpmsStatus')
                or not all(isinstance(v, (int, float)) and math.isfinite(v) and v > 0 for v in [scale, *size])):
            continue
        position = [monitor.get('x'), monitor.get('y')]
        if not all(isinstance(v, (int, float)) and math.isfinite(v) for v in position):
            continue
        if monitor.get('transform', 0) % 2: size.reverse()
        outputs.append({'name': output, 'id': monitor.get('id'), 'scale': scale,
                        'x': position[0], 'y': position[1], 'width': size[0] / scale, 'height': size[1] / scale})
    for output in layers.values():
        for level in output.get('levels', {}).values():
            for layer in level:
                if layer.get('alpha', 1) <= .001:
                    continue
                namespace = str(layer.get('namespace', ''))
                if namespace in ('omarchy-polkit', 'hyprlock', 'swaylock', 'gtklock', 'omarchy-lockscreen'):
                    return {'ok': False, 'reason': 'Authentication or lock dialog is open'}
    if not any(output['name'] == name for output in outputs):
        return {'ok': False, 'reason': 'Selected display is unavailable'}
    return {'ok': True, 'outputs': outputs}


def inspect(name, call=hypr_ipc.call):
    return check(call('monitors', json_output=True, timeout=.3),
                 call('layers', json_output=True, timeout=.3), name)


def main():
    try:
        result = inspect(sys.argv[1]) if len(sys.argv) == 2 else {'ok': False, 'reason': 'Display name required'}
    except Exception:
        result = {'ok': False, 'reason': 'Cannot verify capture context'}
    print(json.dumps(result, separators=(',', ':')), flush=True)


if __name__ == '__main__': main()
