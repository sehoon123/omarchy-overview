"""The fake quickshell reproduces what quickshell 0.3.2 was observed to do. With no
live instance, `ipc call` exits 255 and prints `No running instances for ...`.
A live instance answers with exit 0 and the handler's reply, but while it is busy
or frozen the client simply waits. Every request a live instance has received
still takes effect, even after the client stopped waiting. An instance on another
display adds `Some instances on other displays match:`, and a non-UTF-8 locale
puts a Qt warning before everything the client prints. `--daemonize` leaves a
daemon behind that keeps the descriptors it inherited beyond stdin, stdout and
stderr.
"""
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / 'integrations' / 'omarchy-overview'
UNIT = ROOT / 'integrations' / 'sehun-overview.service'
KEY_DEADLINE = 2.0
SLACK = 0.75
HARNESS_LIMIT = 8.0

FAKE_QUICKSHELL = r'''#!/usr/bin/python3 -IS
import json, os, sys, time
from pathlib import Path
BOX = Path(__file__).resolve().parents[1]
world = json.loads((BOX / 'world.json').read_text())

def log(name, *fields):
    with open(BOX / name, 'a') as f:
        f.write(json.dumps(fields) + '\n')

def lines(name):
    try:
        return [json.loads(l) for l in (BOX / name).read_text().splitlines()]
    except FileNotFoundError:
        return []

def born():
    if world.get('running', True):
        return float('-inf')
    starts = lines('starts.log')
    return starts[0][0] + world.get('starts_in', 0.05) if starts else None

def gone():
    stops = lines('shutdown.log')
    later = world.get('stops_in', 0.05)
    return stops[0][0] + later if stops and later is not None else None

def alive(t):
    b, g = born(), gone()
    return b is not None and t >= b and (g is None or t < g)

args = sys.argv[1:]
# Python's C locale coercion (PEP 538) rewrites LC_CTYPE in os.environ.
env = dict(kv.split('=', 1) for kv in Path('/proc/self/environ').read_text().split('\0') if '=' in kv)
locale = env.get('LC_ALL') or env.get('LC_CTYPE') or env.get('LANG') or 'C'
if 'utf8' not in locale.lower().replace('-', ''):
    print('  WARN: Detected locale "C" with character encoding "ANSI_X3.4-1968", which is not UTF-8.')
    print('Qt depends on a UTF-8 locale, and has switched to "C.UTF-8" instead.')
if args[:1] != ['ipc']:
    log('starts.log', time.time(), 'daemonize')
    if os.fork() == 0:
        time.sleep(5)
        os._exit(0)
    sys.exit(0)
now = time.time()
if not alive(now):
    print('%s "%s/shell.qml"' % (world.get('no_instances', 'No running instances for'), args[args.index('-p') + 1]))
    sys.exit(255)
if world.get('socket_error'):
    print(' ERROR quickshell.ipc: Socket Error QLocalSocket::ServerNotFoundError')
    sys.exit(255)
if world.get('other_display'):
    print('No running instances for "%s/shell.qml"  present on the current display "wayland/wayland-1"'
          % args[args.index('-p') + 1])
    print('Some instances on other displays match:')
    print(' - 4iw6rydfot (unk)')
    sys.exit(255)
call = args[args.index('call') + 2:]
steps = world.get('replies', {}).get(call[0], ['{}' if call[0] == 'status' else 'ok'])
seen = sum(1 for entry in lines('calls.log') if entry[1] == call[0])
step = steps[min(seen, len(steps) - 1)]
step = step if isinstance(step, dict) else {'reply': step}
log('calls.log', now, *call)
if step.get('reply', 'ok') == 'ok':
    log('shutdown.log' if call[0] == 'shutdown' else 'applied.log', now, *call)
after = step.get('after', 0)
answer_at = max(now, born() + world.get('loads_for', 0)) + (1e9 if after == 'never' else after)
limit = now + 20
while time.time() < min(answer_at, limit):
    if not alive(time.time()):
        print(' ERROR quickshell.ipc: Socket Error QLocalSocket::PeerClosedError')
        print(' ERROR quickshell.ipc: Error occurred while waiting for response.')
        sys.exit(0)
    time.sleep(0.01)
print(step.get('reply', 'ok'))
'''

