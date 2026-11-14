from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from validate_runtime import select_simulator


PREFIX = 'com.apple.CoreSimulator.SimRuntime.iOS-'


def phone(name='iPhone 17', **overrides):
    return dict(name=name, udid=name, deviceTypeIdentifier='com.apple.CoreSimulator.SimDeviceType.' + name,
                **(dict(isAvailable=True, state='Shutdown') | overrides))


class SimulatorSelectionTests(unittest.TestCase):
    def test_runner_inventory_avoids_newer_hardware_specific_runtime(self):
        # The actual runner has no generic 27.1 runtime; 27.1 is Duo-only.
        devices = {
            PREFIX + '27-0': [phone('iPhone 18 Pro'), phone()],
            PREFIX + '27-1-iPhone19-4': [phone('iPhone Duo')],
            PREFIX + '27-2': [phone()],
            PREFIX + '27-2-iPhone19-4': [phone('iPhone Duo')],
        }
        runtime, device = select_simulator(devices, '27.1')
        self.assertEqual(runtime, PREFIX + '27-0')
        self.assertEqual(device['name'], 'iPhone 17')

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
        with self.assertRaisesRegex(RuntimeError, 'No generic iPhone runtime compatible'):
            select_simulator({PREFIX + '27-2': [phone()], PREFIX + '27-1-iPhone19-4': [phone('iPhone Duo')]}, '27.1')

    def test_invalid_sdk_version_fails(self):
        with self.assertRaisesRegex(ValueError, 'SDK version'):
            select_simulator({PREFIX + '27-0': [phone()]}, 'unknown')


if __name__ == '__main__':
    unittest.main()
