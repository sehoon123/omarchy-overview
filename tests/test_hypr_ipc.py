import contextlib
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import hypr_ipc

# Nothing a compositor could send — a window title, a data URL, raw pixel bytes —
# may reappear in an error string. These markers are planted and then asserted absent.
HOSTILE = 'Secret Document.pdf \x01 data:image/png;base64,iVBORw0KGgoAAAANS pixel-bytes'

class SocketTests(unittest.TestCase):
    def test_fragmented_reply_and_exact_wire_format(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / 'ipc.sock')
            received = []
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path); server.listen(1)
                def serve():
                    with server.accept()[0] as connection:
                        received.append(connection.recv(4096))
                        connection.sendall(b'[{"id":')
                        connection.sendall(b'1}]')
                thread = threading.Thread(target=serve); thread.start()
                self.assertEqual(hypr_ipc.call('-j', 'workspaces', json_output=True, path=path), [{'id': 1}])
                thread.join(timeout=1)
                self.assertEqual(received, [b'j/workspaces'])

    def test_rejects_framing_characters(self):
        for arg in ['bad\nrequest', 'bad\0request']:
            with self.assertRaises(ValueError): hypr_ipc.call(arg, path='/not-used')


@contextlib.contextmanager
def listener(handler):
    """One local AF_UNIX server in a temp dir — never the live compositor socket.

    `handler(connection, hold)` may wait on `hold` to keep the connection open
    (no EOF) after replying; the fixture always releases it and joins.
    """
    hold = threading.Event()
    with tempfile.TemporaryDirectory() as directory:
        path = str(Path(directory) / 'ipc.sock')
        received, failures = [], []
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(path); server.listen(1)
            def serve():
                try:
                    with server.accept()[0] as connection:
                        received.append(connection.recv(4096))
                        handler(connection, hold)
                except Exception as error:  # a client that gave up is not a test failure
                    failures.append(error)
            thread = threading.Thread(target=serve, daemon=True); thread.start()
            try:
                yield path, received
            finally:
                hold.set()
                thread.join(timeout=2)


class FakeClock:
    """A monotonic clock only the test moves, so no test waits on a real one."""
    def __init__(self): self.now = 1000.0

    def __call__(self): return self.now


class FakeSocket:
    """A socket whose connect() spends budget. Records the order of every call,
    so a phase that is handed a *fresh* timeout instead of the remainder shows up."""
    def __init__(self, clock, cost, chunks):
        self.clock, self.cost, self.chunks = clock, cost, list(chunks)
        self.events, self.sent, self.receives = [], None, 0

    @property
    def timeouts(self):
        return [value for name, value in self.events if name == 'timeout']

    def __enter__(self): return self

    def __exit__(self, *error): return False

    def settimeout(self, value): self.events.append(('timeout', value))

    def connect(self, path):
        self.events.append(('connect', None))
        self.clock.now += self.cost

    def sendall(self, payload):
        self.events.append(('sendall', None))
        self.sent = payload

    def recv(self, size):
        self.events.append(('recv', None))
        self.receives += 1
        return self.chunks.pop(0) if self.chunks else b''


class SessionEnvironmentTests(unittest.TestCase):
    def test_missing_session_environment_names_the_role_not_the_value(self):
        for missing in ('XDG_RUNTIME_DIR', 'HYPRLAND_INSTANCE_SIGNATURE'):
            environment = {'XDG_RUNTIME_DIR': '/run/user/1000', 'HYPRLAND_INSTANCE_SIGNATURE': 'sig_secret_value'}
            del environment[missing]
            with self.subTest(missing=missing), patch.dict(os.environ, environment, clear=True):
                # A bare KeyError used to reach the toast as just the variable name.
                with self.assertRaises(RuntimeError) as caught:
                    hypr_ipc.call('monitors', json_output=True, timeout=.2)
                self.assertEqual(str(caught.exception), 'Hyprland session environment is unavailable')
                self.assertNotIn('sig_secret_value', str(caught.exception))
                self.assertNotIn('/run/user', str(caught.exception))

    def test_an_explicit_path_never_reads_the_environment(self):
        with patch.dict(os.environ, {}, clear=True):
            with listener(lambda connection, hold: connection.sendall(b'ok')) as (path, received):
                self.assertEqual(hypr_ipc.call('version', path=path), 'ok')
            self.assertEqual(received, [b'/version'])


