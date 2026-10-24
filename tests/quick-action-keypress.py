#!/usr/bin/env python3
"""Confirm dashboard quick actions respond to a key without requiring Enter."""
from pathlib import Path
import os
import pty
import select
import subprocess
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'shieldpress/shieldpress.sh'
SOURCE = SCRIPT.read_text()


class QuickActionKeypressTests(unittest.TestCase):
    def test_dashboard_uses_single_key_read_and_preserves_menu_mappings(self):
        self.assertIn('read -r -n 1 -s -t 3 key', SOURCE)
        self.assertIn('1) echo "Opening Admin Menu..."; break ;;', SOURCE)
        self.assertIn('2)\n    check_shieldpress_update force', SOURCE)

    def test_bash_read_receives_key_without_newline(self):
        for key in ('1', '2'):
            master, slave = pty.openpty()
            process = subprocess.Popen(
                ['bash', '-c', 'key=""; IFS= read -r -n 1 -s -t 3 key || true; printf "key=%s\\n" "$key"'],
                stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
            )
            os.close(slave)
            try:
                time.sleep(0.1)
                os.write(master, key.encode())
                ready, _, _ = select.select([master], [], [], 2)
                self.assertTrue(ready, 'single keypress was not read promptly')
                output = os.read(master, 128).decode(errors='replace')
                self.assertIn(f'key={key}', output)
                self.assertEqual(process.wait(timeout=2), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)


if __name__ == '__main__':
    unittest.main()
