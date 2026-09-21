import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import controller as c

class ControllerTests(unittest.TestCase):
    def setUp(self):
        # Unit tests never consult or mutate the running desktop/configuration.
        self.hypr = patch.object(c, 'hypr', side_effect=lambda *args, **kw: {'id': 1} if 'activeworkspace' in args else []).start()
        patch.object(c, 'plugin_count', return_value=0).start()
        self.addCleanup(patch.stopall)

    def test_merge_keeps_saved_order(self):
        self.assertEqual(c.merge_order([3, 1], [1, 2, 3]), [3, 1, 2])

    def test_address_is_normalized(self):
        self.assertEqual(c.address('abcdef'), '0xabcdef')
        self.assertEqual(c.address('0xabcdef'), '0xabcdef')
        for bad in ['', 'address:0x123', 'abc;anything', 'not-a-window']:
            with self.assertRaises(ValueError): c.address(bad)

    def test_special_workspace_is_rejected(self):
        for bad in [0, -1, 2147483647]:
            with self.assertRaises(ValueError): c.ws_id(bad)

    def test_reorder_both_directions(self):
        with patch.object(c, 'read_order', return_value=[1, 2, 3]), patch.object(c, 'save_order'):
            self.assertEqual(c.act(['reorder', '1', '2'])['order'], [2, 1, 3])
            self.assertEqual(c.act(['reorder', '3', '1'])['order'], [3, 1, 2])

    def test_cannot_remove_last_desktop(self):
        with patch.object(c, 'read_order', return_value=[1]):
            with self.assertRaises(ValueError): c.act(['remove', '1'])

    def test_undo_does_not_override_a_later_manual_move(self):
        with patch.object(c, 'read_order', return_value=[1, 2, 3]), patch.object(c, 'save_order'), \
             patch.object(c, 'find_window', return_value={'workspace': {'id': 3}}), patch.object(c, 'move_window') as move:
            result = c.act(['undo', '{"moves":[{"address":"abc","source":1,"target":2}],"order":[1,2]}'])
            move.assert_not_called()
            self.assertIn('skipped', result['message'])

    def test_state_queries_do_not_write_to_disk(self):
        with patch.object(c, 'read_order', return_value=[1, 2]), patch.object(c, 'save_order') as save:
            self.assertEqual(c.act(['state'])['order'], [1, 2])
            save.assert_not_called()

    def test_retired_viewport_priming_cannot_be_invoked(self):
        with patch.object(c, 'read_order', return_value=[1]):
            with self.assertRaises(ValueError): c.act(['prime', 'abc'])


