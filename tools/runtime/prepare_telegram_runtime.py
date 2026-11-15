"""Prepare declared Bazel inputs for Telegram's embedded CPython runtime.

The only download is support-lock.json's SHA-256-pinned archive. This copies
repository sources and stages both supported slices before Bazel analysis;
ios_application and ImportedDynamicFrameworkProcessor perform IPA packaging.
No compiler, plugin, interpreter probe, signing tool or IPA rewrite is run.
"""

import argparse
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tarfile
import tempfile

from support import digest, download, inspect_archive, read_lock, stage_application
from vendor_dependencies import vendor as vendor_dependencies, verify_bundle as verify_dependency_bundle
from native_dependencies import stage_application_policy


ROOT = Path(__file__).resolve().parents[2]
GENERATOR = 'exteraless-telegram-runtime-v1'
CPYTHON_VERSION = '3.12.16'
EXTENSION_COUNT = 54
SEEDS = 'telegram-ios/build-system/exteraless/compat-classes.txt'
SUPPORT_BUILD = 'telegram-ios/third-party/exteraless/runtime.BUILD.bazel'
SOURCE_FILES = (
    'MODULE.bazel', 'BUILD.bazel',
    'swift/PluginHost/BUILD.bazel', 'swift/PluginHooks/BUILD.bazel',
    'swift/ExteralessCore/BUILD.bazel',
    'swift/ExteralessCore/Tests/ExteralessCoreTests/EmojiFontFixture.swift',
    'python/runtime/BUILD.bazel', 'python/runtime/support-lock.json',
    'python/runtime/dependency-lock.json',
    'python/runtime/new-native-dependency-lock.json', 'python/runtime/tl-schema.json',
    'python/runtime/engine.c', 'python/runtime/cpython312_compat.c',
    'python/runtime/cpython312_compat.h', 'python/runtime/register_bridge.c',
    'python/bridge/_exteraless_bridge.c',
)
REQUIRED_FILES = (
    'swift/PluginHost/Sources/PluginHost/CPythonXCFrameworkEngine.swift',
    'swift/PluginHost/Sources/PluginHost/NativeBridgeBinding.swift',
    'swift/PluginHost/Sources/PluginHost/PluginHost.swift',
    'swift/PluginHost/Sources/PluginHost/PythonRuntime.swift',
    'swift/PluginHost/Sources/CPluginHostShims/ph_atomic.c',
    'swift/PluginHost/Sources/CPluginHostShims/include/ph_atomic.h',
    'swift/PluginHooks/Sources/CPluginHookShims/PluginHookGate.c',
    'swift/PluginHooks/Sources/CPluginHookShims/include/PluginHookGate.h',
    'python/runtime/include/EXLPythonEngine.h',
    'python/runtime/include/EXLPythonBridge.h',
    'python/virtualjava/__init__.py', 'python/sdk/base_plugin.py',
    'python/exteraless_runtime/__init__.py',
)
ASSET_PACKAGES = ('virtualjava', 'sdk', 'exteraless_runtime', 'vendor')
EXCLUDED_DIRS = {'__pycache__', 'test', 'tests', 'Tests', '.git', '.pytest_cache'}
BUILD_SUFFIXES = {'.c', '.h', '.a', '.so', '.dylib', '.pyd', '.pyc', '.pyo'}


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + '\n',
                    encoding='utf-8', newline='\n')


def inventory(root):
    return {path.relative_to(root).as_posix(): digest(path)
            for path in sorted(Path(root).rglob('*')) if path.is_file()}


def application_resources(telegram_root):
    """Check tracked client data before Bazel analysis, preserving upstream bytes."""
    root = Path(telegram_root)
    lock = json.loads((root / 'build-system/exteraless/runtime-assets.json').read_text(encoding='utf-8'))
    if lock.get('schema') != 1:
        raise ValueError('Unsupported client resource lock')
    result = {}
    for item in lock['assets']:
        relative = PurePosixPath(item['source'])
        name = item['bundle_path']
        if (relative.is_absolute() or '..' in relative.parts or '\\' in item['source']
                or PurePosixPath(name).name != name or name in result):
            raise ValueError('Invalid client resource path')
        path = root / item['source']
        if (not path.is_file() or path.is_symlink() or path.stat().st_size != item['size']
                or digest(path) != item['sha256']):
            raise ValueError('Pinned client resource mismatch: ' + item['source'])
        result[name] = {key: item[key] for key in ('source', 'size', 'sha256')}
    return result


