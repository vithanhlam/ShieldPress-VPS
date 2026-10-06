#!/usr/bin/env python3
"""Exercise build failure propagation and concurrent deployment exclusion."""
from pathlib import Path
import subprocess
import tempfile
import unittest

MENU = Path(__file__).resolve().parents[1] / 'shieldpress/modules/nodejs/nodejs-menu.sh'
SOURCE = MENU.read_text()


class BuildLimitsTests(unittest.TestCase):
    def test_service_bounds_children_and_propagates_failure(self):
        function = SOURCE.split('run_node_build(){', 1)[1].split('\ncleanup_stale_next_lock(){', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'package.json').write_text('{"scripts":{"build":"next build"},"dependencies":{"next":"16.3.5"}}')
            script = 'fail(){ echo "$*"; }; touch(){ :; }; chown(){ :; }; systemd-run(){ printf "%s\\n" "$@"; return 42; };\nrun_node_build(){' + function
            script += '\nrun_node_build example "$1" .next.candidate\n'
            result = subprocess.run(['bash', '-c', script, '_', directory], text=True, capture_output=True)
            self.assertEqual(result.returncode, 42, result.stderr)
            for argument in ['--property=KillMode=control-group', '--property=MemorySwapMax=1024M',
                             '--property=RuntimeMaxSec=30m', '--property=CPUQuota=100%',
                             '--setenv=RAYON_NUM_THREADS=1', '--setenv=UV_THREADPOOL_SIZE=1',
                             '--setenv=NEXT_DIST_DIR=.next.candidate', '--wait', '--collect', '--webpack']:
                self.assertIn(argument, result.stdout)
            self.assertRegex(result.stdout, r'--property=MemoryMax=\d+M')
            self.assertRegex(result.stdout, r'--property=MemoryHigh=\d+M')
            self.assertRegex(result.stdout, r'--setenv=NODE_OPTIONS=--max-old-space-size=\d+')

    def test_busy_deploy_never_enters_mutation(self):
        wrapper = 'deploy_node_app(){' + SOURCE.split('deploy_node_app(){', 1)[1].split('\ndeploy_node_app_locked(){', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            wrapper = wrapper.replace('/run/lock', directory)
            script = 'fail(){ echo "$*"; };\n' + wrapper + '\n'
            script += 'deploy_node_app_locked(){ echo MUTATED; };\n'
            script += 'exec 8>"$1/shieldpress-node-deploy.lock"; flock -n 8; deploy_node_app\n'
            result = subprocess.run(['bash', '-c', script, '_', directory], text=True, capture_output=True)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertNotIn('MUTATED', result.stdout)


if __name__ == '__main__':
    unittest.main()