class PersistenceTests(unittest.TestCase):
    """desktops.json is hand-editable and syncable: reading it must self-heal.

    Every case runs against a temp state directory and a mocked hypr_ipc call.
    A dispatch would move the user's real windows, so the mock refuses one.
    """

    LIVE = [{'id': 1, 'name': '1', 'monitor': 'DP-1'}, {'id': 2, 'name': '2', 'monitor': 'DP-1'},
            {'id': -99, 'name': 'special:magic', 'monitor': 'DP-1'}]
    MONITORS = [{'id': 0, 'name': 'DP-1', 'description': 'Panel', 'focused': True,
                 'activeWorkspace': {'id': 1, 'name': '1'}}]
    # Every way the file can be unusable; each one must fall back to live desktops.
    CORRUPT = {
        'truncated json': '{"version": 1, "order": [1,',
        'empty file': '',
        'whitespace only': '   \n',
        'json array': '[1, 2]',
        'json scalar': '7',
        'json string': '"1"',
        'json null': 'null',
        'newer version': '{"version": 3, "order": [5, 6]}',
        'missing version': '{"order": [5, 6]}',
        'version as text': '{"version": "1", "order": [5]}',
        'order is an object': '{"version": 1, "order": {"1": true}}',
        'order is null': '{"version": 1, "order": null}',
        'order is a number': '{"version": 1, "order": 5}',
        'null entry': '{"version": 1, "order": [null]}',
        'object entry': '{"version": 1, "order": [{}]}',
        'list entry': '{"version": 1, "order": [[3]]}',
        'zero entry': '{"version": 1, "order": [0]}',
        'negative entry': '{"version": 1, "order": [-3]}',
        'out of range entry': '{"version": 1, "order": [2147483647]}',
        'special name entry': '{"version": 2, "order": ["name:special:magic"]}',
        'bare special entry': '{"version": 2, "order": ["name:special"]}',
        'empty name entry': '{"version": 2, "order": ["name:"]}',
        'control character name': '{"version": 2, "order": ["name:a\\tb"]}',
        'unparsable entry': '{"version": 1, "order": ["desktop three"]}',
    }

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.state = Path(self.directory.name) / 'state'
        self.state.mkdir(mode=0o700)
        # A test may make the directory read-only; let TemporaryDirectory clean up.
        self.addCleanup(lambda: self.state.exists() and self.state.chmod(0o700))
        self.file = self.state / 'desktops.json'
        self.live = [dict(w) for w in self.LIVE]
        patch.object(c, 'STATE', self.state).start()
        patch.object(c, 'plugin_count', return_value=0).start()
        patch.object(c, 'hypr', side_effect=self.reply).start()
        self.addCleanup(patch.stopall)

    def reply(self, *args, **kwargs):
        self.assertNotIn('dispatch', args)  # a unit test never mutates the session
        if 'workspaces' in args: return [dict(w) for w in self.live]
        if 'monitors' in args: return [dict(m) for m in self.MONITORS]
        if 'activeworkspace' in args: return {'id': 1, 'name': '1'}
        return []

    def test_every_corruption_class_still_answers_a_usable_state(self):
        for name, text in self.CORRUPT.items():
            with self.subTest(name):
                self.file.write_text(text)
                before = self.file.read_bytes()
                result = c.act(['state'])
                self.assertTrue(result['ok'])
                self.assertEqual(result['order'], [1, 2])  # the live desktops
                self.assertEqual(sorted(result['desktops']), ['1', '2'])
                self.assertEqual(self.file.read_bytes(), before)  # never rewritten
                self.assertFalse((self.state / 'desktops.json.tmp').exists())

    def test_unreadable_file_shapes_still_answer_a_usable_state(self):
        self.file.write_bytes(b'{"version": 1, "order": [1]}\xff')
        self.assertEqual(c.act(['state'])['order'], [1, 2])
        self.assertEqual(c.read_order(), [1, 2])
        self.file.unlink()
        self.file.mkdir()  # a sync tool or a restore left a directory in its place
        self.assertEqual(c.act(['state'])['order'], [1, 2])
        self.file.rmdir()
        if os.geteuid() == 0: self.skipTest('root ignores file permissions')
        self.file.write_text('{"version": 1, "order": [2, 1]}')
        self.file.chmod(0o000)
        self.assertEqual(c.act(['state'])['order'], [1, 2])
        self.file.chmod(0o600)
        self.assertEqual(c.act(['state'])['order'], [2, 1])  # readable again, order intact

    def test_a_valid_saved_order_is_never_discarded(self):
        self.file.write_text(json.dumps({'version': 2, 'order': [5, 'name:writing', 2]}) + '\n')
        before = self.file.read_bytes()
        result = c.act(['state'])
        self.assertEqual(result['order'], [5, 'name:writing', 2, 1])
        self.assertEqual(self.file.read_bytes(), before)
        # Entries no selector can express are skipped; the valid ones stay put.
        self.file.write_text('{"version": 1, "order": [3, {}, 0, "name:keep", 1]}')
        self.assertEqual(c.act(['state'])['order'], [3, 'name:keep', 1, 2])

    def test_a_query_never_creates_or_deletes_the_file(self):
        self.live = []
        self.assertEqual(c.act(['state'])['order'], [1])  # invented, not saved
        self.assertFalse(self.file.exists())
        self.file.write_text('nonsense')
        c.act(['state'])
        self.assertEqual(self.file.read_text(), 'nonsense')

    def test_a_live_name_no_selector_accepts_does_not_brick_the_read_path(self):
        # Read path only: `hyprctl dispatch renameworkspace 3 "a<TAB>b"`.
        self.live.append({'id': 3, 'name': 'a\tb', 'monitor': 'DP-1'})
        self.assertEqual(c.act(['state'])['order'], [1, 2])
        with self.assertRaises(ValueError): c.act(['switch', 'name:a\tb'])  # requests stay strict

    def test_save_recreates_a_vanished_state_directory(self):
        shutil.rmtree(self.state)
        self.assertTrue(c.save_order([2, 1]))
        self.assertEqual(json.loads(self.file.read_text()), {'version': 1, 'order': [2, 1]})
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.file.stat().st_mode), 0o600)
        self.assertFalse((self.state / 'desktops.json.tmp').exists())

    def test_save_preserves_keys_this_release_does_not_own(self):
        self.file.write_text(json.dumps({'version': 3, 'order': [9], 'future': {'a': 1}}))
        self.assertTrue(c.save_order([2, 'name:keep']))
        self.assertEqual(json.loads(self.file.read_text()),
                         {'version': 2, 'order': [2, 'name:keep'], 'future': {'a': 1}})
        self.assertTrue(c.save_order([1]))
        self.assertEqual(json.loads(self.file.read_text())['version'], 1)

    def test_an_unwritable_state_directory_degrades_without_failing_the_action(self):
        if os.geteuid() == 0: self.skipTest('root ignores directory permissions')
        self.assertTrue(c.save_order([1, 2]))
        before = self.file.read_bytes()
        self.state.chmod(0o500)
        self.assertFalse(c.save_order([2, 1]))
        result = c.act(['reorder', '2', '1'])
        self.assertTrue(result['ok'])
        self.assertEqual(result['order'], [2, 1])
        self.assertIn('not saved', result['message'])
        self.assertEqual(self.file.read_bytes(), before)  # the saved list survives
        self.assertFalse((self.state / 'desktops.json.tmp').exists())

    def test_no_saved_content_or_path_reaches_the_user(self):
        self.file.write_text('{"version": 1, "order": [1, "Bank — Private Browsing"')
        payload = json.dumps(c.act(['state']), ensure_ascii=False)
        self.state.chmod(0o500)
        payload += json.dumps(c.act(['reorder', '2', '1']), ensure_ascii=False)
        for secret in ['Bank', 'Private Browsing', 'Expecting', 'Errno', str(self.state), 'desktops.json']:
            self.assertNotIn(secret, payload)


