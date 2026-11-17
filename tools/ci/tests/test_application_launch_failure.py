"""Scene-order regression for startup rejection before an account can exist."""

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'telegram-ios/build-system/Make'))
from PostboxImportCheck import strip_comments_and_strings


class ApplicationLaunchFailureTests(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / 'telegram-ios/submodules/TelegramUI/Sources/AppDelegate.swift').read_text(encoding='utf-8')
        self.code = strip_comments_and_strings(self.source)

    def body(self, marker):
        start = self.code.index('{', self.code.index(marker))
        depth = 1
        for end in range(start + 1, len(self.code)):
            depth += (self.code[end] == '{') - (self.code[end] == '}')
            if depth == 0:
                return self.code[start + 1:end]
        self.fail('Unclosed body: ' + marker)

    def test_missing_container_rejects_before_store_or_account_construction(self):
        launch = self.body('func application(_ application: UIApplication, didFinishLaunchingWithOptions')
        guard = self.body('guard let appGroupUrl = maybeAppGroupUrl else')
        self.assertIn('self.clientLaunchFailure =', guard)
        self.assertIn('return true', guard)
        self.assertNotIn('presentNative', guard)
        for operation in ('self.prepareClientSettings(', 'setupAccountManager('):
            self.assertLess(launch.index('guard let appGroupUrl'), launch.index(operation))
        self.assertNotIn('NSHomeDirectory()', guard)
        self.assertNotIn('createDirectory', guard)

    def test_failure_is_rendered_only_after_scene_owns_visible_window(self):
        attach = self.body('func attach(scene: UIWindowScene')
        order = [attach.index(text) for text in (
            'self.window?.windowScene = scene', 'self.window?.makeKeyAndVisible()',
            'self.presentClientLaunchFailureIfNeeded()')]
        self.assertEqual(order, sorted(order))
        render = self.body('private func presentClientLaunchFailureIfNeeded()')
        self.assertIn('window.windowScene != nil', render)
        self.assertIn('self.clientLaunchFailureController == nil', render)
        self.assertIn('window.rootViewController = controller', render)
        self.assertIn('window.makeKeyAndVisible()', render)
        self.assertNotIn('mainWindow', render)
        self.assertNotIn('presentNative', render)
        self.assertIn('detail.numberOfLines = 0', render)

    def test_write_probe_failure_is_retained_instead_of_presenting_before_scene(self):
        failure = self.body('if !writeAbilityTestSuccess')
        self.assertIn('self.clientLaunchFailure =', failure)
        self.assertIn('return true', failure)
        self.assertNotIn('presentNative', failure)
        self.assertNotIn('preconditionFailure', failure)

    def test_api_error_is_kept_before_readiness_and_replayed_at_scene_attachment(self):
        preparation = self.body('private func prepareClientSettings(')
        observer = preparation[preparation.index('self.clientAPIErrorsDisposable.set'):]
        self.assertIn('self.clientAPIErrorMessage = error.map', observer)
        self.assertNotIn('guard let self, self.clientSettingsPrepared', observer)
        present = self.body('private func presentClientAPIErrorIfNeeded()')
        self.assertIn('self.clientSettingsPrepared', present)
        self.assertIn('self.window?.windowScene != nil', present)
        self.assertIn('self.clientAPIErrorAlert == nil', present)
        attach = self.body('func attach(scene: UIWindowScene')
        self.assertLess(attach.index('self.window?.makeKeyAndVisible()'),
                        attach.index('self.presentClientAPIErrorIfNeeded()'))


if __name__ == '__main__':
    unittest.main()
