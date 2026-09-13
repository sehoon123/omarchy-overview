from pathlib import Path
import queue
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from worker import Worker

class WorkerTests(unittest.TestCase):
    def test_event_acknowledgement_and_no_replay(self):
        replies = queue.Queue()
        calls = []
        def execute(packet, gate):
            calls.append(packet['id'])
            return {'ok': True, 'primed': gate.wait_for_frame('abc', 1)}
        worker = Worker(replies.put, execute)
        try:
            worker.accept({'id': 1, 'args': ['prime', 'abc']})
            self.assertEqual(replies.get(timeout=1)['event'], 'frame-needed')
            worker.accept({'id': 1, 'args': ['prime', 'abc']})
            self.assertTrue(replies.empty())
            worker.accept({'type': 'frame', 'id': 1})
            self.assertTrue(replies.get(timeout=1)['primed'])
            with self.assertRaises(ValueError): worker.accept({'id': 1, 'args': ['prime', 'abc']})
            self.assertEqual(calls, [1])
        finally: worker.close()

    def test_cancel_interrupts_frame_wait(self):
        replies = queue.Queue()
        worker = Worker(replies.put, lambda p, gate: {'ok': True, 'primed': gate.wait_for_frame('abc', 10)})
        try:
            worker.accept({'id': 7, 'args': ['prime', 'abc']})
            replies.get(timeout=1)
            worker.accept({'type': 'cancel', 'id': 6}) # stale cancellation is ignored
            self.assertTrue(replies.empty())
            worker.accept({'type': 'cancel', 'id': 7})
            self.assertFalse(replies.get(timeout=1)['primed'])
        finally: worker.close()

    def test_rejects_invalid_protocol(self):
        worker = Worker(lambda p: None, lambda p, g: {'ok': True})
        try:
            for packet in [[], {}, {'id': True}, {'id': 1, 'args': ['unknown']}, {'id': 1, 'args': ['move']}]:
                with self.assertRaises(ValueError): worker.accept(packet)
        finally: worker.close()

if __name__ == '__main__': unittest.main()
