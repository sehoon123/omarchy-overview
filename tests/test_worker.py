import contextlib
import io
import json
from pathlib import Path
import queue
import sys
import threading
import types
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker as W
from worker import Worker

# Planted and then asserted absent: no protocol error may echo a window title,
# a data URL or anything resembling pixel data back to the shell.
HOSTILE = 'Secret Document.pdf \x01 data:image/png;base64,iVBORw0KGgo pixel-bytes'


class WorkerTests(unittest.TestCase):
    def test_one_completion_and_no_replay(self):
        replies = queue.Queue()
        calls = []
        entered, release = threading.Event(), threading.Event()
        def execute(packet, gate):
            calls.append(packet['id'])
            entered.set()
            release.wait(1)
            return {'ok': True}
        worker = Worker(replies.put, execute)
        try:
            worker.accept({'id': 1, 'args': ['state']})
            self.assertTrue(entered.wait(1))
            worker.accept({'id': 1, 'args': ['state']})
            self.assertTrue(replies.empty())
            release.set()
            self.assertTrue(replies.get(timeout=1)['ok'])
            with self.assertRaises(ValueError): worker.accept({'id': 1, 'args': ['state']})
            self.assertEqual(calls, [1])
        finally:
            release.set()
            worker.close()

    def test_shutdown_releases_a_waiting_transaction(self):
        replies = queue.Queue()
        entered = threading.Event()
        def execute(packet, gate):
            entered.set()
            return {'ok': True, 'cancelled': gate.cancelled.wait(1)}
        worker = Worker(replies.put, execute)
        worker.accept({'id': 7, 'args': ['state']})
        self.assertTrue(entered.wait(1))
        worker.close()
        self.assertTrue(replies.get(timeout=1)['cancelled'])

    def test_rejects_invalid_protocol_and_retired_viewport_priming(self):
        worker = Worker(lambda p: None, lambda p, g: {'ok': True})
        try:
            for packet in [[], {}, {'id': True}, {'id': 1, 'args': ['unknown']},
                           {'id': 1, 'args': ['move']}, {'id': 1, 'args': ['prime', 'abc']},
                           {'id': 1, 'type': 'frame'}, {'id': 1, 'type': 'cancel'}]:
                with self.assertRaises(ValueError): worker.accept(packet)
        finally: worker.close()


class TransactionFailureTests(unittest.TestCase):
    """A transaction that misbehaves answers once and frees the worker (F-36)."""

    def drain(self, worker, replies, ident):
        worker.accept({'id': ident, 'args': ['state']})
        return replies.get(timeout=1)

    def test_a_non_dict_result_answers_once_and_does_not_wedge_the_worker(self):
        replies = queue.Queue()
        worker = Worker(replies.put, lambda packet, gate: None)
        try:
            reply = self.drain(worker, replies, 1)
            self.assertEqual((reply['ok'], reply['id'], reply['replayed']), (False, 1, False))
            self.assertEqual(reply['error'], 'Overview backend returned an unusable result')
            self.assertIsInstance(reply['elapsedMs'], float)
            self.assertTrue(worker.thread.is_alive())
            self.assertIsNone(worker.active)
            # The next request must not be refused with "Worker is busy" forever.
            self.assertFalse(self.drain(worker, replies, 2)['ok'])
            self.assertTrue(replies.empty())
        finally: worker.close()

    def test_a_raising_transaction_answers_and_frees_the_worker(self):
        replies = queue.Queue()
        def execute(packet, gate): raise RuntimeError('Another desktop action is still running')
        worker = Worker(replies.put, execute)
        try:
            reply = self.drain(worker, replies, 4)
            self.assertEqual(reply['error'], 'Another desktop action is still running')
            self.assertEqual((reply['ok'], reply['replayed'], reply['id']), (False, False, 4))
            self.assertTrue(self.drain(worker, replies, 5)['id'], 5)
        finally: worker.close()

    def test_a_reply_that_cannot_be_emitted_does_not_kill_the_worker(self):
        delivered, first = queue.Queue(), threading.Event()
        def emit(packet):
            if packet['id'] == 1:
                first.set()
                raise TypeError('Object of type set is not JSON serializable')
            delivered.put(packet)
        worker = Worker(emit, lambda packet, gate: {'ok': True})
        try:
            worker.accept({'id': 1, 'args': ['state']})
            self.assertTrue(first.wait(1))
            self.assertTrue(worker.thread.is_alive())
            worker.accept({'id': 2, 'args': ['state']})
            self.assertEqual(delivered.get(timeout=1)['id'], 2)
        finally: worker.close()

    def test_a_huge_transaction_error_is_bounded_before_it_reaches_the_toast(self):
        replies = queue.Queue()
        marker = 'SECRET-WINDOW-TITLE'
        def execute(packet, gate): raise RuntimeError('compositor said:\n' + 'x' * 200000 + marker)
        worker = Worker(replies.put, execute)
        try:
            reply = self.drain(worker, replies, 6)
        finally: worker.close()
        self.assertLessEqual(len(reply['error']), W.MAX_MESSAGE)
        self.assertNotIn(marker, reply['error'])
        self.assertNotIn('\n', reply['error'])
        self.assertTrue(reply['error'].startswith('compositor said: x'))

    def test_an_error_with_no_text_still_answers_with_something_readable(self):
        replies = queue.Queue()
        def execute(packet, gate): raise RuntimeError()
        worker = Worker(replies.put, execute)
        try:
            self.assertEqual(self.drain(worker, replies, 8)['error'],
                             'Overview backend could not complete that request')
        finally: worker.close()


