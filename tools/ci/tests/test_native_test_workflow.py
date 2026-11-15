"""New declaration/command/watchdog checks only; no Bazel, Xcode or simulator runs."""

import argparse
import importlib.util
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
sys.path.insert(0, str(ROOT / 'telegram-ios/build-system/Make'))
from native_test_plan import build_plan
from run_native_integration_tests import LogicClock, select_runtime

with patch.dict(sys.modules, {'TartBuild': types.ModuleType('TartBuild')}):
    spec = importlib.util.spec_from_file_location('native_test_make', ROOT / 'telegram-ios/build-system/Make/Make.py')
    make = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(make)


class NativeTestWorkflowChecks(unittest.TestCase):
    def command_line(self):
        with patch.object(make, 'BuildEnvironment'), patch.object(make, 'prepare_client_sources', return_value={}):
            line = make.BazelCommandLine('/fake/bazel', False, False, '/owned/bazel-user-root')
        line.build_environment.bazel_path = '/fake/bazel'
        line.build_environment.app_version = '13.1.1'
        line.set_configuration('debug_sim_arm64')
        line.set_unsigned()
        line.set_build_number('1')
        line.add_cache_dir('/cache')
        return line

    def test_make_unsigned_compilation_and_run_only_have_identical_platform_and_cache(self):
        parser = argparse.ArgumentParser()
        make.add_test_arguments(parser)
        args = parser.parse_args(['--configurationPath', 'fixture.json', '--unsigned', '--runOnly',
                                  '--target', '//Tests/Exteraless:NativeUIContractsTests'])
        self.assertTrue(args.unsigned)
        self.assertTrue(args.runOnly)
        line = self.command_line()
        target = args.target
        build = line.get_test_arguments(target, build_only=True)
        run = line.get_test_arguments(target, run_only=True, test_filter='NativeUIContractsTests',
                                      test_timeout=270, streamed=True)
        for value in ('--//Telegram:disableProvisioningProfiles', '--features=exteraless_unsigned_compilation',
                      '--features=disable_legacy_signing', '--ios_multi_cpus=sim_arm64', '--disk_cache=/cache'):
            self.assertIn(value, build)
            self.assertIn(value, run)
        self.assertIn('--check_up_to_date', run)
        self.assertIn('--nocheck_tests_up_to_date', run)
        self.assertIn('--cache_test_results=no', run)
        self.assertNotIn('--nobuild', run)
        self.assertNotIn('--check_up_to_date', build)
        query = line.get_unsigned_test_preflight_arguments([target])
        self.assertIn('deps(set(//Telegram:Telegram ' + target + '))', query)
        with self.assertRaisesRegex(ValueError, 'focused'):
            line.get_test_arguments('Tests/AllTests')

    def test_declaration_map_owns_every_required_regression_once(self):
        plan, _ = build_plan(ROOT / 'telegram-ios', source_checkout=True)
        selected = {case['source']: target['label'] for target in plan['targets'] for case in target['classes']}
        for source, label in plan['contract']['required_sources'].items():
            self.assertEqual(selected[source], label)
        self.assertEqual(sum(target['label'] == '//submodules/TelegramUI:ExteralessAINativeTests'
                             for target in plan['targets']), 1)
        self.assertFalse(any('AllTests' in target['label'] for target in plan['targets']))

    def clock(self):
        contract = {'preparation_seconds': 180, 'logic_seconds': 30, 'finalization_seconds': 60}
        return LogicClock({'class': 'NativeCase', 'methods': ['testOne']}, contract, 0)

    def test_thirty_second_clock_starts_at_native_logic_not_runner_startup(self):
        clock = self.clock()
        self.assertEqual(clock.deadline(), (180, 'runner preparation'))
        clock.observe("Test Suite 'Selected tests' started at fixture", 120)
        self.assertEqual(clock.deadline(), (150, 'XCTest logic'))
        clock.observe("Test Case '-[Module.NativeCase testOne]' started.", 121)
        clock.observe("Test Case '-[Module.NativeCase testOne]' passed (0.01 seconds).", 122)
        clock.observe("Test Suite 'NativeCase' passed at fixture", 123)
        self.assertEqual(clock.deadline(), (183, 'runner finalization'))
        self.assertEqual(clock.finish()['logic_seconds'], 3)

    def test_zero_partial_skipped_and_over_budget_native_results_cannot_pass(self):
        with self.assertRaisesRegex(ValueError, 'Missing/partial'):
            self.clock().finish()
        for state in ('skipped', 'failed'):
            clock = self.clock()
            clock.observe("Test Suite 'NativeCase' started at fixture", 1)
            clock.observe("Test Case '-[Module.NativeCase testOne]' started.", 2)
            clock.observe("Test Case '-[Module.NativeCase testOne]' " + state, 3)
            clock.observe("Test Suite 'NativeCase' passed at fixture", 4)
            with self.assertRaises(ValueError):
                clock.finish()
        clock = self.clock()
        clock.observe("Test Suite 'NativeCase' started at fixture", 1)
        clock.observe("Test Case '-[Module.NativeCase testOne]' started.", 2)
        clock.observe("Test Case '-[Module.NativeCase testOne]' passed.", 3)
        clock.observe("Test Suite 'NativeCase' passed at fixture", 32)
        with self.assertRaisesRegex(ValueError, '30-second'):
            clock.finish()

    def test_iOS_27_runtime_is_required_instead_of_a_component_sdk_fallback(self):
        types = [{'name': 'iPhone 17', 'identifier': 'device.iphone17'}]
        old = {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-5', 'version': '26.5', 'isAvailable': True}
        current = {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', 'version': '27.0', 'isAvailable': True}
        contract = {'device': 'iPhone 17', 'os_version': '27.0'}
        with self.assertRaisesRegex(ValueError, 'iOS 27.0'):
            select_runtime(types, [old], contract)
        self.assertEqual(select_runtime(types, [old, current], contract), ('device.iphone17', current['identifier']))


if __name__ == '__main__':
    unittest.main()
