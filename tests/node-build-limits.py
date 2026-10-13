#!/usr/bin/env python3
"""Exercise build failure propagation and concurrent deployment exclusion."""
from pathlib import Path
import subprocess
import tempfile
import unittest

MENU = Path(__file__).resolve().parents[1] / 'shieldpress/modules/nodejs/nodejs-menu.sh'
SOURCE = MENU.read_text()
PROFILE = 'node_build_profile(){' + SOURCE.split('node_build_profile(){', 1)[1].split('\n# Next 16', 1)[0]


class BuildLimitsTests(unittest.TestCase):
    def test_service_bounds_children_and_propagates_failure(self):
        function = SOURCE.split('run_node_build(){', 1)[1].split('\ncleanup_stale_next_lock(){', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'package.json').write_text('{"scripts":{"build":"next build"},"dependencies":{"next":"16.3.5"}}')
            script = PROFILE + '\n'
            script += 'fail(){ echo "$*"; }; warn(){ echo "$*"; }; touch(){ :; }; chown(){ :; }; systemd-run(){ printf "%s\\n" "$@"; return 42; };\n'
            script += 'awk(){ case "$1" in *MemTotal*) echo 4096;; *SwapFree*) echo 2048;; esac; }; nproc(){ echo 4; };\n'
            script += 'run_node_build(){' + function
            script += '\nrun_node_build example "$1" .next.candidate\n'
            result = subprocess.run(['bash', '-c', script, '_', directory], text=True, capture_output=True)
            self.assertEqual(result.returncode, 42, result.stderr)
            for argument in ['--property=KillMode=control-group', '--property=MemorySwapMax=1536M',
                             '--property=RuntimeMaxSec=60m', '--property=CPUQuota=100%',
                             '--setenv=RAYON_NUM_THREADS=1', '--setenv=UV_THREADPOOL_SIZE=1',
                             '--setenv=NEXT_DIST_DIR=.next.candidate', '--wait', '--collect', '--webpack']:
                self.assertIn(argument, result.stdout)
            self.assertRegex(result.stdout, r'--property=MemoryMax=\d+M')
            self.assertIn('--property=MemoryHigh=infinity', result.stdout)
            self.assertRegex(result.stdout, r'--setenv=NODE_OPTIONS=--max-old-space-size=\d+')

    def test_profiles_cover_small_and_large_vps(self):
        for total, ram, swap, heap, cpus, timeout in [
            (1024, 614, 1228, 768, 1, '90m'),
            (2048, 1228, 2456, 1152, 1, '90m'),
            (3072, 1843, 3584, 1600, 1, '60m'),
            (4096, 2457, 3584, 1984, 1, '60m'),
            (8192, 4915, 3584, 3648, 2, '60m'),
            (16384, 9830, 3584, 4096, 4, '60m'),
        ]:
            with self.subTest(total=total):
                result = subprocess.run(['bash', '-c', PROFILE + f'\nnode_build_profile {total} 4096 8'], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), f'{ram} {swap} {heap} {cpus} {timeout}')

    def test_swap_reserve_and_cpu_availability(self):
        for swap_free in (0, 128, 512):
            result = subprocess.run(['bash', '-c', PROFILE + f'\nnode_build_profile 16384 {swap_free} 1'], text=True, capture_output=True)
            self.assertEqual(result.stdout.strip(), '9830 0 4096 1 60m')

    def test_too_small_or_invalid_host_is_rejected(self):
        for values in ('512 4096 2', 'unknown 0 1', '1024 invalid 1'):
            result = subprocess.run(['bash', '-c', PROFILE + '\nnode_build_profile ' + values], capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_next_admission_and_timeout_validation(self):
        function = SOURCE.split('run_node_build(){', 1)[1].split('\ncleanup_stale_next_lock(){', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'package.json').write_text('{"dependencies":{"next":"16.3.5"}}')
            for total, swap, duration, expected in [
                (1024, 0, '60m', 1),
                (4096, 4096, '0m', 1),
                (4096, 4096, 'forever', 1),
                (4096, 4096, '120m', 0),
            ]:
                with self.subTest(total=total, duration=duration):
                    script = PROFILE + '\nfail(){ echo "$*"; }; warn(){ :; }; touch(){ :; }; chown(){ :; }; nproc(){ echo 4; };\n'
                    script += f'awk(){{ case "$1" in *MemTotal*) echo {total};; *SwapFree*) echo {swap};; esac; }};\n'
                    script += 'systemd-run(){ echo STARTED; printf "%s\\n" "$@"; };\nrun_node_build(){' + function
                    script += f'\nSHIELDPRESS_BUILD_TIMEOUT={duration} run_node_build example "$1"\n'
                    result = subprocess.run(['bash', '-c', script, '_', directory], text=True, capture_output=True)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    if expected:
                        self.assertNotIn('STARTED', result.stdout)
                    else:
                        self.assertIn('--property=RuntimeMaxSec=120m', result.stdout)

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
