"""Scoped CMC declarations and native-runner admission; no whole-cohort recount."""

import ast
import copy
import json
from pathlib import Path
import re
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
TELEGRAM = ROOT / 'telegram-ios'
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from native_test_plan import Declarations, plan_target
from PostboxImportCheck import strip_comments_and_strings
from run_native_integration_tests import require_single_simulator


class NativeComposerCohorts(unittest.TestCase):
    def setUp(self):
        self.contract = json.loads((TELEGRAM / 'Tests/Exteraless/native-tests.json').read_text())
        self.declarations = Declarations(TELEGRAM, source_checkout=True)

    def test_composer_classes_use_the_real_scene_host_and_compile_the_existing_helpers(self):
        for label, name, count in (
            ('ExteralessComposerSelectionTests', 'HarnessComposerSelectionActionTests', 5),
            ('ExteralessComposerPasteTests', 'HarnessComposerPlainPasteTests', 7),
        ):
            target = plan_target(self.declarations, '//Tests/ComposerHarness:' + label, self.contract)
            self.assertEqual([(case['class'], len(case['methods'])) for case in target['classes']], [(name, count)])
            self.assertEqual(target['host'], '//Tests/ComposerHarness:ComposerHarness')
            self.assertEqual(target['host_bundle_id'], 'org.telegram.ComposerHarness')
        for name in ('Sources/AppDelegate.swift', 'Sources/HarnessBootstrap.swift', 'Tests/ComposerSelectionActionFixture.swift',
                     'Tests/HarnessEditedContent.swift', 'Tests/HarnessEngineTestSupport.swift',
                     'Tests/HarnessLegacyTestSupport.swift', 'Tests/HarnessComposerFuzzTests.swift'):
            self.assertIn('Tests/ComposerHarness/' + name, self.declarations.inputs)
        self.assertIn('Tests/Common/Main/main.m', self.declarations.inputs)

    def swift_body(self, relative, declaration):
        path = TELEGRAM / 'Tests/ComposerHarness' / relative
        self.assertTrue(path.is_file(), 'Missing Composer source: ' + relative)
        code = strip_comments_and_strings(path.read_text(encoding='utf-8'))
        start = code.index('{', code.index(declaration))
        depth = 1
        for index in range(start + 1, len(code)):
            depth += (code[index] == '{') - (code[index] == '}')
            if depth == 0:
                return code[start + 1:index]
        self.fail('Unclosed Swift declaration: ' + declaration)

    def ordered(self, code, *calls):
        position = -1
        for call in calls:
            next_position = code.find(call, position + 1)
            self.assertGreater(next_position, position, 'Missing/reordered startup operation: ' + call)
            position = next_position

    def test_scene_prepares_before_root_and_account_consumers_require_readiness(self):
        scene = self.swift_body('Sources/AppDelegate.swift', 'public func scene(')
        self.ordered(scene, 'HarnessBootstrap.shared.prepare()', 'HarnessRootViewController()',
                     'root.recordStartupFailure(', 'AppDelegate.setRootViewController(root)',
                     'window.rootViewController = root')
        root = self.swift_body('Sources/HarnessRootViewController.swift', 'override func viewDidLoad(')
        self.ordered(root, 'try self.requireStartup()', 'try HarnessBootstrap.shared.requirePrepared()',
                     'composerHarnessAccountWithReadiness()')
        self.assertIn('self?.recordStartupFailure(failure)', root)
        helper = self.swift_body('Tests/HarnessEngineTestSupport.swift', 'static func root(')
        self.ordered(helper, 'try value.requireStartup()', 'value.loadViewIfNeeded()',
                     'while value.panelHost == nil', 'try value.requireStartup()', 'RunLoop.current.run(')
        self.assertGreaterEqual(helper.count('try value.requireStartup()'), 3)
        self.assertIn('addingTimeInterval(30.0)', helper)

    def test_bootstrap_owns_its_inputs_and_uses_real_retention_and_api_configuration(self):
        path = TELEGRAM / 'Tests/ComposerHarness/Sources/HarnessBootstrap.swift'
        self.assertTrue(path.is_file(), 'Composer needs a process bootstrap before its first Account open')
        raw = path.read_text(encoding='utf-8')
        code = strip_comments_and_strings(raw)
        self.assertIn('FileManager.default.temporaryDirectory', code)
        self.assertIn('UUID().uuidString', code)
        self.assertIn('NSHomeDirectory()', code)
        self.assertIn('@MainActor\nfinal class HarnessBootstrap', code)
        self.assertIn('static let shared = HarnessBootstrap()', code)
        prepare = self.swift_body('Sources/HarnessBootstrap.swift', 'func prepare(')
        self.ordered(prepare, 'if let preparation', 'self.configure()', 'self.preparation = result')
        configure = self.swift_body('Sources/HarnessBootstrap.swift', 'private func configure(')
        self.ordered(configure, 'FileManager.default.createDirectory(', 'ClientSettings.shared.configure(',
                     'ClientSettings.shared.register(RetentionFeatures.definitions + ChatFeatures.definitions)',
                     'ClientSettings.shared.applyPublic(', 'ExteralessRetentionProcessConfiguration(',
                     'ExteralessAccountRetentionEnvironment.shared.configure(', 'ClientAPIConfigurationStore(',
                     'ExteralessClientAPIEnvironment.shared.configure(')
        self.assertIn('role: .mainApplication', configure)
        self.assertEqual(configure.count('durabilityRootURL: self.container'), 2)
        self.assertIn('snapshot: ClientSettings.shared.readSnapshot()', configure)
        self.assertIn('secretStore: self.privateStore', configure)
        self.assertIn('settingsSecrets: self.privateStore', configure)
        self.assertIn('ClientAPIVault(storage: self.privateStore)', configure)
        counterpart = (TELEGRAM / 'Tests/ExteralessHarness/Sources/ClientHarnessBootstrap.swift').read_text(encoding='utf-8')
        tuple_pattern = r'configure\(builtinApiId:\s*(\d+),\s*builtinApiHash:\s*"([^"]+)"'
        self.assertTrue(re.search(tuple_pattern, raw).groups() == re.search(tuple_pattern, counterpart).groups(),
                        'Composer must use the already approved synthetic API tuple')
        for value in ('"chats.showTextCreateDate": .bool(true)', '"chats.stripTrackingOnPaste": .bool(true)',
                      '"chats.disableMarkdown": .bool(false)'):
            self.assertIn(value, raw)
            self.assertIn(value, counterpart)
        self.assertNotIn('nonisolated(unsafe)', code)
        self.assertNotIn('ClientSecrets.systemStore()', code)
        self.assertNotIn('ClientAPIKeychain.storage(', code)
        _, _, library = self.declarations.rule('//Tests/ComposerHarness:ComposerHarnessLib')
        self.assertIn('//third-party/exteraless:ExteralessCore', ast.literal_eval(library['deps']))

    def test_startup_failures_are_typed_before_account_delivery_and_escape_fixture_wait(self):
        account = self.swift_body('Sources/HarnessBootstrap.swift', 'func composerHarnessAccountWithReadiness(')
        self.ordered(account, 'ExteralessAccountRecoveryCenter.shared.pending.start(',
                     'ExteralessClientAPIEnvironment.shared.errors.start(',
                     'ExteralessAccountRetentionEnvironment.shared.current.configuration == nil',
                     'HarnessAccount.make().start(')
        self.assertIn('entry.recovery.currentStatus', account)
        self.assertIn('fail(.retention(failure))', account)
        self.assertIn('fail(.accountAPIAdmission)', account)
        self.assertIn('fail(.accountCompletedWithoutValue)', account)
        self.assertIn('subscriber.putError(failure)', account)
        self.assertIn('subscriber.putNext(value)', account)
        self.assertNotIn('.single(', account)
        self.assertNotIn('retry', account)
        root = self.swift_body('Sources/HarnessRootViewController.swift', 'func requireStartup(')
        self.assertIn('throw startupFailure', root)
        bootstrap = (TELEGRAM / 'Tests/ComposerHarness/Sources/HarnessBootstrap.swift').read_text(encoding='utf-8')
        self.assertNotIn('localizedDescription', bootstrap)
        self.assertNotIn('String(describing:', bootstrap)

    def test_canvas_support_class_cannot_expand_the_selected_runtime_cohort(self):
        target = plan_target(self.declarations,
            '//submodules/TelegramUI/Components/RichTextEditor:ExteralessComposerUIKitTests', self.contract)
        self.assertEqual([(case['class'], len(case['methods'])) for case in target['classes']],
                         [('CanvasPlainPasteLiteralTests', 3)])
        self.assertTrue(any(name.endswith('/CanvasClipboardTests.swift') for name in self.declarations.inputs))

    def test_metadata_mapper_inputdec_producers_and_media_have_concrete_class_bindings(self):
        rich = '//submodules/TelegramUI/Components/RichTextEditor:'
        cases = (
            (rich + 'ExteralessComposerMetadataTests', 'DocumentSelectionMediaMetadataTests', 1),
            (rich + 'ExteralessComposerMapperTests', 'AttributedStringMapperLinkTests', 7),
            (rich + 'ExteralessComposerInputDecTests', 'ChatLinkIngressTests', 5),
            ('//submodules/TextFormat:ExteralessComposerTests', 'ExteralessComposerProducerTests', 4),
            ('//submodules/TelegramUI:ExteralessChatMediaTests', 'ChatMediaRemediationNativeTests', 8),
        )
        for label, name, count in cases:
            target = plan_target(self.declarations, label, self.contract)
            case = next(case for case in target['classes'] if case['class'] == name)
            self.assertEqual(len(case['methods']), count)
            self.assertEqual(self.contract['required_sources'][case['source']], label)

    def test_missing_filter_wildcard_or_wrong_host_cannot_produce_a_zero_test_pass(self):
        label = '//Tests/ComposerHarness:ExteralessComposerSelectionTests'
        package, kind, original = self.declarations.rule(label)
        for value in ('MissingClass', 'Harness*', 'One,Two', '-One'):
            rule = copy.deepcopy(original)
            rule['test_filter'] = ast.Constant(value)
            self.declarations.cache[package]['ExteralessComposerSelectionTests'] = kind, rule
            with self.assertRaises(ValueError):
                plan_target(self.declarations, label, self.contract)
        self.declarations.cache[package]['ExteralessComposerSelectionTests'] = kind, original
        contract = copy.deepcopy(self.contract)
        contract['target_hosts'][label]['bundle_id'] = 'org.exteraless.NativeTests'
        with self.assertRaisesRegex(ValueError, 'bundle identity'):
            plan_target(self.declarations, label, contract)
        del contract['target_hosts']
        with self.assertRaisesRegex(ValueError, 'test host'):
            plan_target(self.declarations, label, contract)

    def test_another_booted_simulator_blocks_execution_without_shutting_it_down(self):
        for devices, allowed in (([], True), ([{'udid': 'own', 'state': 'Booted'}], True),
                                 ([{'udid': 'other', 'state': 'Booted'}], False)):
            with patch('run_native_integration_tests.output', return_value=json.dumps({'devices': {'ios': devices}})) as output:
                if allowed:
                    require_single_simulator({'udid': 'own'})
                else:
                    with self.assertRaisesRegex(ValueError, 'freshly owned'):
                        require_single_simulator({'udid': 'own'})
                output.assert_called_once()


if __name__ == '__main__':
    unittest.main()
