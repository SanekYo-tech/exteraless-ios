"""Native packaging/admission checks without a compiler or executing plugins."""

import copy
import json
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from native_dependencies import (framework_name, install_extension, read_lock,
                                 stage_application_policy, validate_admission)


def macho(platform=2, dependency='@rpath/Python.framework/Python'):
    data = dependency.encode() + b'\0'
    length = (24 + len(data) + 7) & ~7
    load = struct.pack('<6I', 0xC, length, 24, 0, 0, 0) + data + bytes(length - 24 - len(data))
    commands = struct.pack('<6I', 0x32, 24, platform, 0xF0000, 0x1A0000, 0) + load
    return struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 8, 2, len(commands), 0, 0) + commands


class NativeDependencyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='native-dependencies-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.lock = read_lock()
        self.package = copy.deepcopy(self.lock['packages'][0])

    def test_dotted_and_underscored_names_cannot_collide(self):
        names = ['PIL._imaging', 'PIL__imaging', 'other._imaging']
        self.assertEqual(len({framework_name(name) for name in names}), len(names))
        with self.assertRaises(ValueError):
            framework_name('../outside')

    def test_framework_preserves_real_binary_and_round_trip_origin(self):
        source = self.root / '_imaging.cpython-312-iphoneos.so'
        source.write_bytes(macho())
        app = self.root / 'App.app'
        entry = install_extension(source, 'PIL/' + source.name, app, self.package, 'device', 'com.example')
        self.assertEqual((app / entry['binary']).read_bytes(), source.read_bytes())
        self.assertEqual((app / entry['marker']).read_text().strip(), entry['binary'])
        self.assertEqual((app / entry['origin']).read_text().strip(), entry['marker'])
        self.assertFalse(list((app / 'python').rglob('*.so')))
        info = plistlib.loads((app / entry['binary']).with_name('Info.plist').read_bytes())
        self.assertEqual(info['CFBundleExecutable'], entry['framework'])

    def test_wrong_platform_and_unmapped_dylib_fail_before_framework_creation(self):
        source = self.root / '_imaging.cpython-312-iphoneos.so'
        app = self.root / 'App.app'
        source.write_bytes(macho(7))
        with self.assertRaisesRegex(ValueError, 'platform'):
            install_extension(source, 'PIL/' + source.name, app, self.package, 'device', 'com.example')
        source.write_bytes(macho(dependency='@rpath/libunmapped.dylib'))
        with self.assertRaisesRegex(ValueError, 'explicit framework mapping'):
            install_extension(source, 'PIL/' + source.name, app, self.package, 'device', 'com.example')
        self.assertFalse(app.exists())

    def test_known_incompatible_package_cannot_be_admitted_by_a_success_boolean(self):
        proof = {'actual_cpython': '3.12.16', 'platform': 'ios', 'check_multi_interp_extensions': 1,
                 'own_gil_interpreters': 2, 'own_gil_supported': True, 'native_completed': True,
                 'package': 'pillow', 'mode': 'own-gil', 'results': [{'ok': True}, {'ok': True}]}
        for package in self.lock['packages']:
            with self.assertRaisesRegex(ValueError, 'not admitted'):
                validate_admission(self.lock, package, proof)
        reviewed = dict(self.package, production_eligible=True, own_gil='supported')
        validate_admission(self.lock, reviewed, proof)
        for changed in ({'platform': 'win32'}, {'actual_cpython': '3.12.10'},
                        {'check_multi_interp_extensions': 0}, {'native_completed': False},
                        {'package': 'other'}, {'results': [{'ok': True}]}):
            with self.assertRaisesRegex(ValueError, 'completed iOS OWN_GIL'):
                validate_admission(self.lock, reviewed, dict(proof, **changed))

    def test_default_app_policy_has_constraints_but_no_pretend_native_packages(self):
        app = self.root / 'App.app'
        policy = stage_application_policy(app, 'device')
        self.assertEqual(policy['admitted_packages'], [])
        self.assertEqual(policy['frameworks'], [])
        self.assertEqual({item['name'] for item in policy['constraints']}, {'pillow', 'lxml'})
        self.assertEqual(json.loads((app / 'python/native-dependencies.json').read_text()), policy)
        self.assertFalse((app / 'python/native-vendor').exists())
        self.assertFalse((app / 'Frameworks').exists())


if __name__ == '__main__':
    unittest.main()
