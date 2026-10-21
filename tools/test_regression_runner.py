"""Exercise the regression entrypoint without installing toolchains or networking."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class RegressionRunnerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'tools').mkdir()
        (self.root / 'core').mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        shutil.copyfile(Path(__file__).with_name('check-regressions.sh'),
                        self.root / 'tools/check-regressions.sh')
        self.log = self.root / 'commands.jsonl'
        stub = f'''#!{sys.executable}
import json, os, sys
from pathlib import Path
command = Path(sys.argv[0]).name
with open(os.environ['COMMAND_LOG'], 'a') as log:
    log.write(json.dumps([command, sys.argv[1:], os.getcwd(), os.environ.get('GOFLAGS'), os.environ.get('CGO_ENABLED')]) + '\\n')
if os.environ.get('FAIL_COMMAND') == command:
    sys.exit(17)
'''
        for tool in ('flutter', 'cargo', 'go', 'python3'):
            path = self.bin / tool
            path.write_text(stub)
            path.chmod(0o755)

    def run_suite(self, suite, fail=''):
        env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                   COMMAND_LOG=str(self.log), FAIL_COMMAND=fail, GOFLAGS='')
        result = subprocess.run(['bash', str(self.root / 'tools/check-regressions.sh'), suite],
                                cwd='/', env=env, capture_output=True, text=True)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def test_flutter_builds_native_library_before_full_suite(self):
        result, calls = self.run_suite('flutter')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in calls],
                         ['flutter', 'cargo', 'cargo', 'flutter', 'flutter', 'python3'])
        self.assertEqual(calls[0][1], ['pub', 'get', '--enforce-lockfile'])
        self.assertIn('--locked', calls[1][1])
        self.assertIn('--release', calls[2][1])
        self.assertEqual(calls[4][1], ['test', '--no-pub', '--concurrency=1', '--reporter', 'expanded'])
        self.assertTrue(all(call[2] == str(self.root) for call in calls))

    def test_core_includes_race_vet_and_tagged_tests(self):
        result, calls = self.run_suite('core')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 4)
        self.assertTrue(all(call[0] == 'go' and call[2] == str(self.root / 'core') for call in calls))
        self.assertIn('-race', calls[1][1])
        self.assertEqual(calls[2][1], ['vet', './...'])
        self.assertIn('-tags=with_gvisor', calls[3][1])
        self.assertTrue(all(call[3] == '-mod=readonly' and call[4] == '1' for call in calls))

    def test_failure_stops_remaining_checks(self):
        for suite, tool in [('flutter', 'cargo'), ('core', 'go')]:
            with self.subTest(suite=suite):
                self.log.unlink(missing_ok=True)
                result, calls = self.run_suite(suite, fail=tool)
                self.assertEqual(result.returncode, 17)
                self.assertEqual(calls[-1][0], tool)
                self.assertEqual(len(calls), 2 if suite == 'flutter' else 1)

    def test_all_runs_both_suites(self):
        result, calls = self.run_suite('all')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 10)
        self.assertEqual(calls[-1][0], 'go')

    def test_unknown_suite_fails_before_any_tool(self):
        result, calls = self.run_suite('release')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(calls, [])
        self.assertIn('Usage:', result.stderr)


if __name__ == '__main__':
    unittest.main()
