#!/usr/bin/env python3
"""Run the actual PHP fallback snippets against an isolated WordPress stub."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

SCRIPT = Path(__file__).resolve().parents[1] / 'shieldpress/modules/wordpress/reset-password.sh'
source = SCRIPT.read_text()
snippets = re.findall(r"-r '(.*?)' \"\$ROOT/wp-load\.php\"", source, re.S)
assert len(snippets) == 2, 'Expected admin-list and password-reset PHP fallbacks'

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    stub = root / 'wp-load.php'
    result_file = root / 'updated.json'
    stub.write_text('''<?php
function get_users($query) {
    if ($query !== ["role" => "administrator"]) { throw new Exception("Wrong role"); }
    return [(object)["user_login" => "admin"], (object)["user_login" => "second-admin"]];
}
function get_user_by($field, $value) {
    return $field === "login" && $value === "admin" ? (object)["ID" => 42] : false;
}
function wp_set_password($password, $id) {
    file_put_contents(getenv("RESET_RESULT"), json_encode(["id" => $id, "password" => $password]));
}
''')
    env = {**os.environ, 'RESET_RESULT': str(result_file)}

    def execute(code, **values):
        return subprocess.run(['php', '-r', code, str(stub)],
                              env={**env, **values}, capture_output=True, text=True)

    listing = execute(snippets[0])
    assert listing.returncode == 0, listing.stderr
    assert listing.stdout.splitlines() == ['admin', 'second-admin']

    password = "Example!@#$%&*'\\Safe123"
    success = execute(snippets[1], WP_RESET_LOGIN='admin', WP_RESET_PASS=password)
    assert success.returncode == 0, success.stderr
    assert json.loads(result_file.read_text()) == {'id': 42, 'password': password}
    assert password not in success.stdout + success.stderr
    result_file.unlink()

    missing = execute(snippets[1], WP_RESET_LOGIN='missing', WP_RESET_PASS=password)
    assert missing.returncode == 2, missing.stderr
    assert 'Administrator account was not found.' in missing.stderr
    assert not result_file.exists()
    assert password not in missing.stdout + missing.stderr

    # A broken WordPress bootstrap must fail rather than report a reset success.
    stub.write_text('<?php throw new Exception("WordPress bootstrap failed");')
    for code in snippets:
        failed = execute(code, WP_RESET_LOGIN='admin', WP_RESET_PASS=password)
        assert failed.returncode != 0
    assert not result_file.exists()

print('WordPress password-reset regression checks passed.')
