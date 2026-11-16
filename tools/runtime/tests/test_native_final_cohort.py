"""Final cohort rejection/compile-input contracts; no native success is simulated."""

import ast
import copy
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
import check_swift_plugin_embedding as embedding
from check_component_inputs import fixture_compiler_inputs
from fixtures import elyx_developer_probe_driver as developer
from sdk_followup_inputs import NATIVE_FILES_TEST, NATIVE_INGRESS_TEST, ingress_native_sources
from verify_native_sdk_cohort import CHILDREN, validate_summary


class FinalNativeCohortTests(unittest.TestCase):
    def test_four_child_or_missing_last_success_cannot_be_relabelled_complete(self):
        summary = {'ok': True, 'phase': 'complete', 'native_children': 5,
                   'tl_phase2': True, 'hns_remediation': True, 'archive_lifecycle': True, 'elyx_developer': True,
                   'tl_report': CHILDREN[1][1], 'hns_report': CHILDREN[2][1],
                   'archive_report': CHILDREN[3][1], 'elyx_report': CHILDREN[4][1]}
        validate_summary(summary)  # Summary shape only, not verify()/native acceptance.
        for key, value in (('native_children', 4), ('elyx_developer', False), ('elyx_developer', 1),
                           ('archive_lifecycle', False), ('hns_remediation', False), ('tl_phase2', False),
                           ('phase', 'elyx-developer'), ('elyx_report', CHILDREN[3][1])):
            bad = copy.deepcopy(summary); bad[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                validate_summary(bad)

    def test_source_and_actual_staged_helper_must_survive_the_whole_five_child_seal(self):
        with tempfile.TemporaryDirectory(prefix='five-child-inputs-') as temporary:
            root = Path(temporary)
            paths = [root / 'source.py', root / 'staged.py', root / 'manifest.json']
            for path in paths: path.write_bytes(b'owned source input\n')
            hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
            embedding.validate_cohort_inputs(hashes)
            for path in paths:
                path.write_bytes(b'changed\n')
                with self.subTest(path=path.name), self.assertRaisesRegex(RuntimeError, 'five-child cohort'):
                    embedding.validate_cohort_inputs(hashes)
                path.write_bytes(b'owned source input\n')
        with self.assertRaisesRegex(RuntimeError, 'Missing five-child'):
            embedding.validate_cohort_inputs({})

    def test_native_selectors_compile_current_host_roots_and_keep_120_30_bounds(self):
        inputs = fixture_compiler_inputs()
        required = {ROOT / 'swift/PluginHost/Sources/PluginHost' / name for name in (
            'PluginElyxDeveloperReadiness.swift', 'PluginElyxDeveloperService.swift')}
        self.assertTrue(required <= set(inputs[NATIVE_FILES_TEST]))
        self.assertTrue(required <= set(inputs[NATIVE_INGRESS_TEST]))
        self.assertTrue(set(ingress_native_sources()) <= set(inputs[NATIVE_INGRESS_TEST]))
        self.assertTrue({ROOT / 'swift/PluginHost/Tests/PluginHostTests' / name for name in (
            'PluginElyxDeveloperFilesTests.swift', 'PluginElyxDeveloperActivationTests.swift',
            'PluginElyxDeveloperTests.swift')} <= set(inputs[NATIVE_FILES_TEST]))
        for name in (NATIVE_FILES_TEST, NATIVE_INGRESS_TEST):
            tree = ast.parse((ROOT / name).read_text(encoding='utf-8'))
            calls = sorted((node for node in ast.walk(tree) if isinstance(node, ast.Call)
                            and isinstance(node.func, ast.Attribute) and node.func.attr == 'run_bounded'),
                           key=lambda node: node.lineno)
            self.assertEqual([ast.literal_eval(next(k.value for k in node.keywords if k.arg == 'timeout'))
                              for node in calls], [120, 30])
        source_inputs = developer.source_inputs(ROOT / 'python')
        self.assertIn(ROOT / 'python/exteraless_runtime/_elyx_readiness.py', source_inputs)
        self.assertTrue({developer.SWIFT_PROBE, developer.HELPER, developer.EMITTER, Path(developer.__file__).resolve()}
                        <= set(source_inputs))

    def test_fifth_reader_rejects_absent_readiness_or_outstanding_fd_tickets(self):
        report = dict.fromkeys(developer.REQUIRED_CHECKS, True)
        report.update(boundary=developer.BOUNDARY, initializations=1, finalizations=1,
                      unexpected_effects=[], source_receipts=0, stages=0, read_tickets=0,
                      capabilities=0, file_authorities=0)
        absent = dict(report, actual_readiness=False)
        with self.assertRaisesRegex(RuntimeError, 'activation/publication'):
            developer.validate_report(absent, ROOT / 'python', ROOT / 'build/unexecuted')
        for name in ('source_receipts', 'stages', 'read_tickets', 'capabilities', 'file_authorities'):
            with self.subTest(counter=name), self.assertRaisesRegex(RuntimeError, 'custody'):
                developer.validate_report(dict(report, **{name: 1}), ROOT / 'python', ROOT / 'build/unexecuted')


if __name__ == '__main__':
    unittest.main()
