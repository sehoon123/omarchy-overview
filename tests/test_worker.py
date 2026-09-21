from pathlib import Path
import queue
import sys
import threading
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from worker import Worker


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


if __name__ == '__main__': unittest.main()
