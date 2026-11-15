import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from validate_runtime import completed_report, validate_bridge_report


class ProbeReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='runtime-report-')
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'runtime-smoke.json'

    def test_missing_report_is_not_success(self):
        with self.assertRaisesRegex(RuntimeError, 'no completed report'):
            completed_report(self.path, timeout=0)

    def test_success_before_native_teardown_is_not_complete(self):
        self.path.write_text(json.dumps({'ok': True, 'phase': 'finalizing'}))
        with self.assertRaisesRegex(RuntimeError, 'no completed report'):
            completed_report(self.path, timeout=0)

    def test_completed_report_preserves_native_failure(self):
        result = {'ok': False, 'native_completed': True, 'native_exit_status': 8, 'phase': 'stdlib'}
        self.path.write_text(json.dumps(result))
        self.assertEqual(completed_report(self.path, timeout=0), result)

    def bridge_report(self):
        # The published P2 native_report, independent of the validator's required
        # field list: removing a legacy check must break these regression tests.
        return json.loads((Path(__file__).parent / 'fixtures/native-bridge-p2.json').read_text(encoding='utf-8'))

    def test_owner_epoch_gate_keeps_baseline_and_requires_exact_new_counts(self):
        report = self.bridge_report()
        self.assertIs(validate_bridge_report(report), report)
        for changed in ({'callbacks': 169}, {'callbacks': 213}, {'baseline_callbacks': 168}, {'owner_bound_callbacks': 35},
                        {'callbacks': '219'}, {'native_workers': 1}, {'previous_suite_callbacks': 212},
                        {'bulk_clear_callbacks': 5}, {'terminal_admission_checks': 26},
                        {'terminal_payloads_freed': 1}, {'probe': 'native-runtime'}):
            with self.subTest(changed=changed), self.assertRaisesRegex(RuntimeError, 'contract failed'):
                validate_bridge_report(dict(report, **changed))
        for key, value in report.items():
            if type(value) is int:
                for invalid in (None, str(value), float(value), True):
                    with self.subTest(key=key, invalid=invalid), self.assertRaisesRegex(RuntimeError, 'contract failed'):
                        validate_bridge_report(dict(report, **{key: invalid}))

    def test_owner_epoch_gate_rejects_a_missing_new_or_old_check(self):
        for key, value in self.bridge_report().items():
            if type(value) is not bool:
                continue
            report = self.bridge_report()
            del report[key]
            with self.subTest(key=key), self.assertRaisesRegex(RuntimeError, 'contract failed'):
                validate_bridge_report(report)
            for invalid in (False, 1, 'true'):
                with self.subTest(key=key, invalid=invalid), self.assertRaisesRegex(RuntimeError, 'contract failed'):
                    validate_bridge_report(dict(report, **{key: invalid}))

    def test_terminal_clear_accepts_only_the_two_documented_gc_timings(self):
        report = self.bridge_report()
        validate_bridge_report(dict(report, terminal_admission_rejected=2, terminal_admission_before_clear=0))
        for rejected, before in ((0, 2), (1, 0), (2, 1), (True, 1)):
            with self.subTest(rejected=rejected, before=before), self.assertRaisesRegex(RuntimeError, 'contract failed'):
                validate_bridge_report(dict(report, terminal_admission_rejected=rejected, terminal_admission_before_clear=before))


if __name__ == '__main__':
    unittest.main()
