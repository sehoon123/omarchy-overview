"""A covered viewport lease. Capture completion arrives as an event, not a poll."""
import time


def prime(api, addr, cover, gate):
    addr = api.address(addr)
    if cover.get('visible') is not True or gate.cancelled.is_set(): return False
    target = api.find_window(addr)
    if not target: return False
    workspace = api.hypr('-j', 'activeworkspace', json_output=True)
    if (workspace['id'] != cover.get('workspace') or workspace['monitorID'] != cover.get('monitor') or
            target['monitor'] != workspace['monitorID'] or target['workspace']['id'] != workspace['id'] or
            workspace.get('tiledLayout') != 'scrolling' or target.get('floating')):
        return False
    direction = api.hypr('-j', 'getoption', 'scrolling:direction', json_output=True).get('str', 'right')
    if direction not in ('right', '', '[[EMPTY]]'): return False
    monitor = next(m for m in api.hypr('-j', 'monitors', json_output=True) if m['id'] == target['monitor'])
    original = [w for w in api.clients() if w['workspace']['id'] == workspace['id'] and not w.get('floating')]
    delta = monitor['x'] + monitor['width'] / monitor['scale'] / 2 - (target['at'][0] + target['size'][0] / 2)
    if gate.cancelled.is_set(): return False
    try:
        api.dispatch(f'hl.dsp.layout("move {delta:+.3f}")')
        return gate.wait_for_frame(addr, .75)
    finally:
        current = {w['address']: w for w in api.clients()}
        reference = next((w for w in original if w['address'] in current and
                          current[w['address']]['workspace']['id'] == workspace['id']), None)
        active = api.hypr('-j', 'activeworkspace', json_output=True)
        if reference and active['id'] == workspace['id'] and active['monitorID'] == workspace['monitorID']:
            restore = reference['at'][0] - current[reference['address']]['at'][0]
            api.dispatch(f'hl.dsp.layout("move {restore:+.3f}")')
        # The lease remains held until the compositor's return animation settles.
        time.sleep(.25)
