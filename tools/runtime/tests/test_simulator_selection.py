import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from validate_runtime import main, select_simulator


PREFIX = 'com.apple.CoreSimulator.SimRuntime.iOS-'


def phone(name='iPhone 17', **overrides):
    return dict(name=name, udid=name, deviceTypeIdentifier='com.apple.CoreSimulator.SimDeviceType.' + name,
                **(dict(isAvailable=True, state='Shutdown') | overrides))


class SimulatorSelectionTests(unittest.TestCase):
    def test_runner_inventory_avoids_duo_on_generic_runtime(self):
        # Run 43605905475: generic 27.1 contains only Duo, without a hardware suffix.
        models = ('iPhone 18 Pro', 'iPhone 18 Pro Max', 'iPhone 17e', 'iPhone Air', 'iPhone 17')
        devices = {
            PREFIX + '27-0': [phone(name) for name in models],
            PREFIX + '27-1': [phone('iPhone Duo')],
            PREFIX + '27-2': [phone(name) for name in models],
            PREFIX + '27-2-iPhone19-4': [phone('iPhone Duo')],
        }
        runtime, device = select_simulator(devices, '27.1')
        self.assertEqual(runtime, PREFIX + '27-0')
        self.assertEqual(device['name'], 'iPhone 17')

    def test_missing_requested_device_fails_instead_of_falling_back(self):
        devices = {
            PREFIX + '27-0': [phone('iPhone 17e'), phone('iPhone 18 Pro'), phone('iPhone Air')],
            PREFIX + '27-1': [phone('iPhone Duo')],
        }
        for name in ('iPhone 17', 'iPhone 16'):
            with self.subTest(name=name):
                with self.assertRaises(RuntimeError) as error:
                    select_simulator(devices, '27.1', simulator_device=name)
                message = str(error.exception)
                self.assertIn(repr(name), message)
                self.assertIn('SDK 27.1', message)
                for runtime in devices:
                    self.assertIn(runtime, message)

    def test_explicit_alternative_model_is_selected(self):
        runtime, device = select_simulator({
            PREFIX + '27-0': [phone(), phone('iPhone 18 Pro')],
            PREFIX + '27-1': [phone(), phone('iPhone 18 Pro')],
        }, '27.1', simulator_device='iPhone 18 Pro')
        self.assertEqual(runtime, PREFIX + '27-1')
        self.assertEqual(device['name'], 'iPhone 18 Pro')

    def test_cli_device_reaches_simulator_clone_selection(self):
        devices = {PREFIX + '27-0': [phone(), phone('iPhone 18 Pro')]}
        for options, expected in (([], 'iPhone 17'), (['--simulator-device', 'iPhone 18 Pro'], 'iPhone 18 Pro')):
            with self.subTest(options=options), tempfile.TemporaryDirectory(prefix='runtime-selection-') as folder:
                root = Path(folder)
                output = root / 'output'
                argv = ['validate_runtime.py', '--support', str(root / 'support'), '--output', str(output), *options]
                # Exercise CLI -> probe -> selector, stopping at the clone command.
                with (patch.object(sys, 'argv', argv), patch.object(sys, 'platform', 'darwin'),
                      patch('validate_runtime.build_target', return_value=(root / 'Probe.app', root / 'bridge.a', {})),
                      patch('validate_runtime.run', side_effect=[
                          Mock(stdout='27.1'), Mock(stdout=json.dumps({'devices': devices})),
                          RuntimeError('clone boundary reached'),
                      ]) as run):
                    with self.assertRaisesRegex(RuntimeError, 'clone boundary reached'):
                        main()
                run.assert_called_with('xcrun', 'simctl', 'clone', expected, 'Exteraless Python Probe', capture=True)
                inventory = json.loads((output / 'simulator-inventory.json').read_text(encoding='utf-8'))
                self.assertEqual(inventory['requested_device'], expected)

    def test_matching_generic_runtime_is_preferred(self):
        runtime, _ = select_simulator({PREFIX + '27-0': [phone()], PREFIX + '27-1': [phone()]}, '27.1.0')
        self.assertEqual(runtime, PREFIX + '27-1')

    def test_versions_are_compared_numerically(self):
        runtime, _ = select_simulator({PREFIX + '27-2': [phone()], PREFIX + '27-10': [phone()]}, '27.10')
        self.assertEqual(runtime, PREFIX + '27-10')

    def test_unavailable_or_booted_templates_are_not_cloned(self):
        runtime, _ = select_simulator({
            PREFIX + '27-1': [phone(state='Booted'), phone(isAvailable=False)],
            PREFIX + '27-0': [phone()],
        }, '27.1')
        self.assertEqual(runtime, PREFIX + '27-0')

    def test_incompatible_inventory_fails_instead_of_using_future_runtime(self):
        with self.assertRaisesRegex(RuntimeError, 'generic iOS runtime compatible with SDK 27.1'):
            select_simulator({PREFIX + '27-2': [phone()], PREFIX + '27-1-iPhone19-4': [phone()]}, '27.1')

    def test_invalid_sdk_version_fails(self):
        with self.assertRaisesRegex(ValueError, 'SDK version'):
            select_simulator({PREFIX + '27-0': [phone()]}, 'unknown')


if __name__ == '__main__':
    unittest.main()
