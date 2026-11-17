"""Nested artifact layout must still produce one verified flat release stage."""

from pathlib import Path
import hashlib
import json
import tempfile
import unittest
import zipfile

from tools.ci.publish_unsigned_release import stage


class PublishUnsignedReleaseTests(unittest.TestCase):
    def test_nested_upload_paths_stage_without_losing_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            nested = root / 'Shared/telegram-ios/build/artifacts'
            nested.mkdir(parents=True)
            ipa = nested / 'Telegram.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Telegram.app/Info.plist', b'unsigned-test')
            digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
            (nested / 'build-manifest.json').write_text(json.dumps({
                'signing': 'unsigned (linker ad-hoc signatures allowed)',
                'version': '13.1.1', 'build_number': '42', 'sha256': digest,
            }))
            for name in ('Telegram.DSYMs.zip', 'runtime-manifest.json', 'Telegram_dossier.zip'):
                (nested / name).write_bytes(b'asset-' + name.encode())
            entitlements = nested / 'signing-entitlements'
            entitlements.mkdir()
            (entitlements / 'Telegram.entitlements').write_text('<plist/>', encoding='utf-8')
            destination = root / 'stage'
            result = stage(root, '13.1.1', '42',
                           'f2baf58680d3899123291e2431699465d5b63559', destination, root / 'notes.md')
            self.assertEqual(result['digest'], digest)
            self.assertTrue((destination / 'exteraless-ios-13.1.1-42.ipa').is_file())
            with zipfile.ZipFile(destination / 'signing-entitlements.zip') as archive:
                self.assertEqual(archive.namelist(), ['Telegram.entitlements'])
            self.assertIn('f2baf58680d3899123291e2431699465d5b63559', (root / 'notes.md').read_text(encoding='utf-8'))

    def test_profile_or_hash_mismatch_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ipa = root / 'Telegram.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('embedded.mobileprovision', b'profile')
            (root / 'build-manifest.json').write_text(json.dumps({
                'signing': 'unsigned', 'version': '13.1.1', 'build_number': '42',
                'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest(),
            }))
            for name in ('Telegram.DSYMs.zip', 'runtime-manifest.json', 'Telegram_dossier.zip'):
                (root / name).write_bytes(b'x')
            (root / 'App.entitlements').write_text('<plist/>', encoding='utf-8')
            with self.assertRaises(SystemExit):
                stage(root, '13.1.1', '42', 'abc', root / 'out', root / 'notes.md')


if __name__ == '__main__':
    unittest.main()
