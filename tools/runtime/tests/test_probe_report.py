import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from validate_runtime import completed_report


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


if __name__ == '__main__':
    unittest.main()
