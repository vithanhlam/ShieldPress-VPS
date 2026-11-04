#!/usr/bin/env python3
"""Exercise build failure propagation and concurrent deployment exclusion."""
from pathlib import Path
import subprocess
import tempfile
import unittest

MENU = Path(__file__).resolve().parents[1] / 'shieldpress/modules/nodejs/nodejs-menu.sh'
SOURCE = MENU.read_text()
PROFILE = 'node_build_profile(){' + SOURCE.split('node_build_profile(){', 1)[1].split('\n# Next 16', 1)[0]
DIAG = '# ---- Build diagnostics' + SOURCE.split('# ---- Build diagnostics', 1)[1].split('\nrun_node_build(){', 1)[0]


class BuildDiagnosticsTests(unittest.TestCase):
    def fake_cgroup(self, root, pids, oom=0, swap=0):
        cg = Path(root) / 'cg'
        cg.mkdir()
        (cg / 'cpu.stat').write_text('usage_usec 0\nnr_throttled 0\n')
        (cg / 'io.stat').write_text('8:0 rbytes=0 wbytes=0\n')
        (cg / 'memory.events').write_text(f'oom_kill {oom}\n')
        (cg / 'memory.swap.current').write_text(f'{swap}\n')
        (cg / 'cgroup.procs').write_text(''.join(f'{pid}\n' for pid in pids))
        return cg

    def diagnose(self, cg, heap, cpu, io, thr, log='/nonexistent'):
        script = DIAG + f'\nnode_build_diagnose "{cg}" {heap} "{log}" {cpu} {io} {thr}'
        return subprocess.run(['bash', '-c', script], text=True, capture_output=True)

    def test_causes(self):
        with tempfile.TemporaryDirectory() as d:
            sleeper = subprocess.Popen(['sleep', '30'])
            try:
                cg = self.fake_cgroup(d, [sleeper.pid])
                idle = self.diagnose(cg, 4096, 0, 0, 0)
                self.assertEqual(idle.returncode, 0)
                self.assertIn('idle', idle.stdout)
                slow = self.diagnose(cg, 4096, 80, 0, 3)
                self.assertEqual(slow.returncode, 1)
                self.assertIn('slow, not hung', slow.stdout)
                busy = self.diagnose(cg, 4096, 80, 0, 0)
                self.assertEqual(busy.returncode, 1)
                (cg / 'memory.events').write_text('oom_kill 2\n')
                oom = self.diagnose(cg, 4096, 0, 0, 0)
                self.assertEqual(oom.returncode, 0)
                self.assertIn('OOM', oom.stdout)
                (cg / 'memory.events').write_text('oom_kill 0\n')
                (cg / 'memory.swap.current').write_text(str(512 * 1048576))
                swap = self.diagnose(cg, 4096, 10, 5000, 0)
                self.assertIn('swapping', swap.stdout)
            finally:
                sleeper.kill(); sleeper.wait()

    def test_heap_exhaustion_is_identified(self):
        with tempfile.TemporaryDirectory() as d:
            node = Path(d) / 'node'
            node.symlink_to('/usr/bin/python3')
            proc = subprocess.Popen([str(node), '-I', '-c', 'import time; b = bytearray(80_000_000); b[::4096] = b"x" * len(b[::4096]); time.sleep(30)'])
            try:
                import time
                time.sleep(1.5)
                cg = self.fake_cgroup(d, [proc.pid])
                result = self.diagnose(cg, 64, 90, 0, 0)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn('heap is nearly full', result.stdout)
                self.assertIn('SHIELDPRESS_BUILD_HEAP_MB', result.stdout)
            finally:
                proc.kill(); proc.wait()

    def test_postmortem(self):
        cases = [('FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory', 'heap limit'),
                 ('Finished with result: oom-kill', 'memory cap'),
                 ('Finished with result: timeout', 'time limit'),
                 ("Module not found: Can't resolve './missing'", 'application code'),
                 ('something odd', 'not recognised')]
        for text, expected in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as d:
                log = Path(d) / 'log'
                log.write_text(text + '\n')
                result = subprocess.run(['bash', '-c', DIAG + f'\nnode_build_postmortem "{log}" 4096'], text=True, capture_output=True)
                self.assertIn(expected, result.stdout)

    def test_watchdog_stops_idle_build(self):
        with tempfile.TemporaryDirectory() as d:
            sleeper = subprocess.Popen(['sleep', '30'])
            try:
                cg = self.fake_cgroup(d, [sleeper.pid])
                log = Path(d) / 'build.log'
                log.write_text('compiling\n')
                stop = Path(d) / 'stopped'
                script = DIAG + f'\nsystemctl(){{ echo "$*" > "{stop}"; }}\nnode_build_watchdog unit 4096 "{log}" 1 2'
                env = {'PATH': '/usr/bin:/bin', 'SHIELDPRESS_BUILD_CGROUP': str(cg), 'SHIELDPRESS_BUILD_WATCH_INTERVAL': '1', 'SHIELDPRESS_BUILD_WATCH_MINUTE_SECONDS': '1'}
                result = subprocess.run(['bash', '-c', script], text=True, capture_output=True, env=env, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('Diagnosing', result.stdout)
                self.assertEqual(stop.read_text().strip(), 'stop unit')
                self.assertIn('stopped automatically', Path(str(log) + '.diag').read_text())
            finally:
                sleeper.kill(); sleeper.wait()

    def test_watchdog_does_not_stop_progressing_build(self):
        with tempfile.TemporaryDirectory() as d:
            sleeper = subprocess.Popen(['sleep', '30'])
            try:
                cg = self.fake_cgroup(d, [sleeper.pid])
                log = Path(d) / 'build.log'
                log.write_text('')
                stop = Path(d) / 'stopped'
                script = DIAG + f'\nsystemctl(){{ echo "$*" > "{stop}"; }}\n(for i in 1 2 3 4 5 6; do echo line >> "{log}"; sleep 1; done) &\nnode_build_watchdog unit 4096 "{log}" 2 3 & w=$!; sleep 5; kill $w'
                env = {'PATH': '/usr/bin:/bin', 'SHIELDPRESS_BUILD_CGROUP': str(cg), 'SHIELDPRESS_BUILD_WATCH_INTERVAL': '1', 'SHIELDPRESS_BUILD_WATCH_MINUTE_SECONDS': '1'}
                subprocess.run(['bash', '-c', script], text=True, capture_output=True, env=env, timeout=20)
                self.assertFalse(stop.exists())
            finally:
                sleeper.kill(); sleeper.wait()


class BuildUnitTests(unittest.TestCase):
    def run_prepare(self, active, loaded=True):
        script = DIAG + f'''
systemctl(){{
    case "$1" in
        cat) return {0 if loaded else 1} ;;
        is-failed) return 1 ;;
        is-active) [ "$2" = "--quiet" ] && {{ [ "{active}" = active ]; return; }}; echo {active} ;;
        show) echo "Wed 2026-11-04 10:00:00 UTC" ;;
        reset-failed) echo reset "$2" > "$RESET_MARK" ;;
    esac
}}
node_build_unit_prepare shieldpress-node-build'''
        with tempfile.TemporaryDirectory() as directory:
            mark = Path(directory) / 'mark'
            result = subprocess.run(['bash', '-c', script], text=True, capture_output=True, env={'PATH': '/usr/bin:/bin', 'RESET_MARK': str(mark)})
            result.reset = mark.read_text() if mark.exists() else ''
        return result

    def test_running_build_blocks_a_second_one(self):
        result = self.run_prepare('active')
        self.assertEqual(result.returncode, 1)
        self.assertIn('still running', result.stdout)
        self.assertIn('systemctl stop shieldpress-node-build', result.stdout)

    def test_leftover_unit_is_cleared(self):
        result = self.run_prepare('failed')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('reset shieldpress-node-build.service', result.reset)

    def test_no_unit_is_a_noop(self):
        result = self.run_prepare('inactive', loaded=False)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')


class BuildLimitsTests(unittest.TestCase):
    def test_service_bounds_children_and_propagates_failure(self):
        function = SOURCE.split('run_node_build(){', 1)[1].split('\ncleanup_stale_next_lock(){', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'package.json').write_text('{"scripts":{"build":"next build"},"dependencies":{"next":"16.3.5"}}')
            script = PROFILE + '\n'
            script += 'node_build_unit_prepare(){ return 0; }\n'
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

    def test_large_hosts_scale_heap_and_cpus(self):
        for total, heap, cpus in [(32768, 8192, 8), (65536, 16384, 16), (122880, 16384, 16)]:
            with self.subTest(total=total):
                result = subprocess.run(['bash', '-c', PROFILE + f'\nnode_build_profile {total} 4096 32'], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                fields = result.stdout.split()
                self.assertEqual((int(fields[2]), int(fields[3])), (heap, cpus))

    def test_dependency_audit_is_advisory(self):
        self.assertIn('npm audit --omit=dev --audit-level=high', SOURCE)
        self.assertIn('audit_node_dependencies "$sysuser"', SOURCE)

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
                    script = PROFILE + '\nnode_build_unit_prepare(){ return 0; }; fail(){ echo "$*"; }; warn(){ :; }; touch(){ :; }; chown(){ :; }; nproc(){ echo 4; };\n'
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
