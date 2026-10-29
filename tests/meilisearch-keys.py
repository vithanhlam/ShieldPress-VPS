#!/usr/bin/env python3
"""Exercise domain key lifecycle with an isolated Meilisearch API stub."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'shieldpress/modules/tools/meilisearch.sh').read_text()
source = source.split('if declare -F sp_header')[0]
source = source.replace('[[ $EUID -eq 0 ]] || fail "Run with sudo/root."', '')
source = source.replace('[[ -f "$UI_FILE" ]] && source "$UI_FILE"', ':')

with tempfile.TemporaryDirectory() as temp:
    base = Path(temp)
    domain = base / 'domain.env'
    domain.write_text('DOMAIN=cms.authentic-shoes.com\nAPP_TYPE=php\n')
    log = base / 'calls'
    harness = source + r'''
select_domain(){
    DOMAIN_NAME=cms.authentic-shoes.com
    DOMAIN_INDEX=products_cms_authentic-shoes_com
    DOMAIN_ENV="$TEST_DOMAIN_ENV"
}
read_master_key(){ echo test-master; }
curl(){
    printf '%s\n' "$@" >> "$TEST_LOG"
    case "$*" in
        *"/keys"*)
            if [[ "$TEST_FAILURE" == yes ]]; then
                echo '{"message":"denied","code":"invalid_api_key"}'
            else
                printf '{"uid":"%s","key":"value-%s"}\n' "$TEST_UID" "$TEST_UID"
            fi ;;
    esac
}
manage_key "$TEST_ACTION" "$TEST_PURPOSE"
'''
    script = base / 'harness.sh'
    script.write_text(harness)

    def run(action, purpose, uid='new', failure=False, answer='y\n'):
        result = subprocess.run(['bash', str(script)], input=answer, text=True,
                                capture_output=True, env={**os.environ,
                                'TEST_DOMAIN_ENV': str(domain), 'TEST_LOG': str(log),
                                'TEST_ACTION': action, 'TEST_PURPOSE': purpose,
                                'TEST_UID': uid, 'TEST_FAILURE': 'yes' if failure else 'no'})
        assert (result.returncode != 0) == failure, result.stdout + result.stderr
        return result.stdout

    run('create', 'search', 'search-old')
    run('create', 'crm', 'crm-old')
    settings = domain.read_text()
    assert 'MEILI_KEY=value-search-old\n' in settings
    assert 'MEILI_CRM_KEY=value-crm-old\n' in settings
    payloads = [json.loads(line) for line in log.read_text().splitlines() if line.startswith('{')]
    keys = [p for p in payloads if 'actions' in p]
    assert keys[0]['actions'] == ['search']
    assert set(keys[1]['actions']) == {'search', 'indexes.get', 'indexes.create',
        'documents.add', 'documents.delete', 'settings.get', 'settings.update', 'tasks.get'}
    assert all(p['indexes'] == ['products_cms_authentic-shoes_com'] and p['expiresAt'] for p in keys)
    assert domain.stat().st_mode & 0o777 == 0o600

    run('create', 'crm', failure=True)
    assert domain.read_text() == settings
    assert '/keys/crm-old' not in log.read_text()
    run('create', 'crm', 'crm-new', answer='n\n')
    assert domain.read_text() == settings
    run('create', 'crm', 'crm-new')
    assert '/keys/crm-old' in log.read_text()
    assert '/keys/search-old' not in log.read_text()
    assert 'value-crm-new' in run('show', 'crm')
    assert 'value-search-old' in run('show', 'search')
    run('revoke', 'crm')
    assert 'MEILI_CRM_KEY' not in domain.read_text()
    assert 'MEILI_KEY=value-search-old\n' in domain.read_text()
    run('create', 'crm', 'crm-repeat')
    run('revoke', 'search')
    assert 'MEILI_KEY=' not in domain.read_text()
    assert 'MEILI_CRM_KEY=value-crm-repeat\n' in domain.read_text()
    assert 'MEILI_HOST=' in domain.read_text() and 'MEILI_INDEX=' in domain.read_text()
    assert 'APP_TYPE=php\n' in domain.read_text()

spec = importlib.util.spec_from_file_location('domain_security', ROOT / 'shieldpress/core/domain-security.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert {'MEILI_CRM_KEY', 'MEILI_CRM_KEY_UID', 'MEILI_CRM_KEY_EXPIRES_AT'} <= module.KEYS
print('[PASS] Existing search keys, scoped CRM permissions, rotation, failure, repeat creation, revocation and settings allowlist')
