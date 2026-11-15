"""Small source/packaging fixtures: no plugin imports, compiler or simulator."""

import copy
import json
from pathlib import Path
import plistlib
import shutil
import struct
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
sys.path.insert(0, str(ROOT / 'telegram-ios/build-system/Make'))
from prepare_telegram_runtime import application_resources, compatibility_manifest, copy_assets, inventory, source_inventory, stage_support
from RuntimePackaging import EXTENSIONS, NATIVE_SOURCES, load_staging_manifest, validate_runtime_actions, verify_runtime_ipa
from support import digest, read_lock
from vendor_dependencies import bundle_hash
from ClientSourcePatches import prepare_client_sources
from test_client_source_patches import create_fixture


def macho(platform=2, loads=(), rpaths=(), install_name=None, filetype=6):
    commands = [struct.pack('<6I', 0x32, 24, platform, 0xF0000, 0x1B0000, 0)]

    def string_command(kind, value, base):
        data = value.encode('utf-8') + b'\0'
        size = (base + len(data) + 7) & ~7
        prefix = struct.pack('<3I', kind, size, base) + bytes(base - 12)
        return prefix + data + bytes(size - base - len(data))

    commands.extend(string_command(0xC, value, 24) for value in loads)
    commands.extend(string_command(0x8000001C, value, 12) for value in rpaths)
    if install_name is not None:
        commands.append(string_command(0xD, install_name, 24))
    return struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, filetype,
                       len(commands), sum(map(len, commands)), 0, 0) + b''.join(commands)


class TelegramPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='telegram-runtime-packaging-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.lock = copy.deepcopy(read_lock())
        self.lock['required_extensions'] = ['_ssl', '_sqlite3']
        self.framework = self.root / 'Python.xcframework'
        self.write(self.framework / 'lib/python3.12/encodings/__init__.py', b'# stdlib fixture\n')
        self.write(self.framework / 'lib/python3.12/test/test_os.py', b'raise RuntimeError("never execute")\n')
        self.write(self.framework / 'lib/python3.12/unittest/__init__.py', b'# public stdlib\n')
        self.write(self.framework / 'lib/python3.12/unittest/test/test_case.py', b'# CPython tests\n')
        self.write(self.framework / 'lib/python3.12/config-3.12-ios/Makefile', b'build only')
        self.write(self.framework / 'build/iOS-dylib-Info-template.plist', plistlib.dumps({'CFBundlePackageType': 'FMWK'}))
        for target, spec in self.lock['slices'].items():
            folder = self.framework / spec['library']
            self.write(folder / 'Python.framework/Python', macho(spec['platform_id'], install_name='@rpath/Python.framework/Python'))
            self.write(folder / 'Python.framework/Info.plist', plistlib.dumps({'CFBundleExecutable': 'Python'}))
            self.write(folder / 'Python.framework/Headers/Python.h', b'/* compile input */')
            self.write(folder / 'Python.framework/Headers/internal/pycore_interp.h', b'/* private compile input */')
            for module in ('_ssl', '_sqlite3', '_testcapi'):
                suffix = '.cpython-312-' + spec['sdk'] + '.so'
                self.write(folder / ('lib-arm64/python3.12/lib-dynload/' + module + suffix),
                           macho(spec['platform_id'], loads=['@rpath/Python.framework/Python'], filetype=8))
        self.support = self.root / 'support'
        self.targets = stage_support(self.framework, self.support, self.lock, 'com.example.telegram', expected_count=2)
        self.assets = self.root / 'assets'
        for package in ('virtualjava', 'sdk', 'exteraless_runtime'):
            self.write(self.assets / 'python' / package / '__init__.py', b'# asset fixture\n')
        self.write(self.assets / 'python/compat-manifest.json', b'{"classes":{}}\n')
        vendor = self.assets / 'python/vendor'
        self.write(vendor / 'certifi/__init__.py', b'# pure dependency\n')
        self.write(vendor / 'certifi/tests/test_certify.py', b'raise AssertionError("data only")\n')
        files = {name: {'sha256': sha, 'size': (vendor / name).stat().st_size}
                 for name, sha in inventory(vendor).items()}
        packages = [{'name': 'certifi', 'version': '1.0', 'sha256': 'b' * 64}]
        self.dependencies = {'lock_sha256': 'a' * 64, 'bundle_sha256': bundle_hash('a' * 64, files),
                             'packages': packages}
        self.write(vendor / 'exteraless-dependencies.json', json.dumps(dict(self.dependencies,
            schema=1, generator='exteraless-pure-python-dependencies-v1', python='3.12', files=files)).encode())
        self.manifest = {'actual_cpython': '3.12.16', 'support': {'sha256': self.lock['sha256']},
                         'targets': self.targets, 'assets': inventory(self.assets), 'dependencies': self.dependencies}

    def write(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def test_relocated_bazel_inputs_include_the_exported_font_fixture_and_all_core_host_sources(self):
        files = {path.as_posix() for path in source_inventory(ROOT)}
        fixture = 'swift/ExteralessCore/Tests/ExteralessCoreTests/EmojiFontFixture.swift'
        self.assertIn(fixture, files)
        for package in ('ExteralessCore', 'PluginHost', 'PluginHooks'):
            sources = {path.relative_to(ROOT).as_posix()
                       for path in (ROOT / 'swift' / package / 'Sources').rglob('*.swift')}
            self.assertTrue(sources)
            self.assertFalse(sources - files)
        self.assertFalse(any(name.startswith('resources/') for name in files))

    def app(self, target='device'):
        app = self.support / target / 'app'
        platform = self.lock['slices'][target]['platform_id']
        shutil.copytree(self.assets, app, dirs_exist_ok=True)
        ui = '@rpath/TelegramUIFramework.framework/TelegramUIFramework'
        core = '@rpath/TelegramCoreFramework.framework/TelegramCoreFramework'
        self.write(app / 'Telegram', macho(platform, loads=[ui, core], rpaths=['@executable_path/Frameworks'], filetype=2))
        self.write(app / 'Info.plist', plistlib.dumps({'CFBundleExecutable': 'Telegram'}))
        self.write(app / 'Frameworks/TelegramUIFramework.framework/TelegramUIFramework',
                   macho(platform, loads=['@rpath/Python.framework/Python', core],
                         rpaths=['@loader_path/..'], install_name=ui))
        self.write(app / 'Frameworks/TelegramCoreFramework.framework/TelegramCoreFramework',
                   macho(platform, rpaths=['@executable_path/Frameworks'], install_name=core))
        for name in EXTENSIONS:
            bundle = app / 'PlugIns' / (name + '.appex')
            # Mirror the real graph: Widget/Siri use Core, the other four UI.
            loads = [core] if name in ('WidgetExtension', 'IntentsExtension') else [ui]
            self.write(bundle / name, macho(platform, loads=loads,
                                           rpaths=['@executable_path/Frameworks', '@executable_path/../../Frameworks'], filetype=2))
            self.write(bundle / 'Info.plist', plistlib.dumps({'CFBundleExecutable': name}))
        return app

    def archive(self, app):
        path = self.root / 'Telegram.ipa'
        with zipfile.ZipFile(path, 'w') as archive:
            for item in sorted(app.rglob('*')):
                if item.is_file():
                    archive.write(item, 'Payload/Telegram.app/' + item.relative_to(app).as_posix())
        return path

    def test_real_resource_layout_and_all_six_extension_load_paths(self):
        app = self.app()
        report = verify_runtime_ipa(self.archive(app), self.manifest)
        self.assertEqual(len(report['extensions']), 6)
        self.assertTrue(report['extensions']['ShareExtension']['loads_python'])
        self.assertFalse(report['extensions']['WidgetExtension']['loads_python'])
        self.assertFalse(report['runtime_execution_verified'])
        self.assertTrue((self.support / 'device/Headers/internal/pycore_interp.h').is_file())
        self.assertFalse((app / 'Frameworks/Python.framework/Headers').exists())
        self.assertFalse((app / 'python-stdlib/lib/python3.12/test').exists())
        self.assertFalse((app / 'python-stdlib/lib/python3.12/unittest/test').exists())
        self.assertFalse((app / 'python-stdlib/lib/python3.12/config-3.12-ios').exists())
        self.assertTrue((app / 'python-stdlib/lib/python3.12/unittest/__init__.py').is_file())

    def test_simulator_markers_and_platform_are_distinct(self):
        app = self.app('simulator')
        report = verify_runtime_ipa(self.archive(app), self.manifest, 'simulator')
        self.assertEqual(report['target'], 'simulator')
        self.assertTrue((app / 'python-stdlib/lib/python3.12/lib-dynload/_ssl.cpython-312-iphonesimulator.fwork').is_file())
        self.assertFalse((app / 'python-stdlib/lib/python3.12/lib-dynload/_ssl.cpython-312-iphoneos.fwork').exists())

    def test_missing_framework_is_rejected_even_with_intact_markers(self):
        app = self.app()
        (app / 'Frameworks/_ssl.framework/_ssl').unlink()
        with self.assertRaises(KeyError):
            verify_runtime_ipa(self.archive(app), self.manifest)

    def test_changed_sdk_source_is_rejected(self):
        app = self.app()
        (app / 'python/sdk/__init__.py').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'differs from Bazel staging'):
            verify_runtime_ipa(self.archive(app), self.manifest)

    def test_pinned_adguard_data_and_license_are_present_as_exact_source_bytes(self):
        resources = application_resources(ROOT / 'telegram-ios')
        self.assertEqual(resources['adguard_url_tracking.txt']['sha256'],
                         '06098fad1d9ee93ce294223206d9cb4b4c180df7a356eb563fa64e775e36cdfc')
        self.assertEqual(resources['adguard_url_tracking.txt']['size'], 184303)
        self.assertIn('adguard_url_tracking.LICENSE.txt', resources)

    def test_application_resource_is_hashed_and_must_be_at_the_main_bundle_root(self):
        app = self.app()
        name = 'adguard_url_tracking.txt'
        self.write(app / name, b'! licensed fixture\n$removeparam=fixture\n')
        manifest = dict(self.manifest, application_resources={name: {
            'source': 'Resources/' + name, 'size': (app / name).stat().st_size, 'sha256': digest(app / name),
        }})
        self.assertIn(name, verify_runtime_ipa(self.archive(app), manifest)['application_resources'])
        self.write(app / 'Nested' / name, (app / name).read_bytes())
        (app / name).unlink()
        with self.assertRaisesRegex(ValueError, 'main bundle root'):
            verify_runtime_ipa(self.archive(app), manifest)
        self.write(app / name, b'x' * manifest['application_resources'][name]['size'])
        (app / 'Nested' / name).unlink()
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            verify_runtime_ipa(self.archive(app), manifest)

    def test_vendor_copy_preserves_its_sealed_inventory(self):
        copied = self.root / 'copied-assets'
        copy_assets(self.assets, copied)
        self.assertEqual(inventory(self.assets / 'python/vendor'), inventory(copied / 'python/vendor'))

    def test_pruned_vendor_cannot_pass_with_a_self_consistent_outer_inventory(self):
        app = self.app()
        name = 'python/vendor/certifi/tests/test_certify.py'
        (app / name).unlink()
        self.manifest['assets'].pop(name)
        with self.assertRaisesRegex(ValueError, 'Sealed dependency file inventory mismatch'):
            verify_runtime_ipa(self.archive(app), self.manifest)

    def test_vendor_lock_must_match_the_staging_provenance(self):
        app = self.app()
        self.manifest['dependencies']['lock_sha256'] = 'c' * 64
        with self.assertRaisesRegex(ValueError, 'Dependency manifest disagrees'):
            verify_runtime_ipa(self.archive(app), self.manifest)

    def test_invalid_origin_is_rejected(self):
        app = self.app()
        (app / 'Frameworks/_ssl.framework/_ssl.origin').write_text('python/not-a-marker.py\n')
        with self.assertRaisesRegex(ValueError, 'Invalid framework origin'):
            verify_runtime_ipa(self.archive(app), self.manifest)

    def test_resource_copy_in_shared_framework_is_rejected(self):
        app = self.app()
        self.write(app / 'Frameworks/TelegramUIFramework.framework/python-stdlib/lib/python3.12/os.py', b'# wrong owner')
        with self.assertRaisesRegex(ValueError, 'outside the main app'):
            verify_runtime_ipa(self.archive(app), self.manifest)

    def test_c_bridge_cannot_arrive_as_a_dynamic_runfile(self):
        app = self.app()
        self.write(app / 'Frameworks/TelegramUIFramework.framework/_solib/lib_CPythonRuntimeImplementation.so', macho())
        with self.assertRaisesRegex(ValueError, 'statically linked'):
            verify_runtime_ipa(self.archive(app), self.manifest)

    def test_extension_needs_host_rpath_even_if_main_application_is_valid(self):
        app = self.app()
        self.write(app / 'PlugIns/ShareExtension.appex/ShareExtension',
                   macho(loads=['@rpath/TelegramUIFramework.framework/TelegramUIFramework'],
                         rpaths=['@executable_path/Frameworks'], filetype=2))
        with self.assertRaisesRegex(ValueError, 'Extension cannot resolve'):
            verify_runtime_ipa(self.archive(app), self.manifest)

    def test_transitive_dependency_must_be_resolvable(self):
        app = self.app()
        self.write(app / 'Frameworks/_ssl.framework/_ssl', macho(loads=['@rpath/Missing.framework/Missing']))
        with self.assertRaisesRegex(ValueError, 'Unresolved embedded dependency'):
            verify_runtime_ipa(self.archive(app), self.manifest)

    def graph(self):
        labels = ['@@exteraless+//python/runtime:_CPythonRuntimeImplementation',
                  '@@exteraless+//swift/PluginHost:PluginHost', '@@exteraless+//swift/PluginHooks:PluginHooks',
                  '//Telegram:Telegram', '//Telegram:TelegramUIFramework']
        actions = [{'targetId': 0, 'mnemonic': 'CppCompile', 'arguments': ['clang', '-c', 'external/exteraless/python/runtime/' + name]}
                   for name in NATIVE_SOURCES]
        actions += [{'targetId': 1, 'mnemonic': 'SwiftCompile', 'paramFiles': [{'arguments': [
            'Sources/CPythonXCFrameworkEngine.swift', 'Sources/NativeBridgeBinding.swift', 'Sources/PluginHost.swift']} ]},
                    {'targetId': 2, 'mnemonic': 'SwiftCompile', 'arguments': ['Sources/Hooks.swift']},
                    {'targetId': 4, 'mnemonic': 'ObjcLink', 'arguments': ['-Wl,-rpath,@loader_path/..']}]
        actions += [{'targetId': 3, 'mnemonic': 'ImportedDynamicFrameworkProcessor', 'arguments': [
            '--framework_binary', 'support/device/app/Frameworks/{0}.framework/{0}'.format(name), '--disable_signing']}
                    for name in ('Python', '_sqlite3', '_ssl')]
        return {'targets': [{'id': index, 'label': label} for index, label in enumerate(labels)], 'actions': actions}

    def test_preflight_requires_source_compiles_and_main_framework_imports(self):
        path = self.root / 'actions.json'
        graph = self.graph()
        path.write_text(json.dumps(graph))
        self.assertEqual(validate_runtime_actions(path, self.manifest)['status'], 'valid')
        graph['actions'] = [action for action in graph['actions'] if not any(
            arg.endswith('/cpython312_compat.c') for arg in action.get('arguments', []))]
        path.write_text(json.dumps(graph))
        with self.assertRaisesRegex(RuntimeError, 'cpython312_compat.c'):
            validate_runtime_actions(path, self.manifest)

    def test_preflight_requires_the_client_core_module_when_staged(self):
        manifest = dict(self.manifest, client_core_module='ExteralessCore')
        graph = self.graph()
        path = self.root / 'core-actions.json'
        path.write_text(json.dumps(graph))
        with self.assertRaisesRegex(RuntimeError, 'ExteralessCore'):
            validate_runtime_actions(path, manifest)
        graph['targets'].append({'id': 5, 'label': '@@exteraless+//swift/ExteralessCore:ExteralessCore'})
        graph['actions'].append({'targetId': 5, 'mnemonic': 'SwiftCompile', 'arguments': ['Sources/ClientSettings.swift']})
        path.write_text(json.dumps(graph))
        self.assertEqual(validate_runtime_actions(path, manifest)['status'], 'valid')

    def test_custom_native_framework_uses_its_manifest_paths_and_dynamic_count(self):
        from native_dependencies import install_extension
        app = self.app()
        source = self.root / '_image.cpython-312-iphoneos.so'
        source.write_bytes(macho(loads=['@rpath/Python.framework/Python'], filetype=8))
        entry = install_extension(source, 'fixture/' + source.name, app,
                                  {'name': 'fixture', 'version': '1.0', 'import_roots': ['fixture']},
                                  'device', 'com.example')
        manifest = copy.deepcopy(self.manifest)
        manifest['targets']['device']['native_frameworks'] = [entry]
        manifest['native_dependency_lock_sha256'] = 'f' * 64
        policy = {'schema': 1, 'generator': 'exteraless-native-dependencies-v1',
                  'lock_sha256': 'f' * 64, 'support_sha256': manifest['support']['sha256'],
                  'actual_cpython': '3.12.16', 'target': 'device',
                  'frameworks': [entry], 'admitted_packages': ['fixture']}
        self.write(app / 'python/native-dependencies.json', json.dumps(policy).encode())
        for name in (entry['marker'], 'python/native-dependencies.json'):
            manifest['targets']['device']['resources'][name] = digest(app / name)
        report = verify_runtime_ipa(self.archive(app), manifest)
        self.assertEqual(len(report['frameworks']), 4)
        self.assertIn(entry['framework'], report['frameworks'])
        (app / entry['origin']).write_text('python/wrong.fwork\n')
        with self.assertRaisesRegex(ValueError, 'Broken native PEP 730'):
            verify_runtime_ipa(self.archive(app), manifest)

    def test_compatibility_manifest_is_deterministic_source_data(self):
        source = self.root / 'source'
        seed = source / 'telegram-ios/build-system/exteraless/compat-classes.txt'
        self.write(seed, b'org.example.Api\norg.example.Missing\n')
        java = source / 'third_party/exteraless-android/TMessagesProj/src/main/java/org/example/Api.java'
        self.write(java, b'package org.example; public class Api { public int color; public void send() {} }')
        for name in ('javaapi.py', 'corpus.py'):
            self.write(source / 'tools/compat' / name, (ROOT / 'tools/compat' / name).read_bytes())
        # No Python file outside the source packages is imported or evaluated.
        self.write(source / 'third_party/corpus/all/fixture.plugin', b'raise AssertionError("never execute")')
        first = compatibility_manifest(source)
        self.assertEqual(first, compatibility_manifest(source))
        self.assertEqual(first['classes']['org.example.Api']['declared']['fields'], ['color'])
        self.assertIsNone(first['classes']['org.example.Missing']['declared'])
        self.assertNotIn('plugins', first)
        self.assertFalse(any(Path(name).is_absolute() for name in first['source_files']))
        self.write(java, b'package org.example; public class Api { public int changed; }')
        self.assertEqual(compatibility_manifest(source)['classes']['org.example.Api']['declared']['fields'], ['changed'])

    def test_local_build_refuses_staging_from_before_a_source_edit(self):
        checkout = self.root / 'checkout'
        base = checkout / 'telegram-ios'
        stage = base / 'build-input/exteraless'
        name = 'swift/PluginHost/Sources/PluginHost/Example.swift'
        self.write(checkout / name, b'// source version one\n')
        self.write(stage / name, (checkout / name).read_bytes())
        self.write(checkout / 'tools/runtime/prepare_telegram_runtime.py', b'# checkout marker\n')
        create_fixture(base)
        client_patches = prepare_client_sources(base)
        manifest = {'generator': 'exteraless-telegram-runtime-v1', 'actual_cpython': '3.12.16',
                    'targets': {target: {'architecture': 'arm64', 'extension_frameworks': list(range(54))}
                                for target in ('device', 'simulator')},
                    'files': inventory(stage), 'source_files': {name: digest(checkout / name)},
                    'client_source_patches': client_patches}
        for group in ('input_sha256', 'postimage_sha256'):
            manifest['source_files'].update({'telegram-ios/' + key: sha for key, sha in client_patches[group].items()})
        self.write(stage / 'runtime-staging.json', json.dumps(manifest).encode())
        self.assertEqual(load_staging_manifest(base)['actual_cpython'], '3.12.16')
        metadata = base / 'build-system/exteraless-patches/manifest.json'
        original = metadata.read_bytes()
        metadata.write_bytes(original + b'\n')
        with self.assertRaisesRegex(RuntimeError, 'patch provenance changed'):
            load_staging_manifest(base)
        metadata.write_bytes(original)
        self.write(checkout / name, b'// source version two\n')
        with self.assertRaisesRegex(RuntimeError, 'Runtime source changed'):
            load_staging_manifest(base)
        self.write(stage / 'unexpected.swift', b'// unrecorded Bazel glob input\n')
        with self.assertRaisesRegex(RuntimeError, 'file inventory changed'):
            load_staging_manifest(base)

    def test_app_artifact_requires_and_carries_client_patch_identity(self):
        base = self.root / 'client'
        create_fixture(base)
        proof = prepare_client_sources(base)
        manifest = dict(self.manifest, generator='exteraless-telegram-runtime-v1')
        archive = self.archive(self.app())
        with self.assertRaisesRegex(ValueError, 'Missing or stale client source patch'):
            verify_runtime_ipa(archive, manifest)
        manifest['client_source_patches'] = proof
        result = verify_runtime_ipa(archive, manifest)
        self.assertEqual(result['client_source_patches'], proof)


if __name__ == '__main__':
    unittest.main()