class RetransmissionTests(unittest.TestCase):
    def test_a_conflicting_retransmission_is_answered_not_swallowed(self):
        replies, calls = queue.Queue(), []
        entered, release = threading.Event(), threading.Event()
        def execute(packet, gate):
            calls.append(tuple(packet['args']))
            entered.set()
            release.wait(2)
            return {'ok': True}
        worker = Worker(replies.put, execute)
        try:
            worker.accept({'id': 9, 'args': ['switch', '2']})
            self.assertTrue(entered.wait(1))
            worker.accept({'id': 9, 'args': ['switch', '2']})  # genuine retransmission: ignored
            with self.assertRaises(ValueError) as caught:
                worker.accept({'id': 9, 'args': ['remove', '2']})  # same id, different request
            self.assertEqual(str(caught.exception), 'Conflicting retransmission')
            self.assertTrue(replies.empty())
        finally:
            release.set()
            worker.close()
        # The mutating request ran exactly once and the conflicting one never ran.
        self.assertEqual(calls, [('switch', '2')])
        self.assertEqual(replies.get(timeout=1)['id'], 9)

    def test_replayed_and_out_of_order_ids_are_never_executed(self):
        replies, calls = queue.Queue(), []
        def execute(packet, gate):
            calls.append(packet['id'])
            return {'ok': True}
        worker = Worker(replies.put, execute)
        try:
            worker.accept({'id': 5, 'args': ['remove', '2']})
            self.assertEqual(replies.get(timeout=1)['id'], 5)
            for ident in (5, 4, 1):
                with self.assertRaises(ValueError) as caught:
                    worker.accept({'id': ident, 'args': ['remove', '2']})
                self.assertEqual(str(caught.exception), 'Request already seen; not replayed')
            self.assertTrue(replies.empty())
        finally: worker.close()
        self.assertEqual(calls, [5])

    def test_protocol_errors_never_echo_titles_or_pixel_data(self):
        worker = Worker(lambda packet: None, lambda packet, gate: {'ok': True})
        try:
            for packet in [{'id': 1, 'args': ['state', HOSTILE]}, {'id': 1, 'args': [HOSTILE]},
                           {'id': 1, 'args': ['state'], 'monitor': 3}, {'id': 1, 'args': [HOSTILE, HOSTILE]},
                           {'id': 1, 'args': ['state'], 'cover': HOSTILE},
                           {'id': 1, 'type': HOSTILE, 'args': ['state']}, {'id': HOSTILE, 'args': ['state']}]:
                with self.subTest(packet=sorted(packet)):
                    with self.assertRaises(ValueError) as caught: worker.accept(packet)
                    message = str(caught.exception)
                    for leak in ('Secret', 'data:image', 'pixel-bytes'):
                        self.assertNotIn(leak, message)
                    self.assertEqual(message, W.message(caught.exception))
        finally: worker.close()


