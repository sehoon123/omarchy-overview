"""Stable workspace selectors and the optional Per-monitor Workspaces catalog."""
import json
import os
from pathlib import Path
import re

PLUGIN = 'mmsbrggr.per-monitor-workspaces'
SHELL_CONFIG = Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home() / '.config'))) / 'omarchy/shell.json'


def ws_id(value):
    value = int(value)
    if not 0 < value < 2147483647:
        raise ValueError('Invalid desktop number')
    return value


def workspace_ref(value):
    if isinstance(value, str) and value.startswith('name:'):
        name = value[5:]
        if not name or name == 'special' or name.startswith('special:') or any(ord(c) < 32 or ord(c) == 127 for c in name):
            raise ValueError('Invalid desktop name')
        return value
    return ws_id(value)


def workspace_key(workspace):
    if not workspace:
        return 0
    name = workspace.get('name', '')
    if name == 'special' or name.startswith('special:') or workspace.get('special'):
        return 0
    ident = workspace.get('id', 0)
    if ident > 0 and (not name or name == str(ident)):
        return ident
    return 'name:' + name if name else 0


def workspace_sort_key(ref):
    if isinstance(ref, int):
        return (0, '', ref, '')
    prefix, _, suffix = ref.rpartition(':')
    return (1, prefix, int(suffix) if suffix.isdigit() else 0, ref)


def monitor_keys(monitors):
    keys = {}
    for monitor in monitors:
        description = monitor.get('description') or ''
        duplicate = description and sum(m.get('description') == description for m in monitors) > 1
        keys[monitor['name']] = (description + '@' + monitor['name'] if duplicate else description) or monitor['name']
    return keys


def slot_number(ref, prefix):
    start = 'name:' + prefix + ':'
    suffix = str(ref)[len(start):] if str(ref).startswith(start) else ''
    return int(suffix) if re.fullmatch(r'[1-9][0-9]*', suffix) else 0


def plugin_count():
    # Read the widget's source of truth, never execute its projected Lua file.
    try:
        layout = json.loads(SHELL_CONFIG.read_text()).get('bar', {}).get('layout', {})
        for section in layout.values():
            for item in section:
                if isinstance(item, dict) and item.get('id') == PLUGIN:
                    count = float(item.get('count', 5))
                    return max(1, int(count)) if count > 0 else 5
    except (OSError, ValueError, TypeError, AttributeError, OverflowError):
        pass
    return 0


def catalog(order, live, monitors, count):
    keys = monitor_keys(monitors)
    result = list(order)
    if count:
        for prefix in keys.values():
            for slot in range(1, count + 1):
                ref = 'name:' + prefix + ':' + str(slot)
                if ref not in result:
                    result.append(ref)
    existing = {workspace_key(w): w for w in live if workspace_key(w)}
    info = {}
    for ref in result:
        workspace = existing.get(ref, {})
        owner = next((name for name, prefix in keys.items() if slot_number(ref, prefix)), '') if count else ''
        monitor = workspace.get('monitor') or owner
        slot = slot_number(ref, keys[owner]) if owner else 0
        name = str(ref).removeprefix('name:')
        label = 'Desktop ' + (str(slot) if owner and owner == monitor else name)
        info[str(ref)] = {'monitor': monitor, 'label': label,
                          'pinned': bool(workspace.get('ispersistent')) or bool(slot and slot <= count)}
    return result, info


def scoped_order(order, info, monitor, count):
    return [ref for ref in order if not count or info[str(ref)]['monitor'] == monitor]


def next_desktop(order, prefix=''):
    if prefix:
        number = max([slot_number(ref, prefix) for ref in order] + [0]) + 1
        return 'name:' + prefix + ':' + str(ws_id(number))
    return ws_id(max([ref for ref in order if isinstance(ref, int)] + [0]) + 1)


def lua_string(value):
    # Names reject control characters; JSON's quote/backslash escapes are Lua's too.
    return json.dumps(str(value), ensure_ascii=False)
