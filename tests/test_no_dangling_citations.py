"""Comments must not cite documents that are not in the repository."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SKIP_DIRS = {'.git', '.audit', '__pycache__', 'fixtures'}
SUFFIXES = {'.qml', '.js', '.py', '.md', '.service', ''}
AUDIT = re.compile(r'AUDIT(?:\.md| F-)')
LINE_CITATION = re.compile(r'\b[A-Za-z]+\.(?:qml|js|py):\d+')


def sources():
    for path in ROOT.rglob('*'):
        parts = path.relative_to(ROOT).parts
        if (path.is_file() and path.suffix in SUFFIXES and path != Path(__file__).resolve()
                and not any(p in SKIP_DIRS or p.startswith('.deployment-backup-') for p in parts)):
            yield path


class CitationTests(unittest.TestCase):
    def scan(self, pattern):
        return [f'{p.relative_to(ROOT)}:{n}' for p in sources()
                for n, line in enumerate(p.read_text(encoding='utf-8', errors='replace').splitlines(), 1)
                if pattern.search(line)]

    def test_no_citation_of_the_missing_audit_file(self):
        self.assertEqual([], self.scan(AUDIT),
                         'AUDIT.md does not exist in this repository; state the reason in the comment instead of citing it')

    def test_no_line_number_citations_of_other_files(self):
        self.assertEqual([], self.scan(LINE_CITATION),
                         'line numbers rot; cite the function or property name instead')


if __name__ == '__main__':
    unittest.main()