class ShutdownTests(unittest.TestCase):
    def test_close_is_bounded_and_idempotent_while_a_transaction_waits(self):
        replies = queue.Queue()
        entered, release = threading.Event(), threading.Event()
        def execute(packet, gate):
            entered.set()
            release.wait(5)  # a transaction that ignores its gate, like controller.act
            return {'ok': True}
        worker = Worker(replies.put, execute)
        try:
            worker.accept({'id': 3, 'args': ['state']})
            self.assertTrue(entered.wait(1))
            # Bounded: the graceful-stop window is not silently extended.
            self.assertFalse(worker.close(timeout=.05))
            self.assertTrue(worker.closed)
        finally:
            release.set()
        self.assertTrue(worker.close(timeout=5))  # idempotent, and the reply still arrives
        self.assertEqual(replies.get(timeout=1)['id'], 3)
        self.assertFalse(worker.thread.is_alive())

    def test_close_without_a_transaction_ends_the_thread(self):
        worker = Worker(lambda packet: None, lambda packet, gate: {'ok': True})
        self.assertTrue(worker.close(timeout=5))
        with self.assertRaises(ValueError) as caught: worker.accept({'id': 2, 'args': ['state']})
        self.assertEqual(str(caught.exception), 'Worker is busy')


class MainLoopTests(unittest.TestCase):
    """main() runs in-process with a stubbed Worker: python3 worker.py is never spawned."""

    def drive(self, data):
        accepted = []
        class Stub:
            def __init__(self, emit, execute=None): self.emit = emit
            def accept(self, packet):
                if not isinstance(packet, dict): raise ValueError('Expected an object')
                accepted.append(packet)
            def close(self, *args, **kwargs): return True
        signals, stream = Mock(), io.StringIO()
        stdin = types.SimpleNamespace(buffer=io.BytesIO(data))
        with patch.object(W, 'Worker', Stub), \
             patch.object(W, 'signal', types.SimpleNamespace(signal=signals, SIGTERM=15)), \
             patch.object(W, 'sys', types.SimpleNamespace(stdin=stdin)), \
             contextlib.redirect_stdout(stream):
            W.main()
        return accepted, [json.loads(line) for line in stream.getvalue().splitlines()], signals

    def test_an_oversized_packet_is_refused_politely_and_its_tail_is_not_a_request(self):
        oversized = b'{"id":1,"args":["state"],"pad":"' + b'x' * (W.MAX_PACKET + 16) + b'"}\n'
        accepted, replies, signals = self.drive(oversized + b'{"id":2,"args":["state"]}\n')
        self.assertEqual(replies[0], {'event': 'ready', 'protocol': 1})
        self.assertEqual([reply for reply in replies if not reply.get('ok', True)],
                         [{'id': 0, 'ok': False, 'error': 'Protocol packet is too large'}])
        # The tail of the oversized line must never be parsed as a second request.
        self.assertEqual([packet['id'] for packet in accepted], [2])
        self.assertEqual(signals.call_args.args[0], 15)

    def test_non_utf8_and_garbage_lines_answer_and_keep_the_loop_running(self):
        accepted, replies, _ = self.drive(b'\xff\xfe{"id":1,"args":["state"]}\n' + b'not json\n' + b'[]\n'
                                          + b'{"id":3,"args":["state"]}\n')
        errors = [reply for reply in replies if not reply.get('ok', True)]
        self.assertEqual([reply['id'] for reply in errors], [0, 0, 0])
        self.assertTrue(all(reply['error'] and len(reply['error']) <= W.MAX_MESSAGE for reply in errors))
        self.assertEqual([packet['id'] for packet in accepted], [3])

    def test_a_protocol_error_reply_never_echoes_the_packet(self):
        accepted, replies, _ = self.drive(('{"id":0,"args":["state"],"title":"%s"}\n' % HOSTILE.replace('\x01', ' ')
                                           ).encode() + b'{"id":4,"args":["state"]}\n')
        errors = [reply for reply in replies if not reply.get('ok', True)]
        self.assertEqual([packet['id'] for packet in accepted], [0, 4])  # the stub does not validate ids
        self.assertEqual(errors, [])
        self.assertNotIn('Secret', json.dumps(replies))


if __name__ == '__main__': unittest.main()
