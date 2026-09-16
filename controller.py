#!/usr/bin/env python3
"""Explicit, address-targeted workspace actions. Never closes applications."""
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import time

import hypr_ipc
from workspaces import (ws_id, workspace_ref, workspace_key, monitor_keys, slot_number,
                        plugin_count, catalog, scoped_order, next_desktop, lua_string, workspace_sort_key)

STATE = Path(os.environ.get('OVERVIEW_STATE_DIR', str(Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'omarchy/overview')))


def hypr(*args, json_output=False):
    return hypr_ipc.call(*args, json_output=json_output)


def dispatch(expr):
    return hypr('dispatch', expr)


def address(value):
    value = str(value)
    if not re.fullmatch(r'(?:0x)?[0-9a-fA-F]+', value):
        raise ValueError('Invalid window address')
    return value if value.startswith('0x') else '0x' + value


def clients():
    return hypr('-j', 'clients', json_output=True)


def find_window(addr):
    return next((w for w in clients() if w['address'] == addr), None)


def wait_for(test):
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if test():
            return
        time.sleep(.04)
    raise RuntimeError('Hyprland did not confirm the change; please try again')


def merge_order(saved, live):
    return list(dict.fromkeys([workspace_ref(i) for i in saved] +
                              sorted((workspace_ref(i) for i in live), key=workspace_sort_key)))


def read_order(live=None):
    if live is None:
        live = [workspace_key(w) for w in hypr('-j', 'workspaces', json_output=True) if workspace_key(w)]
    try:
        saved = json.loads((STATE / 'desktops.json').read_text())
        if saved.get('version') not in (1, 2) or not isinstance(saved.get('order'), list):
            raise ValueError('Invalid saved desktop list')
        return merge_order(saved['order'], live)
    except FileNotFoundError:
        return merge_order([], live) or [1]


def save_order(order):
    tmp = STATE / 'desktops.json.tmp'
    tmp.write_text(json.dumps({'version': 2 if any(isinstance(i, str) for i in order) else 1,
                               'order': order}, indent=2) + '\n')
    tmp.replace(STATE / 'desktops.json')


def desktop_state():
    live = hypr('-j', 'workspaces', json_output=True)
    monitors = hypr('-j', 'monitors', json_output=True)
    count = plugin_count()
    slots, _ = catalog([], live, monitors, count)
    order = read_order(slots + [workspace_key(w) for w in live if workspace_key(w)])
    order, info = catalog(order, live, monitors, count)
    return order, info, monitors, count


def dispatch_to(target, expression, restore=False):
    # Missing named slots are created on the focused screen, not the screen
    # encoded in their name. Focus the owner atomically, then restore for moves.
    monitor = ''
    if isinstance(target, str):
        live = hypr('-j', 'workspaces', json_output=True)
        monitor = next((w['monitor'] for w in live if workspace_key(w) == target), '')
        if not monitor:
            keys = monitor_keys(hypr('-j', 'monitors', json_output=True))
            monitor = next((name for name, prefix in keys.items() if slot_number(target, prefix)), '')
    if not monitor:
        return dispatch(expression)
    body = 'local origin = hl.get_active_monitor(); ' if restore else ''
    body += f'hl.dispatch(hl.dsp.focus({{ monitor = {lua_string(monitor)} }})); '
    body += f'hl.dispatch({expression}); '
    if restore:
        body += 'if origin then hl.dispatch(hl.dsp.focus({ monitor = origin.name })) end '
    return dispatch('function() ' + body + 'end')


def move_window(addr, target):
    addr, target = address(addr), workspace_ref(target)
    before = find_window(addr)
    if not before:
        raise ValueError('That window has already closed')
    if not workspace_key(before['workspace']):
        raise ValueError('Special workspaces are not managed here')
    if workspace_key(before['workspace']) == target:
        return []
    # A grouped window can move its whole group. Include those members in Undo.
    members = set(before.get('grouped', []) + [addr])
    original = [w for w in clients() if w['address'] in members]
    dispatch_to(target, f'hl.dsp.window.move({{ window = "address:{addr}", workspace = {lua_string(target)}, follow = false }})', restore=True)
    wait_for(lambda: workspace_key((find_window(addr) or {}).get('workspace')) == target)
    after = {w['address']: w for w in clients()}
    return [{'address': w['address'], 'source': workspace_key(w['workspace']), 'target': target}
            for w in original if workspace_key(w['workspace']) != target and
            workspace_key(after.get(w['address'], {}).get('workspace')) == target]


def focus_desktop(target):
    target = workspace_ref(target)
    dispatch_to(target, f'hl.dsp.focus({{ workspace = {lua_string(target)} }})')
    wait_for(lambda: workspace_key(hypr('-j', 'activeworkspace', json_output=True)) == target)


