#!/usr/bin/env python3
"""Every numeric selection offers 0 = Back; the shared picker validates input."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'shieldpress'
PROMPT = re.compile(r'read (?:-r )?(?:-p|-rp) ?"([^"]*)"\s+(\w+)')
SELECT = re.compile(r'^\s*(select|choose|choice|option)\b|number|^\s*select [a-z ]+:|\[\d\]:\s*$|\(1/2', re.I)
TEXT = re.compile(r'HH:MM|percent|seconds|size in|threshold|prefix|command|IP |port|title|chat id|api base|level \(|'
                  r'workers|EAB|label|hour|day of|frequency|wait after|requests|retention|minutes', re.I)
# Mid-operation prompts where going back would leave work half done; each offers an explicit skip/default.
EXCEPTIONS = {
    ('modules/database/import-domain.sh', 'PREFIX_ACTION'),  # after the database was imported; option 3 skips
    ('modules/nodejs/nodejs-menu.sh', 'PM2_MODE'),           # after code was deployed (deploy start mode)
}


def prompts():
    for path in sorted(ROOT.rglob('*.sh')):
        lines = path.read_text(errors='replace').splitlines()
        for i, line in enumerate(lines):
            m = PROMPT.search(line)
            if not m or not SELECT.search(m.group(1)) or TEXT.search(m.group(1)):
                continue
            j = i + 1
            while j < len(lines) and j < i + 200:
                n = PROMPT.search(lines[j])
                if n and SELECT.search(n.group(1)):
                    break
                j += 1
            yield path.relative_to(ROOT).as_posix(), i + 1, m.group(2), lines[max(0, i - 40):i + 1], lines[i:j]


class Back(unittest.TestCase):
    def test_every_selection_shows_and_handles_zero(self):
        missing = []
        for name, number, var, before, after in prompts():
            shown = re.search(r'\b0[)\]]|"0\||0 ?= ?back|\[ ?0\]|\bBack\b|0 to back|0=cancel', '\n'.join(before))
            handled = re.search(r'in 0(\|"")?\)|(^|\s|\|)0\)|"0"\)|\$\{?' + var + r'\}?"? ?(==|=|-eq) ?"?0\b|^\s*0\|',
                                '\n'.join(after), re.M)
            if (name, var) in EXCEPTIONS:
                continue
            if not (shown and handled):
                missing.append(f'{name}:{number} {var} shown={bool(shown)} handled={bool(handled)}')
        self.assertEqual(missing, [])

    def test_exceptions_still_exist(self):
        found = {(name, var) for name, _, var, _, _ in prompts()}
        self.assertTrue(EXCEPTIONS <= found, EXCEPTIONS - found)


class Picker(unittest.TestCase):
    def run_picker(self, root, answers):
        script = f'source "{ROOT}/core/ui.sh"; DOMAINS_ROOT="{root}"\n' \
                 'if sp_pick_domain "Pick"; then echo "PICK=$SP_PICK_DOMAIN|$SP_PICK_PATH"; else echo "BACK=$?"; fi'
        result = subprocess.run(['bash', '-c', script], input=answers, text=True, capture_output=True)
        return re.sub(r'\x1b\[[0-9;]*m', '', result.stdout)

    def test_domain_picker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for folder, name in (('a_com', 'a.com'), ('b_org', '"b.org"')):
                (root / folder / 'config').mkdir(parents=True)
                (root / folder / 'config/domain.env').write_text(f'DOMAIN={name}\n')
            (root / 'no_config').mkdir()
            out = self.run_picker(root, '0\n')
            self.assertIn('[ 0] Back', out)
            self.assertIn('BACK=1', out)
            self.assertIn('BACK=1', self.run_picker(root, '\n'))
            self.assertIn('BACK=1', self.run_picker(root, ''))  # EOF
            out = self.run_picker(root, '9\nabc\n2\n')
            self.assertEqual(out.count('Enter a number from 0 to 2.'), 2)
            self.assertIn(f'PICK=b.org|{root}/b_org', out)
            self.assertNotIn('no_config', out)
            empty = root / 'none'
            empty.mkdir()
            self.assertIn('No domains found', self.run_picker(empty, '1\n'))

    def test_shared_selectors_use_the_picker(self):
        for name in ('core/helpers.sh', 'modules/domain/helpers.sh', 'modules/wordpress/helpers.sh'):
            text = (ROOT / name).read_text()
            self.assertIn('sp_pick_domain', text, name)
            subprocess.run(['bash', '-n', str(ROOT / name)], check=True)


if __name__ == '__main__':
    unittest.main(verbosity=1)
