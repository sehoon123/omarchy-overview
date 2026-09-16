"""Numeric, named and per-monitor regression checks; no compositor required."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import controller as c
import workspaces as w


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        patch.object(c, 'STATE', Path(self.directory.name)).start()
        self.monitors = [
            {'id': 0, 'name': 'DP-1', 'description': 'Main', 'focused': True,
             'activeWorkspace': {'id': -1337, 'name': 'Main:1'}},
            {'id': 1, 'name': 'DP-2', 'description': 'Side', 'focused': False,
             'activeWorkspace': {'id': -1338, 'name': 'Side:1'}},
        ]
        self.live = [dict(m['activeWorkspace'], monitor=m['name']) for m in self.monitors]
        self.windows = []
        def hypr(*args, **kwargs):
            return {'workspaces': self.live, 'monitors': self.monitors, 'clients': self.windows,
                    'activeworkspace': self.monitors[0]['activeWorkspace']}[args[-1]]
        patch.object(c, 'hypr', side_effect=hypr).start()
        patch.object(c, 'plugin_count', return_value=5).start()
        self.addCleanup(patch.stopall)

    def test_named_is_not_special_and_ids_are_not_identity(self):
        self.assertEqual(w.workspace_key({'id': -1337, 'name': 'Main:1'}), 'name:Main:1')
        self.assertEqual(w.workspace_key({'id': -1499, 'name': 'Main:1'}), 'name:Main:1')
        self.assertEqual(w.workspace_key({'id': 3, 'name': '3'}), 3)
        self.assertEqual(w.workspace_key({'id': 3, 'name': 'renamed'}), 'name:renamed')
        for workspace in [{'id': -99, 'name': 'special:scratch'}, {'id': -1, 'name': 'special'}, {}]:
            self.assertEqual(w.workspace_key(workspace), 0)
        for ref in ['name:', 'name:special:scratch', 'name:bad\nname', '-1337', '0']:
            with self.assertRaises(ValueError): w.workspace_ref(ref)
        name = 'name:화면 "quoted" \\ panel:2'
        self.assertEqual(json.loads(w.lua_string(w.workspace_ref(name))), name)

    def test_empty_slots_numeric_legacy_and_per_monitor_scope(self):
        c.save_order([2, 1])
        result = c.act(['state'])
        local = w.scoped_order(result['order'], result['desktops'], 'DP-1', 5)
        self.assertEqual(local, ['name:Main:' + str(i) for i in range(1, 6)])
        self.assertEqual(result['order'][:2], [2, 1])
        self.assertTrue(result['desktops']['name:Main:5']['pinned'])
        self.assertEqual(json.loads((c.STATE / 'desktops.json').read_text()), {'version': 1, 'order': [2, 1]})
        with patch.object(c, 'focus_desktop') as focus:
            c.act(['step', 'next'], 'DP-2')
            focus.assert_called_once_with('name:Side:2')
            focus.reset_mock()
            c.act(['step', 'previous'], 'DP-2')
            focus.assert_called_once_with('name:Side:1')
        with self.assertRaises(ValueError): c.act(['switch', 'name:Side:1'], 'DP-1')
        with self.assertRaises(ValueError): c.act(['remove', 'name:Main:1'], 'DP-1')
        with self.assertRaises(ValueError): c.act(['create'], 'unplugged')

    def test_create_reorder_remove_undo_and_restart_use_names(self):
        created = c.act(['create'], 'DP-2')['created']
        self.assertEqual(created, 'name:Side:6')
        moved = c.act(['reorder', created, 'name:Side:2'], 'DP-2')
        local = w.scoped_order(moved['order'], moved['desktops'], 'DP-2', 5)
        self.assertEqual(local[:3], ['name:Side:1', created, 'name:Side:2'])
        removed = c.act(['remove', created], 'DP-2')
        self.assertEqual(removed['target'], 'name:Side:1')
        self.assertNotIn(created, removed['order'])
        restored = c.act(['undo', json.dumps(removed['undo'])], 'DP-2')
        self.assertIn(created, restored['order'])
        self.assertEqual(c.act(['state'])['order'], restored['order'])
        self.assertEqual(json.loads((c.STATE / 'desktops.json').read_text())['version'], 2)

    def test_named_move_group_and_undo_ignore_reallocated_ids(self):
        before = [{'address': a, 'workspace': {'id': -1337, 'name': 'Main:1'}, 'grouped': ['0xabc', '0xdef']}
                  for a in ['0xabc', '0xdef']]
        after = [dict(item, workspace={'id': -1444, 'name': 'Main:2'}) for item in before]
        with patch.object(c, 'find_window', side_effect=[before[0], after[0]]), \
             patch.object(c, 'clients', side_effect=[before, after]), patch.object(c, 'dispatch_to') as dispatch:
            record = c.move_window('abc', 'name:Main:2')
        self.assertEqual(len(record), 2)
        self.assertEqual(record[0]['source'], 'name:Main:1')
        self.assertIn('workspace = "name:Main:2"', dispatch.call_args.args[1])
        self.assertTrue(dispatch.call_args.kwargs['restore'])
        self.windows = [dict(after[0], workspace={'id': -1999, 'name': 'Main:2'}),
                        dict(after[1], workspace={'id': -1444, 'name': 'Main:3'})]
        with patch.object(c, 'move_window') as move:
            result = c.act(['undo', json.dumps({'moves': record, 'order': []})])
            move.assert_called_once_with('0xabc', 'name:Main:1')
            self.assertIn('skipped', result['message'])

    def test_new_slot_dispatch_focuses_owner_and_restores_origin(self):
        with patch.object(c, 'dispatch') as dispatch:
            c.dispatch_to('name:Side:2', 'ACTION', restore=True)
            expr = dispatch.call_args.args[0]
            self.assertLess(expr.index('monitor = "DP-2"'), expr.index('hl.dispatch(ACTION)'))
            self.assertGreater(expr.index('monitor = origin.name'), expr.index('hl.dispatch(ACTION)'))
            c.focus_desktop('name:Main:1')
            self.assertIn('workspace = "name:Main:1"', dispatch.call_args.args[0])

    def test_duplicate_descriptions_parked_and_hotplug(self):
        duplicates = [dict(m, description='Twin') for m in self.monitors]
        self.assertEqual(w.monitor_keys(duplicates), {'DP-1': 'Twin@DP-1', 'DP-2': 'Twin@DP-2'})
        replugged = [dict(self.monitors[0], name='DP-9')]
        self.assertEqual(w.monitor_keys(replugged), {'DP-9': 'Main'})
        parked = [{'id': -1444, 'name': 'Missing:2', 'monitor': 'DP-1'},
                  {'id': 7, 'name': '7', 'monitor': 'DP-1'}]
        order, info = w.catalog(['name:Missing:2', 7, 9], parked, self.monitors, 5)
        local = w.scoped_order(order, info, 'DP-1', 5)
        self.assertIn('name:Missing:2', local)
        self.assertIn(7, local)
        self.assertNotIn(9, local)  # dormant numeric placeholder, not a parked desktop
        self.assertFalse(info['name:Missing:2']['pinned'])

    def test_numeric_and_generic_named_workspaces_without_plugin(self):
        self.live = [{'id': 3, 'name': '3', 'monitor': 'DP-1'},
                     {'id': -1337, 'name': 'writing', 'monitor': 'DP-2'},
                     {'id': -99, 'name': 'special:scratch', 'monitor': 'DP-1'}]
        self.monitors[0]['activeWorkspace'] = {'id': 3, 'name': '3'}
        c.save_order([3, 1, 2])
        with patch.object(c, 'plugin_count', return_value=0):
            self.assertEqual(c.act(['state'])['order'], [3, 1, 2, 'name:writing'])
            with patch.object(c, 'focus_desktop') as focus:
                c.act(['step', 'next'])
                focus.assert_called_once_with(1)
            self.assertEqual(c.act(['create'])['created'], 4)
            self.assertEqual(c.act(['reorder', '4', '1'])['order'], [3, 4, 1, 2, 'name:writing'])
            self.assertNotIn(4, c.act(['remove', '4'])['order'])

    def test_config_count_and_natural_slot_order(self):
        config = Path(self.directory.name) / 'shell.json'
        config.write_text(json.dumps({'bar': {'layout': {'left': [{'id': w.PLUGIN, 'count': 12}]}}}))
        with patch.object(w, 'SHELL_CONFIG', config):
            self.assertEqual(w.plugin_count(), 12)
            config.write_text('{invalid')
            self.assertEqual(w.plugin_count(), 0)
        with patch.object(c, 'plugin_count', return_value=12):
            self.live[0]['name'] = 'Main:3'
            order, info, _, count = c.desktop_state()
            self.assertEqual(w.scoped_order(order, info, 'DP-1', count), ['name:Main:' + str(i) for i in range(1, 13)])


if __name__ == '__main__': unittest.main()
