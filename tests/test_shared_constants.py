"""Constants that the Python helper and the QML/JS side each spell out must stay equal.

They are duplicated on purpose (the helper runs before QML, QML must not import
Python), so this test reads both sources and fails when the copies drift.
Equal sets are not equal matching: Python compares lock namespaces exactly,
while shell.qml's regex also matches them as substrings.
"""
import ast
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / name).read_text(encoding='utf-8')


def one(pattern, text, where):
    found = re.findall(pattern, text, re.S | re.M)
    assert len(found) == 1, f'{where}: expected exactly one match for {pattern!r}, found {len(found)}'
    return found[0]


class SharedConstantTests(unittest.TestCase):
    def assertSameSet(self, py_file, py_values, other_file, other_values, what):
        self.assertEqual(
            set(py_values), set(other_values),
            f'{what} differ between {py_file} {sorted(py_values)} and {other_file} {sorted(other_values)}; '
            f'update both files together')
        self.assertTrue(py_values and other_values, f'{what}: empty in {py_file} or {other_file}')

    def test_lock_layer_namespaces_match(self):
        py = ast.literal_eval(one(r'^LOCK_NAMESPACES = (\(.*?\))$', source('capture_context.py'), 'capture_context.py'))
        regex = one(r'event\.name === "openlayer" && /([^/]+)/\.test', source('shell.qml'), 'shell.qml')
        self.assertSameSet('capture_context.py', py, 'shell.qml', regex.split('|'), 'lock/auth layer namespaces')

    def test_placeholder_output_prefixes_match(self):
        py = ast.literal_eval(one(r"name\.startswith\((\([^)]*\))\)", source('capture_context.py'), 'capture_context.py'))
        js = one(r'function previewScreens\(.*?\.test\(s\.name\)', source('OverviewLogic.js'), 'OverviewLogic.js')
        group = one(r'!/\^\(([^)]*)\)/', js, 'OverviewLogic.js previewScreens')
        self.assertSameSet('capture_context.py', py, 'OverviewLogic.js', group.split('|'),
                           'placeholder output name prefixes (HEADLESS-/FALLBACK)')


if __name__ == '__main__':
    unittest.main()
