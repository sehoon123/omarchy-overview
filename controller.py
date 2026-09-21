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
                        plugin_count, catalog, scoped_order, next_desktop, lua_string,
                        workspace_sort_key, text, usable_monitors)

STATE = Path(os.environ.get('OVERVIEW_STATE_DIR', str(Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'omarchy/overview')))
DESKTOPS = 'desktops.json'
# Bounded wait for the serial action lock (AUDIT.md F-40). A held keybinding must
# refuse quickly instead of queueing desktop switches that all fire at once when
# an earlier action finally releases it.
LOCK_TIMEOUT = 1.5


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
    """The windows Overview can act on, from a reply whose shape is not promised.

    A window with no address cannot be moved, matched or undone, so it is not a
    window this helper knows about. A reply that is not a list is not a window
    list: say so once, clearly, instead of leaking a KeyError or a TypeError.
    """
    reply = hypr('-j', 'clients', json_output=True)
    if not isinstance(reply, list):
        raise RuntimeError('Hyprland sent an unexpected window list')
    return [w for w in reply if isinstance(w, dict) and text(w.get('address'))]


def live_workspaces():
    reply = hypr('-j', 'workspaces', json_output=True)
    if not isinstance(reply, list):
        raise RuntimeError('Hyprland sent an unexpected desktop list')
    # Entries keep their fields; workspace_key() decides what is a desktop.
    return [w for w in reply if isinstance(w, dict)]


def live_monitors():
    # Monitors without a usable name are skipped; a non-list reply is refused.
    return usable_monitors(hypr('-j', 'monitors', json_output=True))


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


def selectable(refs):
    """Keep the refs a selector can express and skip the ones it cannot.

    Observation is not a request: a hand-edited saved entry, or a live workspace
    the compositor reports under a name no selector accepts, must never brick a
    read-only query. Requested selectors stay strictly validated.
    """
    result = []
    for ref in refs:
        try:
            result.append(workspace_ref(ref))
        except (ValueError, TypeError, OverflowError):
            continue
    return result


def read_document():
    """Return the saved JSON object, or {} when the file is missing or unreadable.

    Corrupt or truncated JSON, non-UTF8 bytes, a document that is not an object,
    a denied read and a directory in the file's place all mean 'nothing
    readable'. Nothing here rewrites or deletes the file, so a hand-editable
    list always survives a bad read.
    """
    saved = STATE / DESKTOPS
    try:
        # Anything that is not a regular file is not our document, and opening
        # one (a directory, a fifo) may fail or block a query that must answer.
        document = json.loads(saved.read_text()) if saved.is_file() else None
    except (OSError, ValueError, RecursionError):
        return {}
    return document if isinstance(document, dict) else {}


def read_order(live=None):
    if live is None:
        live = [workspace_key(w) for w in live_workspaces() if workspace_key(w)]
    document = read_document()
    # A valid saved order is always kept; only a version this release
    # understands may contribute one, and anything else falls back to the live
    # desktops instead of failing every action.
    saved = document.get('order') if document.get('version') in (1, 2) else None
    return merge_order(selectable(saved if isinstance(saved, list) else []), selectable(live)) or [1]


def save_order(order):
    """Record the desktop list atomically; report a failure instead of raising.

    The caller's desktop change has already happened, so a state directory that
    vanished is recreated and any remaining write failure degrades to False.
    Keys written by another version are preserved; only `version` and `order`
    belong to this release.
    """
    document = read_document()
    document.update(version=2 if any(isinstance(i, str) for i in order) else 1, order=order)
    tmp = STATE / (DESKTOPS + '.tmp')
    try:
        STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
        tmp.write_text(json.dumps(document, indent=2) + '\n')
        tmp.chmod(0o600)
        tmp.replace(STATE / DESKTOPS)
        return True
    except OSError:
        # Only our own temporary file is removed; the saved list stays as it is.
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        return False


