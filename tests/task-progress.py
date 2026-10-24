#!/usr/bin/env python3
"""Check progress reporting, historical ETA and command failure propagation."""
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'shieldpress/modules/helpers/task-progress.sh'


class ProgressTests(unittest.TestCase):
    def test_eta_and_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            history = Path(directory) / 'timing'
            script = 'source "$1"; run_with_progress Example "$2" bash -c "echo command-output; exit $3"'
            def run(code):
                return subprocess.run(['bash', '-c', script, '_', str(HELPER), str(history), str(code)], text=True, capture_output=True, timeout=5)
            first = run(0)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertIn('estimating on first run', first.stdout)
            self.assertIn('command-output', first.stdout)
            self.assertIn('finished in', first.stdout)
            saved = history.read_text()
            failed = run(42)
            self.assertEqual(failed.returncode, 42, failed.stderr)
            self.assertIn('previous successful run', failed.stdout)
            self.assertEqual(history.read_text(), saved)

    def test_heartbeat(self):
        script = 'source "$1"; run_with_progress Slow "$2" sleep 11'
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['bash', '-c', script, '_', str(HELPER), directory + '/timing'], text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('running, elapsed', result.stdout)
        self.assertIn('ETA not available yet', result.stdout)


if __name__ == '__main__':
    unittest.main()