def source_inventory(source_root):
    files = {Path(name) for name in SOURCE_FILES}
    for folder, suffixes in (
        ('swift/PluginHost/Sources', {'.swift', '.c', '.h'}),
        ('swift/PluginHooks/Sources', {'.swift', '.c', '.h'}),
        ('swift/ExteralessCore/Sources/ExteralessCore', {'.swift'}),
        ('python/runtime/include', {'.h'}),
    ):
        found = [path for path in (source_root / folder).rglob('*')
                 if path.is_file() and path.suffix in suffixes]
        if not found:
            raise ValueError('Missing runtime sources: ' + folder)
        files.update(path.relative_to(source_root) for path in found)
    for name in (*SOURCE_FILES, *REQUIRED_FILES):
        if not (source_root / name).is_file():
            raise ValueError('Missing runtime source: ' + name)
    return sorted(files)


def compatibility_manifest(source_root):
    """Regenerate declaration metadata from versioned sources, with no corpus.

    Use the existing Java/Kotlin parsers, but explicit repository paths rather
    than their environment-dependent source discovery or reference fallbacks.
    Only the requested source files are parsed; no SDK/plugin module is imported.
    """
    sys.path.insert(0, str(source_root))
    from tools.compat import javaapi

    source_root = Path(source_root)
    seed_path = source_root / SEEDS
    names = sorted({line.strip() for line in seed_path.read_text(encoding='utf-8').splitlines()
                    if line.strip() and not line.lstrip().startswith('#')})
    if not names or any(not re.fullmatch(r'[A-Za-z_]\w*(?:[.$][A-Za-z_]\w*)+', name) for name in names):
        raise ValueError('Invalid compatibility declaration seeds')
    inputs = {SEEDS: digest(seed_path)}
    for name in ('tools/compat/javaapi.py', 'tools/compat/corpus.py'):
        inputs[name] = digest(source_root / name)
    base = source_root / 'third_party/exteraless-android/TMessagesProj/src/main'
    parsed = {}
    classes = {}
    for fqcn in names:
        parts = fqcn.split('$', 1)[0].split('.')
        found = None
        for folder, extension, parse in (
            ('java', '.java', javaapi.parse_file),
            ('kotlin', '.java', javaapi.parse_file),
            ('kotlin', '.kt', javaapi._parse_kotlin),
        ):
            for cut in range(len(parts), 0, -1):
                path = (base / folder).joinpath(*parts[:cut]).with_suffix(extension)
                if not path.is_file():
                    continue
                if path not in parsed:
                    parsed[path] = parse(str(path), '.'.join(parts[:cut - 1]))
                    inputs[path.relative_to(source_root).as_posix()] = digest(path)
                found = javaapi._match(parsed[path], fqcn)
                if found is not None:
                    break
            if found is not None:
                break
        declared = None if found is None else {
            'kind': found.kind,
            'fields': sorted(found.fields),
            'methods': {name: len(signatures) for name, signatures in sorted(found.methods.items())},
            'nested': sorted(found.nested),
        }
        classes[fqcn] = {'declared': declared}
    return {'schema': 1, 'kind': 'source-declarations', 'classes': classes,
            'source_files': dict(sorted(inputs.items()))}


