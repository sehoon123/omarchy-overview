#!/usr/bin/env python3
"""Opt-in ordinary native-preview smoke test, not a hotplug/crash reproduction.

Briefly opens only a staging Overview. No keyboard injection, test windows,
workspace/focus dispatchers, compositor settings, screenshot files or snapshots.
The desktop should be left alone while this bounded check runs.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
import capture_context


def command(*args):
    return subprocess.check_output(args, text=True, timeout=3, stderr=subprocess.DEVNULL).strip()


def footprint():
    fields = ('address', 'at', 'size', 'workspace', 'monitor', 'floating', 'fullscreen')
    return sorted([{k: w.get(k) for k in fields} for w in json.loads(command('hyprctl', '-j', 'clients'))], key=lambda w: w['address'])


def wait_for(check, process, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None: raise AssertionError('Staging Overview exited')
        try:
            value = check()
            if value: return value
        except (subprocess.SubprocessError, ValueError): pass
        time.sleep(.035)
    raise AssertionError('Timed out waiting for staging Overview')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true')
    args = parser.parse_args()
    if not args.run: raise SystemExit('Requires --run; briefly displays a native-preview Overview.')
    monitors = json.loads(command('hyprctl', '-j', 'monitors'))
    layers = json.loads(command('hyprctl', '-j', 'layers'))
    name = next((m['name'] for m in monitors if m.get('focused')), '')
    context = capture_context.check(monitors, layers, name)
    if not context['ok']: raise SystemExit(context['reason'])
    for output in layers.values():
        for level in output.get('levels', {}).values():
            if any(l.get('namespace') == 'sehun-overview' and l.get('alpha', 1) > 0 for l in level):
                raise SystemExit('Close the existing Overview before testing a staging copy.')
    before, compositor_pid = footprint(), command('pgrep', '-x', 'Hyprland')
    focus = json.loads(command('hyprctl', '-j', 'activewindow')).get('address')
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
                wait_for(lambda: status()['captureTopologyReady'] and not status()['busy'], process)
                assert status()['captureViews'] == 0 and status()['cachedFrames'] == 0
                call('openOverview')
                wait_for(lambda: status()['visible'] and status()['motionProgress'] == 1 and not status()['busy'], process)
                wait_for(lambda: any(w['imageReady'] and w['live'] for w in status()['windows']), process)
                current = status()
                assert current['captureBackend'] == 'native-window' and current['windowCaptureEnabled']
                assert 0 < current['captureViews'] <= 32
                sources = {w['address']: w['sourceId'] for w in current['windows'] if w['sourceId']}
                assert len(set(sources.values())) == len(sources), 'Duplicate native producer'
                wait_for(lambda: call('togglePreview') == 'true', process)
                preview = status()
                assert preview['previewSourceId'] == sources.get(preview['previewAddress'], 0)
                assert preview['captureViews'] == current['captureViews'], 'Quick Look created another capture'
                call('togglePreview')
                wait_for(lambda: call('setQuery', '__overview_synthetic_no_match__') == 'true', process)
                wait_for(lambda: not status()['windows'], process)
                wait_for(lambda: call('setQuery', '') == 'true', process)
                wait_for(lambda: len(status()['windows']) == len(current['windows']), process)
                restored = {w['address']: w['sourceId'] for w in status()['windows'] if w['sourceId']}
                assert restored == sources, 'Search destroyed/recreated native producers'
                call('showSettings')
                wait_for(lambda: status()['settingsShown'], process)
                call('close')
                wait_for(lambda: not status()['visible'] and not status()['closing'], process)
                hidden = status()
                assert hidden['captureViews'] == 0 and hidden['cachedFrames'] == 0
                assert not hidden['windowCaptureEnabled']
                time.sleep(.15)
                assert status()['captureViews'] == 0, 'Hidden capture restarted'
                assert footprint() == before, 'Desktop/window geometry changed'
                assert json.loads(command('hyprctl', '-j', 'activewindow')).get('address') == focus, 'Application focus changed'
                assert command('pgrep', '-x', 'Hyprland') == compositor_pid, 'Compositor process changed'
                log.flush(); log.seek(0)
                assert not re.search(r'ReferenceError|TypeError|Binding loop|(?:Cannot|Unable to) assign|ERROR', log.read()), 'QML runtime error'
                print(json.dumps({'nativeReady': sum(w['imageReady'] for w in current['windows']), 'windows': len(current['windows']),
                                  'captureViewsWhileOpen': current['captureViews'], 'captureViewsWhenClosed': hidden['captureViews'],
                                  'firstFrameMs': current['firstFrameMs'], 'desktopUnchanged': True}))
            except Exception:
                try:
                    s = status()
                    print(json.dumps({k: s.get(k) for k in ('visible', 'opening', 'closing', 'busy', 'captureViews', 'previewError', 'motionProgress')}))
                    print('Preview reasons:', [w.get('reason') for w in s['windows']])
                except Exception: pass
                log.flush(); log.seek(0); print(log.read()[-10000:])
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
