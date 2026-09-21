import base64
import copy
import struct
import sys
import unittest
from unittest.mock import Mock, patch
import zlib

import snapshot as S


def window(address='0x1', x=10, y=10, width=180, height=180, **extra):
    return dict(address=address, at=[x, y], size=[width, height], title='Fixture', pid=10,
                stableId=1, monitor=0, workspace={'id': 1}, mapped=True, hidden=False,
                visible=True, floating=False, fullscreen=0, focusHistoryID=0, **extra)


def scene():
    return {'monitors': [dict(id=0, name='TEST', x=0, y=0, width=400, height=200, scale=1,
                             transform=0, dpmsStatus=True, disabled=False,
                             activeWorkspace={'id': 1}, specialWorkspace={'id': 0}, solitaryBlockedBy=[])],
            'clients': [window()], 'layers': {'TEST': {'levels': {'2': [], '3': []}}}}


def ppm(width=200, height=100):
    # Distinct red/blue halves make wrong coordinate spaces observable.
    pixels = b''.join(b'\xff\x00\x00' if x < width // 2 else b'\x00\x00\xff'
                      for y in range(height) for x in range(width))
    return f'P6\n{width} {height}\n255\n'.encode() + pixels


def decode_png(uri):
    data = base64.b64decode(uri.split(',', 1)[1])
    assert data.startswith(b'\x89PNG\r\n\x1a\n')
    offset, compressed = 8, b''
    width = height = 0
    while offset < len(data):
        length = struct.unpack('!I', data[offset:offset + 4])[0]
        kind, body = data[offset + 4:offset + 8], data[offset + 8:offset + 8 + length]
        assert zlib.crc32(kind + body) == struct.unpack('!I', data[offset + 8 + length:offset + 12 + length])[0]
        if kind == b'IHDR': width, height = struct.unpack('!II', body[:8])
        if kind == b'IDAT': compressed += body
        offset += 12 + length
    rows = zlib.decompress(compressed)
    return width, height, b''.join(rows[y * (width * 3 + 1) + 1:(y + 1) * (width * 3 + 1)] for y in range(height))