class FieldGuardTests(unittest.TestCase):
    """A clients/workspaces/monitors reply is data: its shape is never assumed.

    Every case runs against a temp state directory and a mocked hypr_ipc call
    that refuses any 'dispatch', so nothing here can move a window, focus a
    desktop or touch the running session. A malformed field must produce one
    clear sentence, never a KeyError/TypeError traceback on the path of every
    action, and never a fragment of the reply.
    """

    MONITORS = [{'id': 0, 'name': 'DP-1', 'description': 'Panel', 'focused': True,
                 'activeWorkspace': {'id': 1, 'name': '1'}}]
    LIVE = [{'id': 1, 'name': '1', 'monitor': 'DP-1'}, {'id': 2, 'name': '2', 'monitor': 'DP-1'}]

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.state = Path(self.directory.name)
        self.live = [dict(w) for w in self.LIVE]
        self.monitors = [dict(m) for m in self.MONITORS]
        self.windows = []
        self.active = {'id': 1, 'name': '1'}
        self.count = 0
        patch.object(c, 'STATE', self.state).start()
        patch.object(c, 'plugin_count', side_effect=lambda: self.count).start()
        patch.object(c, 'hypr', side_effect=self.reply).start()
        self.addCleanup(patch.stopall)

    def reply(self, *args, **kwargs):
        self.assertNotIn('dispatch', args)  # a unit test never mutates the session
        if 'workspaces' in args: return self.live
        if 'monitors' in args: return self.monitors
        if 'clients' in args: return self.windows
        if 'activeworkspace' in args: return self.active
        return []

    def test_a_window_list_that_is_not_a_list_is_refused_once_and_clearly(self):
        for reply in [{'0xabc': {}}, None, 'window', 7]:
            self.windows = reply
            for call in [c.clients, lambda: c.find_window('0xabc')]:
                with self.assertRaises(RuntimeError) as caught:
                    call()
                self.assertEqual(str(caught.exception), 'Hyprland sent an unexpected window list')

    def test_windows_without_a_usable_address_are_not_windows(self):
        self.windows = [{'workspace': {'id': 1, 'name': '1'}}, 'not a window', None, [], 7,
                        {'address': 7}, {'address': ''},
                        {'address': '0xabc', 'workspace': {'id': 1, 'name': '1'}}]
        self.assertEqual([window['address'] for window in c.clients()], ['0xabc'])
        self.assertIsNone(c.find_window('0xdef'))
        self.assertEqual(c.find_window('0xabc')['address'], '0xabc')

    def test_a_desktop_list_that_is_not_a_list_is_refused_once_and_clearly(self):
        for reply in [{'1': {}}, None, '1', 7]:
            self.live = reply
            for call in [c.read_order, lambda: c.act(['state'])]:
                with self.assertRaises(RuntimeError) as caught:
                    call()
                self.assertEqual(str(caught.exception), 'Hyprland sent an unexpected desktop list')

    def test_a_display_list_that_is_not_a_list_is_refused_once_and_clearly(self):
        for reply in [{'DP-1': {}}, None, 'DP-1', 7]:
            self.monitors = reply
            with self.assertRaises(RuntimeError) as caught:
                c.act(['state'])
            self.assertEqual(str(caught.exception), 'Hyprland sent an unexpected display list')

    def test_malformed_workspaces_and_monitors_still_answer_a_usable_state(self):
        self.live = self.live + [[], None, 'ws', 7, {}, {'id': 'x', 'name': 3}, {'id': -1337}]
        self.monitors = [{'description': 'ghost', 'focused': True}, None, 'DP-9', 7] + self.monitors
        result = c.act(['state'])
        self.assertTrue(result['ok'])
        self.assertEqual(result['order'], [1, 2])
        self.assertEqual(result['desktops']['1']['monitor'], 'DP-1')  # the real monitor still decides
        with self.assertRaises(ValueError) as caught:
            c.act(['state'], 'ghost')
        self.assertEqual(str(caught.exception), 'That monitor is no longer available')

    def test_pinned_slots_survive_a_monitor_entry_without_a_name(self):
        self.count = 2
        self.monitors = [{'description': 'ghost'}] + self.monitors
        result = c.act(['state'])
        self.assertEqual(c.scoped_order(result['order'], result['desktops'], 'DP-1', 2),
                         [1, 2, 'name:Panel:1', 'name:Panel:2'])
        self.assertTrue(result['desktops']['name:Panel:1']['pinned'])
        self.assertTrue(result['perMonitor'])
        self.assertNotIn('name:ghost:1', result['desktops'])

    def test_move_refuses_a_window_whose_desktop_is_not_reported(self):
        for workspace in [None, 'name:1', 7, []]:
            self.windows = [dict({'address': '0xabc'}, **({} if workspace is None else {'workspace': workspace}))]
            with self.assertRaises(ValueError) as caught:
                c.move_window('abc', 2)
            self.assertEqual(str(caught.exception), 'Hyprland did not report a desktop for that window')
        # The special-workspace refusal keeps its own, unchanged message.
        self.windows = [{'address': '0xabc', 'workspace': {'id': -99, 'name': 'special:magic'}}]
        with self.assertRaises(ValueError) as caught:
            c.move_window('abc', 2)
        self.assertEqual(str(caught.exception), 'Special workspaces are not managed here')
        self.windows = [{'address': '0xabc', 'workspace': {'id': 2, 'name': '2'}}]
        self.assertEqual(c.move_window('abc', 2), [])  # already there: no dispatch, no record

    def test_move_ignores_a_group_field_it_cannot_read(self):
        before = {'address': '0xabc', 'workspace': {'id': 1, 'name': '1'}, 'grouped': 'not a list'}
        after = {'address': '0xabc', 'workspace': {'id': 2, 'name': '2'}}
        with patch.object(c, 'clients', side_effect=[[before], [after]]), \
             patch.object(c, 'find_window', side_effect=[before, after]), \
             patch.object(c, 'dispatch_to') as dispatch:
            self.assertEqual(c.move_window('abc', 2), [{'address': '0xabc', 'source': 1, 'target': 2}])
            self.assertTrue(dispatch.called)
        grouped = dict(before, grouped=[{}, None, 7, '0xdef'])
        member = {'address': '0xdef', 'workspace': {'id': 1, 'name': '1'}}
        landed = [dict(grouped, workspace={'id': 2, 'name': '2'}), dict(member, workspace={'id': 2, 'name': '2'})]
        with patch.object(c, 'clients', side_effect=[[grouped, member], landed]), \
             patch.object(c, 'find_window', side_effect=[grouped, landed[0]]), \
             patch.object(c, 'dispatch_to'):
            self.assertEqual([entry['address'] for entry in c.move_window('abc', 2)], ['0xabc', '0xdef'])

    def test_a_move_undo_could_not_replay_is_not_recorded(self):
        before = {'address': '0xabc', 'workspace': {'id': 1, 'name': '1'}, 'grouped': ['0xabc', '0xdef']}
        member = {'address': '0xdef', 'workspace': {'id': -99, 'name': 'special:magic'}}
        landed = [dict(before, workspace={'id': 2, 'name': '2'}), dict(member, workspace={'id': 2, 'name': '2'})]
        with patch.object(c, 'clients', side_effect=[[before, member], landed]), \
             patch.object(c, 'find_window', side_effect=[before, landed[0]]), \
             patch.object(c, 'dispatch_to'):
            self.assertEqual(c.move_window('abc', 2), [{'address': '0xabc', 'source': 1, 'target': 2}])

    def test_dispatch_to_survives_a_workspace_without_a_monitor_field(self):
        self.live = [{'id': -1337, 'name': 'Panel:1'}]  # renamed slot, monitor not reported
        with patch.object(c, 'dispatch') as dispatch:
            c.dispatch_to('name:Panel:1', 'ACTION', restore=True)
        self.assertIn('monitor = "DP-1"', dispatch.call_args.args[0])  # the slot owner, from monitor_keys

    def test_step_without_an_active_workspace_field_starts_from_the_first_desktop(self):
        self.monitors = [{'id': 0, 'name': 'DP-1', 'description': 'Panel', 'focused': True}]
        with patch.object(c, 'focus_desktop') as focus:
            c.act(['step', 'next'])
            focus.assert_called_once_with(2)
            focus.reset_mock()
            self.monitors[0].pop('focused')  # nothing focused: the compositor is asked instead
            self.active = 'not a workspace'
            c.act(['step', 'next'])
            focus.assert_called_once_with(2)

    def test_an_incomplete_or_unreadable_request_is_a_sentence_not_a_traceback(self):
        self.assertEqual(c.act([])['order'], [1, 2])  # answered as a state query
        for args in [['move'], ['move', '0xabc'], ['switch'], ['step'], ['reorder'], ['reorder', '1'],
                     ['remove'], ['undo']]:
            with self.subTest(args):
                with self.assertRaises(ValueError) as caught:
                    c.act(args)
                self.assertEqual(str(caught.exception), 'Incomplete overview request')
        for args in [['switch', 'nope'], ['reorder', 'nope', '1'], ['remove', '1.5'], ['move', '0xabc', '-1']]:
            with self.subTest(args):
                with self.assertRaises(ValueError) as caught:
                    c.act(args)
                self.assertEqual(str(caught.exception), 'Invalid desktop number')
        with self.assertRaises(ValueError) as caught:
            c.act(['fly'])
        self.assertEqual(str(caught.exception), 'Unknown overview action')

    def test_a_garbled_undo_record_is_refused_whole(self):
        moves = [{'address': '0x%x' % (index + 1), 'source': 1, 'target': 2} for index in range(501)]
        for payload in [json.dumps({'moves': moves}), 'not json', '', '[]', '7', '"undo"', 'null',
                        '{"moves": {}}', '{"moves": null}', '{"moves": 3}', '{"moves": [null]}',
                        '{"moves": ["0xabc"]}', '{"moves": [[]]}',
                        '{"moves": [{"source": 1, "target": 2}]}',
                        '{"moves": [{"address": "0xabc", "target": 2}]}',
                        '{"moves": [{"address": "0xabc", "source": 1}]}',
                        '{"moves": [{"address": "not hex", "source": 1, "target": 2}]}',
                        '{"moves": [{"address": "0xabc", "source": 0, "target": 2}]}',
                        '{"moves": [{"address": "0xabc", "source": true, "target": 2}]}',
                        '{"moves": [{"address": "0xabc", "source": 1, "target": "name:special"}]}',
                        '{"moves": [{"address": "0xabc", "source": 1, "target": {}}]}']:
            with self.subTest(payload[:48]):
                with patch.object(c, 'move_window') as move, patch.object(c, 'save_order') as save:
                    with self.assertRaises(ValueError) as caught:
                        c.act(['undo', payload])
                    self.assertEqual(str(caught.exception), 'Invalid undo record')
                    move.assert_not_called()
                    save.assert_not_called()
        # 500 entries are still accepted, and an order entry no selector can
        # express is skipped rather than refusing the whole undo.
        with patch.object(c, 'find_window', return_value=None):
            result = c.act(['undo', json.dumps({'moves': moves[:500], 'order': [3, {}, 0, 'name:keep']})])
        self.assertEqual(result['order'], [3, 'name:keep', 1, 2])
        self.assertIn('skipped', result['message'])

    def test_undo_skips_a_desktop_that_was_renamed_after_the_move(self):
        self.windows = [{'address': '0xabc', 'workspace': {'id': 2, 'name': 'writing'}}]
        with patch.object(c, 'move_window') as move:
            result = c.act(['undo', json.dumps({'moves': [{'address': '0xabc', 'source': 1, 'target': 2}],
                                                'order': [1, 2]})])
        move.assert_not_called()
        self.assertIn('skipped', result['message'])

    def test_remove_rolls_back_every_move_it_made_when_one_fails(self):
        self.windows = [{'address': '0x1', 'workspace': {'id': 2, 'name': '2'}},
                        {'address': '0x2', 'workspace': {'id': 2, 'name': '2'}}]
        calls = []
        def move(addr, target):
            calls.append((addr, target))
            if (addr, target) == ('0x2', 1):
                raise RuntimeError('Hyprland did not confirm the change; please try again')
            return [{'address': addr, 'source': 2, 'target': target}]
        with patch.object(c, 'move_window', side_effect=move), patch.object(c, 'save_order') as save:
            with self.assertRaises(RuntimeError) as caught:
                c.act(['remove', '2'])
            self.assertEqual(str(caught.exception), 'Hyprland did not confirm the change; please try again')
            save.assert_not_called()
        self.assertEqual(calls, [('0x1', 1), ('0x2', 1), ('0x1', 2)])  # the move that worked is undone
        self.assertEqual(c.act(['state'])['order'], [1, 2])  # the desktop was kept

    def test_a_workspace_whose_monitor_vanished_stays_listed_but_out_of_scope(self):
        self.count = 2
        self.live = self.live + [{'id': 7, 'name': '7', 'monitor': 'DP-9'}, {'id': 8, 'name': '8'}]
        result = c.act(['state'])
        self.assertIn(7, result['order'])
        self.assertEqual(result['desktops']['7']['monitor'], 'DP-9')
        self.assertEqual(result['desktops']['8']['monitor'], '')
        self.assertNotIn(7, c.scoped_order(result['order'], result['desktops'], 'DP-1', 2))
        for args in [['switch', '7'], ['remove', '7'], ['move', '0xabc', '7']]:
            with self.assertRaises(ValueError):
                c.act(args, 'DP-1')

    def test_a_rename_between_two_replies_never_fails_the_action(self):
        renamed = [dict(self.LIVE[0]), {'id': 2, 'name': 'writing', 'monitor': 'DP-1'}]
        seen = []
        def reply(*args, **kwargs):
            self.assertNotIn('dispatch', args)
            if 'workspaces' in args:
                seen.append(args)
                return renamed if len(seen) > 1 else self.live
            return self.monitors if 'monitors' in args else self.active
        with patch.object(c, 'hypr', side_effect=reply):
            result = c.act(['create'])
        self.assertEqual((result['created'], result['order']), (3, [1, 2, 3]))
        self.assertEqual(sorted(result['desktops']), ['1', '2', '3'])
        self.assertEqual(result['desktops']['2']['monitor'], '')  # renamed away by the last reply
        self.assertEqual(json.loads((self.state / 'desktops.json').read_text())['order'], [1, 2, 3])

    def test_a_completed_action_is_not_failed_by_an_unusable_second_reply(self):
        seen = []
        def reply(*args, **kwargs):
            self.assertNotIn('dispatch', args)
            if 'workspaces' in args:
                seen.append(args)
                return None if len(seen) > 1 else self.live
            return self.monitors if 'monitors' in args else self.active
        with patch.object(c, 'hypr', side_effect=reply):
            result = c.act(['create'])
        self.assertTrue(result['ok'])
        self.assertEqual((result['created'], result['order']), (3, [1, 2, 3]))
        self.assertEqual(sorted(result['desktops']), ['1', '2', '3'])
        self.assertEqual(json.loads((self.state / 'desktops.json').read_text())['order'], [1, 2, 3])

    def test_a_query_under_malformed_replies_never_rewrites_the_saved_order(self):
        saved = json.dumps({'version': 1, 'order': [2, 1]}, indent=2) + '\n'
        (self.state / 'desktops.json').write_text(saved)
        self.windows = [{'no': 'address'}, None]
        self.monitors = [{'description': 'ghost'}] + self.monitors
        self.live = self.live + [[], None, 'ws']
        with patch.object(c, 'save_order') as save, patch.object(c, 'focus_desktop'):
            self.assertEqual(c.act(['state'])['order'], [2, 1])
            c.act(['switch', '1'], 'DP-1')
            c.act(['step', 'next'])
            save.assert_not_called()
        self.assertEqual((self.state / 'desktops.json').read_text(), saved)
        self.assertFalse((self.state / 'desktops.json.tmp').exists())

    def test_no_window_title_or_pixel_field_reaches_the_user(self):
        secret, path = 'Bank Statement — Private Browsing', '/home/sehun/.cache/overview/shot.png'
        self.windows = [{'title': secret, 'class': secret},  # no address: not a window at all
                        {'address': '0xabc', 'title': secret, 'initialClass': secret,
                         'filePath': path, 'pixels': 'data:image/png;base64,AAAA'},
                        {'address': '0xdef', 'title': secret, 'workspace': {'id': 2, 'name': '2'}}]
        self.monitors = [dict(self.MONITORS[0], make=secret, model=secret, serial=secret)]
        seen = []
        for args in [[], ['state'], ['fly'], ['step'], ['move', '0xabc', '2'], ['move', '0xdef', '9'],
                     ['remove', '9'], ['switch', '9'],
                     ['undo', json.dumps({'moves': [{'address': secret, 'source': 1, 'target': 2}]})]]:
            try:
                seen.append(json.dumps(c.act(args), ensure_ascii=False))
            except Exception as error:
                seen.append(type(error).__name__ + ': ' + str(error))
        payload = '\n'.join(seen)
        for fragment in ['Bank', 'Statement', 'Private', 'Browsing', '/home/', '.png', 'data:',
                         'base64', 'pixels', 'filePath', 'title']:
            self.assertNotIn(fragment, payload)
        self.assertIn('Hyprland did not report a desktop for that window', payload)

    def test_contended_action_lock_refuses_instead_of_queueing(self):
        # AUDIT.md F-40: a held keybinding must not stack desktop switches that
        # all apply once an earlier action releases the lock.
        import fcntl
        path = Path(self.state) / 'actions.lock'
        with path.open('a') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            waits = []
            with path.open('a') as second:
                clock = iter([0, .5, 1.0, 1.6])
                taken = c.take_lock(second, timeout=1.5, now=lambda: next(clock), sleep=waits.append)
            self.assertFalse(taken)
            self.assertTrue(waits and max(waits) <= .05, waits)
            with patch.object(c.sys, 'argv', ['controller.py', 'state']), \
                 patch('builtins.print') as printed:
                self.assertEqual(c.main(), 1)
            reply = json.loads(printed.call_args[0][0])
            self.assertFalse(reply['ok'])
            self.assertIn('still running', reply['error'])
        with path.open('a') as free:
            self.assertTrue(c.take_lock(free, timeout=0))

    def test_no_action_can_close_an_application(self):
        source = Path(c.__file__).read_text()
        for forbidden in ['killactive', 'forcekillactive', 'closewindow', 'window.close',
                          'window.kill', 'hl.dsp.close', 'hl.dsp.kill']:
            self.assertNotIn(forbidden, source)


if __name__ == '__main__': unittest.main()
