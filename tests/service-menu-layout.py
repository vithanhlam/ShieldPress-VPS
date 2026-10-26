#!/usr/bin/env python3
"""Render shared service menus and verify visible column boundaries."""
import os
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / 'shieldpress/core/ui.sh'


def render(body, width=100):
    result = subprocess.run(['bash', '-c', 'source "$1"\n' + body, '_', str(UI)],
                            env={**os.environ, 'COLUMNS': str(width)}, check=True,
                            stdout=subprocess.PIPE, text=True).stdout
    return re.sub(r'\x1b\[[0-9;]*m', '', result)


class Layout(unittest.TestCase):
    def test_all_service_update_headers_and_long_labels(self):
        for name in ['Nginx', 'PHP', 'MariaDB', 'PostgreSQL']:
            text = render(f'''sp_header "{name} Version & Security Updates" "Repository advisories and same-branch updates"
sp_menu_grid "1|Check Versions & CVE Advisories|cyan" "2|Apply Repository Security Updates|green" "3|Apply All Same-Branch Updates|yellow" "4|Repair Package Protection|blue" "0|Back|white"''')
            self.assertTrue(all(len(line) <= 78 for line in text.splitlines()))
            rows = [line for line in text.splitlines() if re.search(r'\[\s*\d+\]', line)]
            self.assertEqual(len(rows), 5)
            self.assertTrue(all(len(re.findall(r'\[\s*\d+\]', line)) == 1 for line in rows))

    def test_short_labels_keep_grid_and_narrow_terminal_stacks(self):
        header = render('sp_header "Nginx Manager" "Configuration"')
        self.assertTrue(all(len(line) == 78 for line in header.splitlines()))
        script = 'sp_menu_grid "1|Check|cyan" "2|Update|green" "0|Back|white"'
        self.assertIn('[ 1] Check                        [ 2]', render(script))
        self.assertEqual(len([line for line in render(script, 70).splitlines() if '[' in line]), 3)

    def test_labels_from_every_existing_menu(self):
        entries = []
        for menu in (ROOT / 'shieldpress/modules').rglob('*menu.sh'):
            entries += re.findall(r'"(\d+\|[^|"\n]+\|\w+)"', menu.read_text())
        for entry in entries:
            # Supply labels as positional args rather than interpolated shell code.
            result = subprocess.run(['bash', '-c', 'source "$1"; sp_menu_grid "$2" "$2"', '_', str(UI), entry],
                                    check=True, stdout=subprocess.PIPE, text=True)
            text = re.sub(r'\x1b\[[0-9;]*m', '', result.stdout)
            self.assertTrue(all(len(line) <= 78 for line in text.splitlines()), entry)


if __name__ == '__main__':
    unittest.main()