class OutputSnapshotTests(unittest.TestCase):
    def test_scene_queries_are_read_only(self):
        with patch.object(S.hypr_ipc, 'call', return_value=[]) as call:
            S.read_scene()
            self.assertEqual([c.args for c in call.call_args_list], [('monitors',), ('clients',), ('layers',)])
            self.assertTrue(all(c.kwargs['timeout'] == .35 for c in call.call_args_list))

    def test_owned_output_child_is_reaped_on_success_and_memory_limit(self):
        start = S.subprocess.Popen
        children = []
        def fixture(*args, **kwargs):
            child = start([sys.executable, '-c', "import sys; sys.stdout.buffer.write(b'x'*2048)"], **kwargs)
            children.append(child)
            return child
        with patch.object(S.subprocess, 'Popen', side_effect=fixture):
            self.assertEqual(len(S.grab_output('TEST', .5)), 2048)
            with patch.object(S, 'MAX_PPM', 32), self.assertRaises(S.Unavailable):
                S.grab_output('TEST', .5)
        self.assertTrue(all(p.poll() is not None and p.stdout.closed for p in children))

    def test_owned_child_is_killed_and_reaped_on_timeout(self):
        start = S.subprocess.Popen
        child = start([sys.executable, '-c', 'import time; time.sleep(10)'], stdout=S.subprocess.PIPE)
        try:
            with patch.object(S.subprocess, 'Popen', return_value=child), self.assertRaises(S.Unavailable):
                S.grab_output('TEST', .5)
            self.assertIsNotNone(child.poll())
            self.assertTrue(child.stdout.closed)
        finally:
            if child.poll() is None: child.kill(); child.wait()

    def test_output_regions_become_real_pngs_without_files(self):
        state = scene()
        state['clients'].append(window('0x2', x=210))
        result = S.capture('TEST', lambda: copy.deepcopy(state), lambda name, scale: ppm())
        self.assertTrue(result['ok'])
        self.assertEqual(len(result['frames']), 2)
        for frame, color in zip(result['frames'], (b'\xff\x00\x00', b'\x00\x00\xff')):
            w, h, pixels = decode_png(frame['imageSource'])
            self.assertEqual((w, h), (90, 90))
            self.assertEqual(pixels, color * w * h)
            self.assertFalse(frame['partial'])

    def test_nonzero_output_origin_and_scaling(self):
        state = scene()
        state['monitors'][0].update(x=-400, y=200, width=800, height=400, scale=2)
        state['clients'] = [window(x=-390, y=210)]
        result = S.capture('TEST', lambda: copy.deepcopy(state), lambda *args: ppm())
        self.assertEqual(decode_png(result['frames'][0]['imageSource'])[2], b'\xff\x00\x00' * 90 * 90)

    def test_rotated_output_uses_logical_dimensions(self):
        state = scene()
        state['monitors'][0].update(width=200, height=400, transform=1)
        self.assertEqual(S.monitor_context(state, 'TEST')[1], (0, 0, 400, 200))

    def test_partial_regions_are_marked_not_stretched_to_full_window(self):
        state = scene()
        state['clients'] = [window(x=-50, width=200)]
        frame = S.capture('TEST', lambda: copy.deepcopy(state), lambda *args: ppm())['frames'][0]
        self.assertTrue(frame['partial'])
        self.assertEqual((frame['width'], frame['height']), (75, 90))
        self.assertEqual(frame['windowSize'], [200, 180])

    def test_offscreen_hidden_other_workspace_and_tiny_slivers_are_skipped(self):
        for changes in ({'at': [500, 10]}, {'hidden': True}, {'visible': False}, {'mapped': False},
                        {'workspace': {'id': 2}}, {'at': [-175, 10]}, {'monitor': 8}):
            state = scene()
            state['clients'][0].update(changes)
            grab = Mock()
            self.assertEqual(S.capture('TEST', lambda: state, grab)['frames'], [])
            grab.assert_not_called()

    def test_floating_window_does_not_leak_into_underlying_tile_preview(self):
        state = scene()
        top = window('0x2', x=40, y=40, width=100, height=100)
        top['floating'] = True
        state['clients'].append(top)
        self.assertEqual([w['address'] for w, *_ in S.candidates(state, 'TEST')], ['0x2'])

    def test_ambiguous_fullscreen_and_floating_overlap_is_omitted(self):
        state = scene()
        state['clients'][0]['fullscreen'] = 2
        top = window('0x2', x=40, y=40, width=100, height=100)
        top['floating'] = True
        state['clients'].append(top)
        self.assertEqual(S.candidates(state, 'TEST'), [])

    def test_layers_obscure_crops_and_overview_never_captures_itself(self):
        state = scene()
        state['layers']['TEST']['levels']['3'] = [dict(namespace='notification', x=20, y=20, w=50, h=50)]
        self.assertEqual(S.candidates(state, 'TEST'), [])
        state['layers']['TEST']['levels']['3'][0]['namespace'] = 'sehun-overview'
        with self.assertRaises(S.Unavailable): S.candidates(state, 'TEST')

    def test_auth_dialog_blocks_opening_without_capturing(self):
        before, protected = scene(), scene()
        protected['layers']['TEST']['levels']['3'] = [dict(namespace='omarchy-polkit', x=0, y=0, w=400, h=200)]
        grab = Mock()
        with self.assertRaises(S.Unavailable) as error:
            S.capture('TEST', lambda: protected, grab)
        self.assertTrue(error.exception.blocked)
        grab.assert_not_called()
        with self.assertRaises(S.Unavailable) as error:
            S.capture('TEST', Mock(side_effect=[before, protected]), lambda *args: ppm())
        self.assertTrue(error.exception.blocked)
        protected['layers']['OTHER'] = protected['layers'].pop('TEST')
        protected['monitors'][0]['specialWorkspace'] = {'id': -99}
        with self.assertRaises(S.Unavailable) as error:
            S.capture('TEST', lambda: protected, grab)
        self.assertTrue(error.exception.blocked)
        grab.assert_not_called()

    def test_locked_or_undetermined_sessions_never_start_capture(self):
        for blockers in (['LOCK'], ['WORKSPACE'], None):
            state = scene()
            state['monitors'][0]['solitaryBlockedBy'] = blockers
            grab = Mock()
            with self.assertRaises(S.Unavailable) as error:
                S.capture('TEST', lambda: state, grab)
            self.assertTrue(error.exception.blocked)
            grab.assert_not_called()

    def test_missing_output_and_dpms_off_do_not_capture(self):
        for changes in ({'name': 'FALLBACK'}, {'dpmsStatus': False}, {'disabled': True}):
            state = scene()
            state['monitors'][0].update(changes)
            grab = Mock()
            with self.assertRaises(S.Unavailable): S.capture('TEST', lambda: state, grab)
            grab.assert_not_called()

    def test_metadata_and_topology_changes_reject_the_entire_snapshot(self):
        for mutate in (lambda s: s['clients'][0].update(title='New tab'),
                       lambda s: s['clients'][0].update(at=[20, 10]),
                       lambda s: s['monitors'][0].update(activeWorkspace={'id': 2}),
                       lambda s: s['monitors'][0].update(scale=2)):
            before, after = scene(), scene()
            mutate(after)
            with self.assertRaises(S.Unavailable):
                S.capture('TEST', Mock(side_effect=[before, after]), lambda *args: ppm())

    def test_lock_during_capture_discards_pixels(self):
        before, after = scene(), scene()
        after['monitors'][0]['solitaryBlockedBy'] = ['LOCK']
        with self.assertRaises(S.Unavailable) as error:
            S.capture('TEST', Mock(side_effect=[before, after]), lambda *args: ppm())
        self.assertTrue(error.exception.blocked)

    def test_own_screencast_bookkeeping_does_not_invalidate_snapshot(self):
        before, after = scene(), scene()
        after['monitors'][0]['solitaryBlockedBy'] = ['SCREENCOPY']
        self.assertEqual(len(S.capture('TEST', Mock(side_effect=[before, after]), lambda *args: ppm())['frames']), 1)

    def test_ppm_bounds_and_binary_whitespace(self):
        raw = b'P6\n# fixture\n1 1\n255\n' + b'\n\r '
        self.assertEqual(S.parse_ppm(raw)[2].tobytes(), b'\n\r ')
        for raw in (b'', b'P3 1 1 255 abc', b'P6 0 1 255 ', b'P6 999999 999999 255 ',
                    b'P6 1 1 65535 abc', b'P6 1 1 255 ab', b'P6\n# unfinished'):
            with self.assertRaises((S.Unavailable, ValueError)): S.parse_ppm(raw)

    def test_total_encoded_payload_is_bounded(self):
        with patch.object(S, 'MAX_URL_BYTES', 1):
            self.assertEqual(S.capture('TEST', scene, lambda *args: ppm())['frames'], [])

    def test_grim_uses_only_named_output_and_stdout(self):
        with patch.object(S.subprocess, 'Popen', side_effect=FileNotFoundError) as run:
            with self.assertRaises(FileNotFoundError): S.grab_output('TEST', .5)
            self.assertEqual(run.call_args.args[0], ['grim', '-o', 'TEST', '-s', '0.5', '-t', 'ppm', '-'])
            self.assertNotIn('shell', run.call_args.kwargs)


if __name__ == '__main__': unittest.main()
