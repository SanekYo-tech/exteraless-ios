"""Small real-emitter and evidence-rejection checks; no native execution."""

import copy
import ast
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import textwrap
import re
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
import check_swift_plugin_embedding as embedding
from sdk_followup_inputs import DEVELOPER_NATIVE_TEST, developer_native_sources
from client_ui_control_frames import validate_control
from native_fd_evidence import IOS_FD_HELPER, validate_ios_fd_observations, verify_ios_fd_helper_bundle


class SDKFollowupToolingTests(unittest.TestCase):
    def test_applied_ui_fd_join_uses_complete_sources_and_post_cleanup_worker_capture(self):
        helper = (ROOT / IOS_FD_HELPER).read_bytes()
        self.assertEqual(helper, (ROOT / 'python/runtime/smoke/native_plugin_probe.py').read_bytes())
        def method(text):
            return ast.dump(next(node for node in ast.walk(ast.parse(text))
                if isinstance(node, ast.FunctionDef) and node.name == 'fd_family_probe'), include_attributes=False)
        self.assertEqual(method((ROOT / 'telegram-ios/Tests/ExteralessHarness/Fixtures/client_ui_fixture.plugin').read_text(encoding='utf-8')),
                         method((ROOT / 'python/runtime/smoke/plugins/native_wave_probe.plugin').read_text(encoding='utf-8')))
        swift = (ROOT / 'telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessNativeObservation.swift').read_text(encoding='utf-8')
        code = re.search(r'self.native.runScript\(reference, """\n(.*?)\n            """\)', swift, re.S)[1]
        code = textwrap.dedent(code).replace(r'\(helperPath)', '"fixture.py"').replace(r'\(reference.raw)', '2')
        tree = ast.parse(code)  # Syntax only; no synthetic sys.platform or FD execution.
        call = next(node for node in ast.walk(tree) if isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Attribute) and node.func.attr == '_probe_darwin_family_fds')
        capture = next(node for node in tree.body if isinstance(node, ast.Assign)
                       and any(isinstance(target, ast.Name) and target.id == '_fd_observation' for target in node.targets))
        self.assertGreater(capture.lineno, call.end_lineno)
        self.assertFalse(any(isinstance(node, ast.ExceptHandler) for node in ast.walk(tree)))
        self.assertIn('private let native = CPythonXCFrameworkEngine()', swift)
        self.assertIn('let result = try self.native.runScript(reference, source)', swift)
        runtime = (ROOT / 'telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessRuntime.swift').read_text(encoding='utf-8')
        self.assertIn('NativeBridgeBinding(services: self.host.bridge)', runtime)
        self.assertLess(runtime.index('try self.binding.install()'), runtime.index('try await self.host.start()'))
        self.assertIn('page: PluginSettingsPageExecution.current', runtime)
        ast.parse(helper)

    def test_bundled_fd_helper_rejects_truncation_or_another_source_hash(self):
        source = (ROOT / IOS_FD_HELPER).read_bytes()
        manifest = {'files': {IOS_FD_HELPER: hashlib.sha256(source).hexdigest()}}
        for payload in (source, source[:100], source + b'\n# stale\n'):
            data = io.BytesIO()
            with zipfile.ZipFile(data, 'w') as archive:
                archive.writestr('app/native_plugin_probe.py', payload)
            with zipfile.ZipFile(data) as archive:
                if payload == source:
                    self.assertEqual(verify_ios_fd_helper_bundle(archive, 'app', manifest), manifest['files'][IOS_FD_HELPER])
                else:
                    with self.assertRaisesRegex(ValueError, 'compiled source hash'):
                        verify_ios_fd_helper_bundle(archive, 'app', manifest)

    def test_ios_fd_gate_rejects_mac_flags_and_stale_helper_or_owner(self):
        epochs = ['00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002']
        manifest = {'files': {IOS_FD_HELPER: 'a' * 64}}
        engine = {'initializations': 1, 'finalizations': 1,
            'created': [1, 2, 3], 'destroyed': [1, 2, 3], 'fdProbeScriptCalls': 4,
            'fdPaths': [{'nativeReference': index + 2, 'ownerToken': owner, 'platform': 'ios',
                'bridgeBuiltin': True, 'helperSHA256': 'a' * 64,
                'checks': {'darwin_family_fd_paths': True, 'actual_ios_fd_paths': True}}
                for index, owner in enumerate(epochs)]}
        validate_ios_fd_observations(engine, epochs, manifest)
        for change in ('mac-platform', 'mac-flag', 'old-helper', 'old-owner', 'reused-interpreter', 'missing-lifetime',
                       'before-finalization', 'classification-error'):
            bad = copy.deepcopy(engine)
            row = bad['fdPaths'][0]
            if change == 'mac-platform': row['platform'] = 'darwin'
            elif change == 'mac-flag': row['checks'].pop('actual_ios_fd_paths')
            elif change == 'old-helper': row['helperSHA256'] = 'b' * 64
            elif change == 'old-owner': row['ownerToken'] = epochs[1]
            elif change == 'reused-interpreter': row['nativeReference'] = 3
            elif change == 'missing-lifetime': bad['fdPaths'].pop()
            elif change == 'before-finalization': bad['finalizations'] = 0
            else: row['error'] = 'Host.fd_probe_classification: unknown service'
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_ios_fd_observations(bad, epochs, manifest)

    def test_first_sdk_child_requires_the_real_darwin_family_fd_observation(self):
        checks = dict.fromkeys(embedding.REQUIRED_SDK_OBSERVATIONS, True)
        embedding.validate_sdk_observations(checks)
        for value in (None, False, "true", 1):
            invalid = dict(checks, darwin_family_fd_paths=value)
            invalid['actual_ios_fd_paths'] = True
            with self.subTest(value=value), self.assertRaisesRegex(RuntimeError, 'darwin_family_fd_paths'):
                embedding.validate_sdk_observations(invalid)
        for old in set(checks) - {'darwin_family_fd_paths'}:
            invalid = dict(checks); invalid.pop(old)
            with self.subTest(old=old), self.assertRaisesRegex(RuntimeError, old):
                embedding.validate_sdk_observations(invalid)

    def test_emitter_has_changed_same_name_wheel_and_format_specific_ids(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / 'input'
            hashes = embedding.emit_archive_fixtures(target)
            self.assertEqual(len(hashes), 5)
            with zipfile.ZipFile(target / 'owned.elyx') as first, zipfile.ZipFile(target / 'owned-next.elyx') as second:
                name = 'wheels/ownlib-1.0-py3-none-any.whl'
                self.assertNotEqual(first.read(name), second.read(name))
                self.assertNotEqual(first.read('entry/helpers.py'), second.read('entry/helpers.py'))
                self.assertEqual(json.loads(first.read('meta/info.json'))['id'], '7_archive')
            with zipfile.ZipFile(target / 'literal.eaf') as literal:
                self.assertIn(b"'_archive'", literal.read('meta/info.py'))
            with zipfile.ZipFile(target / 'requires.elyx') as required:
                self.assertIn('neighbour(2)', json.loads(required.read('meta/info.json'))['requires'])

    def test_archive_input_inventory_rejects_stale_fd_path_adapter(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for relative in embedding.ARCHIVE_PYTHON_INPUTS:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / 'python' / relative, path)
            self.assertEqual(len(embedding.archive_source_inputs(root)), len(embedding.ARCHIVE_PYTHON_INPUTS))
            (root / 'exteraless_runtime/_audit_paths.py').write_text('# stale helper\n')
            with self.assertRaisesRegex(RuntimeError, '_audit_paths'):
                embedding.archive_source_inputs(root)

    def test_listener_inventory_matches_real_compile_arguments_and_phase_budgets(self):
        spec = importlib.util.spec_from_file_location('owned_developer_test', ROOT / DEVELOPER_NATIVE_TEST)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        commands = []
        logs = []
        def run(command, timeout, *, log):
            commands.append((command, timeout))
            logs.append(Path(log))
            return 'SDK_DEVELOPER_NATIVE_OK\n'
        with tempfile.TemporaryDirectory() as folder, patch.object(module.shutil, 'which', return_value='fixture-swiftc'), \
                patch.object(module, 'run_bounded', side_effect=run), patch('sys.stdout', io.StringIO()):
            module.worker(folder)
        actual = [Path(value) for value in commands[0][0] if str(value).endswith('.swift')]
        self.assertEqual(actual, developer_native_sources())
        self.assertEqual([timeout for _, timeout in commands], [120, 10])
        self.assertEqual(logs, [Path(folder) / 'evidence' / name for name in ('compile.log', 'execute.log')])

    def test_configured_control_cannot_pass_with_missing_or_clipped_native_label(self):
        value = {'id': 'exteraless.inlineMath.insert', 'inWindow': True, 'title': '= 3  ·  Insert', 'label': '= 3  ·  Insert',
                 'buttonFrame': [0, 0, 300, 44], 'labelFrame': [14, 10, 250, 20],
                 'insets': [0, 14, 0, 14], 'font': 'fixture-font', 'pointSize': 15}
        validate_control(value, value['id'], 14, 14)
        for key, changed in (('inWindow', False), ('labelFrame', [14, 10, 400, 20]), ('insets', [0, 0, 0, 0])):
            bad = dict(value, **{key: changed})
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_control(bad, value['id'], 14, 14)

    def test_archive_pass_flag_does_not_replace_native_lifetimes(self):
        report = dict.fromkeys(embedding.REQUIRED_ARCHIVE_CHECKS, True)
        report['boundary'] = 'Real Host/C/CPython Elyx SDK; local generated ZIP/wheel fixtures; no UIKit/network'
        report.update(initializations=0, finalizations=0, traces=[])
        with self.assertRaisesRegex(RuntimeError, 'process lifetime'):
            embedding.validate_archive_report(report, ROOT / 'python', ROOT / 'build/unused-fixture')


if __name__ == '__main__':
    unittest.main()
