"""Resource placement/hash evidence only; no font registration or UIKit execution."""

import hashlib
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from native_bundle_resources import verify_archive


class NativeBundleResourceTests(unittest.TestCase):
    def fixture(self, directory, mutation=None):
        font, notice = b'owned font bytes', b'owned license bytes'
        resources = [{'source': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                     for name, data in (('Fonts/Test.ttf', font), ('Notices/LICENSE.txt', notice))]
        contract = {'groups': {'owned': resources}, 'archives': {'Test': {'Payload/Test.app': ['owned']}}}
        path = Path(directory) / 'test.ipa'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('Payload/Test.app/Info.plist', plistlib.dumps({'UIAppFonts': ['Test.ttf']} if mutation == 'registration' else {}))
            archive.writestr('Payload/Test.app/Test.ttf', b'x' * len(font) if mutation == 'hash' else font)
            if mutation != 'missing-license':
                archive.writestr('Payload/Test.app/' + ('Nested/' if mutation == 'nested' else '') + 'LICENSE.txt', notice)
        return path, contract

    def test_exact_root_resources_are_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            path, contract = self.fixture(directory)
            self.assertEqual(verify_archive(path, contract, 'Test')['status'], 'verified')

    def test_missing_nested_modified_or_double_registered_resources_fail(self):
        for mutation in ('missing-license', 'nested', 'hash', 'registration'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                path, contract = self.fixture(directory, mutation)
                with self.assertRaises(ValueError):
                    verify_archive(path, contract, 'Test')


if __name__ == '__main__':
    unittest.main()
