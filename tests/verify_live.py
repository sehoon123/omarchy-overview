"""Opt-in integration check; requires an already-created disposable test window."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

CONTROLLER = Path(__file__).resolve().parents[1] / 'controller.py'

def clients():
    return json.loads(subprocess.check_output(['hyprctl', '-j', 'clients']))

windows = clients()
test = next(w for w in windows if w['class'] == 'overview-verification')
assert test['workspace']['id'] == 90
assert not any(w['workspace']['id'] in (91, 92) for w in windows)
original = {w['address']: w['workspace']['id'] for w in windows if w['address'] != test['address']}

with tempfile.TemporaryDirectory(prefix='overview-verification-') as state:
    env = dict(os.environ, OVERVIEW_STATE_DIR=state)
    def call(*args):
        p = subprocess.run(['python3', str(CONTROLLER), *args], text=True, capture_output=True, env=env)
        result = json.loads(p.stdout)
        assert p.returncode == 0 and result['ok'], result
        return result
    def location():
        return next(w['workspace']['id'] for w in clients() if w['address'] == test['address'])

    try:
        call('state')
        # Create empty desktop; moving explicitly targets the disposable window.
        made = call('create')
        assert made['created'] == 91
        moved = call('move', test['address'], '91')
        assert location() == 91
        call('undo', json.dumps(moved['undo']))
        assert location() == 90
        call('move', test['address'], '91')
        removed = call('remove', '91')
        assert location() == 90 and 91 not in removed['order']
        call('undo', json.dumps(removed['undo']))
        assert location() == 91
        moved_new = call('move', test['address'], 'new')
        assert moved_new['target'] == 92 and location() == 92
        call('undo', json.dumps(moved_new['undo']))
        assert location() == 91
        reordered = call('reorder', '92', '90')
        assert reordered['order'].index(92) < reordered['order'].index(90)
        # Saved empty desktops and their order survive a new controller process.
        assert call('state')['order'] == reordered['order']
        now = {w['address']: w['workspace']['id'] for w in clients()}
        assert all(now.get(addr) == ws for addr, ws in original.items()), 'A non-test window changed desktop'
        print('PASS: create, move, undo, remove-without-closing, undo removal, drop-to-new, reorder, persistence')
        print('PASS: all non-test windows stayed on their original desktops')
    finally:
        # This is exclusively the disposable window created for this test.
        current = next((w for w in clients() if w['address'] == test['address']), None)
        if current and current['class'] == 'overview-verification':
            subprocess.run(['hyprctl', 'dispatch', f'hl.dsp.window.close({{ window = "address:{test["address"]}" }})'], check=True)