def act(args, monitor=''):
    order, info, monitors, count = desktop_state()
    old_order = order[:]
    screen = (next((m for m in monitors if m['name'] == monitor), None) if monitor else
              next((m for m in monitors if m.get('focused')), None))
    if monitor and not screen:
        raise ValueError('That monitor is no longer available')
    monitor = screen['name'] if screen else ''
    local = scoped_order(order, info, monitor, count)
    prefix = monitor_keys(monitors).get(monitor, '') if count else ''
    action = args[0]
    out = {'ok': True}
    label = lambda ref: info.get(str(ref), {}).get('label', 'Desktop ' + str(ref).removeprefix('name:').rsplit(':', 1)[-1])
    if action == 'state':
        pass
    elif action == 'prime':
        raise ValueError('Preview capture requires the resident worker and a viewport lease')
    elif action == 'create':
        target = next_desktop(order, prefix)
        order.append(target)
        out.update(created=target, message=f'{label(target)} added')
    elif action == 'move':
        target = next_desktop(order, prefix) if args[2] == 'new' else workspace_ref(args[2])
        if args[2] != 'new' and target not in local:
            raise ValueError('Destination desktop is no longer available')
        moved = move_window(args[1], target)
        order = merge_order(order, [target])
        out.update(target=target, message=f'Moved to {label(target)}', undo={'moves': moved, 'order': old_order})
    elif action == 'switch':
        target = workspace_ref(args[1])
        if target not in local:
            raise ValueError('That desktop is no longer available')
        focus_desktop(target)
    elif action == 'step':
        if not local:
            raise ValueError('No desktops on this monitor')
        current = workspace_key(screen['activeWorkspace'] if screen else hypr('-j', 'activeworkspace', json_output=True))
        index = local.index(current) if current in local else 0
        offset = 1 if args[1] == 'next' else -1
        focus_desktop(local[max(0, min(len(local) - 1, index + offset))])
    elif action == 'reorder':
        source, before = workspace_ref(args[1]), workspace_ref(args[2])
        if source not in local or before not in local:
            raise ValueError('Desktop is no longer available')
        if source != before:
            destination = order.index(before)
            order.remove(source)
            order.insert(destination, source)
        out['message'] = 'Desktop order updated'
    elif action == 'remove':
        source = workspace_ref(args[1])
        if source not in local or len(local) < 2:
            raise ValueError('Keep at least one desktop on this monitor')
        if info[str(source)]['pinned']:
            raise ValueError('This desktop is pinned by Hyprland or Per-monitor Workspaces')
        index = local.index(source)
        target = local[index - 1] if index else local[1]
        moved = []
        try:
            for w in clients():
                if workspace_key(w['workspace']) == source:
                    moved.extend(move_window(w['address'], target))
            if (any(workspace_key(m.get('activeWorkspace')) == source for m in monitors) or
                    workspace_key(hypr('-j', 'activeworkspace', json_output=True)) == source):
                focus_desktop(target)
            if any(workspace_key(w['workspace']) == source for w in clients()):
                raise RuntimeError('Some windows could not be moved; desktop was kept')
        except Exception:
            # Best-effort rollback; never forget a desktop containing windows.
            for entry in moved:
                try:
                    move_window(entry['address'], entry['source'])
                except Exception:
                    pass
            raise
        order.remove(source)
        out.update(removed=source, target=target, message=f'{label(source)} removed · windows kept',
                   undo={'moves': moved, 'order': old_order})
    elif action == 'undo':
        record = json.loads(args[1])
        moves = record.get('moves', [])
        if not isinstance(moves, list) or len(moves) > 500:
            raise ValueError('Invalid undo record')
        skipped = 0
        for entry in moves:
            addr = address(entry['address'])
            w = find_window(addr)
            # Do not override subsequent moves made outside Overview.
            if w and workspace_key(w['workspace']) == workspace_ref(entry['target']):
                move_window(addr, workspace_ref(entry['source']))
            elif not w or workspace_key(w['workspace']) != workspace_ref(entry['source']):
                skipped += 1
        order = merge_order(record.get('order', []), order)
        out['message'] = 'Undone' if not skipped else 'Undone · changed or closed windows skipped'
    else:
        raise ValueError('Unknown overview action')
    # Queries, capture and focus operations must not rewrite desktop state.
    if order != old_order:
        save_order(order)
    _, info = catalog(order, hypr('-j', 'workspaces', json_output=True), monitors, count)
    out.update(order=order, desktops=info, perMonitor=bool(count))
    return out


def main():
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (STATE / 'actions.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            print(json.dumps(act(sys.argv[1:] or ['state'])))
        except Exception as error:
            print(json.dumps({'ok': False, 'error': str(error)}))
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
