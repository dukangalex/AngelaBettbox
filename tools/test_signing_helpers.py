"""Offline tests using fake bytes only: no key creation, GitHub writes, or credentials."""
import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).parent

def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

class SigningHelpersTest(unittest.TestCase):
    def test_properties_escape(self):
        writer = load('writer', 'write-signing-properties.py')
        self.assertEqual(writer.escape(' a:b=c\\d\n\t'), r'\ a\:b\=c\\d\n\t')
        self.assertEqual(writer.escape('中'), r'\u4e2d')
        self.assertEqual(writer.escape('😀'), r'\ud83d\ude00')

    def exercise_upload(self, confirmation):
        config = load('config', 'configure-android-signing.py')
        with tempfile.TemporaryDirectory() as d:
            store = Path(d) / 'fake.p12'; store.write_bytes(b'FAKE-NOT-A-KEY')
            output = io.StringIO()
            with patch('sys.argv', ['configure', str(store)]), \
                 patch.object(config.subprocess, 'run') as run, \
                 patch.object(config.getpass, 'getpass', side_effect=['FAKE-PASSWORD', '']), \
                 patch('builtins.input', return_value=confirmation), contextlib.redirect_stdout(output):
                config.main()
            self.assertNotIn('FAKE-PASSWORD', output.getvalue())
            self.assertNotIn('FAKE-NOT-A-KEY', output.getvalue())
            return run.call_args_list

    def test_cancel_never_writes_secrets(self):
        calls = self.exercise_upload('CANCEL')
        self.assertFalse(any('secret' in c.args[0] for c in calls))

    def test_confirm_uploads_exact_four_names_via_stdin(self):
        calls = self.exercise_upload('UPLOAD')
        writes = [c for c in calls if 'secret' in c.args[0]]
        self.assertEqual([c.args[0][3] for c in writes],
                         ['KEYSTORE', 'KEY_ALIAS', 'STORE_PASSWORD', 'KEY_PASSWORD'])
        for c in writes:
            self.assertIn('input', c.kwargs)
            self.assertNotIn('FAKE-PASSWORD', c.args[0])

if __name__ == '__main__': unittest.main()
