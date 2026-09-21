import contextlib
import copy
import io
import json
import os
import sys
import unittest
from unittest.mock import Mock, patch

import capture_context as C
import hypr_ipc

# A title, a data URL and raw pixel bytes are planted and then asserted absent:
# this helper never receives pixels and must never echo anything like them.
HOSTILE = 'Secret Document.pdf \x01 data:image/png;base64,iVBORw0KGgo pixel-bytes'


def monitor(**changes):
    return dict(dict(id=0, name='TEST', x=0, y=0, width=1920, height=1080, scale=1,
                     transform=0, dpmsStatus=True, solitaryBlockedBy=[]), **changes)


def without(field, **changes):
    entry = monitor(**changes)
    del entry[field]
    return entry


def layer_stack(**layer):
    return {'OTHER': {'levels': {'3': [layer]}}}


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


class FieldTypeTests(unittest.TestCase):
    """Unexpected types fail closed inside check(), not as a traceback in main()."""

    def test_unreadable_monitor_fields_never_produce_an_output(self):
        for changes in (dict(transform='1'), dict(transform=None), dict(transform=[1]), dict(transform=True),
                        dict(transform=8), dict(transform=-1), dict(transform=1.0),
                        dict(scale=True), dict(width=True), dict(height=True), dict(x=True), dict(y=True),
                        dict(id=True), dict(id='0'), dict(id=1.5), dict(id=None),
                        dict(name=3), dict(name=None), dict(name=['TEST'])):
            with self.subTest(changes=changes):
                result = C.check([monitor(**changes)], {}, 'TEST')
                self.assertFalse(result['ok'])
                self.assertTrue(result['reason'])
        for missing in ('id', 'name', 'x', 'y', 'width', 'height', 'scale'):
            with self.subTest(missing=missing):
                self.assertFalse(C.check([without(missing)], {}, 'TEST')['ok'])
        # A missing transform still means "not rotated", as Hyprland's default does.
        self.assertTrue(C.check([without('transform')], {}, 'TEST')['ok'])

    def test_an_unusable_second_output_does_not_block_the_selected_one(self):
        result = C.check([monitor(name='OTHER', id=1, transform='1'), monitor()], {}, 'TEST')
        self.assertTrue(result['ok'])
        self.assertEqual([output['name'] for output in result['outputs']], ['TEST'])

    def test_a_monitors_entry_that_is_not_an_object_is_not_a_display_list(self):
        for entry in ([], 'DP-2', None, 3, HOSTILE):
            with self.subTest(entry=entry):
                result = C.check([entry], {}, 'TEST')
                self.assertEqual(result, {'ok': False, 'reason': 'Display state unavailable'})
        self.assertEqual(C.check([monitor(), None], {}, 'TEST'),
                         {'ok': False, 'reason': 'Display state unavailable'})

    def test_malformed_layer_shapes_fail_closed(self):
        for layers in ({'OTHER': 'string'}, {'OTHER': []}, {'OTHER': {'levels': []}},
                       {'OTHER': {'levels': {'3': {}}}}, {'OTHER': {'levels': {'3': 'x'}}},
                       {'OTHER': {'levels': {'3': [None]}}}, {'OTHER': {'levels': {'3': ['hyprlock']}}},
                       layer_stack(namespace=['hyprlock']), layer_stack(namespace=3)):
            with self.subTest(layers=layers):
                result = C.check([monitor()], layers, 'TEST')
                self.assertEqual(result, {'ok': False, 'reason': 'Display state could not be verified'})

    def test_a_lock_layer_with_unreadable_alpha_still_blocks_the_open(self):
        for alpha in ('x', None, [0], float('nan'), True):
            with self.subTest(alpha=alpha):
                result = C.check([monitor()], layer_stack(namespace='hyprlock', alpha=alpha), 'TEST')
                self.assertEqual(result, {'ok': False, 'reason': 'Authentication or lock dialog is open'})
        # A readable, transparent lock surface is still not a blocker.
        self.assertTrue(C.check([monitor()], layer_stack(namespace='hyprlock', alpha=0), 'TEST')['ok'])

    def test_unreadable_lock_state_is_not_reported_as_a_locked_session(self):
        self.assertEqual(C.check([monitor(solitaryBlockedBy=['LOCK'])], {}, 'TEST'),
                         {'ok': False, 'reason': 'Session locked or lock state unavailable'})
        for blockers in (['WORKSPACE'], ['WINDOWED', 'WORKSPACE'], None, 'LOCK', [3], {'LOCK': True}):
            with self.subTest(blockers=blockers):
                self.assertEqual(C.check([monitor(solitaryBlockedBy=blockers)], {}, 'TEST'),
                                 {'ok': False, 'reason': 'Display state could not be verified'})
        self.assertEqual(C.check([without('solitaryBlockedBy')], {}, 'TEST'),
                         {'ok': False, 'reason': 'Display state could not be verified'})
        # The live direct-scanout values are not a lock and never were.
        self.assertTrue(C.check([monitor(solitaryBlockedBy=['WINDOWED', 'CANDIDATE'])], {}, 'TEST')['ok'])


