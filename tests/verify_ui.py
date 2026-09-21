#!/usr/bin/env python3
"""Opt-in visible UI smoke test, ONLY against a temporary staging config.

Uses real keyboard events, including fcitx5 Hangul composition. Never activates,
closes or moves an application, and never writes screenshots. Temporarily edits
only the staged settings file. Do not interact with the desktop while it runs.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time


def command(*args):
    return subprocess.check_output(args, text=True, timeout=5).strip()


def wait_for(check, timeout=4):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.04)
    raise AssertionError('Timed out: ' + str(check))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--config', type=Path, required=True)
    args = parser.parse_args()
    config = args.config.resolve()
    if not args.run or not config.is_relative_to(Path(tempfile.gettempdir()).resolve()):
        raise SystemExit('Requires --run and a staging config under /tmp, not your installed Overview.')
    ipc = ['quickshell', 'ipc', '-p', str(config), 'call', 'overview']
    def call(*values): return command(*ipc, *values)
    def status(): return json.loads(call('status'))
    def key(name): command('wtype', '-k', name)
    def select_engine(name):
        # fcitx can report failure during a Wayland context transition even
        # though the request was applied. Confirm the observable engine instead.
        def selected():
            subprocess.run(['fcitx5-remote', '-s', name], capture_output=True, timeout=2)
            time.sleep(.05)
            return command('fcitx5-remote', '-n') == name
        wait_for(selected)
        time.sleep(.15)
    def write_settings(document):
        temporary = config / 'settings.test-tmp'
        temporary.write_text(json.dumps(document))
        temporary.replace(config / 'settings.json')
    if status()['visible']:
        raise SystemExit('Close the staging Overview before testing.')
    before = json.loads(command('hyprctl', '-j', 'clients'))
    focused = json.loads(command('hyprctl', '-j', 'activewindow')).get('address')
    engine, active = command('fcitx5-remote', '-n'), command('fcitx5-remote')
    path = config / 'settings.json'
    saved = path.read_bytes() if path.exists() else None
    try:
        write_settings({'version': 1, 'future': {'preserved': True}, 'followTheme': True})
        call('openOverview')
        wait_for(lambda: status()['visible'] and status()['searchFocused'] and not status()['busy'])
        select_engine('keyboard-us')
        time.sleep(.35)
        baseline = status()
        assert baseline['windows'], 'Test needs at least one window on the current desktop'
        views = baseline['captureViews']
        key('space')
        wait_for(lambda: status()['previewAddress'])
        preview = status()
        assert preview['captureViews'] == views, 'Quick Look created another capture'
        assert preview['previewSourceId'] and preview['previewSourceId'] in [w['sourceId'] for w in preview['windows']]
        key('Escape')
        assert status()['visible'] and not status()['previewAddress']
        query = 'overview-regression-no-match-7bca9'
        command('wtype', query)
        wait_for(lambda: status()['query'] == query)
        filtered = status()
        assert not filtered['windows']
        assert filtered['delegateCount'] == baseline['delegateCount'], 'Filtering rebuilt window delegates'
        assert filtered['captureViews'] == views, 'Filtering rebuilt native captures'
        key('Return')
        assert status()['visible'], 'Enter on an empty search must not switch desktops'
        key('Escape')
        assert status()['visible'] and not status()['query']
        select_engine('hangul')
        command('wtype', '-d', '30', 'gks')
        wait_for(lambda: status()['composing'])
        key('Escape')
        assert status()['visible'], 'Cancelling preedit must not close Overview'
        wait_for(lambda: not status()['composing'])
        command('wtype', '-d', '30', 'gksrmf')
        wait_for(lambda: status()['composing'])
        key('Return')
        wait_for(lambda: status()['query'] == '한글')
        assert status()['visible'], 'IME commit must not activate a window'
        time.sleep(.15)
        key('Escape')
        assert not status()['query']
        select_engine('keyboard-us')
        call('showSettings')
        wait_for(lambda: status()['settingsShown'])
        time.sleep(.1)
        key('space')
        wait_for(lambda: not status()['settings']['followTheme'])
        wait_for(lambda: json.loads(path.read_text()).get('followTheme') is False)
        assert json.loads(path.read_text())['future']['preserved']
        key('space')
        wait_for(lambda: json.loads(path.read_text()).get('followTheme') is True)
        key('Escape')
        assert status()['visible'] and not status()['settingsShown']
        document = json.loads(path.read_text())
        document.update(liveLimit=1, unknownFutureKey='kept')
        write_settings(document)
        wait_for(lambda: status()['settings']['liveLimit'] == 1)
        wait_for(lambda: len(status()['liveAddresses']) <= 1)
        call('close')
        wait_for(lambda: not status()['visible'] and not status()['preparing'] and not status()['closing'])
        wait_for(lambda: status()['captureViews'] == 0 and status()['cachedFrames'] == 0)
        time.sleep(.2)
        assert status()['captureViews'] == 0, 'Hidden capture restarted'
        call('openOverview')
        wait_for(lambda: status()['captureViews'] > 0)
        print(json.dumps({'result': 'passed', 'checks': ['stable filtered cards', 'empty-query Enter guard',
            'Quick Look shares one native source', 'fcitx5 Hangul composition', 'atomic settings write',
            'unknown settings preserved', 'captures released while hidden', 'captures rebuilt on reopen'],
            'firstFrameMs': status()['firstFrameMs']}, ensure_ascii=False, indent=2))
    finally:
        call('close')
        wait_for(lambda: not status()['visible'] and not status()['busy'] and not status()['preparing'] and not status()['closing'])
        if saved is None:
            path.unlink(missing_ok=True)
        else:
            path.write_bytes(saved)
        if engine:
            subprocess.run(['fcitx5-remote', '-s', engine], capture_output=True, timeout=2)
            subprocess.run(['fcitx5-remote', '-o' if active == '2' else '-c'], capture_output=True, timeout=2)
        after = {w['address']: w for w in json.loads(command('hyprctl', '-j', 'clients'))}
        for window in before:
            assert window['address'] in after, 'Application closed during test'
            current = after[window['address']]
            assert current['workspace'] == window['workspace'], 'Workspace membership changed'
            assert current['size'] == window['size'], 'Window size changed'
            assert max(abs(a - b) for a, b in zip(current['at'], window['at'])) <= 2, 'Viewport not restored'
        assert json.loads(command('hyprctl', '-j', 'activewindow')).get('address') == focused, 'Application focus changed'


if __name__ == '__main__':
    main()