def extract_support(archive_path, destination, lock):
    """Extract the verified framework tree, excluding build-only dylib links.

    Omitting the unused testbed and libpython symlinks also permits packaging
    tests on Windows without symlink privileges. Runtime files remain intact.
    """
    prefix = lock['framework'] + '/'
    runtime_prefixes = [prefix + 'lib/python3.12/']
    for spec in lock['slices'].values():
        runtime_prefixes += [prefix + spec['library'] + '/Python.framework/',
                             prefix + spec['library'] + '/lib-' + spec['architecture'] + '/']
    required_files = {prefix + 'Info.plist', prefix + 'build/iOS-dylib-Info-template.plist'}
    with tarfile.open(archive_path, 'r:gz') as archive:
        members = []
        for member in archive.getmembers():
            if not member.name.startswith(prefix):
                continue
            if member.name not in required_files and not any(member.name.startswith(item) for item in runtime_prefixes):
                continue
            parts = PurePosixPath(member.name).parts
            if EXCLUDED_DIRS.intersection(parts) or any(part.startswith('config-3.12-') for part in parts):
                continue
            if member.issym() or member.islnk():
                if PurePosixPath(member.name).name == 'libpython3.12.dylib':
                    continue
                raise ValueError('Unexpected link in runtime support: ' + member.name)
            members.append(member)
        archive.extractall(destination, members=members, filter='data')


def prune_build_resources(home):
    for path in sorted(Path(home).rglob('*'), key=lambda item: len(item.parts), reverse=True):
        if path.is_dir() and (path.name in EXCLUDED_DIRS or path.name.startswith('config-3.12-')):
            shutil.rmtree(path)
        elif path.is_file() and (path.suffix in BUILD_SUFFIXES or path.name == 'Makefile'):
            path.unlink()


def validate_markers(app, extensions):
    markers = sorted((app / 'python-stdlib/lib/python3.12/lib-dynload').glob('*.fwork'))
    found = set()
    for marker in markers:
        module = marker.name.split('.')[0]
        expected = 'Frameworks/{0}.framework/{0}'.format(module)
        if marker.read_text(encoding='utf-8').strip() != expected:
            raise ValueError('Incorrect PEP 730 framework marker: ' + marker.name)
        binary = app / expected
        origin = binary.with_suffix('.origin')
        if not binary.is_file() or origin.read_text(encoding='utf-8').strip() != marker.relative_to(app).as_posix():
            raise ValueError('Incorrect PEP 730 origin: ' + module)
        found.add(module)
    if found != set(extensions) or len(markers) != len(extensions):
        raise ValueError('PEP 730 marker/framework inventory mismatch')


def stage_support(framework, destination, lock, bundle_id, expected_count=EXTENSION_COUNT,
                  native_lock=None, native_bundle=None):
    reports = {}
    modules = None
    for target in ('device', 'simulator'):
        spec = lock['slices'][target]
        folder = destination / target
        app = folder / 'app'
        staged = stage_application(framework, app, target, lock, bundle_id)
        extensions = staged['extension_frameworks']
        if len(extensions) != expected_count or (modules is not None and modules != extensions):
            raise ValueError('Unexpected extension framework inventory for ' + target)
        modules = extensions
        prune_build_resources(app / 'python-stdlib')
        validate_markers(app, extensions)
        # These headers are C compile inputs, outside the application resources.
        headers = framework / spec['library'] / 'Python.framework/Headers'
        shutil.copytree(headers, folder / 'Headers')
        policy = stage_application_policy(app, target, lock_path=native_lock, bundle=native_bundle) if native_lock else None
        if policy and policy['support_sha256'] != lock['sha256']:
            raise ValueError('Native dependency and CPython support pins disagree')
        reports[target] = {
            'architecture': spec['architecture'], 'platform_id': spec['platform_id'],
            'extension_frameworks': extensions,
            'native_frameworks': policy['frameworks'] if policy else [],
            'resources': {name: sha for name, sha in inventory(app).items()
                          if name.startswith(('python-stdlib/', 'python/'))},
        }
    (destination / 'extensions.bzl').write_text(
        '# Generated from the SHA-256-verified support archive.\nEXTENSION_MODULES = ' +
        json.dumps(modules, indent=4) + '\nNATIVE_FRAMEWORKS = ' +
        json.dumps([entry['framework'] for entry in reports['device']['native_frameworks']], indent=4) + '\n',
        encoding='utf-8', newline='\n')
    if ([entry['framework'] for entry in reports['device']['native_frameworks']] !=
            [entry['framework'] for entry in reports['simulator']['native_frameworks']]):
        raise ValueError('Native device/simulator framework inventories must match')
    return reports


