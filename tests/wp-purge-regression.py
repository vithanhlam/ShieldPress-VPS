#!/usr/bin/env python3
"""Exercise PHP signal fallback and the privileged consumer without WordPress."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('signals', ROOT / 'shieldpress/core/purge-signals.py')
signals = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signals)
with tempfile.TemporaryDirectory() as temp:
    base = Path(temp)
    site = base / 'example_com'
    (site / 'public_html').mkdir(parents=True)
    (site / 'tmp').mkdir()
    plugin = site / 'plugin.php'
    plugin.write_bytes((ROOT / 'shieldpress/templates/wp-mu-plugins/shieldpress-cache-purge.php').read_bytes())
    harness = site / 'test.php'
    harness.write_text('''<?php
    define('ABSPATH', __DIR__ . '/public_html/');
    function add_action(...$args) {}
    function wp_cache_flush() {}
    function wp_is_post_revision($id) {return false;}
    function wp_is_post_autosave($id) {return false;}
    function get_post($id) {return (object)['ID'=>$id, 'post_status'=>'trash'];}
    require __DIR__ . '/plugin.php';
    $p = new ShieldPress_Cache_Purge();
    if ($argv[1] === 'post') {$p->purge_post(1);}
    echo $p->purge(), ':', $p->purge();
    ''')
    def php(mode):
        return subprocess.check_output(['php', '-d', 'disable_functions=exec', '-d', f'open_basedir={site}', str(harness), mode], text=True)
    assert 'exec(' not in plugin.read_text() and '@exec' not in plugin.read_text()
    for mode in ('manual', 'post'):
        assert php(mode) == 'queued:queued'
        assert (site / 'tmp/.purge-cache').read_text() == 'example_com'
        helper = base / 'helper'
        helper.write_text('#!/bin/sh\nexit 1\n')
        helper.chmod(0o755)
        signals.consume(base, helper)
        assert (site / 'tmp/.purge-cache').exists(), 'Failed purges must remain retryable'
        helper.write_text('#!/bin/sh\nexit 0\n')
        signals.consume(base, helper)
        assert not (site / 'tmp/.purge-cache').exists()
    (site / 'tmp').rmdir()
    assert php('manual') == 'fail:fail'
print('PASS: manual/post/trash fallback under open_basedir and disabled exec, queued status, failed signal retry, missing tmp failure')
