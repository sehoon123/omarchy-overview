from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import controller as c

class ControllerTests(unittest.TestCase):
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

    def test_prime_cannot_be_invoked_without_resident_lease(self):
        with patch.object(c, 'read_order', return_value=[1]):
            with self.assertRaises(ValueError): c.act(['prime', 'abc'])

if __name__ == '__main__': unittest.main()
