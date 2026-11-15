"""Scoped CMC declarations and native-runner admission; no whole-cohort recount."""

import ast
import copy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
TELEGRAM = ROOT / 'telegram-ios'
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from native_test_plan import Declarations, plan_target
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
        for name in ('Sources/AppDelegate.swift', 'Tests/ComposerSelectionActionFixture.swift',
                     'Tests/HarnessEditedContent.swift', 'Tests/HarnessEngineTestSupport.swift',
                     'Tests/HarnessLegacyTestSupport.swift', 'Tests/HarnessComposerFuzzTests.swift'):
            self.assertIn('Tests/ComposerHarness/' + name, self.declarations.inputs)
        self.assertIn('Tests/Common/Main/main.m', self.declarations.inputs)

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