def undo_record(payload):
    """Validate a returned undo record whole, or refuse it whole.

    The record is Overview's own receipt, round-tripped through the shell, so a
    garbled one is a corrupted request rather than a stale one and must never be
    half-applied. Skipping stays a per-window decision about desktops that
    genuinely changed. Nothing from the payload reaches the error text.
    """
    try:
        record = json.loads(payload)
    except (TypeError, ValueError, RecursionError):
        raise ValueError('Invalid undo record') from None
    moves = record.get('moves', []) if isinstance(record, dict) else None
    if not isinstance(moves, list) or len(moves) > 500:
        raise ValueError('Invalid undo record')
    entries = []
    for entry in moves:
        if not isinstance(entry, dict):
            raise ValueError('Invalid undo record')
        try:
            entries.append({'address': address(entry.get('address')),
                            'source': workspace_ref(entry.get('source')),
                            'target': workspace_ref(entry.get('target'))})
        except (ValueError, TypeError, OverflowError):
            raise ValueError('Invalid undo record') from None
    saved = record.get('order')
    # The recorded order is data, like the saved file: keep what a selector can
    # express and skip the rest instead of refusing the whole undo.
    return entries, selectable(saved if isinstance(saved, list) else [])


def desktop_state():
    live = live_workspaces()
    monitors = live_monitors()
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
        live = live_workspaces()
        monitor = next((text(w.get('monitor')) for w in live if workspace_key(w) == target), '')
        if not monitor:
            keys = monitor_keys(live_monitors())
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
    if not isinstance(before.get('workspace'), dict):
        raise ValueError('Hyprland did not report a desktop for that window')
    source = workspace_key(before['workspace'])
    if not source:
        raise ValueError('Special workspaces are not managed here')
    if source == target:
        return []
    # A grouped window can move its whole group. Include those members in Undo.
    grouped = before.get('grouped')
    members = {addr} | {a for a in (grouped if isinstance(grouped, list) else []) if isinstance(a, str)}
    original = [w for w in clients() if w['address'] in members]
    dispatch_to(target, f'hl.dsp.window.move({{ window = "address:{addr}", workspace = {lua_string(target)}, follow = false }})', restore=True)
    wait_for(lambda: workspace_key((find_window(addr) or {}).get('workspace')) == target)
    after = {w['address']: w for w in clients()}
    moved = []
    for window in original:
        origin = workspace_key(window.get('workspace'))
        # A move whose source cannot be named back is not recorded: an undo
        # entry Overview cannot replay is worse than no entry at all.
        if origin and origin != target and workspace_key(after.get(window['address'], {}).get('workspace')) == target:
            moved.append({'address': window['address'], 'source': origin, 'target': target})
    return moved


def focus_desktop(target):
    target = workspace_ref(target)
    dispatch_to(target, f'hl.dsp.focus({{ workspace = {lua_string(target)} }})')
    wait_for(lambda: workspace_key(hypr('-j', 'activeworkspace', json_output=True)) == target)


