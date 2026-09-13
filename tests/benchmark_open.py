#!/usr/bin/env python3
"""Opt-in visible benchmark. Do not interact with the desktop while it runs.

Measures command -> IPC visible/all-captures-ready, NOT compositor presentation.
Opens/closes Overview four times; never moves windows between workspaces.
Use --cold to gracefully restart the overview service before the first sample.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import time

config = Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home() / '.config'))) / 'omarchy/overview'
probe = ['quickshell', 'ipc', '-p', str(config), 'call', 'overview']

def status():
    result = subprocess.run([*probe, 'status'], capture_output=True, text=True, timeout=2)
    return json.loads(result.stdout) if result.returncode == 0 else None

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cold', action='store_true')
    args = parser.parse_args()
    initial = status()
    if initial and (initial['visible'] or initial['busy']):
        raise SystemExit('Close Overview and wait for any action to finish first.')
    if args.cold:
        subprocess.run(['systemctl', '--user', 'restart', 'sehun-overview.service'], check=True)
        time.sleep(.5)
    samples = []
    try:
        for index in range(4):
            start = time.monotonic()
            subprocess.run(['omarchy-overview'], check=True, capture_output=True, timeout=5)
            opened = None
            while time.monotonic() - start < 5:
                current = status()
                if not current or not current['visible']:
                    raise RuntimeError('Overview closed during measurement; retry without desktop input.')
                if opened is None: opened = time.monotonic() - start
                if current['windows'] and all(w['thumbnail'] for w in current['windows']) and not current['busy'] and not current.get('preparing', False) and current.get('firstFrameMs', 0) >= 0:
                    break
                time.sleep(.015)
            else:
                raise RuntimeError('Some previews are unavailable; cannot report a full-ready time.')
            samples.append({'run': index + 1, 'open_ms': round(opened * 1000),
                            'ready_ms': round((time.monotonic() - start) * 1000),
                            'window_count': len(current['windows']), 'primed': len(current['primed']),
                            'first_qt_frame_ms': current.get('firstFrameMs')})
            subprocess.run([*probe, 'close'], check=True, capture_output=True, timeout=2)
            time.sleep(.3)
            hidden = status()
            if not hidden or hidden['visible']:
                raise RuntimeError('Resident process did not survive closing.')
        print(json.dumps({'samples': samples, 'warm_median_ready_ms': statistics.median(s['ready_ms'] for s in samples[1:])}, indent=2))
    finally:
        subprocess.run([*probe, 'close'], capture_output=True, timeout=2)

if __name__ == '__main__': main()
