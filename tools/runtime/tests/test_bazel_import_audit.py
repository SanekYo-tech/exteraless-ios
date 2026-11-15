from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from check_bazel_imports import audit


class BazelImportAuditTests(unittest.TestCase):
    def test_recursive_glob_and_test_ownership_are_distinct(self):
        with tempfile.TemporaryDirectory(prefix='bazel-import-audit-') as temporary:
            root = Path(temporary)
            package = root / 'submodules/ActualPackage'
            (package / 'Sources/Nested').mkdir(parents=True)
            (package / 'Tests').mkdir()
            (package / 'BUILD').write_text('''
swift_library(name = "RealModule", srcs = glob(["Sources/**/*.swift"]),
              deps = ["//third-party/exteraless:ExteralessCore"])
swift_library(name = "RealTests", testonly = True, srcs = glob(["Tests/**/*.swift"]), deps = [])
''')
            for name in ('Sources/File.swift', 'Sources/Nested/File.swift', 'Tests/Test.swift'):
                (package / name).write_text('import ExteralessCore\n')
            (package / 'Tests/Test.swift').write_text('@testable import ExteralessCore\n')
            report = audit(root, ['ExteralessCore'])
            self.assertEqual(report['checked_imports'], 3)
            self.assertEqual([item['target'] for item in report['missing']], ['RealTests'])
            self.assertEqual(report['unresolved_ownership'], [])

    def test_excluded_source_is_not_assigned_to_an_unrelated_rule(self):
        with tempfile.TemporaryDirectory(prefix='bazel-import-exclusion-') as temporary:
            root = Path(temporary)
            (root / 'Sources').mkdir()
            (root / 'BUILD').write_text('''
swift_library(name = "DifferentName", srcs = glob(["Sources/**"], exclude = ["Sources/Omitted.swift"]), deps = [])
''')
            (root / 'Sources/Omitted.swift').write_text('import ExteralessCore\n')
            report = audit(root, ['ExteralessCore'])
            self.assertEqual(report['missing'], [])
            self.assertEqual(len(report['unresolved_ownership']), 1)


if __name__ == '__main__':
    unittest.main()
