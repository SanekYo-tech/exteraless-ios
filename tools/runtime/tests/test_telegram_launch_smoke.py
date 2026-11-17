import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from telegram_launch_smoke import (APP_ROOT, DEVICE_PREFIX, main_app_info, owned_device,
                                    parse_launch_pid, sanitize_diagnostics, process_state)


class NormalLaunchContracts(unittest.TestCase):
    def test_only_exact_created_simulator_can_be_cleaned(self):
        record = {'udid': str(uuid.uuid4()), 'name': DEVICE_PREFIX + str(uuid.uuid4()),
                  'deviceType': 'type', 'runtime': 'runtime'}
        item = {'udid': record['udid'], 'name': record['name'], 'deviceTypeIdentifier': 'type'}
        self.assertTrue(owned_device(record, {'runtime': [item]}))
        for key in ('udid', 'name', 'deviceTypeIdentifier'):
            with self.subTest(key=key):
                self.assertFalse(owned_device(record, {'runtime': [dict(item, **{key: 'foreign'})]}))
        self.assertFalse(owned_device(record, {'different-runtime': [item]}))

    def test_launch_pid_must_belong_to_exact_normal_bundle(self):
        self.assertEqual(parse_launch_pid('ph.telegra.Telegraph: 1234\n', 'ph.telegra.Telegraph'), 1234)
        for text in ('org.exteraless.ClientUIHarness: 1234', 'ph.telegra.Telegraph: 0', 'error 1234'):
            with self.assertRaises(ValueError):
                parse_launch_pid(text, 'ph.telegra.Telegraph')

    def test_ipa_identity_preserves_all_extensions_and_rejects_harness_device_and_traversal(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'Telegram.ipa'
            def make(bundle='ph.telegra.Telegraph', platform='iPhoneSimulator', extensions=6, unsafe=False):
                with zipfile.ZipFile(path, 'w') as archive:
                    archive.writestr(APP_ROOT + '/Info.plist', plistlib.dumps({
                        'CFBundleIdentifier': bundle, 'CFBundleExecutable': 'Telegram',
                        'CFBundleSupportedPlatforms': [platform],
                        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False}}))
                    for index in range(extensions):
                        archive.writestr(APP_ROOT + '/PlugIns/Ext%d.appex/Info.plist' % index,
                                         plistlib.dumps({'CFBundleIdentifier': bundle + '.Ext%d' % index}))
                    if unsafe:
                        archive.writestr(APP_ROOT + '/../escape', 'no')
            make()
            result = main_app_info(path, 'ph.telegra.Telegraph')
            self.assertEqual(len(result['extensions']), 6)
            self.assertIn('UIApplicationSceneManifest', result['plist'])
            for options in ({'bundle': 'org.exteraless.ClientUIHarness'}, {'platform': 'iPhoneOS'},
                            {'extensions': 0}, {'unsafe': True}):
                make(**options)
                with self.assertRaises(ValueError):
                    main_app_info(path, 'ph.telegra.Telegraph')

    def test_redaction_drops_private_graph_but_keeps_full_failure_log(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'private-actions.json').write_text('{"generated": "secret-value"}')
            (root / 'build.log').write_text('first\nsecret-value\nlast\n')
            (root / 'report.json').write_text(json.dumps({'error': 'secret-value'}))
            sanitize_diagnostics(root, ('secret-value',))
            self.assertFalse((root / 'private-actions.json').exists())
            self.assertEqual((root / 'build.log').read_text(), 'first\n[REDACTED_API_HASH]\nlast\n')
            self.assertNotIn('secret-value', (root / 'report.json').read_text())

    def test_process_evidence_does_not_confuse_relaunch_with_original_pid(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            path = root / 'sample-process-list-stdout.log'
            path.write_text('234\t0\tUIKitApplication:ph.telegra.Telegraph[abc]\n999\t0\tunrelated\n')
            with patch('telegram_launch_smoke.receipt'), patch('telegram_launch_smoke.device_state', return_value={}):
                result = process_state({'udid': 'own'}, 'ph.telegra.Telegraph', 123, root, 'sample')
            self.assertFalse(result['alive'])
            self.assertNotIn('unrelated', path.read_text())

    def test_workflow_is_full_build_then_normal_launch_with_no_native_suite(self):
        text = (ROOT / '.github/workflows/telegram-launch-smoke.yml').read_text(encoding='utf-8')
        self.assertIn('timeout-minutes: 215', text)
        self.assertIn('/Users/Shared/exteraless-launch-smoke', text)
        self.assertIn('--phase launch', text)
        self.assertNotIn('run_native_integration_tests.py', text)
        self.assertNotIn('native_test_disk.py reset', text)
        self.assertNotIn('private-actions.json', text)
        self.assertLess(text.index('Install pinned frame tools'), text.index('Build the full graph'))


if __name__ == '__main__':
    unittest.main()
