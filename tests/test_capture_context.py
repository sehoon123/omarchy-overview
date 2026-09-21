import copy
import unittest
from unittest.mock import Mock

import capture_context as C


def monitor(**changes):
    return dict(dict(id=0, name='TEST', x=0, y=0, width=1920, height=1080, scale=1,
                     transform=0, dpmsStatus=True, solitaryBlockedBy=[]), **changes)


class CaptureContextTests(unittest.TestCase):
    def test_checks_only_read_only_monitor_and_layer_queries(self):
        call = Mock(side_effect=[[monitor()], {}])
        result = C.inspect('TEST', call)
        self.assertTrue(result['ok'])
        self.assertEqual([c.args for c in call.call_args_list], [('monitors',), ('layers',)])
        self.assertTrue(all(c.kwargs == {'json_output': True, 'timeout': .3} for c in call.call_args_list))
        self.assertNotIn('frames', result)

    def test_rotated_scaled_geometry(self):
        result = C.check([monitor(width=2160, height=3840, scale=2, transform=1, x=-1920)], {}, 'TEST')
        self.assertEqual(result['outputs'][0], dict(name='TEST', id=0, x=-1920, y=0, width=1920, height=1080, scale=2))

    def test_locks_and_unknown_lock_state_fail_closed(self):
        for blockers in (['LOCK'], ['WORKSPACE'], None, 'LOCK'):
            with self.subTest(blockers=blockers):
                self.assertFalse(C.check([monitor(solitaryBlockedBy=blockers)], {}, 'TEST')['ok'])
        self.assertFalse(C.check([], {}, 'TEST')['ok'])
        self.assertFalse(C.check(None, {}, 'TEST')['ok'])
        self.assertFalse(C.check([monitor()], None, 'TEST')['ok'])

    def test_inactive_placeholder_and_malformed_outputs_are_rejected(self):
        for changes in (dict(name=''), dict(name='HEADLESS-1'), dict(name='FALLBACK'),
                        dict(disabled=True), dict(dpmsStatus=False), dict(scale=0),
                        dict(scale=float('nan')), dict(width=0), dict(x=None)):
            with self.subTest(changes=changes):
                self.assertFalse(C.check([monitor(**changes)], {}, 'TEST')['ok'])

    def test_capture_bookkeeping_is_not_a_lock(self):
        self.assertTrue(C.check([monitor(solitaryBlockedBy=['SCREENCOPY'])], {}, 'TEST')['ok'])

    def test_authentication_on_any_display_blocks_opening(self):
        for namespace in ('omarchy-polkit', 'hyprlock', 'swaylock', 'gtklock', 'omarchy-lockscreen'):
            layer = {'OTHER': {'levels': {'3': [dict(namespace=namespace)]}}}
            self.assertFalse(C.check([monitor()], layer, 'TEST')['ok'])
            layer['OTHER']['levels']['3'][0]['alpha'] = 0
            self.assertTrue(C.check([monitor()], layer, 'TEST')['ok'])

    def test_ordinary_overlay_is_not_a_reason_to_crop_or_hide_windows(self):
        layer = {'TEST': {'levels': {'3': [dict(namespace='notification', x=0, y=0, w=1920, h=1080)]}}}
        self.assertTrue(C.check([monitor()], layer, 'TEST')['ok'])

    def test_read_only_check_does_not_mutate_scene(self):
        monitors, layers = [monitor()], {'TEST': {'levels': {}}}
        before = copy.deepcopy([monitors, layers])
        C.check(monitors, layers, 'TEST')
        self.assertEqual([monitors, layers], before)


if __name__ == '__main__': unittest.main()