class TransportFailureTests(unittest.TestCase):
    def test_missing_or_refused_socket_reports_one_clear_error(self):
        with tempfile.TemporaryDirectory() as directory:
            # A path that does not exist, then a directory: ENOENT and ECONNREFUSED.
            for path in [str(Path(directory) / 'absent.sock'), directory]:
                with self.subTest(path=path):
                    with self.assertRaises(RuntimeError) as caught:
                        hypr_ipc.call('monitors', json_output=True, path=path, timeout=.2)
                    self.assertIsInstance(caught.exception, hypr_ipc.Unreachable)
                    self.assertEqual(str(caught.exception), 'Hyprland is not reachable')
                    self.assertNotIn(directory, str(caught.exception))
                    self.assertNotIn('Errno', str(caught.exception))

    def test_non_utf8_reply_is_not_a_codec_error(self):
        def handler(connection, hold):
            connection.sendall(b'[{"name":"\xff\xfe' + HOSTILE.encode() + b'"}]')
        with listener(handler) as (path, _):
            with self.assertRaises(RuntimeError) as caught:
                hypr_ipc.call('monitors', json_output=True, path=path, timeout=.5)
        message = str(caught.exception)
        self.assertIsInstance(caught.exception, hypr_ipc.Unreadable)
        self.assertEqual(message, 'Hyprland sent a reply Overview could not read')
        for leak in ('codec', 'Secret', 'data:image', 'pixel-bytes'):
            self.assertNotIn(leak, message)

    def test_malformed_json_reply_is_reported_without_its_content(self):
        with listener(lambda connection, hold: connection.sendall(b'[{"title":"' + HOSTILE.encode() + b'"')) as (path, _):
            with self.assertRaises(RuntimeError) as caught:
                hypr_ipc.call('clients', json_output=True, path=path, timeout=.5)
        self.assertEqual(str(caught.exception), 'Hyprland sent a reply Overview could not read')
        self.assertNotIn('Secret', str(caught.exception))
        self.assertNotIn('Expecting value', str(caught.exception))

    def test_an_empty_reply_keeps_its_own_message_on_both_paths(self):
        for json_output in (False, True):
            with self.subTest(json_output=json_output), listener(lambda connection, hold: None) as (path, _):
                with self.assertRaises(RuntimeError) as caught:
                    hypr_ipc.call('version', json_output=json_output, path=path, timeout=.5)
                self.assertEqual(str(caught.exception), 'Empty compositor response; request not retried')

    def test_compositor_error_text_is_bounded_to_one_line(self):
        marker = 'SECRET-WINDOW-TITLE'
        reply = ('Invalid dispatcher\nstack:\t' + 'x' * 200000 + marker).encode()
        with listener(lambda connection, hold: connection.sendall(reply)) as (path, _):
            with self.assertRaises(RuntimeError) as caught:
                hypr_ipc.call('version', path=path, timeout=.5)
        message = str(caught.exception)
        self.assertLessEqual(len(message), hypr_ipc.MAX_MESSAGE)
        self.assertTrue(message.startswith('Invalid dispatcher stack: x'))
        self.assertNotIn(marker, message)
        self.assertNotIn('\n', message)
        self.assertNotIn('\t', message)

    def test_a_reply_with_nothing_printable_is_never_an_empty_message(self):
        with listener(lambda connection, hold: connection.sendall(b'\x00\x01\x02' * 8)) as (path, _):
            with self.assertRaises(RuntimeError) as caught:
                hypr_ipc.call('version', path=path, timeout=.5)
        self.assertEqual(str(caught.exception), 'Hyprland sent a reply Overview could not read')

    def test_oversized_reply_is_still_refused_by_max_reply(self):
        def handler(connection, hold):
            for _ in range(4): connection.sendall(b'x' * 1024)
        with patch.object(hypr_ipc, 'MAX_REPLY', 2048), listener(handler) as (path, _):
            with self.assertRaises(RuntimeError) as caught:
                hypr_ipc.call('clients', json_output=True, path=path, timeout=.5)
        self.assertEqual(str(caught.exception), 'Compositor reply is too large')


