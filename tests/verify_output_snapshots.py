#!/usr/bin/env python3
"""Opt-in, bounded Overview-only UI check. No user windows/workspaces are moved.

Starts an isolated staging copy inside this repository, briefly opens/closes its
own overlay, and checks decoded PNGs plus desktop-state continuity. No screenshot
files or compositor settings are written. Do not interact while this runs.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]


def command(*args):
    return subprocess.check_output(args, text=True, timeout=3, stderr=subprocess.DEVNULL).strip()


def footprint():
    clients = json.loads(command('hyprctl', '-j', 'clients'))
    fields = ('address', 'at', 'size', 'workspace', 'monitor', 'floating', 'fullscreen')
    return sorted([{k: c.get(k) for k in fields} for c in clients], key=lambda c: c['address'])


def wait_for(check, process, timeout=6):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError('Staging Overview exited before verification')
        try:
            value = check()
            if value: return value
        except (subprocess.SubprocessError, ValueError):
            pass
        time.sleep(.04)
    raise AssertionError('Timed out waiting for staging Overview')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true')
    args = parser.parse_args()
    if not args.run:
        raise SystemExit('Requires --run; this briefly displays an Overview overlay.')
    before = footprint()
    focus = json.loads(command('hyprctl', '-j', 'activewindow')).get('address')
    compositor = json.loads(command('hyprctl', '-j', 'version'))
    with tempfile.TemporaryDirectory(prefix='.overview-smoke-', dir=REPO) as directory:
        stage = Path(directory)
        for pattern in ('*.qml', '*.js', '*.py'):
            for path in REPO.glob(pattern): shutil.copy2(path, stage / path.name)
        env = dict(os.environ, OVERVIEW_START_HIDDEN='1', OVERVIEW_STATE_DIR=str(stage / 'state'),
                   OVERVIEW_SETTINGS_PATH=str(stage / 'settings.json'))
        ipc = ['quickshell', 'ipc', '-p', str(stage), 'call', 'overview']
        def call(*args): return command(*ipc, *args)
        def status(): return json.loads(call('status'))
        with (stage / 'runtime.log').open('w+') as log:
            process = subprocess.Popen(['quickshell', '-p', str(stage), '--no-duplicate'], env=env, stdout=log, stderr=log)
            try:
                wait_for(lambda: status().get('captureTopologyReady') and not status()['busy'], process)
                decoded = []
                # A naturally changing title during capture may invalidate an
                # attempt. One ordinary reopen is allowed, never viewport priming.
                for attempt in range(2):
                    call('openOverview')
                    wait_for(lambda: status()['visible'] and status()['searchFocused'] and not status()['busy'], process)
                    time.sleep(.15)
                    current = status()
                    assert current['captureBackend'] == 'output-snapshot'
                    assert not current['windowCaptureEnabled'] and current['captureViews'] == 0
                    decoded = [w for w in current['windows'] if w['imageReady']]
                    if decoded: break
                    call('close')
                    wait_for(lambda: not status()['visible'], process)
                    time.sleep(.3)
                assert decoded, 'No PNG decoded; reason: ' + current.get('snapshotError', '')
                assert all(not w['fresh'] for w in decoded), 'A snapshot must not claim to be live'
                assert current['snapshotBytes'] <= 8 * 1024 * 1024
                assert current['snapshotPixels'] <= 12000000
                wait_for(lambda: call('togglePreview') == 'true', process)
                wait_for(lambda: bool(status()['previewAddress']), process)
                assert not status()['liveAddresses'], 'Quick Look must not start native capture'
                wait_for(lambda: call('togglePreview') == 'true', process)
                wait_for(lambda: not status()['previewAddress'] and status()['searchFocused'], process)
                call('showSettings')
                wait_for(lambda: status()['settingsShown'], process)
                call('close')
                wait_for(lambda: not status()['visible'] and not status()['opening'], process)
                retained = status()['cachedFrames']
                time.sleep(.2)
                assert status()['cachedFrames'] == retained, 'Hidden Overview started new captures'
                assert footprint() == before, 'Application geometry/desktop state changed'
                assert json.loads(command('hyprctl', '-j', 'activewindow')).get('address') == focus, 'Application focus changed'
                assert json.loads(command('hyprctl', '-j', 'version')) == compositor, 'Compositor version changed'
                log.flush(); log.seek(0)
                assert not re.search(r'ReferenceError|TypeError|Binding loop|(?:Cannot|Unable to) assign', log.read()), 'QML runtime error'
                print(json.dumps({'decodedPreviews': len(decoded), 'windows': len(current['windows']),
                                  'firstFrameMs': current['firstFrameMs'], 'snapshotBytes': current['snapshotBytes'],
                                  'nativeCaptureViews': 0, 'desktopUnchanged': True}))
            except Exception:
                log.flush(); log.seek(0)
                print(re.sub(r'data:image/png;base64,[A-Za-z0-9+/=]+', '[snapshot redacted]', log.read()[-12000:]))
                raise
            finally:
                try: call('shutdown')
                except subprocess.SubprocessError: pass
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try: process.wait(timeout=3)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()


if __name__ == '__main__': main()
