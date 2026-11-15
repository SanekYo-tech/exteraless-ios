"""Checks only the new fixture wiring/deadlines; no Swift compiler is launched."""

import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
DRIVER = ROOT / 'telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/run_remediation_fixture.py'
spec = importlib.util.spec_from_file_location('hns_fixture_driver', DRIVER)
driver = importlib.util.module_from_spec(spec)
with patch.object(sys, 'path', [str(DRIVER.parent), *sys.path]):
    spec.loader.exec_module(driver)


class RemediationFixtureDriverTests(unittest.TestCase):
    def test_shipping_input_inventory_includes_authority_budget_and_schema_helpers(self):
        inventory = driver.source_inventory()
        prefix = 'telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/'
        for name in ('PluginUISettingsActionGate.swift', 'PluginUISettingsActionInvocation.swift',
                     'PluginUIRetainedEffect.swift', 'PluginUIUnprovenSchemaCache.swift',
                     'Tests/PluginUIRemediationFixture.swift'):
            self.assertIn(prefix + name, inventory)
        for name in driver.SOURCES:
            self.assertIsNone(re.search(r'^\s*(?:@preconcurrency\s+)?import UIKit\b',
                                        (driver.UI / name).read_text(encoding='utf-8'), re.M))
        self.assertIn('swift/PluginHost/Package.swift', inventory)
        self.assertIn('swift/ExteralessCore/Package.swift', inventory)

    def test_compile_failure_never_runs_a_cached_executable(self):
        with tempfile.TemporaryDirectory(prefix='hns-driver-') as directory:
            output = Path(directory)
            with patch.object(driver, 'bounded', side_effect=subprocess.CalledProcessError(1, ['swift', 'build'])) as run:
                with self.assertRaises(subprocess.CalledProcessError):
                    driver.run_fixture('swift', output, output / 'cache', 480, 30)
            self.assertEqual(run.call_count, 1)
            report = json.loads((output / 'remediation-report.json').read_text())
            self.assertIs(report['ok'], False)
            self.assertEqual(report['phase'], 'compile')
            self.assertEqual(report['scenarios'], 0)

    def test_slow_compile_leaves_a_fresh_thirty_second_execution_budget(self):
        with tempfile.TemporaryDirectory(prefix='hns-deadlines-') as directory:
            output = Path(directory)
            binary_dir = output / 'bin'
            binary_dir.mkdir()
            (binary_dir / ('Fixture.exe' if os.name == 'nt' else 'Fixture')).write_bytes(b'not executed')
            calls = []
            now = 0
            def run(command, *, deadline, environment, log):
                nonlocal now
                calls.append((command, deadline))
                if len(calls) == 2:
                    log.write(driver.COMPLETION + '\n')
                    now = 451
                else:
                    now = 450
            with (patch.object(driver, 'bounded', side_effect=run),
                  patch.object(driver.subprocess, 'check_output', return_value=str(binary_dir)),
                  patch('builtins.print'),
                  patch.object(driver.time, 'monotonic', side_effect=lambda: now)):
                report = driver.run_fixture('swift', output, output / 'cache', 480, 30)
            self.assertEqual(calls[0][1], 480)
            self.assertEqual(calls[1][1] - 450, 30)
            self.assertIn('--jobs', calls[0][0])
            self.assertEqual(report['scenarios'], 23)
            self.assertIs(report['uikit_executed'], False)
            self.assertIs(report['cpython_executed'], False)


if __name__ == '__main__':
    unittest.main()