class GeometryTests(unittest.TestCase):
    def test_this_machine_fractional_scale_is_logical_and_exact(self):
        result = C.check([monitor(id=1, name='eDP-1', width=2560, height=1600, scale=1.6, x=480, y=1440)], {}, 'eDP-1')
        self.assertEqual(result['outputs'][0], dict(name='eDP-1', id=1, scale=1.6,
                                                    x=480, y=1440, width=1600.0, height=1000.0))

    def test_every_wl_output_transform_keeps_rotation_corrected_geometry(self):
        for transform, size in {0: (1600.0, 1000.0), 1: (1000.0, 1600.0), 2: (1600.0, 1000.0),
                                3: (1000.0, 1600.0), 4: (1600.0, 1000.0), 5: (1000.0, 1600.0),
                                6: (1600.0, 1000.0), 7: (1000.0, 1600.0)}.items():
            with self.subTest(transform=transform):
                output = C.check([monitor(width=2560, height=1600, scale=1.6, transform=transform)],
                                 {}, 'TEST')['outputs'][0]
                self.assertEqual((output['width'], output['height']), size)

    def test_output_payload_carries_no_titles_descriptions_or_pixels(self):
        entry = monitor(description='Panel SERIAL-ABC123', model=HOSTILE, title=HOSTILE,
                        frames=[1, 2, 3], activeWorkspace={'name': HOSTILE})
        result = C.check([entry], layer_stack(namespace='notification', title=HOSTILE), 'TEST')
        self.assertTrue(result['ok'])
        self.assertEqual(set(result['outputs'][0]), {'name', 'id', 'scale', 'x', 'y', 'width', 'height'})
        printed = json.dumps(result)
        for leak in ('SERIAL-ABC123', 'Secret', 'data:image', 'pixel-bytes', 'frames'):
            self.assertNotIn(leak, printed)


class MainTests(unittest.TestCase):
    """main() is driven with an injected inspect(): no compositor, no subprocess."""

    def run_main(self, argv, **inspect):
        stream = io.StringIO()
        with patch.object(C, 'inspect', Mock(**inspect)), patch.object(sys, 'argv', argv), \
             contextlib.redirect_stdout(stream):
            C.main()
        return json.loads(stream.getvalue())

    def test_transport_failures_are_distinguishable_from_malformed_state(self):
        reasons = {}
        for error in (hypr_ipc.Unreachable('Hyprland is not reachable'),
                      hypr_ipc.Unreachable('Hyprland session environment is unavailable'),
                      hypr_ipc.ReplyTimeout('Hyprland did not answer in time; the request was not retried'),
                      hypr_ipc.Unreadable('Hyprland sent a reply Overview could not read'),
                      hypr_ipc.Unreadable('Compositor reply is too large')):
            result = self.run_main(['capture_context.py', 'TEST'], side_effect=error)
            self.assertFalse(result['ok'])
            reasons[str(error)] = result['reason']
        self.assertEqual(reasons, {message: message for message in reasons})
        self.assertEqual(len(set(reasons.values())), 5)

    def test_an_unexpected_failure_still_fails_closed_with_one_reason(self):
        for error in (TypeError('unsupported operand'), AttributeError("'list' object has no attribute 'get'"),
                      RuntimeError(HOSTILE), KeyError('HYPRLAND_INSTANCE_SIGNATURE')):
            with self.subTest(error=type(error).__name__):
                result = self.run_main(['capture_context.py', 'TEST'], side_effect=error)
                self.assertEqual(result, {'ok': False, 'reason': 'Cannot verify capture context'})

    def test_argument_handling_and_the_happy_path_are_unchanged(self):
        self.assertEqual(self.run_main(['capture_context.py'], return_value={'ok': True}),
                         {'ok': False, 'reason': 'Display name required'})
        self.assertEqual(self.run_main(['capture_context.py', 'TEST', 'extra'], return_value={'ok': True}),
                         {'ok': False, 'reason': 'Display name required'})
        self.assertEqual(self.run_main(['capture_context.py', 'TEST'],
                                       return_value=C.check([monitor()], {}, 'TEST')),
                         {'ok': True, 'outputs': [dict(name='TEST', id=0, scale=1, x=0, y=0,
                                                       width=1920.0, height=1080.0)]})

    def test_the_transport_is_late_bound_so_a_test_can_never_reach_a_compositor(self):
        self.assertEqual(C.inspect.__defaults__, (None,))
        call = Mock(side_effect=[[monitor()], {}])
        # With no session environment, an import-time default would fail instead
        # of using the injected transport.
        with patch.dict(os.environ, {}, clear=True), patch.object(C.hypr_ipc, 'call', call):
            self.assertTrue(C.inspect('TEST')['ok'])
        self.assertEqual(call.call_count, 2)


if __name__ == '__main__': unittest.main()