class DeadlineTests(unittest.TestCase):
    def test_complete_reply_is_not_discarded_when_the_budget_expires(self):
        # The peer answers in full and then holds the connection open: the reply is
        # complete, only the EOF is missing, so it must not be thrown away.
        def handler(connection, hold):
            connection.sendall(b'[{"id":1}]')
            hold.wait(2)
        with listener(handler) as (path, received):
            self.assertEqual(hypr_ipc.call('monitors', json_output=True, path=path, timeout=.25), [{'id': 1}])
            self.assertEqual(received, [b'j/monitors'])

    def test_an_unfinished_reply_at_the_deadline_is_a_clear_timeout(self):
        def handler(connection, hold):
            connection.sendall(b'[{"id":')
            hold.wait(2)
        with listener(handler) as (path, received):
            with self.assertRaises(TimeoutError) as caught:
                hypr_ipc.call('monitors', json_output=True, path=path, timeout=.1)
            self.assertEqual(received, [b'j/monitors'])  # one request, never retried
        self.assertIsInstance(caught.exception, hypr_ipc.ReplyTimeout)
        self.assertEqual(str(caught.exception), 'Hyprland did not answer in time; the request was not retried')

    def test_one_budget_covers_connect_send_and_receive(self):
        clock = FakeClock()
        fake = FakeSocket(clock, .2, [b'ok'])
        with patch.object(hypr_ipc, 'time', types.SimpleNamespace(monotonic=clock)), \
             patch.object(hypr_ipc, 'socket', types.SimpleNamespace(
                 socket=lambda *a: fake, AF_UNIX=socket.AF_UNIX, SOCK_STREAM=socket.SOCK_STREAM)):
            self.assertEqual(hypr_ipc.call('version', path='/not-used', timeout=.3), 'ok')
        self.assertEqual(fake.sent, b'/version')
        # connect, send and recv each get what is left of the same budget, never a fresh one:
        # a timeout is re-derived after the connect spent .2 of the .3 s budget.
        self.assertEqual([name for name, _ in fake.events[:5]],
                         ['timeout', 'connect', 'timeout', 'sendall', 'timeout'])
        self.assertAlmostEqual(fake.timeouts[0], .3)
        self.assertTrue(all(round(value, 6) <= .1 for value in fake.timeouts[1:]), fake.timeouts)

    def test_a_connect_that_spends_the_whole_budget_never_starts_a_fresh_one(self):
        clock = FakeClock()
        fake = FakeSocket(clock, .5, [b'ok'])
        with patch.object(hypr_ipc, 'time', types.SimpleNamespace(monotonic=clock)), \
             patch.object(hypr_ipc, 'socket', types.SimpleNamespace(
                 socket=lambda *a: fake, AF_UNIX=socket.AF_UNIX, SOCK_STREAM=socket.SOCK_STREAM)):
            with self.assertRaises(TimeoutError) as caught:
                hypr_ipc.call('version', path='/not-used', timeout=.3)
        self.assertEqual(str(caught.exception), 'Hyprland did not answer in time; the request was not retried')
        self.assertEqual(fake.receives, 0)


class ContractTests(unittest.TestCase):
    def test_exception_types_downstream_callers_catch_are_unchanged(self):
        self.assertTrue(issubclass(hypr_ipc.Unreachable, RuntimeError))
        self.assertTrue(issubclass(hypr_ipc.Unreadable, RuntimeError))
        self.assertTrue(issubclass(hypr_ipc.ReplyTimeout, TimeoutError))

    def test_every_message_is_bounded_and_single_line(self):
        for text in (HOSTILE * 40, 'ok\nnot ok', '\x00\x1f  spaced  \t out ', ''):
            with self.subTest(text=text[:20]):
                message = hypr_ipc.summary(text)
                self.assertLessEqual(len(message), hypr_ipc.MAX_MESSAGE)
                self.assertNotIn('\n', message)
                self.assertNotIn('\x00', message)

    def test_transport_starts_no_subprocess(self):
        source = Path(hypr_ipc.__file__).read_text()
        for forbidden in ('import subprocess', 'os.system', 'popen', 'Popen', 'os.exec', 'run('):
            self.assertNotIn(forbidden, source)


if __name__ == '__main__': unittest.main()
