"""Actual redirected-process diagnostics and the failed Postbox visibility edge."""

import ast
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
import client_ui_harness_build as build


class BuildGraphDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        base = Path(os.environ['LOCALAPPDATA']) / 'Temp/opencode' if os.name == 'nt' else None
        self.temporary = tempfile.TemporaryDirectory(prefix='uikit-graph-test-', dir=base)
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def test_exact_harness_test_client_resolves_the_observed_postbox_edge(self):
        path = ROOT / 'telegram-ios/submodules/Postbox/BUILD'
        source = path.read_text(encoding='utf-8')
        self.assertEqual(build.postbox_visibility_errors(ROOT / 'telegram-ios'), [])
        groups = {}
        for node in ast.parse(source).body:
            if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call):
                attrs = {item.arg: item.value for item in node.value.keywords}
                if 'packages' in attrs:
                    groups[ast.literal_eval(attrs['name'])] = ast.literal_eval(attrs['packages'])
        self.assertIn('//Tests/ExteralessHarness', groups['test_clients'])
        self.assertNotIn('//Tests/ExteralessHarness', groups['clients'])
        broken = self.directory / 'submodules/Postbox/BUILD'
        broken.parent.mkdir(parents=True)
        broken.write_text(source.replace('        "//Tests/ExteralessHarness",\n', ''), encoding='utf-8')
        self.assertIn('Postbox must expose :test_clients', build.postbox_visibility_errors(self.directory)[0])

    def test_failed_aquery_style_redirect_surfaces_real_stderr_without_private_stdout(self):
        diagnostic = "ERROR: target '//submodules/Postbox:Postbox' is not visible from '//Tests/ExteralessHarness:ClientHarnessAccount'\n"
        private = 'PRIVATE_ACTION_GRAPH_SENTINEL'
        argv = [sys.executable, '-I', '-S', '-B', '-c',
                "import sys; print('" + private + "'); sys.stderr.write(" + repr(diagnostic) + "); sys.exit(1)"]
        with (self.directory / 'build.log').open('w', encoding='utf-8') as log, \
                (self.directory / 'private-actions.json').open('w', encoding='utf-8') as graph:
            with self.assertRaises(RuntimeError) as error:
                build.logged_build_command(argv, phase='aquery', output=self.directory, log=log,
                                           stdout=graph, stderr=log, timeout=3, cwd=self.directory)
        self.assertIn(diagnostic.strip(), str(error.exception))
        report = json.loads((self.directory / 'build-failure.json').read_text(encoding='utf-8'))
        self.assertEqual(report['status'], 'build-command-failed')
        self.assertEqual(report['phase'], 'aquery')
        self.assertEqual(report['targets'], ['//Telegram:Telegram', '//Telegram:ClientUIHarness'])
        self.assertFalse(report['buildVerified'])
        self.assertFalse(report['uikitExecuted'])
        tail = report['diagnostic']
        data = (self.directory / 'build.log').read_bytes()[tail['byteOffset']:tail['byteOffset'] + tail['bytes']]
        self.assertEqual(tail['sha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual(tail['text'], data.decode('utf-8'))
        # The command is itself logged, so the sentinel appears only in its
        # quoted argv. No output line from the private aquery stream is surfaced.
        self.assertNotIn('\n' + private + '\n', tail['text'])
        self.assertEqual((self.directory / 'private-actions.json').read_text(encoding='utf-8').strip(), private)
        self.assertFalse((self.directory / 'build-result.json').exists())

    def test_diagnostic_read_is_byte_bounded_and_preserves_exact_tail(self):
        path = self.directory / 'build.log'
        data = b'old progress\n' * 5000 + 'ERROR: visibility failure 雪\n'.encode('utf-8')
        path.write_bytes(data)
        result = build.diagnostic_tail(path)
        self.assertEqual(result['bytes'], build.DIAGNOSTIC_TAIL_BYTES)
        self.assertEqual(result['byteOffset'], len(data) - build.DIAGNOSTIC_TAIL_BYTES)
        self.assertEqual(result['sha256'], hashlib.sha256(data[-build.DIAGNOSTIC_TAIL_BYTES:]).hexdigest())
        self.assertTrue(result['text'].endswith('ERROR: visibility failure 雪\n'))


if __name__ == '__main__':
    unittest.main()