def act(args, monitor=''):
    order, info, monitors, count = desktop_state()
    old_order = order[:]
    screen = (next((m for m in monitors if m.get('name') == monitor), None) if monitor else
              next((m for m in monitors if m.get('focused')), None))
    if monitor and not screen:
        raise ValueError('That monitor is no longer available')
    monitor = text(screen.get('name')) if screen else ''
    local = scoped_order(order, info, monitor, count)
    prefix = monitor_keys(monitors).get(monitor, '') if count else ''
    action = args[0] if args else 'state'
    out = {'ok': True}
    label = lambda ref: info.get(str(ref), {}).get('label', 'Desktop ' + str(ref).removeprefix('name:').rsplit(':', 1)[-1])

    def argument(index):
        # worker.ARITY already fixes every action's arity; this keeps a
        # hand-assembled request from failing with an IndexError.
        if not isinstance(args, (list, tuple)) or index >= len(args):
            raise ValueError('Incomplete overview request')
        return args[index]

    if action == 'state':
        pass
    elif action == 'prime':
        raise ValueError('Viewport priming is retired; output snapshots never move desktops')
    elif action == 'create':
        target = next_desktop(order, prefix)
        order.append(target)
        out.update(created=target, message=f'{label(target)} added')
    elif action == 'move':
        target = next_desktop(order, prefix) if argument(2) == 'new' else workspace_ref(argument(2))
        if argument(2) != 'new' and target not in local:
            raise ValueError('Destination desktop is no longer available')
        moved = move_window(argument(1), target)
        order = merge_order(order, [target])
        out.update(target=target, message=f'Moved to {label(target)}', undo={'moves': moved, 'order': old_order})
    elif action == 'switch':
        target = workspace_ref(argument(1))
        if target not in local:
            raise ValueError('That desktop is no longer available')
        focus_desktop(target)
    elif action == 'step':
        if not local:
            raise ValueError('No desktops on this monitor')
        current = workspace_key(screen.get('activeWorkspace') if screen else hypr('-j', 'activeworkspace', json_output=True))
        index = local.index(current) if current in local else 0
        offset = 1 if argument(1) == 'next' else -1
        focus_desktop(local[max(0, min(len(local) - 1, index + offset))])
    elif action == 'reorder':
        source, before = workspace_ref(argument(1)), workspace_ref(argument(2))
        if source not in local or before not in local:
            raise ValueError('Desktop is no longer available')
        if source != before:
            destination = order.index(before)
            order.remove(source)
            order.insert(destination, source)
        out['message'] = 'Desktop order updated'
    elif action == 'remove':
        source = workspace_ref(argument(1))
        if source not in local or len(local) < 2:
            raise ValueError('Keep at least one desktop on this monitor')
        if info.get(str(source), {}).get('pinned'):
            raise ValueError('This desktop is pinned by Hyprland or Per-monitor Workspaces')
        index = local.index(source)
        target = local[index - 1] if index else local[1]
        moved = []
        try:
            for w in clients():
                if workspace_key(w.get('workspace')) == source:
                    moved.extend(move_window(w['address'], target))
            if (any(workspace_key(m.get('activeWorkspace')) == source for m in monitors) or
                    workspace_key(hypr('-j', 'activeworkspace', json_output=True)) == source):
                focus_desktop(target)
            if any(workspace_key(w.get('workspace')) == source for w in clients()):
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
        moves, saved = undo_record(argument(1))
        skipped = 0
        for entry in moves:
            w = find_window(entry['address'])
            # Do not override subsequent moves made outside Overview.
            if w and workspace_key(w.get('workspace')) == entry['target']:
                move_window(entry['address'], entry['source'])
            elif not w or workspace_key(w.get('workspace')) != entry['source']:
                skipped += 1
        order = merge_order(saved, order)
        out['message'] = 'Undone' if not skipped else 'Undone · changed or closed windows skipped'
    else:
        raise ValueError('Unknown overview action')
    # Queries, capture and focus operations must not rewrite desktop state.
    if order != old_order and not save_order(order):
        # The desktop change already happened: say the list was not recorded
        # rather than reporting a completed action as a failure.
        out['message'] = ' · '.join(filter(None, [out.get('message'), 'desktop order not saved']))
    try:
        live = live_workspaces()
    except RuntimeError:
        # The action has already happened: a second, unusable reply must not turn
        # a completed change into a failure. The refs are still known.
        live = []
    _, info = catalog(order, live, monitors, count)
    out.update(order=order, desktops=info, perMonitor=bool(count))
    return out


def take_lock(lock, timeout=LOCK_TIMEOUT, now=time.monotonic, sleep=time.sleep):
    deadline = now() + timeout
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            if now() >= deadline:
                return False
            sleep(.02)


def main():
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (STATE / 'actions.lock').open('a') as lock:
        if not take_lock(lock):
            print(json.dumps({'ok': False, 'error': 'Another overview action is still running'}))
            return 1
        try:
            print(json.dumps(act(sys.argv[1:] or ['state'])))
        except Exception as error:
            print(json.dumps({'ok': False, 'error': str(error)}))
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
