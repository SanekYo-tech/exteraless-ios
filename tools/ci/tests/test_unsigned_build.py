"""Small build-plumbing tests: no plugin code, macOS SDK, or Bazel build runs."""

import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
MAKE_ROOT = ROOT / 'telegram-ios/build-system/Make'
sys.path.insert(0, str(MAKE_ROOT))
# VM orchestration is macOS-only (fcntl); it is not part of the build wrapper
# being exercised here. Do not mock signing resolution or argument generation.
with patch.dict(sys.modules, {'TartBuild': types.ModuleType('TartBuild')}):
    spec = importlib.util.spec_from_file_location('telegram_make', MAKE_ROOT / 'Make.py')
    make = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(make)

from UnsignedBuild import prepare_unsigned_rules, validate_unsigned_actions


class UnsignedBuildTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='exteraless-unsigned-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def parser(self):
        parser = argparse.ArgumentParser()
        make.add_project_and_build_common_arguments(parser, allow_unsigned=True)
        return parser

    def test_unsigned_is_explicit_and_excludes_signing_material(self):
        args = self.parser().parse_args(['--configurationPath', 'config.json', '--unsigned'])
        self.assertTrue(args.unsigned)
        self.assertIsNone(args.codesigningInformationPath)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.parser().parse_args(['--configurationPath', 'config.json', '--unsigned', '--codesigningInformationPath', 'certs'])

    def test_signed_option_remains_available(self):
        args = self.parser().parse_args(['--configurationPath', 'config.json', '--codesigningInformationPath', 'certs'])
        self.assertFalse(args.unsigned)
        self.assertEqual(args.codesigningInformationPath, 'certs')

    def test_unsigned_does_not_read_certificates_or_profiles(self):
        config = ROOT / 'telegram-ios/build-system/exteraless-configuration.json'
        args = self.parser().parse_args(['--configurationPath', str(config), '--unsigned'])
        profile_dir = self.root / 'build-input/configuration-repository/provisioning'
        profile_dir.mkdir(parents=True)
        (profile_dir / 'stale.mobileprovision').write_bytes(b'not a valid profile')
        with patch.object(make, 'DirectoryCodesigningSource', side_effect=AssertionError('must not read signing files')):
            make.resolve_configuration(str(self.root), types.SimpleNamespace(bazel='/fake/bazel'), args, None)
        variables = (profile_dir.parent / 'variables.bzl').read_text()
        self.assertIn('telegram_use_xcode_managed_codesigning = False', variables)
        self.assertIn('telegram_enable_siri = False', variables)
        self.assertEqual([p.name for p in profile_dir.iterdir()], ['BUILD'])
        self.assertEqual((profile_dir / 'BUILD').read_text(), 'exports_files([\n])\n')

    def command_line(self):
        with patch.object(make, 'BuildEnvironment'):
            return make.BazelCommandLine('/fake/bazel', False, False, None)

    def test_unsigned_enables_both_packaging_guards(self):
        command = self.command_line()
        command.set_unsigned()
        self.assertTrue(command.disable_provisioning_profiles)
        self.assertIn('--features=disable_legacy_signing', command.get_additional_build_arguments())
        self.assertIn('--features=exteraless_unsigned_compilation', command.get_additional_build_arguments())

    def test_signed_build_has_no_unsigned_features(self):
        command = self.command_line()
        self.assertFalse(command.disable_provisioning_profiles)
        self.assertEqual(command.get_additional_build_arguments(), [])

    def test_preflight_and_build_use_the_same_device_configuration(self):
        command = self.command_line()
        command.build_environment.bazel_path = '/fake/bazel'
        command.build_environment.app_version = '13.1.1'
        command.set_configuration('release_arm64')
        command.set_unsigned()
        command.set_build_number(42)
        graph = self.action_graph().read_text()
        queries = []

        def run_query(arguments, stdout, check):
            queries.append(arguments)
            stdout.write(graph)

        previous = Path.cwd()
        try:
            os.chdir(self.root)
            with patch.object(make.subprocess, 'run', side_effect=run_query), patch.object(make, 'call_executable') as run_build:
                command.invoke_build()
            actual_build = run_build.call_args.args[0]
        finally:
            os.chdir(previous)
        self.assertEqual(len(queries), 1)
        for flag in ('--ios_multi_cpus=arm64', '--//Telegram:disableProvisioningProfiles',
                     '--features=disable_legacy_signing', '--features=exteraless_unsigned_compilation',
                     '--output_groups=+dsyms,+dossier'):
            self.assertIn(flag, queries[0])
            self.assertIn(flag, actual_build)
        self.assertIn('deps(//Telegram:Telegram)', queries[0])
        self.assertIn('--nobuild', queries[0])
        self.assertIn('Telegram/Telegram', actual_build)
        self.assertNotIn('--nobuild', actual_build)

    def rules_fixture(self):
        rules = self.root / 'build-system/bazel-rules/rules_apple'
        source = rules / 'apple/internal/ios_rules.bzl'
        source.parent.mkdir(parents=True)
        original = ROOT / 'telegram-ios/build-system/bazel-rules/rules_apple/apple/internal/ios_rules.bzl'
        source.write_text(original.read_text(encoding='utf-8'), encoding='utf-8', newline='\n')
        target = self.root / 'build-system/patches/unsigned-rules-apple.patch'
        target.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / 'telegram-ios/build-system/patches/unsigned-rules-apple.patch', target)
        return source

    def test_patch_applies_to_pinned_rules_and_is_idempotent(self):
        source = self.rules_fixture()
        prepare_unsigned_rules(self.root)
        first = source.read_bytes()
        prepare_unsigned_rules(self.root)
        self.assertEqual(first, source.read_bytes())
        self.assertEqual(first.count(b'exteraless_unsigned_compilation'), 6)

    def test_patch_refuses_a_different_upstream_source(self):
        source = self.rules_fixture()
        source.write_text(source.read_text(encoding='utf-8') + '\n# changed upstream\n', encoding='utf-8')
        with self.assertRaisesRegex(RuntimeError, 'review the patch'):
            prepare_unsigned_rules(self.root)

    def action_graph(self, signing=False):
        targets = ['Telegram', 'ShareExtension', 'NotificationContentExtension',
                   'NotificationServiceExtensionv1', 'IntentsExtension', 'WidgetExtension',
                   'BroadcastUploadExtension']
        path = self.root / 'actions.json'
        path.write_text(json.dumps({
            'targets': [{'id': i, 'label': '//Telegram:' + name} for i, name in enumerate(targets)],
            'actions': [{'targetId': i, 'mnemonic': 'ProcessAndSign', 'arguments': [
                '/bin/bash', 'process-and-sign.sh',
                *(['should_sign'] if signing and i == 5 else []), 'should_compress'
            ]} for i in range(len(targets))],
        }), encoding='utf-8')
        return path

    def test_preflight_checks_main_app_and_extensions(self):
        report = validate_unsigned_actions(self.action_graph())
        self.assertEqual(report['packaging_actions'], 7)
        self.assertTrue((self.root / 'unsigned-preflight.json').is_file())

    def test_preflight_rejects_one_signed_extension(self):
        with self.assertRaisesRegex(RuntimeError, 'WidgetExtension still selects signing'):
            validate_unsigned_actions(self.action_graph(signing=True))

    def test_empty_action_graph_is_not_success(self):
        path = self.root / 'actions.json'
        path.write_text('{}', encoding='utf-8')
        with self.assertRaisesRegex(RuntimeError, 'No ProcessAndSign'):
            validate_unsigned_actions(path)

    def test_copy_only_packaging_action_is_unsigned(self):
        path = self.action_graph()
        graph = json.loads(path.read_text())
        graph['actions'][0]['arguments'] = ['/bin/bash', '-c', "cp -p 'input.zip' 'output.ipa'"]
        path.write_text(json.dumps(graph))
        self.assertEqual(validate_unsigned_actions(path)['signing'], 'unsigned')

    def test_imported_framework_requires_explicit_signing_disable(self):
        path = self.action_graph()
        graph = json.loads(path.read_text())
        graph['actions'].append({'targetId': 0, 'mnemonic': 'ImportedDynamicFrameworkProcessor',
                                 'arguments': ['framework-tool', '--framework_binary', 'Library']})
        path.write_text(json.dumps(graph))
        with self.assertRaisesRegex(RuntimeError, 'framework with signing enabled'):
            validate_unsigned_actions(path)
        graph['actions'][-1]['paramFiles'] = [{'arguments': ['--disable_signing']}]
        path.write_text(json.dumps(graph))
        self.assertEqual(validate_unsigned_actions(path)['imported_framework_actions'], 1)

    def test_template_signing_commands_are_rejected(self):
        path = self.action_graph()
        graph = json.loads(path.read_text())
        graph['actions'].append({'targetId': 0, 'mnemonic': 'TemplateExpand',
                                 'substitutions': [{'key': '%signing_command_lines%', 'value': 'some-signing-tool --identity abc'}]})
        path.write_text(json.dumps(graph))
        with self.assertRaisesRegex(RuntimeError, 'non-empty signing commands'):
            validate_unsigned_actions(path)

    def test_missing_extension_cannot_pass_preflight(self):
        path = self.action_graph()
        graph = json.loads(path.read_text())
        graph['actions'].pop()
        path.write_text(json.dumps(graph))
        with self.assertRaisesRegex(RuntimeError, 'Missing app/extension packaging actions'):
            validate_unsigned_actions(path)


if __name__ == '__main__':
    unittest.main()
