"""Supplement source/lifecycle/identity gates with synthetic evidence only."""

import copy
import hashlib
import json
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from client_ui_harness_domains import batch_name, selected_scenarios
from client_ui_harness_supplements import (RESET_SCENARIOS, RESET_SOURCES, RESET_DARK,
    TRUST_SOURCES, SUPPLEMENT_BATCHES, reset_probes, validate_reset)
from client_ui_harness_map import MAP_SCENARIOS, MAP_SOURCES, MAP_TILE_SOURCE, MAP_ENTRY, MAP_BOUNDARY
from verify_client_ui_batches import verify
from verify_client_ui_supplements import verify_supplements
from tools.ci.tests import test_client_ui_batches as batch_checks


class SupplementChecks(unittest.TestCase):
    def reset_state(self, scenario='reset-ready-cancelled'):
        native = ROOT / 'telegram-ios/Tests/Exteraless/SettingsResetNavigationChecks.swift'
        files = {name: 'a' * 64 for name in RESET_SOURCES}
        files['telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessResetSupplement.swift'] = 'a' * 64
        from client_ui_harness_domains import REQUIRED_SOURCE_SUFFIXES
        files.update({'telegram-ios/fixture' + name: 'a' * 64 for name in REQUIRED_SOURCE_SUFFIXES})
        canonical = ''.join(sha + '  ' + name + '\n' for name, sha in sorted(files.items()))
        manifest = {'format': 'exteraless-ui-domain-sources/1', 'files': files, 'sha256': hashlib.sha256(canonical.encode()).hexdigest()}
        first = {'scenario': scenario, 'authorityID': '00000000-0000-0000-0000-000000000001',
            'planID': '00000000-0000-0000-0000-000000000002', 'sessionPlanID': 'none',
            'prepareReplies': 1, 'resetReplies': 0, 'removals': 0, 'actualValue': 2, 'storedOverride': True,
            'pageFrame': [0, 0, 320, 640], 'authorityValid': True, 'visible': True, 'queuedPreview': False, 'busy': False}
        probes, artifacts = [], []
        for name in reset_probes(scenario):
            value = copy.deepcopy(first)
            if name == 'reset-before-swipe':
                value.update(lifecycle=['willAppear', 'didAppear'], sources={name: files[name] for name in RESET_SOURCES})
            elif name == 'reset-dragging':
                value.update(lifecycle=['willDisappear'], authorityValid=False)
            elif name in ('reset-navigation-ended', 'reset-returned-ready'):
                value.update(lifecycle=['willDisappear', 'didAppear'], authorityID='00000000-0000-0000-0000-000000000003',
                    planID='00000000-0000-0000-0000-000000000004', prepareReplies=2, actionFrame=[0, 100, 300, 44])
            elif name == 'reset-cleanup':
                value = {'nativeFixtureReturned': True, 'firstResponder': False}
            if name != 'home':
                image = 'native/' + name + '.png'
                value['nativeViewImage'] = image
                artifacts.append({'path': image, 'sha256': 'b' * 64, 'bytes': 100, 'width': 320, 'height': 640})
            probes.append({'name': name, 'semantic': value, 'dark': scenario in RESET_DARK})
        return {'pythonRequested': False, 'probes': probes, 'facts': {'domainSources': manifest,
            'visualArtifacts': artifacts, 'resetSupplement': {'completed': True, 'scenario': scenario,
                'fixture': 'SettingsResetNavigationChecks', 'interactionDeadlineSeconds': 18, 'replyGateSeconds': 6,
                'palette': 'dark' if scenario in RESET_DARK else 'light'}}}

    def test_reset_whitelist_and_22_inputs_match_the_actual_given_context_fixture(self):
        text = (ROOT / 'telegram-ios/Tests/Exteraless/SettingsResetNavigationChecks.swift').read_text(encoding='utf-8')
        scenarios = re.findall(r'case \w+ = "(reset-[^"]+)"', text)
        self.assertEqual(tuple(scenarios), RESET_SCENARIOS)
        block = re.search(r'static let requiredSources = \[(.*?)\n    \]', text, re.S)[1]
        self.assertEqual(tuple(re.findall(r'"([^"]+)"', block)), RESET_SOURCES)

    def test_reset_rejects_synthetic_lifecycle_old_plan_and_mutated_file_state(self):
        state = self.reset_state()
        validate_reset(state, RESET_SCENARIOS[0])
        for change in ('lifecycle', 'plan', 'value', 'source', 'no-image'):
            bad = copy.deepcopy(state)
            values = {p['name']: p['semantic'] for p in bad['probes']}
            if change == 'lifecycle': values['reset-navigation-ended']['lifecycle'].insert(1, 'willAppear')
            elif change == 'plan': values['reset-returned-ready']['planID'] = values['reset-before-swipe']['planID']
            elif change == 'value': values['reset-returned-ready']['actualValue'] = 3
            elif change == 'source': values['reset-before-swipe']['sources'].pop(RESET_SOURCES[0])
            else: values['reset-dragging'].pop('nativeViewImage')
            with self.subTest(change=change), self.assertRaises((ValueError, KeyError)):
                validate_reset(bad, RESET_SCENARIOS[0])

    def test_base_default_stays_three_and_supplements_cannot_mix_batches(self):
        baseline = ('core-light', 'core-dark', 'sdk-ui')
        self.assertEqual(selected_scenarios(None, baseline), baseline)
        for _, name, group in SUPPLEMENT_BATCHES:
            self.assertEqual(selected_scenarios(group, baseline), group)
            self.assertEqual(batch_name(group, baseline), name)
        for names in ((RESET_SCENARIOS[0], 'core-light'), (RESET_SCENARIOS[0], RESET_SCENARIOS[4])):
            with self.assertRaises(ValueError): selected_scenarios(names, baseline)

    def supplement_evidence(self):
        build, native, baseline, domains, visuals, receipts = batch_checks.SerialUIBatchChecks().fixtures()
        files = build['domainSources']['files']
        files.update({name: 'a' * 64 for name in RESET_SOURCES + TRUST_SOURCES + MAP_SOURCES})
        files['telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessResetSupplement.swift'] = 'a' * 64
        build['domainSources']['sha256'] = hashlib.sha256(''.join(sha+'  '+name+'\n' for name,sha in sorted(files.items())).encode()).hexdigest()
        base = verify(build, native, baseline, domains, visuals, receipts)
        base['simulatorIds'] = ['00000000-0000-0000-0000-' + str(i).zfill(12) for i in range(1,4)]
        reports, bound, devices = [], [], []
        for index, (_, name, group) in enumerate(SUPPLEMENT_BATCHES):
            report = copy.deepcopy(domains)
            report.update(batch=name, requestedScenarios=list(group),
                scenarios=[{'scenario': item, 'semanticPassed': True, 'processSeconds': 2} for item in group],
                recordings=[{'scenario': item, 'frameCount': 2} for item in group])
            if group == MAP_SCENARIOS:
                report['recordings'][0].update(timestampSource='ffprobe', mapEvidence={
                    'nativeEntry': MAP_ENTRY, 'networkBoundary': MAP_BOUNDARY, 'nativePNGCount': 13,
                    'paletteStateCount': 6, 'stateSha256': 'b' * 64, 'frameHandlesSha256': 'c' * 64,
                    'tileSHA256': files[MAP_TILE_SOURCE], 'sourceManifestSHA256': build['domainSources']['sha256']})
            receipt = copy.deepcopy(receipts[0]); receipt.update(batch=name, requestedScenarios=list(group))
            reports.append(report); bound.append(receipt)
            devices.append({'udid': '00000000-0000-0000-0000-' + str(index+4).zfill(12)})
        return build, native, base, reports, bound, devices, base['nativeResultsSha256']

    def test_supplement_gate_requires_20_distinct_scenes_and_fresh_same_ipa_batches(self):
        result = verify_supplements(*self.supplement_evidence())
        self.assertEqual(result['sceneCount'], 20)
        self.assertEqual(len(result['simulatorIds']), 9)
        for change in ('missing-map', 'partial', 'old-device', 'other-ipa', 'map-without-pts'):
            args = self.supplement_evidence()
            if change == 'missing-map': args[3].pop()
            elif change == 'partial': args[3][0]['scenarios'].pop()
            elif change == 'old-device': args[5][-1]['udid'] = args[5][0]['udid']
            elif change == 'other-ipa': args[3][-1]['bundle']['ipaSha256'] = '0' * 64
            else: args[3][-1]['recordings'][0].pop('mapEvidence')
            with self.subTest(change=change), self.assertRaises(ValueError): verify_supplements(*args)


if __name__ == '__main__':
    unittest.main()
