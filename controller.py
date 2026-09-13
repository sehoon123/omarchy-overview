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

STATE = Path(os.environ.get('OVERVIEW_STATE_DIR', str(Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'omarchy/overview')))


def hypr(*args, json_output=False):
    return hypr_ipc.call(*args, json_output=json_output)


def dispatch(expr):
    return hypr('dispatch', expr)


def ws_id(value):
    value = int(value)
    if not 0 < value < 2147483647:
        raise ValueError('Invalid desktop number')
    return value


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
    return list(dict.fromkeys([ws_id(i) for i in saved] + sorted(ws_id(i) for i in live)))


def read_order():
    live = [w['id'] for w in hypr('-j', 'workspaces', json_output=True) if w['id'] > 0]
    try:
        saved = json.loads((STATE / 'desktops.json').read_text())
        if saved.get('version') != 1 or not isinstance(saved.get('order'), list):
            raise ValueError('Invalid saved desktop list')
        return merge_order(saved['order'], live)
    except FileNotFoundError:
        return merge_order([], live) or [1]


def save_order(order):
    tmp = STATE / 'desktops.json.tmp'
    tmp.write_text(json.dumps({'version': 1, 'order': order}, indent=2) + '\n')
    tmp.replace(STATE / 'desktops.json')


def move_window(addr, target):
    addr, target = address(addr), ws_id(target)
    before = find_window(addr)
    if not before:
        raise ValueError('That window has already closed')
    if before['workspace']['id'] <= 0:
        raise ValueError('Special workspaces are not managed here')
    if before['workspace']['id'] == target:
        return []
    # A grouped window can move its whole group. Include those members in Undo.
    members = set(before.get('grouped', []) + [addr])
    original = [w for w in clients() if w['address'] in members]
    dispatch(f'hl.dsp.window.move({{ window = "address:{addr}", workspace = "{target}", follow = false }})')
    wait_for(lambda: (find_window(addr) or {}).get('workspace', {}).get('id') == target)
    after = {w['address']: w for w in clients()}
    return [{'address': w['address'], 'source': w['workspace']['id'], 'target': target}
            for w in original if w['workspace']['id'] != target and
            after.get(w['address'], {}).get('workspace', {}).get('id') == target]


def focus_desktop(target):
    target = ws_id(target)
    dispatch(f'hl.dsp.focus({{ workspace = "{target}" }})')
    wait_for(lambda: hypr('-j', 'activeworkspace', json_output=True)['id'] == target)


def act(args):
    order = read_order()[:]
    old_order = order[:]
    action = args[0]
    out = {'ok': True}
    if action == 'state':
        pass
    elif action == 'prime':
        raise ValueError('Preview capture requires the resident worker and a viewport lease')
    elif action == 'create':
        target = ws_id(max(order) + 1)
        order.append(target)
        out.update(created=target, message=f'Desktop {target} added')
    elif action == 'move':
        target = ws_id(max(order) + 1) if args[2] == 'new' else ws_id(args[2])
        if args[2] != 'new' and target not in order:
            raise ValueError('Destination desktop is no longer available')
        moved = move_window(args[1], target)
        order = merge_order(order, [target])
        out.update(target=target, message=f'Moved to Desktop {target}', undo={'moves': moved, 'order': old_order})
    elif action == 'switch':
        target = ws_id(args[1])
        if target not in order:
            raise ValueError('That desktop is no longer available')
        focus_desktop(target)
    elif action == 'step':
        current = hypr('-j', 'activeworkspace', json_output=True)['id']
        index = order.index(current) if current in order else 0
        offset = 1 if args[1] == 'next' else -1
        focus_desktop(order[max(0, min(len(order) - 1, index + offset))])
    elif action == 'reorder':
        source, before = ws_id(args[1]), ws_id(args[2])
        if source not in order or before not in order:
            raise ValueError('Desktop is no longer available')
        if source != before:
            destination = order.index(before)
            order.remove(source)
            order.insert(destination, source)
        out['message'] = 'Desktop order updated'
    elif action == 'remove':
        source = ws_id(args[1])
        if source not in order or len(order) < 2:
            raise ValueError('Keep at least one desktop')
        workspace = next((w for w in hypr('-j', 'workspaces', json_output=True) if w['id'] == source), {})
        if workspace.get('ispersistent'):
            raise ValueError('This desktop is pinned in your Hyprland configuration')
        index = order.index(source)
        target = order[index - 1] if index else order[1]
        moved = []
        try:
            for w in clients():
                if w['workspace']['id'] == source:
                    moved.extend(move_window(w['address'], target))
            if hypr('-j', 'activeworkspace', json_output=True)['id'] == source:
                focus_desktop(target)
            if any(w['workspace']['id'] == source for w in clients()):
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
        out.update(removed=source, target=target, message=f'Desktop {source} removed · windows kept',
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
            if w and w['workspace']['id'] == ws_id(entry['target']):
                move_window(addr, ws_id(entry['source']))
            elif not w or w['workspace']['id'] != ws_id(entry['source']):
                skipped += 1
        order = merge_order(record.get('order', []), order)
        out['message'] = 'Undone' if not skipped else 'Undone · changed or closed windows skipped'
    else:
        raise ValueError('Unknown overview action')
    # Queries, capture and focus operations must not rewrite desktop state.
    if order != old_order:
        save_order(order)
    out['order'] = order
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
