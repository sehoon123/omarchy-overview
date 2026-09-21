"""Stable workspace selectors and the optional Per-monitor Workspaces catalog."""
import json
import os
from pathlib import Path
import re

PLUGIN = 'mmsbrggr.per-monitor-workspaces'
SHELL_CONFIG = Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home() / '.config'))) / 'omarchy/shell.json'


def text(value):
    """A string field from the compositor; any other type reads as absent.

    Reading a reply is observation, not a request: a field with the wrong type
    means 'Hyprland did not tell us', never a traceback.
    """
    return value if isinstance(value, str) else ''


def expressible(value):
    """A compositor string a selector or a dispatch expression can carry, else ''.

    Control characters are the whole test: `workspace_ref` refuses them in a
    requested name, and `lua_string` would spell them `\\uXXXX`, which is valid
    JSON and a Lua 5.4 syntax error.
    """
    value = text(value)
    return '' if any(ord(c) < 32 or ord(c) == 127 for c in value) else value


def is_ref(value):
    """A shape the catalog can index by: a desktop name or a desktop number."""
    return isinstance(value, str) or (isinstance(value, int) and not isinstance(value, bool))


def ws_id(value):
    # A desktop number is an integer the compositor can name: True is not
    # desktop 1, 1.9 is not desktop 1, and '-1'/'1e3' are not numbers here.
    if isinstance(value, str):
        if not re.fullmatch(r'[0-9]{1,10}', value):
            raise ValueError('Invalid desktop number')
    elif not isinstance(value, int) or isinstance(value, bool):
        raise ValueError('Invalid desktop number')
    value = int(value)
    if not 0 < value < 2147483647:
        raise ValueError('Invalid desktop number')
    return value


def workspace_ref(value):
    if isinstance(value, str) and value.startswith('name:'):
        name = value[5:]
        if not name or name != expressible(name) or name == 'special' or name.startswith('special:'):
            raise ValueError('Invalid desktop name')
        return value
    return ws_id(value)


def workspace_key(workspace):
    """The stable ref of a live workspace, or 0 when it is not one we manage.

    Every field is optional and may have the wrong type; a malformed entry is
    'not a desktop', which is exactly how a special workspace is reported.
    """
    if not isinstance(workspace, dict):
        return 0
    name = text(workspace.get('name'))
    if name == 'special' or name.startswith('special:') or workspace.get('special'):
        return 0
    ident = workspace.get('id')
    ident = ident if isinstance(ident, int) and not isinstance(ident, bool) else 0
    if ident > 0 and (not name or name == str(ident)):
        return ident
    return 'name:' + name if name else 0


def workspace_sort_key(ref):
    if isinstance(ref, int):
        return (0, '', ref, '')
    prefix, _, suffix = ref.rpartition(':')
    return (1, prefix, int(suffix) if suffix.isdigit() else 0, ref)


def usable_monitors(monitors):
    """The monitors this release can talk about; an unusable reply is refused once.

    A monitor with no usable `name` cannot be focused, keyed or scoped, so it is
    skipped. A reply that is not a list is not a display list at all, and
    guessing would silently unpin every per-monitor slot.
    """
    if not isinstance(monitors, list):
        raise RuntimeError('Hyprland sent an unexpected display list')
    return [m for m in monitors if isinstance(m, dict) and expressible(m.get('name'))]


def monitor_keys(monitors):
    keys = {}
    entries = usable_monitors(monitors)
    for monitor in entries:
        name = monitor['name']
        description = expressible(monitor.get('description'))
        duplicate = description and sum(expressible(m.get('description')) == description for m in entries) > 1
        keys[name] = (description + '@' + name if duplicate else description) or name
    return keys


def slot_number(ref, prefix):
    start = 'name:' + text(prefix) + ':'
    suffix = str(ref)[len(start):] if str(ref).startswith(start) else ''
    # Bounded on purpose: a slot number longer than a desktop count can be is
    # not a slot, and int() on a long digit run is its own failure mode.
    return int(suffix) if re.fullmatch(r'[1-9][0-9]{0,8}', suffix) else 0


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
    count = count if isinstance(count, int) and not isinstance(count, bool) and count > 0 else 0
    result = [ref for ref in order if is_ref(ref)] if isinstance(order, (list, tuple)) else []
    if count:
        for prefix in keys.values():
            for slot in range(1, count + 1):
                ref = 'name:' + prefix + ':' + str(slot)
                if ref not in result:
                    result.append(ref)
    existing = {}
    for workspace in (live if isinstance(live, list) else []):
        key = workspace_key(workspace)
        if key:
            existing[key] = workspace
    info = {}
    for ref in result:
        workspace = existing.get(ref, {})
        owner = next((name for name, prefix in keys.items() if slot_number(ref, prefix)), '') if count else ''
        monitor = text(workspace.get('monitor')) or owner
        slot = slot_number(ref, keys.get(owner, '')) if owner else 0
        name = str(ref).removeprefix('name:')
        label = 'Desktop ' + (str(slot) if owner and owner == monitor else name)
        info[str(ref)] = {'monitor': monitor, 'label': label,
                          'pinned': bool(workspace.get('ispersistent')) or bool(slot and slot <= count)}
    return result, info


def scoped_order(order, info, monitor, count):
    # A ref the catalog knows nothing about belongs to no monitor, so it is out
    # of scope rather than a KeyError on the path of every action.
    info = info if isinstance(info, dict) else {}
    return [ref for ref in (order if isinstance(order, (list, tuple)) else [])
            if not count or info.get(str(ref), {}).get('monitor') == monitor]


def next_desktop(order, prefix=''):
    order = order if isinstance(order, (list, tuple)) else []
    if prefix:
        number = max([slot_number(ref, prefix) for ref in order] + [0]) + 1
        return 'name:' + prefix + ':' + str(ws_id(number))
    return ws_id(max([ref for ref in order if isinstance(ref, int) and not isinstance(ref, bool)] + [0]) + 1)


def lua_string(value):
    # Names reject control characters; JSON's quote/backslash escapes are Lua's too.
    value = str(value)
    if value != expressible(value):
        # json.dumps would emit `\u001f`, which Lua 5.4 cannot parse: refuse to
        # generate an expression instead of dispatching a syntax error.
        raise ValueError('Invalid compositor request')
    return json.dumps(value, ensure_ascii=False)
