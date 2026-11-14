import copy
from pathlib import Path
import plistlib
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from support import digest, inspect_archive, read_lock, stage_application


class SupportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='runtime-package-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.lock = copy.deepcopy(read_lock())
        self.lock['required_extensions'] = ['_ssl', '_sqlite3']
        self.framework = self.root / 'support/Python.xcframework'
        self.write(self.framework / 'lib/python3.12/encodings/__init__.py', b'# encoding fixture')
        self.write(self.framework / 'build/iOS-dylib-Info-template.plist', plistlib.dumps({'CFBundlePackageType': 'FMWK'}))
        libraries = []
        for target, spec in self.lock['slices'].items():
            folder = self.framework / spec['library']
            entry = {'LibraryIdentifier': spec['library'], 'BinaryPath': 'Python.framework/Python',
                     'LibraryPath': 'Python.framework', 'SupportedArchitectures': ['arm64'], 'SupportedPlatform': 'ios'}
            if target == 'simulator':
                entry['SupportedPlatformVariant'] = 'simulator'
            libraries.append(entry)
            self.write(folder / 'Python.framework/Python', b'framework fixture')
            self.write(folder / 'Python.framework/Headers/patchlevel.h', b'#define PY_VERSION "3.12.16"\n')
            for module in self.lock['required_extensions']:
                self.write(folder / ('lib-arm64/python3.12/lib-dynload/' + module + '.cpython-312-iphoneos.so'), b'extension fixture')
            self.write(folder / 'lib-arm64/python3.12/lib-dynload/_ssl.xcprivacy', b'privacy fixture')
        self.write(self.framework / 'Info.plist', plistlib.dumps({'AvailableLibraries': libraries}))

    def write(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def archive(self):
        path = self.root / 'support.tar.gz'
        with tarfile.open(path, 'w:gz') as archive:
            archive.add(self.framework, arcname='Python.xcframework')
        self.lock['sha256'] = digest(path)
        return path

    def test_archive_checks_both_platforms_and_extensions(self):
        report = inspect_archive(self.archive(), self.lock)
        self.assertEqual(set(report['slices']), {'device', 'simulator'})
        self.assertIn('_ssl', report['slices']['device']['extensions'])

    def test_wrong_checksum_is_not_accepted(self):
        archive = self.archive()
        self.lock['sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            inspect_archive(archive, self.lock)

    def test_missing_required_native_module_is_not_accepted(self):
        (self.framework / 'ios-arm64/lib-arm64/python3.12/lib-dynload/_ssl.cpython-312-iphoneos.so').unlink()
        with self.assertRaisesRegex(ValueError, 'lacks extension modules'):
            inspect_archive(self.archive(), self.lock)

    def test_staging_preserves_framework_loader_paths(self):
        app = self.root / 'Probe.app'
        report = stage_application(self.framework, app, 'device', self.lock, 'com.example.probe')
        self.assertEqual(report['extension_frameworks'], ['_sqlite3', '_ssl'])
        marker = app / 'python-stdlib/lib/python3.12/lib-dynload/_ssl.cpython-312-iphoneos.fwork'
        binary = app / marker.read_text(encoding='utf-8').strip()
        self.assertEqual(binary.read_bytes(), b'extension fixture')
        self.assertEqual((binary.parent / '_ssl.origin').read_text().strip(), marker.relative_to(app).as_posix())
        self.assertTrue((binary.parent / 'PrivacyInfo.xcprivacy').is_file())
        self.assertFalse(list((app / 'python-stdlib').rglob('*.so')))
        self.assertTrue((self.framework / 'ios-arm64/lib-arm64/python3.12/lib-dynload/_ssl.cpython-312-iphoneos.so').is_file())

    def test_staging_refuses_to_overwrite_existing_runtime(self):
        app = self.root / 'Probe.app'
        stage_application(self.framework, app, 'device', self.lock, 'com.example.probe')
        with self.assertRaisesRegex(ValueError, 'already staged'):
            stage_application(self.framework, app, 'device', self.lock, 'com.example.probe')

    def test_simulator_framework_metadata(self):
        app = self.root / 'Probe.app'
        stage_application(self.framework, app, 'simulator', self.lock, 'com.example.probe')
        info = plistlib.loads((app / 'Frameworks/_ssl.framework/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleSupportedPlatforms'], ['iPhoneSimulator'])


if __name__ == '__main__':
    unittest.main()
