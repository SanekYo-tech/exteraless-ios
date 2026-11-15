"""Small loading, staging-identity and test-host resource regression fixtures."""

import ast
import copy
import hashlib
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from client_ui_harness_inputs import acceptance_identity, require_build_identity
from native_test_plan import digest, glob_sources
from native_test_resources import verify_test_host_resources


class NativeInputIdentityChecks(unittest.TestCase):
    def test_one_matching_language_does_not_hide_an_empty_bazel_pattern(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            (base / 'Model.swift').write_text('// fixture\n')
            expression = ast.parse('glob(["*.swift", "*.m"])', mode='eval').body
            with self.assertRaisesRegex(ValueError, r'allow_empty=False.*\*\.m'):
                glob_sources(base, expression)
            optional = ast.parse('glob(["*.swift", "*.m"], allow_empty=True)', mode='eval').body
            self.assertEqual(glob_sources(base, optional), [base / 'Model.swift'])

    def test_glob_respects_subpackages_and_final_exclusions(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            (base / 'nested').mkdir()
            (base / 'nested/BUILD').write_text('')
            (base / 'nested/Other.swift').write_text('// another package\n')
            expression = ast.parse('glob(["**/*.swift"])', mode='eval').body
            with self.assertRaisesRegex(ValueError, 'matches no source'):
                glob_sources(base, expression)
            (base / 'Local.swift').write_text('// local\n')
            excluded = ast.parse('glob(["*.swift"], exclude=["Local.swift"])', mode='eval').body
            with self.assertRaisesRegex(ValueError, 'after exclusions'):
                glob_sources(base, excluded)

    def test_compiled_identity_rejects_source_plan_and_archive_drift(self):
        with tempfile.TemporaryDirectory() as folder:
            ipa = Path(folder) / 'retained.ipa'
            ipa.write_bytes(b'compiled archive fixture')
            plan = {'source_fingerprint': 'a' * 64, 'targets': ['actual declaration fixture']}
            harness = {'fingerprint': 'b' * 64, 'domain_sources': {'source': 'fixture'}}
            staging = {'source_files': {'swift/Source.swift': 'c' * 64}}
            identity = acceptance_identity(plan, harness, staging, digest(ipa))
            build = {'acceptanceIdentity': identity, 'nativeTestPlan': plan,
                     'domainSources': harness['domain_sources'], 'packaging': {'ipaSha256': digest(ipa)}}
            self.assertEqual(require_build_identity(build, plan, harness, staging, ipa), identity)
            changed = copy.deepcopy(staging)
            changed['source_files']['swift/Source.swift'] = 'd' * 64
            with self.assertRaisesRegex(ValueError, 'compiled acceptance snapshot'):
                require_build_identity(build, plan, harness, changed, ipa)
            with self.assertRaises(ValueError):
                require_build_identity(build, dict(plan, targets=[]), harness, staging, ipa)
            ipa.write_bytes(b'a different compiled archive')
            with self.assertRaises(ValueError):
                require_build_identity(build, plan, harness, staging, ipa)

    def test_both_native_and_composer_hosts_require_fonts_not_just_the_main_host(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            resource = base / 'Fonts/Fixture.ttf'
            resource.parent.mkdir()
            resource.write_bytes(b'font fixture')
            record = {'source': 'Fonts/Fixture.ttf', 'size': resource.stat().st_size, 'sha256': digest(resource)}
            contract = {'schema': 1, 'groups': {'fonts': [record], 'monet': []}, 'archives': {}}
            path = base / 'build-system/exteraless/native-bundle-resources.json'
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(contract))
            plan = {'targets': [{'host': '//Tests:' + name, 'host_bundle_id': 'fixture.' + name}
                                for name in ('NativeTestHost', 'ComposerHarness')]}
            def archive(name, font=True):
                path = base / 'bazel-bin/Tests' / (name + '.ipa')
                path.parent.mkdir(parents=True, exist_ok=True)
                root = 'Payload/' + name + '.app/'
                with zipfile.ZipFile(path, 'w') as bundle:
                    bundle.writestr(root + 'Info.plist', plistlib.dumps({'CFBundleIdentifier': 'fixture.' + name}))
                    if font:
                        bundle.writestr(root + 'Fixture.ttf', resource.read_bytes())
                    for asset in ('Assets.car', 'PresentationStrings.data', 'en.lproj/Localizable.strings'):
                        bundle.writestr(root + asset, b'nonempty asset')
            archive('NativeTestHost')
            archive('ComposerHarness')
            self.assertEqual(len(verify_test_host_resources(base, plan)), 2)
            archive('ComposerHarness', font=False)
            with self.assertRaisesRegex(ValueError, 'process bundle root'):
                verify_test_host_resources(base, plan)


if __name__ == '__main__':
    unittest.main()
