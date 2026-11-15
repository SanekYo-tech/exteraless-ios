"""Compiler argument coverage and immutable receipts; no Swift process runs."""

from contextlib import nullcontext
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
import check_component_inputs as checker


class ComponentCompilerInputTests(unittest.TestCase):
    def test_added_tl_compiler_source_is_also_required_by_preflight(self):
        load = checker.module_at
        with load('tl_compiler_input_test', ROOT / checker.TL_FIXTURE_RUNNER) as runner:
            # This is a declaration-only path; no production Swift file is created.
            future = runner.NATIVE / 'FutureFixtureCompilerInput.swift'
            commands = []
            def run(command, timeout):
                commands.append((command, timeout))
                return 0
            def module_at(name, path):
                return nullcontext(runner) if path == ROOT / checker.TL_FIXTURE_RUNNER else load(name, path)
            with (patch.object(runner, 'SOURCE_NAMES', (*runner.SOURCE_NAMES, future)),
                  patch.object(runner.shutil, 'which', return_value='fixture-swiftc'),
                  patch.object(runner, 'run_bounded', side_effect=run),
                  patch.object(checker, 'module_at', side_effect=module_at),
                  patch('builtins.print')):
                required = checker.fixture_compiler_inputs()[checker.TL_FIXTURE_RUNNER]
                self.assertEqual(runner.main(), 0)
            compiler, compile_budget = commands[0]
            actual = [Path(value) for value in compiler if str(value).endswith('.swift')]
            self.assertEqual(actual, required)
            self.assertIn(future, required)
            self.assertTrue({'TLEnqueueCommit.swift', 'TLTransformCodec.swift', 'TLUpdatePolicy.swift',
                             'PluginHookIngress.swift'} <= {path.name for path in required})
            self.assertEqual(compile_budget, 120)
            self.assertEqual(commands[1][1], 28.5)
            self.assertEqual(len(commands), 2)

    def test_existing_receipt_cannot_be_relabelled_as_a_new_success(self):
        with tempfile.TemporaryDirectory(prefix='component-receipt-test-') as directory:
            receipt = Path(directory) / 'old-inputs.json'
            original = b'{"status":"inputs-covered","scope":"old incomplete input set"}\n'
            receipt.write_bytes(original)
            with (patch.object(sys, 'argv', ['check_component_inputs.py', '--output', str(receipt)]),
                  patch.object(sys, 'stderr', io.StringIO()),
                  patch.object(checker, 'inventory') as inventory):
                with self.assertRaises(SystemExit) as error:
                    checker.main()
            self.assertEqual(error.exception.code, 2)
            inventory.assert_not_called()
            self.assertEqual(receipt.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
