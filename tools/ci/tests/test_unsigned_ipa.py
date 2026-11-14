"""Exercise output validation with tiny, synthetic IPA archives."""

import io
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.ci.verify_unsigned_ipa import EXTENSIONS, FRAMEWORKS, inspect_executable, verify_ipa


def macho(platform=2, signing=None):
    commands = struct.pack('<6I', 0x32, 24, platform, 0, 0, 0)
    count = 1
    signature = b''
    if signing:
        directory = struct.pack('>4I', 0xFADE0C02, 16, 0, 2)
        signature = struct.pack('>3I', 0xFADE0CC0, 36, 1) + struct.pack('>2I', 0, 20) + directory
        if signing == 'cms':
            signature = (struct.pack('>3I', 0xFADE0CC0, 55, 2)
                         + struct.pack('>4I', 0, 28, 0x10000, 44) + directory
                         + struct.pack('>2I', 0xFADE0B01, 11) + b'CMS')
        commands += struct.pack('<4I', 0x1D, 16, 32 + 24 + 16, len(signature))
        count += 1
    return struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, count, len(commands), 0, 0) + commands + signature


class UnsignedIpaTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='exteraless-ipa-')
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'Telegram.ipa'
        self.config = {'bundle_id': 'com.example.client'}

    def archive(self, omit=None, version='13.1.1', platform=2, signing=None, profile=False):
        with zipfile.ZipFile(self.path, 'w') as archive:
            for name in ['Telegram'] + list(EXTENSIONS):
                if name == omit:
                    continue
                root = 'Payload/Telegram.app'
                bundle_id = self.config['bundle_id']
                if name != 'Telegram':
                    root += '/PlugIns/{}.appex'.format(name)
                    bundle_id += '.' + name
                archive.writestr(root + '/Info.plist', plistlib.dumps({
                    'CFBundleIdentifier': bundle_id,
                    'CFBundleExecutable': name,
                    'CFBundleVersion': '42',
                    'CFBundleShortVersionString': version,
                }))
                archive.writestr(root + '/' + name, macho(platform, signing))
            for name in FRAMEWORKS:
                root = 'Payload/Telegram.app/Frameworks/{}.framework'.format(name)
                archive.writestr(root + '/Info.plist', plistlib.dumps({'CFBundleExecutable': name}))
                archive.writestr(root + '/' + name, macho())
            if profile:
                archive.writestr('Payload/Telegram.app/embedded.mobileprovision', b'profile')
        return self.path

    def test_unsigned_app_and_six_extensions(self):
        report = verify_ipa(self.archive(), self.config, '13.1.1', '42')
        self.assertEqual(len(report['bundles']), 7)
        self.assertEqual(len(report['sha256']), 64)
        self.assertTrue(all(item['signing'] == 'none' for item in report['bundles']))
        self.assertEqual(len(report['embedded_binaries']), 5)

    def test_linker_ad_hoc_signature_is_allowed(self):
        report = verify_ipa(self.archive(signing='adhoc'), self.config, '13.1.1', '42')
        self.assertTrue(all(item['signing'] == 'ad-hoc' for item in report['bundles']))

    def test_developer_signature_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Developer/CMS signature'):
            verify_ipa(self.archive(signing='cms'), self.config, '13.1.1', '42')

    def test_profile_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'provisioning profile'):
            verify_ipa(self.archive(profile=True), self.config, '13.1.1', '42')

    def test_missing_extension_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Missing app/extension'):
            verify_ipa(self.archive(omit='WidgetExtension'), self.config, '13.1.1', '42')

    def test_simulator_binary_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'not a device iOS'):
            verify_ipa(self.archive(platform=7), self.config, '13.1.1', '42')

    def test_old_build_artifact_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Stale or mismatched'):
            verify_ipa(self.archive(version='13.0'), self.config, '13.1.1', '42')

    def test_truncated_macho_commands_are_rejected(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive:
            archive.writestr('binary', macho()[:-5])
        with zipfile.ZipFile(buffer) as archive, self.assertRaisesRegex(ValueError, 'Truncated'):
            inspect_executable(archive, 'binary')

    def test_fat_arm64_dylib_is_checked(self):
        binary = macho(signing='adhoc')
        buffer = io.BytesIO()
        fat = struct.pack('>2I', 0xCAFEBABE, 1) + struct.pack('>5I', 0x0100000C, 0, 28, len(binary), 2) + binary
        with zipfile.ZipFile(buffer, 'w') as archive:
            archive.writestr('libswift.dylib', fat)
        with zipfile.ZipFile(buffer) as archive:
            info = inspect_executable(archive, 'libswift.dylib')
        self.assertEqual(info['signing'], 'ad-hoc')
        self.assertEqual(len(info['slices']), 1)

    def test_signed_embedded_dylib_is_rejected(self):
        self.archive()
        with zipfile.ZipFile(self.path, 'a') as archive:
            archive.writestr('Payload/Telegram.app/Frameworks/libExtra.dylib', macho(signing='cms'))
        with self.assertRaisesRegex(ValueError, 'Developer/CMS signature'):
            verify_ipa(self.path, self.config, '13.1.1', '42')


if __name__ == '__main__':
    unittest.main()
