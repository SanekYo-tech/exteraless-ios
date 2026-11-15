import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from check_swift_components import check_package, package_fingerprint, run_phase


class SwiftComponentTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='swift-component-driver-')
        self.addCleanup(temporary.cleanup)
        self.package = Path(temporary.name) / 'Example'
        self.output = Path(temporary.name) / 'output'
        self.output.mkdir()
        self.inputs = ('Package.swift', 'Sources/Example/Nested/Actor.swift',
                       'Sources/CShims/include/atomics.h', 'Sources/CShims/atomics.c',
                       'Tests/ExampleTests/LifecycleTests.swift')
        for name in self.inputs:
            path = self.package / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture', encoding='utf-8')

    def test_fingerprint_covers_nested_actor_tests_and_c_shims_but_not_build_outputs(self):
        build = self.package / '.build'
        build.mkdir()
        (build / 'generated.swift').write_text('old compiler output')
        first = package_fingerprint(self.package)
        self.assertEqual(set(first), set(self.inputs))
        (self.package / self.inputs[1]).write_text('new actor surface')
        self.assertNotEqual(first, package_fingerprint(self.package))

    def test_compile_failure_cannot_run_stale_cached_tests_or_publish_success(self):
        failure = subprocess.CalledProcessError(1, ['swift', 'build'])
        with (patch('check_swift_components.subprocess.check_output', return_value='Swift 6'),
              patch('check_swift_components.run_phase', side_effect=failure) as run):
            with self.assertRaises(subprocess.CalledProcessError):
                check_package(self.package, self.output)
        self.assertEqual(run.call_count, 1)
        report = json.loads((self.output / 'swift-component-tests.json').read_text())
        self.assertIs(report['ok'], False)
        self.assertEqual(report['phase'], 'build')

    def test_edit_during_compilation_rejects_the_snapshot_before_test_execution(self):
        def build(*_):
            (self.package / self.inputs[1]).write_text('changed during compilation')
            return 0.01

        with (patch('check_swift_components.subprocess.check_output', return_value='Swift 6'),
              patch('check_swift_components.run_phase', side_effect=build) as run):
            with self.assertRaisesRegex(ValueError, 'sources changed during build'):
                check_package(self.package, self.output)
        self.assertEqual(run.call_count, 1)
        self.assertIs(json.loads((self.output / 'swift-component-tests.json').read_text())['ok'], False)

    def test_deadline_kills_the_owned_test_process_group(self):
        process = Mock(pid=31415)
        process.wait.side_effect = [subprocess.TimeoutExpired(['swift', 'test'], 30), -9]
        with (patch('check_swift_components.subprocess.Popen', return_value=process) as popen,
              patch('check_swift_components.os.killpg', create=True) as killpg,
              patch('check_swift_components.signal.SIGKILL', 9, create=True)):
            with self.assertRaises(subprocess.TimeoutExpired):
                run_phase(['swift', 'test'], self.output, 'test', 30)
        self.assertTrue(popen.call_args.kwargs['start_new_session'])
        killpg.assert_called_once_with(31415, 9)
        self.assertEqual(process.wait.call_args.kwargs['timeout'], 5)


if __name__ == '__main__':
    unittest.main()
