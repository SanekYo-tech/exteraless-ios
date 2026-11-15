"""New serial-batch/DEBUG contracts only; no Xcode, simulator or renderer runs."""

import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from client_ui_harness_build import validate_domain_debug_actions
from client_ui_harness_domains import REQUIRED_SOURCE_SUFFIXES
from client_ui_harness_visuals import BUILD_SELECTION, COMMON_SOURCES, VISUAL_SOURCES
from verify_client_ui_batches import BASELINE, DOMAINS, FINAL_VISUALS, verify, verify_devices
from native_test_plan import verify_native_results


class SerialUIBatchChecks(unittest.TestCase):
    def fixtures(self):
        files = {'telegram-ios/fixture' + suffix: 'a' * 64 for suffix in REQUIRED_SOURCE_SUFFIXES}
        files.update({name: 'a' * 64 for name in COMMON_SOURCES})
        files.update({name: 'a' * 64 for paths in VISUAL_SOURCES.values() for name in paths})
        canonical = ''.join(sha + '  ' + name + '\n' for name, sha in sorted(files.items()))
        sources = {'format': 'exteraless-ui-domain-sources/1', 'files': files,
                   'sha256': hashlib.sha256(canonical.encode()).hexdigest()}
        packaging = {'ipaSha256': 'b' * 64, 'clientSourcePatches': {'source_fingerprint': 'c' * 64}}
        build = {'status': 'built', 'configuration': 'debug_sim_arm64', 'packaging': packaging,
                 'domainSources': sources, 'buildSelection': BUILD_SELECTION}
        identity = {'nativePlanSha256': 'f' * 64, 'harnessInputsSha256': '1' * 64,
                    'stagingSourceSha256': '2' * 64, 'ipaSha256': packaging['ipaSha256']}
        case = {'class': 'FixtureTests', 'source': 'Tests/Fixture.swift', 'methods': ['testOne', 'testTwo']}
        target = {'label': '//Tests:Fixture', 'host': '//Tests:Host', 'host_bundle_id': 'fixture.Host', 'classes': [case]}
        plan = {'source_fingerprint': identity['nativePlanSha256'], 'targets': [target],
                'contract': {'logic_seconds': 30, 'preparation_seconds': 180}}
        build.update(acceptanceIdentity=identity, nativeTestPlan=plan, driverSha256='3' * 64)
        tests = {'status': 'passed', 'native_execution_verified': True, 'configuration': 'debug_sim_arm64',
                 'source_fingerprint': plan['source_fingerprint'], 'acceptanceIdentity': identity, 'passed_methods': 2,
                 'classes': [dict(case, target=target['label'], host=target['host'], host_bundle_id=target['host_bundle_id'],
                                  started_methods=case['methods'], passed_methods=case['methods'],
                                  logic_seconds=2, preparation_seconds=5)]}
        def batch(names, name):
            return {'status': 'recorded-awaiting-visual-review', 'semanticPassed': True,
                     'ownedDeviceDeleted': True, 'visualReview': 'pending-recorded-frame-review',
                    'requestedScenarios': list(names), 'batch': name, 'processLimit': 3,
                    'buildSelection': BUILD_SELECTION,
                    'bundle': copy.deepcopy(packaging),
                    'scenarios': [{'scenario': name, 'semanticPassed': True, 'processSeconds': 2.0} for name in names],
                    'recordings': [{'scenario': name, 'frameCount': 3} for name in names]}
        baseline, domains = batch(BASELINE, 'baseline-3'), batch(DOMAINS, 'domains-3')
        visuals = batch(FINAL_VISUALS, 'final-visuals-2')
        domains['domainSources'] = sources
        visuals['domainSources'] = sources
        native_sha = hashlib.sha256((json.dumps(tests, indent=2, sort_keys=True) + '\n').encode()).hexdigest()
        receipts = [{'schema': 1, 'acceptanceIdentity': copy.deepcopy(identity), 'nativeResultsSha256': native_sha,
                     'nativeEvidence': verify_native_results(tests, plan, identity), 'requestedScenarios': list(names),
                     'batch': name, 'driverSha256': build['driverSha256'], 'domainSources': sources}
                    for name, names in (('baseline-3', BASELINE), ('domains-3', DOMAINS), ('final-visuals-2', FINAL_VISUALS))]
        return build, tests, baseline, domains, visuals, receipts

    def test_all_original_and_domain_cases_share_one_ipa_but_no_visual_pass(self):
        result = verify(*self.fixtures())
        self.assertEqual([batch['scenarios'] for batch in result['batches']],
                         [list(BASELINE), list(DOMAINS), list(FINAL_VISUALS)])
        self.assertEqual(result['processDeadlineSeconds'], 30)
        self.assertEqual(result['visualReview'], 'pending-recorded-frame-review')

    def test_missing_baseline_case_changed_ipa_and_long_process_are_rejected(self):
        for mutation in ('missing', 'ipa', 'deadline', 'cleanup', 'native-tests'):
            build, tests, baseline, domains, visuals, receipts = self.fixtures()
            if mutation == 'missing': baseline['scenarios'].pop()
            elif mutation == 'ipa': domains['bundle']['ipaSha256'] = 'd' * 64
            elif mutation == 'deadline': domains['scenarios'][0]['processSeconds'] = 30.01
            elif mutation == 'cleanup': baseline['ownedDeviceDeleted'] = False
            else: tests['native_execution_verified'] = False
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                verify(build, tests, baseline, domains, visuals, receipts)

    def test_domain_manifest_cannot_come_from_a_different_build(self):
        build, tests, baseline, domains, visuals, receipts = self.fixtures()
        domains['domainSources'] = copy.deepcopy(domains['domainSources'])
        domains['domainSources']['sha256'] = 'd' * 64
        with self.assertRaises(ValueError):
            verify(build, tests, baseline, domains, visuals, receipts)

    def test_final_visual_batch_cannot_be_partial_relabelled_or_from_another_ipa(self):
        for mutation in ('missing-recording', 'requested', 'batch', 'process-limit', 'host', 'ipa', 'sources'):
            build, tests, baseline, domains, visuals, receipts = self.fixtures()
            if mutation == 'missing-recording': visuals['recordings'].pop()
            elif mutation == 'requested': visuals['requestedScenarios'].reverse()
            elif mutation == 'batch': visuals['batch'] = 'domains-3'
            elif mutation == 'process-limit': visuals['processLimit'] = 4
            elif mutation == 'host': visuals['buildSelection'] = dict(BUILD_SELECTION, host='other-app')
            elif mutation == 'ipa': visuals['bundle']['ipaSha256'] = 'd' * 64
            else:
                visuals['domainSources'] = copy.deepcopy(visuals['domainSources'])
                visuals['domainSources']['sha256'] = 'd' * 64
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                verify(build, tests, baseline, domains, visuals, receipts)

    def test_built_manifest_must_include_actual_avatar_and_composer_sources(self):
        build, tests, baseline, domains, visuals, receipts = self.fixtures()
        sources = build['domainSources']
        sources['files'].pop('telegram-ios/submodules/Display/Source/ImageNode.swift')
        canonical = ''.join(sha + '  ' + name + '\n' for name, sha in sorted(sources['files'].items()))
        sources['sha256'] = hashlib.sha256(canonical.encode()).hexdigest()
        with self.assertRaisesRegex(ValueError, 'Missing compiled visual-family'):
            verify(build, tests, baseline, domains, visuals, receipts)

    def test_passed_flag_cannot_replace_complete_native_method_evidence(self):
        for mutation in ('zero', 'partial', 'unstarted', 'duplicate', 'count', 'identity'):
            build, tests, baseline, domains, visuals, receipts = self.fixtures()
            if mutation == 'zero': tests['classes'] = []
            elif mutation == 'partial': tests['classes'][0]['passed_methods'] = ['testOne']
            elif mutation == 'unstarted': tests['classes'][0]['started_methods'] = []
            elif mutation == 'duplicate': tests['classes'].append(copy.deepcopy(tests['classes'][0]))
            elif mutation == 'count': tests['passed_methods'] = 0
            else: tests['acceptanceIdentity'] = dict(tests['acceptanceIdentity'], stagingSourceSha256='4' * 64)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                verify(build, tests, baseline, domains, visuals, receipts)

    def test_every_batch_is_bound_to_staging_driver_and_native_evidence(self):
        for mutation in ('missing', 'staging', 'native', 'driver', 'baseline-sources'):
            build, tests, baseline, domains, visuals, receipts = self.fixtures()
            if mutation == 'missing': receipts.pop()
            elif mutation == 'staging': receipts[2]['acceptanceIdentity']['stagingSourceSha256'] = '4' * 64
            elif mutation == 'native': receipts[2]['nativeResultsSha256'] = '4' * 64
            elif mutation == 'driver': receipts[2]['driverSha256'] = '4' * 64
            else: receipts[0]['domainSources'] = {}
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                verify(build, tests, baseline, domains, visuals, receipts)

    def test_third_batch_cannot_reuse_either_previous_simulator(self):
        devices = [{'udid': f'00000000-0000-0000-0000-{number:012d}'} for number in (1, 2, 3)]
        verify_devices(devices)
        for index in (0, 1):
            repeated = copy.deepcopy(devices)
            repeated[2] = repeated[index]
            with self.assertRaisesRegex(ValueError, 'fresh simulator'):
                verify_devices(repeated)

    def test_both_shipping_modules_need_debug_in_actual_compile_arguments(self):
        graph = {'targets': [{'id': 1, 'label': '//submodules/TelegramCore:TelegramCore'},
                             {'id': 2, 'label': '//submodules/TelegramUI:TelegramUI'}],
                 'actions': [{'targetId': 1, 'mnemonic': 'SwiftCompile', 'arguments': ['swiftc', '-DDEBUG']},
                             {'targetId': 2, 'mnemonic': 'SwiftCompile', 'paramFiles': [{'arguments': ['-D', 'DEBUG']}]}]}
        with tempfile.TemporaryDirectory(prefix='domain-debug-declaration-') as temporary:
            path = Path(temporary) / 'actions.json'
            path.write_text(json.dumps(graph))
            self.assertEqual(len(validate_domain_debug_actions(path)['debug_modules']), 2)
            graph['actions'][1]['paramFiles'][0]['arguments'] = ['-DNDEBUG']
            path.write_text(json.dumps(graph))
            with self.assertRaisesRegex(ValueError, 'require DEBUG'):
                validate_domain_debug_actions(path)


if __name__ == '__main__':
    unittest.main()
