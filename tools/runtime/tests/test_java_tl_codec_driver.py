"""Control-plane failure paths for the added Foundation codec execution gate."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
import check_java_tl_codec as driver


class JavaTLCodecDriverTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='java-tl-codec-driver-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / 'output'
        self.output.mkdir()
        schema = self.root / 'python/runtime/tl-schema.json'
        schema.parent.mkdir(parents=True)
        schema.write_text(json.dumps({'sourceSHA256': 'fixture', 'nativeLayoutHash': '1'}))

    def test_skip_zero_duplicate_or_wrong_named_pytest_results_are_rejected(self):
        path = self.output / 'pytest.xml'
        name = driver.TEST_NAME
        for content in ('', f'<testcase name="{name}"><skipped /></testcase>',
                        f'<testcase name="{name}"><failure /></testcase>',
                        '<testcase name="test_other" />', f'<testcase name="{name}" />' * 2):
            path.write_text('<testsuites><testsuite>' + content + '</testsuite></testsuites>')
            with self.assertRaises(ValueError):
                driver.validate_pytest_result(path)
        path.write_text(f'<testsuites><testsuite><testcase name="{name}" /></testsuite></testsuites>')
        self.assertEqual(driver.validate_pytest_result(path)['codec_cases'], 7)

    def test_failed_compile_never_launches_pytest_or_admits_an_old_executable(self):
        with (patch.object(driver, 'source_fingerprint', return_value={'source': 'old'}),
              patch.object(driver.subprocess, 'check_output', side_effect=['Xcode 26.6\nBuild fixture', '/SDK', 'Swift']),
              patch.object(driver, 'run_phase', side_effect=subprocess.CalledProcessError(1, ['swiftc'])) as phase):
            with self.assertRaises(subprocess.CalledProcessError):
                driver.check_codec(self.root, self.output)
        self.assertEqual(phase.call_count, 1)
        report = json.loads((self.output / 'java-tl-codec.json').read_text())
        self.assertIs(report['ok'], False)
        self.assertIs(report['native_execution_verified'], False)
        self.assertEqual(report['phase'], 'build')

    def test_changed_compile_inputs_block_execution_before_pytest(self):
        with (patch.object(driver, 'source_fingerprint', side_effect=[{'source': 'old'}, {'source': 'new'}]),
              patch.object(driver.subprocess, 'check_output', side_effect=['Xcode 26.6', '/SDK', 'Swift']),
              patch.object(driver, 'run_phase', return_value=1.0) as phase):
            with self.assertRaisesRegex(ValueError, 'changed during compilation'):
                driver.check_codec(self.root, self.output)
        self.assertEqual(phase.call_count, 1)

    def test_only_the_named_codec_test_runs_with_separate_compile_and_execution_budgets(self):
        calls = []
        def run(command, output, phase, timeout, **options):
            calls.append((phase, timeout, command, options))
            if phase == 'build':
                (output / 'java-values-codec').write_bytes(b'compiled fixture')
            else:
                (output / 'pytest.xml').write_text(f'<testsuite><testcase name="{driver.TEST_NAME}" /></testsuite>')
            return 0.01
        with (patch.object(driver, 'source_fingerprint', return_value={'source': 'frozen'}),
              patch.object(driver.subprocess, 'check_output', side_effect=['Xcode 26.6', '/SDK', 'Swift']),
              patch.object(driver, 'run_phase', side_effect=run)):
            report = driver.check_codec(self.root, self.output)
        self.assertEqual([(phase, timeout) for phase, timeout, _, _ in calls], [('build', 240), ('test', 30)])
        command, options = calls[1][2:]
        self.assertIn(driver.TEST_SOURCE + '::' + driver.TEST_NAME, command)
        self.assertEqual(options['env']['EXTERALESS_JAVA_TL_CODEC'], str(self.output / 'java-values-codec'))
        self.assertEqual(options['env']['PYTEST_DISABLE_PLUGIN_AUTOLOAD'], '1')
        self.assertEqual(options['env']['PYTEST_ADDOPTS'], '')
        self.assertIs(report['native_execution_verified'], True)


if __name__ == '__main__':
    unittest.main()