FAKE_SYSTEMCTL = r'''#!/usr/bin/python3 -IS
import json, sys, time
from pathlib import Path
BOX = Path(__file__).resolve().parents[1]
mode = json.loads((BOX / 'world.json').read_text()).get('systemctl', 'ok')
def log(name, *fields):
    with open(BOX / name, 'a') as f:
        f.write(json.dumps(fields) + '\n')
log('systemctl.log', time.time(), *sys.argv[1:])
if 'start' in sys.argv:
    if mode == 'hang':
        time.sleep(20)
    if mode == 'fail':
        print('Failed to start sehun-overview.service: Unit sehun-overview.service not found.', file=sys.stderr)
        sys.exit(5)
    log('starts.log', time.time(), 'systemctl')
'''

FAKE_NOTIFY_SEND = r'''#!/usr/bin/python3 -IS
import json, sys, time
from pathlib import Path
BOX = Path(__file__).resolve().parents[1]
with open(BOX / 'notify.log', 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\n')
if json.loads((BOX / 'world.json').read_text()).get('notify') == 'hang':
    time.sleep(20)
'''

FAKE_LOCK_CHECK = r'''#!/usr/bin/python3 -IS
import json, sys, time
from pathlib import Path
BOX = Path(__file__).resolve().parents[1]
mode = json.loads((BOX / 'world.json').read_text()).get('lock_check', 'unlocked')
with open(BOX / 'lockcheck.log', 'a') as f:
    f.write(json.dumps([time.time()]) + '\n')
if mode == 'hang':
    time.sleep(20)
sys.exit(0 if mode == 'locked' else 1)
'''

FAKE_CONTROLLER = r'''import fcntl, json, signal, sys, time
from pathlib import Path
BOX = Path(__file__).resolve().parents[3]
world = json.loads((BOX / 'world.json').read_text())
def log(*fields):
    with open(BOX / 'controller.log', 'a') as f:
        f.write(json.dumps([time.time(), *fields]) + '\n')
def stop(status):
    log('end')
    sys.exit(status)
signal.signal(signal.SIGTERM, lambda *_: stop(143))
log('start', *sys.argv[1:])
with open(BOX / 'actions.lock', 'a') as lock:
    deadline = time.monotonic() + 1.5
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.monotonic() >= deadline:
                print('{"ok": false, "error": "Another overview action is still running"}')
                stop(1)
            time.sleep(0.02)
    if 'controller_error' in world:
        print(json.dumps({'ok': False, 'error': world['controller_error']}))
        stop(1)
    log('fired', *sys.argv[1:])
    time.sleep(0.06)
log('end')
print('{"ok": true}')
'''


def kill_sessions(sids):
    for pid in filter(str.isdigit, os.listdir('/proc')):
        try:
            sid = int(Path('/proc', pid, 'stat').read_text().rsplit(')', 1)[1].split()[3])
            if sid in sids:
                os.kill(int(pid), signal.SIGKILL)
        except (OSError, IndexError, ValueError):
            pass


class Press:
    def __init__(self, box, args):
        self.log = box.root / f'stderr-{len(box.sessions)}'
        with open(self.log, 'w') as stderr:
            self.started = time.time()
            self.proc = subprocess.Popen(['/usr/bin/bash', str(LAUNCHER), *args], env=box.env,
                                         stdout=subprocess.DEVNULL, stderr=stderr, start_new_session=True)
        box.sessions.add(self.proc.pid)
        self.ended = self.rc = None

    @property
    def elapsed(self):
        return self.ended - self.started

    @property
    def stderr(self):
        return self.log.read_text()


def wait_all(presses, limit=HARNESS_LIMIT):
    until = time.time() + limit
    pending = list(presses)
    while pending and time.time() < until:
        for press in [p for p in pending if p.proc.poll() is not None]:
            press.ended, press.rc = time.time(), press.proc.returncode
            pending.remove(press)
        time.sleep(0.005)
    for press in pending:
        press.ended, press.rc = time.time(), 'still running after %.0f s' % limit
        kill_sessions({press.proc.pid})
        press.proc.wait()
    return presses