def copy_assets(source_root, destination, *, include_vendor=True):
    inputs = {}
    for package in ASSET_PACKAGES:
        if package == 'vendor' and not include_vendor:
            continue
        source = source_root / 'python' / package
        for path in sorted(source.rglob('*')):
            relative = path.relative_to(source)
            if not path.is_file():
                continue
            # Vendor is sealed by its own builder. Preserve the entire inventory,
            # including package data/tests and .dist-info; pruning after sealing
            # leaves the runtime and artifact manifest describing different bytes.
            if package != 'vendor' and (EXCLUDED_DIRS.intersection(relative.parts)
                    or path.suffix in BUILD_SUFFIXES or path.name.startswith('.')):
                continue
            target = destination / 'python' / package / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
            inputs[path.relative_to(source_root).as_posix()] = digest(target)
    return inputs


def prepare(source_root, telegram_root, archive, lock, report_path=None, dependency_cache=None, native_bundle=None):
    source_root, telegram_root = Path(source_root).resolve(), Path(telegram_root).resolve()
    sys.path.insert(0, str(source_root / 'telegram-ios/build-system/Make'))
    from ClientSourcePatches import prepare_client_source_copy
    client_patches = prepare_client_source_copy(source_root / 'telegram-ios', telegram_root)
    if set(lock['slices']) != {'device', 'simulator'}:
        raise ValueError('Only the locked device/simulator targets are supported')
    if any(spec['architecture'] != 'arm64' for spec in lock['slices'].values()):
        raise ValueError('Only arm64 runtime targets are supported')
    if lock.get('actualCPython', CPYTHON_VERSION) != CPYTHON_VERSION:
        raise ValueError('Review the C compatibility layer before changing CPython')
    sources = source_inventory(source_root)
    client_assets = application_resources(telegram_root)
    compat = compatibility_manifest(source_root)
    support_report = inspect_archive(archive, lock)
    if any(item['python'] != CPYTHON_VERSION for item in support_report['slices'].values()):
        raise ValueError('Pinned runtime must supply CPython {} headers for both slices'.format(CPYTHON_VERSION))
    config = json.loads((telegram_root / 'build-system/exteraless-configuration.json').read_text(encoding='utf-8'))
    bundle_id = config['bundle_id']
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle_id):
        raise ValueError('Invalid runtime framework bundle identifier')
    build_input = telegram_root / 'build-input'
    build_input.mkdir(parents=True, exist_ok=True)
    destination = build_input / 'exteraless'
    if destination.exists():
        marker = destination / 'runtime-staging.json'
        if not marker.is_file() or json.loads(marker.read_text(encoding='utf-8')).get('generator') != GENERATOR:
            raise ValueError('Refusing to replace an unrecognized staging directory: ' + str(destination))
    with tempfile.TemporaryDirectory(prefix='.exteraless-stage-', dir=build_input) as temporary:
        temporary = Path(temporary)
        extracted, staged = temporary / 'extracted', temporary / 'repository'
        staged.mkdir()
        extract_support(archive, extracted, lock)
        inputs = {}
        for relative in sources:
            target = staged / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source_root / relative, target)
            inputs[relative.as_posix()] = digest(target)
        support = staged / 'support'
        support.mkdir()
        shutil.copyfile(source_root / SUPPORT_BUILD, support / 'BUILD.bazel')
        native_lock = source_root / 'python/runtime/new-native-dependency-lock.json'
        targets = stage_support(extracted / lock['framework'], support, lock, bundle_id,
                               native_lock=native_lock, native_bundle=native_bundle)
        # Build the sealed dependency tree directly as Bazel inputs. A cached
        # source_root/python/vendor from a previous lock is not an app input.
        dependencies = vendor_dependencies(
            dependency_cache or source_root / 'build/dependency-downloads', staged / 'resources/python/vendor',
            lock_path=source_root / 'python/runtime/dependency-lock.json')
        inputs.update(copy_assets(source_root, staged / 'resources', include_vendor=False))
        verify_dependency_bundle(staged / 'resources/python/vendor', dependencies['lock_sha256'])
        inputs.update(compat['source_files'])
        for name in (SUPPORT_BUILD, 'tools/runtime/prepare_telegram_runtime.py', 'tools/runtime/support.py',
                      'tools/runtime/vendor_dependencies.py', 'python/runtime/dependency-lock.json'):
            inputs[name] = digest(source_root / name)
        write_json(staged / 'resources/python/compat-manifest.json', compat)
        for name in ('tools/runtime/native_dependencies.py', 'tools/runtime/pinned_download.py'):
            inputs[name] = digest(source_root / name)
        inputs['telegram-ios/build-system/exteraless/runtime-assets.json'] = digest(
            telegram_root / 'build-system/exteraless/runtime-assets.json')
        for item in client_assets.values():
            inputs['telegram-ios/' + item['source']] = item['sha256']
        for group in ('input_sha256', 'postimage_sha256'):
            inputs.update({'telegram-ios/' + name: sha for name, sha in client_patches[group].items()})
        # TL schema is produced by the TL/services owner. Keep its exact bytes.
        schema = source_root / 'python/runtime/tl-schema.json'
        if not isinstance(json.loads(schema.read_text(encoding='utf-8')), dict):
            raise ValueError('TL schema must be a JSON object')
        shutil.copyfile(schema, staged / 'resources/python/tl-schema.json')
        # Report outside resources: changing provenance never ships build-only
        # C/Swift sources, private headers or diagnostic executables in the app.
        report = {
            'schema': 1, 'generator': GENERATOR,
            'bundle_id': bundle_id, 'actual_cpython': CPYTHON_VERSION,
            'client_core_module': 'ExteralessCore',
            'application_resources': client_assets,
            'client_source_patches': client_patches,
            'support': support_report, 'targets': targets,
            'native_dependency_lock_sha256': digest(native_lock),
            'dependencies': {'bundle_sha256': dependencies['bundle_sha256'],
                             'lock_sha256': dependencies['lock_sha256'],
                             'packages': [{key: item[key] for key in ('name', 'version', 'sha256')}
                                          for item in dependencies['packages']]},
            'assets': inventory(staged / 'resources'),
            'source_files': dict(sorted(inputs.items())),
            'files': inventory(staged),
        }
        write_json(staged / 'runtime-staging.json', report)
        if destination.exists():
            shutil.rmtree(destination)
        staged.rename(destination)
        if report_path is not None:
            write_json(report_path, report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--telegram-root', type=Path)
    parser.add_argument('--cache', type=Path)
    parser.add_argument('--archive', type=Path, help='Use an existing archive; its SHA-256 is still verified')
    parser.add_argument('--dependency-cache', type=Path)
    parser.add_argument('--native-bundle', type=Path, help='Only matching, reviewed OWN_GIL-admitted component inputs')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    source_root = args.source_root.resolve()
    sys.path.insert(0, str(source_root / 'telegram-ios/build-system/Make'))
    from ClientSourcePatches import prepare_client_source_copy
    # Fail on a missing/unknown nested source image before any support download.
    prepare_client_source_copy(source_root / 'telegram-ios', args.telegram_root or source_root / 'telegram-ios')
    lock = read_lock(source_root / 'python/runtime/support-lock.json')
    archive = args.archive or download(lock, args.cache or source_root / 'build/runtime-downloads')
    report = prepare(source_root, args.telegram_root or source_root / 'telegram-ios', archive, lock,
                     args.report, args.dependency_cache, args.native_bundle)
    print('Bazel runtime inputs ready: CPython {}, {} frameworks per target, {} Python assets'.format(
        report['actual_cpython'], 1 + len(report['targets']['device']['extension_frameworks']) +
        len(report['targets']['device']['native_frameworks']), len(report['assets'])))


if __name__ == '__main__':
    main()
