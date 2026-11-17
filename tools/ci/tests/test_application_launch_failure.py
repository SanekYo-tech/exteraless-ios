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

    def test_missing_container_warns_and_continues_in_private_store(self):
        launch = self.body('func application(_ application: UIApplication, didFinishLaunchingWithOptions')
        fallback = launch[launch.index('if let sharedContainer = maybeAppGroupUrl'):launch.index('var isDebugConfiguration')]
        self.assertIn('self.privateLaunchContainer()', fallback)
        self.assertIn('self.clientContainerWarning =', fallback)
        self.assertNotIn('self.clientLaunchFailure =', fallback[:fallback.index('} else {')])
        self.assertNotIn('return true', fallback[:fallback.index('} else {')])
        self.assertLess(launch.index('self.clientContainerWarning ='), launch.index('self.prepareClientSettings('))
        self.assertNotIn('presentNative', fallback)
        helper = self.body('private func privateLaunchContainer()')
        self.assertIn('applicationSupportDirectory', helper)
        self.assertIn('createDirectory', helper)
        self.assertIn('exteraless-private-container', self.source[self.source.index('private func privateLaunchContainer()'):])
        self.assertNotIn('NSHomeDirectory()', helper)
        warning = self.body('private func presentClientContainerWarningIfNeeded()')
        self.assertIn('root.present(alert, animated: false)', warning)
        self.assertNotIn('rootViewController = controller', warning)
        self.assertIn('self.clientLaunchFailure == nil', warning)
        self.assertNotIn('self.clientLaunchFailure = ', warning)
        attach = self.body('func attach(scene: UIWindowScene')
        self.assertLess(attach.index('self.window?.makeKeyAndVisible()'),
                        attach.index('self.presentClientContainerWarningIfNeeded()'))

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

    def test_failed_settings_still_open_the_login_pipeline(self):
        preparation = self.body('private func prepareClientSettings(')
        failed = preparation[preparation.index('case let .failed(message):'):]
        self.assertLess(failed.index('self.presentClientPreparationFailureIfNeeded()'),
                        failed.index('self.clientSettingsReady.set(.single(()))'))
        account = (ROOT / 'telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift').read_text(encoding='utf-8')
        start = account.index('let originalNetworkArguments = networkArguments')
        gate = account[start:account.index('let keychain = makeExclusiveKeychain', start)]
        self.assertNotIn('ExteralessAccountRetentionEnvironment.shared.current.configuration == nil', gate)
        self.assertIn('if accountState is AuthorizedAccountState', gate)
        self.assertIn('networkArguments = originalNetworkArguments', gate)
        window = (ROOT / 'telegram-ios/submodules/Display/Source/NativeWindowHostView.swift').read_text(encoding='utf-8')
        self.assertIn('window.backgroundColor = .systemBackground', window)
        self.assertNotIn('backgroundColor = UIColor.black', self.source)

    def test_presented_api_event_is_consumed_after_guards_without_relatching_resolver(self):
        present = self.body('private func presentClientAPIErrorIfNeeded()')
        self.assertLess(present.index('else { return }'), present.index('self.clientAPIErrorMessage = nil'))
        self.assertLess(present.index('self.clientAPIErrorMessage = nil'), present.index('UIAlertController('))
        self.assertNotIn('configure(', present)
        self.assertNotIn('clientSettingsReady.set', present)
        preparation = self.body('private func prepareClientSettings(')
        first_ready = preparation[preparation.index('if !self.clientSettingsPrepared'):]
        self.assertLess(first_ready.index('self.clientAPIErrorMessage = nil'),
                        first_ready.index('self.clientSettingsPrepared = true'))
        self.assertLess(first_ready.index('self.clientAPIErrorMessage = nil'),
                        first_ready.index('self.clientSettingsReady.set(.single(()))'))


if __name__ == '__main__':
    unittest.main()
