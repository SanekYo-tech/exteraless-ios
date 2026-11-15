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
from verify_client_ui_batches import BASELINE, DOMAINS, verify


class SerialUIBatchChecks(unittest.TestCase):
    def fixtures(self):
        files = {'telegram-ios/fixture' + suffix: 'a' * 64 for suffix in REQUIRED_SOURCE_SUFFIXES}
        canonical = ''.join(sha + '  ' + name + '\n' for name, sha in sorted(files.items()))
        sources = {'format': 'exteraless-ui-domain-sources/1', 'files': files,
                   'sha256': hashlib.sha256(canonical.encode()).hexdigest()}
        packaging = {'ipaSha256': 'b' * 64, 'clientSourcePatches': {'source_fingerprint': 'c' * 64}}
        build = {'status': 'built', 'configuration': 'debug_sim_arm64', 'packaging': packaging, 'domainSources': sources}
        tests = {'status': 'passed', 'native_execution_verified': True}
        def batch(names):
            return {'status': 'recorded-awaiting-visual-review', 'semanticPassed': True,
                    'ownedDeviceDeleted': True, 'visualReview': 'pending-recorded-frame-review',
                    'bundle': copy.deepcopy(packaging),
                    'scenarios': [{'scenario': name, 'semanticPassed': True, 'processSeconds': 2.0} for name in names],
                    'recordings': [{'scenario': name, 'frameCount': 3} for name in names]}
        baseline, domains = batch(BASELINE), batch(DOMAINS)
        domains['domainSources'] = sources
        return build, tests, baseline, domains

    def test_all_original_and_domain_cases_share_one_ipa_but_no_visual_pass(self):
        result = verify(*self.fixtures())
        self.assertEqual([batch['scenarios'] for batch in result['batches']], [list(BASELINE), list(DOMAINS)])
        self.assertEqual(result['processDeadlineSeconds'], 30)
        self.assertEqual(result['visualReview'], 'pending-recorded-frame-review')

    def test_missing_baseline_case_changed_ipa_and_long_process_are_rejected(self):
        for mutation in ('missing', 'ipa', 'deadline', 'cleanup', 'native-tests'):
            build, tests, baseline, domains = self.fixtures()
            if mutation == 'missing': baseline['scenarios'].pop()
            elif mutation == 'ipa': domains['bundle']['ipaSha256'] = 'd' * 64
            elif mutation == 'deadline': domains['scenarios'][0]['processSeconds'] = 30.01
            elif mutation == 'cleanup': baseline['ownedDeviceDeleted'] = False
            else: tests['native_execution_verified'] = False
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                verify(build, tests, baseline, domains)

    def test_domain_manifest_cannot_come_from_a_different_build(self):
        build, tests, baseline, domains = self.fixtures()
        domains['domainSources'] = copy.deepcopy(domains['domainSources'])
        domains['domainSources']['sha256'] = 'd' * 64
        with self.assertRaises(ValueError):
            verify(build, tests, baseline, domains)

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