class Box:
    def __init__(self, case, lang='C.UTF-8', **world):
        self.root = Path(tempfile.mkdtemp(prefix='ov-launcher-'))
        self.sessions = set()
        case.addCleanup(shutil.rmtree, self.root, True)
        case.addCleanup(kill_sessions, self.sessions)
        overview = self.root / 'cfg' / 'omarchy' / 'overview'
        overview.mkdir(parents=True)
        (overview / 'controller.py').write_text(FAKE_CONTROLLER)
        (self.root / 'run').mkdir(mode=0o700)
        (self.root / 'home').mkdir()
        fakes = {'quickshell': FAKE_QUICKSHELL, 'systemctl': FAKE_SYSTEMCTL, 'notify-send': FAKE_NOTIFY_SEND,
                 'omarchy-hyprland-session-locked': FAKE_LOCK_CHECK}
        (self.root / 'bin').mkdir()
        for name, text in fakes.items():
            path = self.root / 'bin' / name
            path.write_text(text)
            path.chmod(0o755)
        self.world = world
        self.update()
        self.env = {'PATH': f'{self.root / "bin"}:/usr/bin:/bin', 'HOME': str(self.root / 'home'),
                    'XDG_RUNTIME_DIR': str(self.root / 'run'), 'XDG_CONFIG_HOME': str(self.root / 'cfg'),
                    'LANG': lang}

    def update(self, **changes):
        self.world.update(changes)
        (self.root / 'world.json').write_text(json.dumps(self.world))

    def start(self, *args):
        return Press(self, args)

    def press(self, *args, limit=HARNESS_LIMIT):
        return wait_all([self.start(*args)], limit)[0]

    def lines(self, name):
        path = self.root / name
        return [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []

    def count(self, name, call):
        return sum(1 for entry in self.lines(name) if entry[1] == call)

    def notices(self):
        return [args[-1] for args in self.lines('notify.log')]

    def controller(self, event):
        return [entry[0] for entry in self.lines('controller.log') if entry[1] == event]


class LauncherTestCase(unittest.TestCase):
    def assertVisibleFailure(self, box, press, within=KEY_DEADLINE + SLACK):
        self.assertNotEqual(0, press.rc, 'a press that did nothing must not report success')
        self.assertLess(press.elapsed, within, f'the press must fail within {within:.2f} s')
        notices = box.notices()
        self.assertEqual(1, len(notices), f'exactly one notification for the failed press: {notices}')
        self.assertIn(notices[0], press.stderr, 'the notification repeats the stderr message')

    def assertQuietSuccess(self, box, press):
        self.assertEqual(0, press.rc, press.stderr)
        self.assertEqual([], box.notices())


class TogglePathTests(LauncherTestCase):
    def test_a_running_overview_toggles_once_without_starting_anything(self):
        for lang in ('C.UTF-8', 'C'):
            with self.subTest(lang=lang):
                box = Box(self, lang=lang, replies={'toggle': ['ok']})
                press = box.press('--app')
                self.assertEqual([['toggle', 'app']], [entry[1:] for entry in box.lines('applied.log')])
                self.assertQuietSuccess(box, press)
                self.assertLess(press.elapsed, 1.0)
                self.assertEqual([], box.lines('systemctl.log'))

    def test_a_locked_session_gets_neither_overview_nor_a_switch(self):
        box = Box(self, lock_check='locked', running=False)
        for args in ((), ('--app',), ('--next',)):
            self.assertQuietSuccess(box, box.press(*args))
        self.assertEqual([], box.lines('calls.log') + box.lines('systemctl.log') + box.lines('controller.log'))

    def test_refusals_have_no_side_effect_and_are_retried_until_accepted(self):
        box = Box(self, replies={'toggle': ['closing', 'Not ready to accept queries yet.', 'ok']})
        press = box.press()
        self.assertQuietSuccess(box, press)
        self.assertEqual(3, box.count('calls.log', 'toggle'))
        self.assertEqual(1, box.count('applied.log', 'toggle'))

    def test_an_ipc_error_is_notified_in_a_fixed_sentence_and_journaled_under_any_locale(self):
        # quickshell's own error lines can name the config path, which a
        # notification would keep in the notification history.
        boxes = [Box(self, lang=lang, socket_error=True) for lang in ('C.UTF-8', 'C')]
        presses = wait_all([box.start('--app') for box in boxes])
        for box, press in zip(boxes, presses):
            with self.subTest(lang=box.env['LANG']):
                self.assertVisibleFailure(box, press)
                self.assertEqual(['Overview could not be reached'], box.notices())
                self.assertIn('Socket Error', press.stderr)

    def test_a_retry_that_gets_no_answer_is_reported_as_unanswered(self):
        # Overview still runs a request it gave no answer to, so the press may yet
        # take effect, and the refusal before that request is not why it failed.
        replies = {'the retry never answers': ['closing', {'after': 'never'}],
                   'the deadline cuts the retry short': [{'reply': 'closing', 'after': 1.5}]}
        cases = [(name, args, Box(self, replies={call: steps}))
                 for name, steps in replies.items()
                 for args, call in (('--app', 'toggle'), ('--next', 'navigateDesktop'))]
        presses = wait_all([box.start(args) for _, args, box in cases])
        for (name, args, box), press in zip(cases, presses):
            with self.subTest(name, args=args):
                self.assertVisibleFailure(box, press)
                self.assertEqual(['Overview did not answer within 2 seconds (last answer: closing)'], box.notices())

    def test_a_stopped_overview_is_started_then_toggled_once_per_press(self):
        for systemctl in ('ok', 'fail'):
            with self.subTest(systemctl=systemctl):
                box = Box(self, running=False, systemctl=systemctl, starts_in=0.1)
                press = box.press('--app')
                self.assertQuietSuccess(box, press)
                self.assertEqual(1, box.count('applied.log', 'toggle'))
                self.assertQuietSuccess(box, box.press('--app'))
                self.assertEqual(2, box.count('applied.log', 'toggle'), 'the started daemon holds no press lock')

    def test_an_overview_that_does_not_answer_fails_visibly_and_is_never_retried(self):
        box = Box(self, replies={'toggle': [{'after': 'never'}]})
        first = box.start('--app')
        time.sleep(0.5)
        second = box.start('--app')
        wait_all([first, second])
        self.assertVisibleFailure(box, first)
        self.assertEqual(0, second.rc, 'a press during an unfinished press is dropped')
        self.assertEqual(1, box.count('calls.log', 'toggle'),
                         'a live instance applies every toggle it received, so only one may be sent')
        self.assertEqual([], box.lines('systemctl.log'), 'a live instance that is slow is not a stopped one')
        box.update(replies={'toggle': ['ok']})
        third = box.press('--app')
        self.assertEqual(0, third.rc, 'the next press is not swallowed by a stale lock')
        self.assertEqual(2, box.count('calls.log', 'toggle'))

    def test_a_late_reply_is_never_retried_into_a_second_toggle(self):
        boxes = {
            'reply 1.2 s late': Box(self, replies={'toggle': [{'after': 1.2}, 'ok']}),
            'cold start that loads for 1.2 s': Box(self, running=False, starts_in=0.05, loads_for=1.2),
        }
        presses = wait_all([box.start('--app') for box in boxes.values()])
        for (name, box), press in zip(boxes.items(), presses):
            with self.subTest(name):
                self.assertEqual(1, box.count('applied.log', 'toggle'), 'one press, one toggle')
                self.assertQuietSuccess(box, press)

    def test_a_press_that_cannot_reach_overview_fails_within_the_deadline(self):
        boxes = {
            'systemctl --user start never returns': Box(self, running=False, systemctl='hang'),
            'the session lock check never returns': Box(self, lock_check='hang'),
            'notify-send never returns': Box(self, replies={'toggle': [{'after': 'never'}]}, notify='hang'),
            'an instance is alive but its socket is unreachable': Box(self, socket_error=True),
            'an instance runs on another display': Box(self, other_display=True),
        }
        presses = [box.start('--app') for box in boxes.values()]
        time.sleep(0.3)
        stuck = boxes['the session lock check never returns']
        wait_all(presses + [stuck.start('--app')])
        for (name, box), press in zip(boxes.items(), presses):
            with self.subTest(name):
                notify_limit = 1 if name == 'notify-send never returns' else 0
                self.assertVisibleFailure(box, press, KEY_DEADLINE + SLACK + notify_limit)
                if name.startswith('an instance'):
                    self.assertEqual([], box.lines('systemctl.log'), 'a live instance is not a stopped one')
        self.assertEqual(1, len(stuck.lines('lockcheck.log')), 'a press during a stuck lock check is dropped')


class StepPathTests(LauncherTestCase):
    def test_the_cli_switch_runs_only_when_overview_is_not_running_or_unavailable(self):
        cases = {
            'not running': (dict(running=False), 1),
            'unavailable': (dict(replies={'navigateDesktop': ['unavailable']}), 1),
            'unavailable, under a C locale': (dict(lang='C', replies={'navigateDesktop': ['unavailable']}), 1),
            'ok': (dict(replies={'navigateDesktop': ['ok']}), 0),
        }
        for name, (world, switches) in cases.items():
            with self.subTest(name):
                box = Box(self, **world)
                press = box.press('--next')
                self.assertQuietSuccess(box, press)
                self.assertEqual(switches, len(box.controller('fired')))

    def test_a_step_ends_quietly_only_on_ok_and_any_other_answer_is_asked_again(self):
        # Each list mixes Overview's refusals with exit-0 messages quickshell prints itself.
        transient = ['closing', 'opening', 'activating', 'busy', 'Not ready to accept queries yet.']
        persistent = ['shutdown', 'settings', 'Target not found.',
                      ' ERROR quickshell.ipc: Error occurred while waiting for response.', '']
        cases = [(reply, Box(self, replies={'navigateDesktop': [reply, 'ok']}), True) for reply in transient]
        cases += [(reply, Box(self, replies={'navigateDesktop': [reply]}), False) for reply in persistent]
        presses = wait_all([box.start('--next') for _, box, _ in cases])
        for (reply, box, took), press in zip(cases, presses):
            with self.subTest(reply=reply):
                self.assertEqual([], box.lines('controller.log'), 'a live Overview gets no switch behind it')
                if took:
                    self.assertQuietSuccess(box, press)
                    self.assertEqual(1, box.count('applied.log', 'navigateDesktop'), 'asked again until it took')
                else:
                    self.assertVisibleFailure(box, press)

    def test_a_slow_or_silent_overview_never_gets_a_desktop_switched_behind_it(self):
        slow = Box(self, replies={'navigateDesktop': [{'after': 1.5}]})
        slow_press = slow.start('--next')
        unproven = {
            'no answer': Box(self, replies={'navigateDesktop': [{'after': 'never'}]}),
            'unreachable socket': Box(self, socket_error=True),
            'another display': Box(self, other_display=True),
        }
        presses = wait_all([slow_press] + [box.start('--previous') for box in unproven.values()])
        self.assertEqual([], slow.lines('controller.log'), 'a late `ok` is still Overview moving its own filter')
        self.assertQuietSuccess(slow, slow_press)
        for (name, box), press in zip(unproven.items(), presses[1:]):
            with self.subTest(name):
                self.assertEqual([], box.lines('controller.log'), 'only `No running instances` proves Overview gone')
                self.assertVisibleFailure(box, press)

    def test_a_cli_switch_that_fails_says_so_in_a_fixed_sentence(self):
        # controller.py's error can quote Hyprland, a workspace name included.
        locked = Box(self, running=False)
        late = Box(self, replies={'navigateDesktop': [{'reply': 'unavailable', 'after': 1.0}]})
        refused = Box(self, running=False, controller_error='Hyprland: no workspace named Payroll')
        for box in (locked, late):
            holder = open(box.root / 'actions.lock', 'a')
            self.addCleanup(holder.close)
            fcntl.flock(holder, fcntl.LOCK_EX)
        cases = {'it cannot take the action lock': (locked, 'The desktop switch failed'),
                 'it outlives the deadline': (late, 'The desktop switch did not finish within 2 seconds'),
                 'Hyprland refuses it': (refused, 'The desktop switch failed')}
        presses = wait_all([box.start('--next') for box, _ in cases.values()])
        for (name, (box, sentence)), press in zip(cases.items(), presses):
            with self.subTest(name):
                self.assertEqual(1, len(box.controller('start')), 'the CLI switch ran')
                self.assertVisibleFailure(box, press)
                self.assertEqual([sentence], box.notices())
        self.assertIn('Another overview action is still running', presses[0].stderr, 'the journal keeps the reason')
        self.assertIn('no workspace named Payroll', presses[2].stderr, 'the journal keeps the reason')

    def test_a_press_stopped_by_a_signal_stops_its_cli_switch(self):
        for sig, status in ((signal.SIGTERM, 143), (signal.SIGINT, 130)):
            with self.subTest(sig.name):
                box = Box(self, running=False)
                holder = open(box.root / 'actions.lock', 'a')
                self.addCleanup(holder.close)
                fcntl.flock(holder, fcntl.LOCK_EX)
                press = box.start('--next')
                until = time.time() + KEY_DEADLINE
                while not box.controller('start') and time.time() < until:
                    time.sleep(0.01)
                self.assertTrue(box.controller('start'), 'the CLI switch is waiting for the action lock')
                os.kill(press.proc.pid, sig)
                time.sleep(0.2)
                holder.close()
                wait_all([press])
                time.sleep(0.3)
                self.assertEqual([], box.controller('fired'), 'the switch stops with the press')
                self.assertEqual(1, len(box.controller('end')))
                self.assertEqual(status, press.rc, press.stderr)
                self.assertEqual([], box.notices())

    def test_a_held_step_key_never_stacks_switches(self):
        box = Box(self, running=False)
        presses = []
        for _ in range(34):
            presses.append(box.start('--next'))
            time.sleep(0.03)
        released = time.time()
        wait_all(presses)
        fired = box.controller('fired')
        self.assertTrue(fired, 'holding the key still switches desktops')
        events = sorted([(t, 1) for t in box.controller('start')] + [(t, -1) for t in box.controller('end')])
        running = peak = 0
        for _, delta in events:
            running += delta
            peak = max(peak, running)
        self.assertEqual(1, peak, 'at most one desktop switch is in flight')
        self.assertLess(max(fired) - released, 0.5, 'no switch fires long after the key was released')


class ShutdownTests(LauncherTestCase):
    def test_shutdown_reports_the_process_gone_only_once_it_is(self):
        stop_budget = int(re.search(r'^TimeoutStopSec=(\d+)$', UNIT.read_text(), re.M).group(1))
        worlds = {
            'status answers until it exits': dict(stops_in=1.5),
            'status hangs until it exits': dict(stops_in=1.5, replies={'status': [{'after': 'never'}]}),
            'the shutdown reply never comes': dict(stops_in=1.5, replies={'shutdown': [{'after': 'never'}]}),
            'quickshell answers the first shutdown itself':
                dict(stops_in=0.05, replies={'shutdown': ['Not ready to accept queries yet.', 'ok']}),
            'exits after the 3 s watchdog': dict(stops_in=4.0),
            'never exits, status answers': dict(stops_in=None),
            'never exits, status hangs': dict(stops_in=None, replies={'status': [{'after': 'never'}]}),
            'never exits, its socket is unreachable': dict(stops_in=None, socket_error=True),
            'never exits, it runs on another display': dict(stops_in=None, other_display=True),
            'not running': dict(running=False),
            'not running, under a C locale': dict(running=False, lang='C'),
        }
        boxes = {name: Box(self, **world) for name, world in worlds.items()}
        presses = wait_all([box.start('--shutdown') for box in boxes.values()], stop_budget + 2)
        for (name, box), press in zip(boxes.items(), presses):
            with self.subTest(name):
                stops = box.lines('shutdown.log')
                stops_in = box.world.get('stops_in', 0.05)
                self.assertLessEqual(len(stops), 1, 'a second shutdown would restart the 3 s watchdog')
                if name.startswith('not running'):
                    self.assertEqual(0, press.rc, press.stderr)
                    self.assertLess(press.elapsed, 0.5)
                elif stops_in is None:
                    self.assertEqual(1, press.rc, 'a process that is still alive is not reported gone')
                    self.assertTrue(press.stderr, 'the journal says why the stop failed')
                    self.assertLess(press.elapsed, stop_budget - 1, 'ExecStop has to finish before TimeoutStopSec')
                else:
                    self.assertEqual(1, len(stops), 'the shutdown reached Overview')
                    early = stops[0][0] + stops_in - press.ended
                    self.assertLessEqual(early, 0, f'reported gone {early:.2f} s before the process exited')
                    self.assertEqual(0, press.rc, press.stderr)
                    self.assertLess(-early, SLACK, 'reported promptly once it was gone')
                self.assertEqual([], box.notices(), 'ExecStop reports to the journal only')

    def test_a_main_process_that_exited_is_gone_whatever_quickshell_prints(self):
        with self.subTest('the unit passes ${MAINPID}'):
            self.assertRegex(UNIT.read_text(), r'(?m)^ExecStop=\S+ --shutdown \$\{MAINPID\}$')
        main, exited = subprocess.Popen(['/usr/bin/sleep', '1.5']), []
        self.addCleanup(main.kill)

        def reap():
            main.wait()
            exited.append(time.time())
        threading.Thread(target=reap, daemon=True).start()
        reworded = 'No instance is running for'
        crashed = Box(self, running=False, no_instances=reworded)
        stopping = Box(self, stops_in=1.5, no_instances=reworded)
        crash, stop = wait_all([crashed.start('--shutdown', ''), stopping.start('--shutdown', str(main.pid))], 12)
        with self.subTest('systemd already saw it exit'):
            self.assertEqual(0, crash.rc, crash.stderr)
            self.assertLess(crash.elapsed, 0.5, 'an empty ${MAINPID} means the main process exited')
        with self.subTest('it exits during the stop'):
            self.assertEqual(0, stop.rc, stop.stderr)
            self.assertGreaterEqual(stop.ended, exited[0], 'reported gone only once the main process exited')
            self.assertLess(stop.ended - exited[0], SLACK, 'reported promptly once it was gone')


    def test_a_stop_for_a_main_process_that_is_gone_leaves_other_instances_alone(self):
        # Whatever answers on the config path then is not the unit's main process,
        # for example a daemon a press started when the service would not start.
        gone = subprocess.Popen(['/usr/bin/true'])
        gone.wait()
        cases = {'systemd already saw it exit': '', 'its PID is gone': str(gone.pid)}
        boxes = {name: Box(self, stops_in=0.05) for name in cases}
        presses = wait_all([boxes[name].start('--shutdown', pid) for name, pid in cases.items()])
        for (name, box), press in zip(boxes.items(), presses):
            with self.subTest(name):
                self.assertEqual(0, press.rc, press.stderr)
                self.assertLess(press.elapsed, 0.5)
                self.assertEqual([], box.lines('calls.log'), 'no request reaches the instance that answers')


class QuickshellContractTests(unittest.TestCase):
    def test_quickshell_still_reports_no_instance_the_way_the_launcher_reads_it(self):
        quickshell = shutil.which('quickshell')
        if quickshell is None:
            self.skipTest('quickshell is not on PATH, so its `No running instances for` reply went unchecked')
        root = Path(tempfile.mkdtemp(prefix='ov-contract-'))
        self.addCleanup(shutil.rmtree, root, True)
        # Without a shell.qml, quickshell 0.3.2 exits 255 with `Could not open config file` instead.
        (root / 'shell.qml').touch()
        run = subprocess.run([quickshell, 'ipc', '-p', str(root), 'call', 'overview', 'status'], capture_output=True,
                             text=True, timeout=10, env={'PATH': '/usr/bin:/bin', 'HOME': str(root),
                                                         'XDG_RUNTIME_DIR': str(root), 'NO_COLOR': '1'})
        lines = run.stdout.splitlines()
        self.assertEqual(255, run.returncode, run.stdout + run.stderr)
        self.assertTrue([line for line in lines if line.startswith('No running instances for ')],
                        f'quickshell changed its no-instance reply {lines}; ipc() in integrations/omarchy-overview '
                        'and FAKE_QUICKSHELL read `No running instances for` as "not running"')


if __name__ == '__main__':
    unittest.main()
