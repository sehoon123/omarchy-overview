from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import MagicMock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import preview

class PreviewTests(unittest.TestCase):
    def setUp(self):
        self.target = {'address': '0xabc', 'workspace': {'id': 1}, 'monitor': 1, 'at': [2500, 38], 'size': [1150, 1300]}
        self.workspace = {'id': 1, 'monitorID': 1, 'tiledLayout': 'scrolling'}
        self.cover = {'visible': True, 'workspace': 1, 'monitor': 1}
        self.api = MagicMock()
        self.api.address.return_value = '0xabc'
        self.api.find_window.return_value = self.target
        def query(*args, **kwargs):
            if args[1] == 'activeworkspace': return self.workspace
            if args[1] == 'getoption': return {'str': 'right'}
            if args[1] == 'monitors': return [{'id': 1, 'x': 0, 'width': 3840, 'scale': 1.6}]
            raise AssertionError(args)
        self.api.hypr.side_effect = query
        # Simulate movement clamped to 1700, NOT the requested 1875.
        self.api.clients.side_effect = [[self.target], [dict(self.target, at=[800, 38])]]
        self.gate = MagicMock(cancelled=threading.Event())

    def test_success_restores_measured_offset(self):
        self.gate.wait_for_frame.return_value = True
        with patch.object(preview.time, 'sleep'):
            self.assertTrue(preview.prime(self.api, 'abc', self.cover, self.gate))
        self.assertEqual([x.args[0] for x in self.api.dispatch.call_args_list],
                         ['hl.dsp.layout("move -1875.000")', 'hl.dsp.layout("move +1700.000")'])

    def test_capture_error_still_restores(self):
        self.gate.wait_for_frame.side_effect = TimeoutError('frame')
        with patch.object(preview.time, 'sleep'), self.assertRaises(TimeoutError):
            preview.prime(self.api, 'abc', self.cover, self.gate)
        self.assertIn('+1700.000', self.api.dispatch.call_args.args[0])

    def test_cancel_still_restores(self):
        self.gate.wait_for_frame.return_value = False
        with patch.object(preview.time, 'sleep'):
            self.assertFalse(preview.prime(self.api, 'abc', self.cover, self.gate))
        self.assertIn('+1700.000', self.api.dispatch.call_args.args[0])

    def test_hidden_or_different_monitor_never_moves(self):
        for cover in [dict(self.cover, visible=False), dict(self.cover, monitor=2), dict(self.cover, workspace=2)]:
            self.assertFalse(preview.prime(self.api, 'abc', cover, self.gate))
        self.api.dispatch.assert_not_called()

    def test_cancel_before_start_never_moves(self):
        self.gate.cancelled.set()
        self.assertFalse(preview.prime(self.api, 'abc', self.cover, self.gate))
        self.api.dispatch.assert_not_called()

if __name__ == '__main__': unittest.main()
