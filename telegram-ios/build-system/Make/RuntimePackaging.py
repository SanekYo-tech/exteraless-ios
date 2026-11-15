"""Read-only validation of staged Bazel inputs, action graph and runtime IPA.

This deliberately does not rewrite an IPA or execute embedded Python. Binary
checks read Mach-O load commands, including the extension-to-host rpath chain.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import struct
import sys
import zipfile

# Also supports the harness's importlib.spec_from_file_location loader.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from ClientSourcePatches import validate_patch_provenance, verify_client_sources


GENERATOR = 'exteraless-telegram-runtime-v1'
CPYTHON_VERSION = '3.12.16'
NATIVE_SOURCES = ('engine.c', 'register_bridge.c', 'cpython312_compat.c', '_exteraless_bridge.c')
EXTENSIONS = ('ShareExtension', 'NotificationContentExtension', 'NotificationServiceExtensionv1',
              'IntentsExtension', 'WidgetExtension', 'BroadcastUploadExtension')


def _digest(stream):
    value = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b''):
        value.update(block)
    return value.hexdigest()


def write_report(path, report):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n', encoding='utf-8', newline='\n')


def load_staging_manifest(base_path):
    base = Path(base_path).resolve()
    root = base / 'build-input/exteraless'
    path = root / 'runtime-staging.json'
    if not path.is_file():
        raise RuntimeError('Prepare the runtime before Bazel analysis: '
                           'python3 ../tools/runtime/prepare_telegram_runtime.py --telegram-root .')
    report = json.loads(path.read_text(encoding='utf-8'))
    if report.get('generator') != GENERATOR or report.get('actual_cpython') != CPYTHON_VERSION:
        raise RuntimeError('Unexpected runtime staging version; regenerate build-input/exteraless')
    if report.get('client_source_patches') != verify_client_sources(base):
        raise RuntimeError('Client source patch provenance changed; regenerate runtime staging')
    for group in ('input_sha256', 'postimage_sha256'):
        for name, expected in report['client_source_patches'][group].items():
            if report['source_files'].get('telegram-ios/' + name) != expected:
                raise RuntimeError('Client patch input missing from source fingerprint: ' + name)
    for target in ('device', 'simulator'):
        spec = report['targets'][target]
        if spec['architecture'] != 'arm64' or len(spec['extension_frameworks']) != 54:
            raise RuntimeError('Unexpected runtime architecture or extension inventory')
    present = {file.relative_to(root).as_posix() for file in root.rglob('*') if file.is_file()}
    if present != set(report['files']) | {'runtime-staging.json'}:
        raise RuntimeError('Runtime staging file inventory changed; regenerate build-input/exteraless')
    for name, expected in report['files'].items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or '..' in relative.parts or '\\' in name:
            raise RuntimeError('Invalid path in runtime input inventory')
        file = root / name
        if not file.is_file():
            raise RuntimeError('Incomplete runtime staging: ' + name)
        with file.open('rb') as stream:
            if _digest(stream) != expected:
                raise RuntimeError('Changed runtime staging input; regenerate: ' + name)
    for name, resource in report.get('application_resources', {}).items():
        file = base / resource['source']
        if not file.is_file() or file.stat().st_size != resource['size']:
            raise RuntimeError('Missing or changed pinned application resource: ' + name)
        with file.open('rb') as stream:
            if _digest(stream) != resource['sha256']:
                raise RuntimeError('Pinned application resource changed after staging: ' + name)
    # A local checkout still has the outer source tree. Refuse an old snapshot
    # after a Swift/C/SDK edit; the relocated CI copy is prepared just beforehand.
    source_root = base.parent
    if (source_root / 'tools/runtime/prepare_telegram_runtime.py').is_file():
        for name, expected in report['source_files'].items():
            file = source_root / name
            if not file.is_file():
                raise RuntimeError('Runtime source disappeared; regenerate staging: ' + name)
            with file.open('rb') as stream:
                if _digest(stream) != expected:
                    raise RuntimeError('Runtime source changed; regenerate staging: ' + name)
    return report


def validate_runtime_actions(graph_path, manifest):
    """Check that the unsigned preflight actually includes the native runtime."""
    if manifest.get('generator') == GENERATOR or 'client_source_patches' in manifest:
        validate_patch_provenance(manifest.get('client_source_patches'))
    graph_path = Path(graph_path)
    graph = json.loads(graph_path.read_text(encoding='utf-8'))
    targets = {str(item['id']): item['label'] for item in graph.get('targets', [])}
    native, swift, imports = set(), set(), set()
    ui_links = []
    for action in graph.get('actions', []):
        label = targets.get(str(action.get('targetId')), '')
        mnemonic = action.get('mnemonic', '')
        args = list(action.get('arguments', []))
        for params in action.get('paramFiles', []):
            args.extend(params.get('arguments', []))
        if mnemonic in ('CppCompile', 'ObjcCompile') and '//python/runtime:' in label:
            native.update(name for name in NATIVE_SOURCES if any(arg.endswith('/' + name) for arg in args))
        if mnemonic.startswith('SwiftCompile'):
            if '//swift/PluginHost:PluginHost' in label:
                swift.update(name for name in ('CPythonXCFrameworkEngine.swift', 'NativeBridgeBinding.swift', 'PluginHost.swift')
                             if any(arg.endswith('/' + name) for arg in args))
            if '//swift/PluginHooks:PluginHooks' in label:
                swift.add('PluginHooks')
            if '//swift/ExteralessCore:ExteralessCore' in label:
                swift.add('ExteralessCore')
        if mnemonic == 'ImportedDynamicFrameworkProcessor' and label.endswith('//Telegram:Telegram'):
            for index, arg in enumerate(args[:-1]):
                if arg == '--framework_binary':
                    imports.add(PurePosixPath(args[index + 1]).name)
        if mnemonic in ('ObjcLink', 'CppLink') and label.endswith('//Telegram:TelegramUIFramework'):
            ui_links.append(args)
    required_swift = {'CPythonXCFrameworkEngine.swift', 'NativeBridgeBinding.swift', 'PluginHost.swift', 'PluginHooks'}
    if manifest.get('client_core_module') == 'ExteralessCore':
        required_swift.add('ExteralessCore')
    required_imports = {'Python', *manifest['targets']['device']['extension_frameworks'],
                        *(entry['framework'] for entry in manifest['targets']['device'].get('native_frameworks', []))}
    errors = []
    if set(NATIVE_SOURCES) - native:
        errors.append('C runtime sources missing from compile actions: ' + ', '.join(sorted(set(NATIVE_SOURCES) - native)))
    if required_swift - swift:
        errors.append('Native Swift modules missing from compile actions: ' + ', '.join(sorted(required_swift - swift)))
    if required_imports - imports:
        errors.append('Main application framework imports missing: ' + ', '.join(sorted(required_imports - imports)))
    if not ui_links or not all(any('@loader_path/..' in arg for arg in args) for args in ui_links):
        errors.append('TelegramUIFramework has no explicit sibling-framework rpath')
    report = {'native_sources': sorted(native), 'swift_sources': sorted(swift),
              'main_app_framework_imports': sorted(imports), 'errors': errors,
              'status': 'invalid' if errors else 'valid'}
    report['client_source_patches'] = manifest.get('client_source_patches')
    write_report(graph_path.parent / 'runtime-preflight.json', report)
    if errors:
        raise RuntimeError('Runtime preflight failed:\n' + '\n'.join(errors))
    print('Runtime preflight: source-built C/Swift bridge and {} main-app framework imports'.format(len(required_imports)))
    return report


def _command_string(command, offset):
    if offset < 12 or offset >= len(command):
        raise ValueError('Invalid Mach-O string offset')
    raw, separator, _ = command[offset:].partition(b'\0')
    if not separator:
        raise ValueError('Unterminated Mach-O load-command string')
    return raw.decode('utf-8')


def _macho_slice(stream, offset, length, expected_platform):
    stream.seek(offset)
    header = stream.read(32)
    if len(header) != 32 or header[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected 64-bit little-endian Mach-O')
    _, cpu, subtype, filetype, count, size, _, _ = struct.unpack('<8I', header)
    if cpu != 0x0100000C or subtype & 0xFFFFFF != 0:
        raise ValueError('Runtime IPA supports arm64 only')
    if size > 1024 * 1024 or count > size // 8 or size > length - 32:
        raise ValueError('Invalid Mach-O load-command bounds')
    commands = stream.read(size)
    if len(commands) != size:
        raise ValueError('Truncated Mach-O load commands')
    platform, install_name, loads, rpaths = None, None, [], []
    cursor = 0
    for _ in range(count):
        if cursor + 8 > size:
            raise ValueError('Truncated Mach-O load command')
        kind, command_size = struct.unpack_from('<II', commands, cursor)
        if command_size < 8 or cursor + command_size > size:
            raise ValueError('Invalid Mach-O load command')
        command = commands[cursor:cursor + command_size]
        if kind == 0x32 and command_size >= 24:  # LC_BUILD_VERSION
            platform = struct.unpack_from('<I', command, 8)[0]
        elif kind == 0x25 and command_size >= 16 and platform is None:
            platform = 2  # LC_VERSION_MIN_IPHONEOS
        elif kind in (0xC, 0xD, 0x80000018, 0x8000001F, 0x20, 0x80000023):
            if command_size < 24:
                raise ValueError('Truncated dylib load command')
            name = _command_string(command, struct.unpack_from('<I', command, 8)[0])
            if kind == 0xD:  # LC_ID_DYLIB
                install_name = name
            else:
                loads.append(name)
        elif kind == 0x8000001C:  # LC_RPATH
            if command_size < 12:
                raise ValueError('Truncated rpath command')
            rpaths.append(_command_string(command, struct.unpack_from('<I', command, 8)[0]))
        cursor += command_size
    if platform != expected_platform:
        raise ValueError('Mach-O platform {} does not match {}'.format(platform, expected_platform))
    return {'filetype': filetype, 'install_name': install_name, 'loads': loads, 'rpaths': rpaths}


def macho_loads(archive, name, platform):
    entry = archive.getinfo(name)
    with archive.open(entry) as stream:
        prefix = stream.read(8)
        formats = {b'\xca\xfe\xba\xbe': ('>', 20), b'\xbe\xba\xfe\xca': ('<', 20),
                   b'\xca\xfe\xba\xbf': ('>', 32), b'\xbf\xba\xfe\xca': ('<', 32)}
        if prefix[:4] not in formats:
            return _macho_slice(stream, 0, entry.file_size, platform)
        endian, record_size = formats[prefix[:4]]
        count = struct.unpack(endian + 'I', prefix[4:])[0]
        if not 1 <= count <= 16:
            raise ValueError('Invalid fat Mach-O architecture count')
        records = stream.read(record_size * count)
        if len(records) != record_size * count:
            raise ValueError('Truncated fat Mach-O')
        slices = []
        for index in range(count):
            fields = struct.unpack_from(endian + ('5I' if record_size == 20 else 'IIQQII'), records, index * record_size)
            cpu, _, offset, length = fields[:4]
            if cpu != 0x0100000C or offset < 8 + len(records) or offset + length > entry.file_size:
                raise ValueError('Unexpected fat Mach-O slice')
            slices.append(_macho_slice(stream, offset, length, platform))
        if any(item != slices[0] for item in slices):
            raise ValueError('Inconsistent Mach-O load commands between slices')
        return slices[0]


def _expand_path(value, loader_dir, executable_dir):
    for prefix, folder in (('@loader_path', loader_dir), ('@executable_path', executable_dir)):
        if value == prefix or value.startswith(prefix + '/'):
            return posixpath.normpath(folder + value[len(prefix):])
    return value


def verify_dependency_archive(archive, root, manifest):
    prefix = 'python/vendor/'
    marker_name = 'exteraless-dependencies.json'
    marker_path = root + '/' + prefix + marker_name
    if archive.getinfo(marker_path).file_size > 2 * 1024 * 1024:
        raise ValueError('Oversized dependency manifest')
    marker = json.loads(archive.read(marker_path))
    expected = manifest['dependencies']
    files = marker.get('files', {})
    if (marker.get('schema') != 1 or marker.get('generator') != 'exteraless-pure-python-dependencies-v1'
            or marker.get('python') != '3.12' or marker.get('lock_sha256') != expected['lock_sha256']
            or not isinstance(files, dict)):
        raise ValueError('Dependency manifest disagrees with Bazel staging')
    sealed = json.dumps({'lock_sha256': marker['lock_sha256'], 'files': files},
                        sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')
    calculated = hashlib.sha256(sealed).hexdigest()
    if calculated != marker.get('bundle_sha256') or calculated != expected['bundle_sha256']:
        raise ValueError('Dependency bundle hash disagrees with Bazel staging')
    packages = [{key: package.get(key) for key in ('name', 'version', 'sha256')}
                for package in marker.get('packages', [])]
    if packages != expected['packages']:
        raise ValueError('Dependency packages disagree with Bazel staging')
    actual = {name[len(root) + 1:] for name in archive.namelist()
              if name.startswith(root + '/' + prefix) and not name.endswith('/')}
    sealed_paths = {prefix + name for name in files} | {prefix + marker_name}
    if actual != sealed_paths:
        raise ValueError('Sealed dependency file inventory mismatch')
    for name, record in files.items():
        parts = PurePosixPath(name).parts
        if not parts or name.startswith('/') or any(part in ('.', '..') for part in parts) or '\\' in name:
            raise ValueError('Invalid sealed dependency path: ' + name)
        path = prefix + name
        if (archive.getinfo(root + '/' + path).file_size != record['size']
                or manifest['assets'].get(path) != record['sha256']):
            raise ValueError('Sealed dependency file differs from staged asset: ' + name)
    return {'bundle_sha256': calculated, 'lock_sha256': expected['lock_sha256'],
            'packages': packages, 'resource_files': len(actual)}


def verify_runtime_ipa(ipa, manifest, target='device'):
    if manifest.get('generator') == GENERATOR or 'client_source_patches' in manifest:
        validate_patch_provenance(manifest.get('client_source_patches'))
    root = 'Payload/Telegram.app'
    spec = manifest['targets'][target]
    modules = spec['extension_frameworks']
    native_frameworks = spec.get('native_frameworks', [])
    framework_names = ['Python', *modules, *(entry['framework'] for entry in native_frameworks)]
    application_assets = manifest.get('application_resources', {})
    expected = dict(spec['resources'], **manifest['assets'])
    with zipfile.ZipFile(ipa) as archive:
        names = set(archive.namelist())
        if len(names) != len(archive.namelist()):
            raise ValueError('Duplicate IPA entries')
        actual_resources = {name[len(root) + 1:] for name in names if not name.endswith('/') and
                            (name.startswith(root + '/python/') or name.startswith(root + '/python-stdlib/'))}
        if actual_resources != set(expected):
            raise ValueError('Runtime resource inventory mismatch: missing {}, extra {}'.format(
                sorted(set(expected) - actual_resources)[:8], sorted(actual_resources - set(expected))[:8]))
        for name, sha in expected.items():
            with archive.open(root + '/' + name) as stream:
                if _digest(stream) != sha:
                    raise ValueError('Runtime resource differs from Bazel staging: ' + name)
        for name, resource in application_assets.items():
            path = root + '/' + name
            matches = {candidate for candidate in names if candidate.endswith('/' + name)}
            if matches != {path}:
                raise ValueError('Application resource must occur once at the main bundle root: ' + name)
            if archive.getinfo(path).file_size != resource['size']:
                raise ValueError('Pinned application resource size mismatch: ' + name)
            with archive.open(path) as stream:
                if _digest(stream) != resource['sha256']:
                    raise ValueError('Pinned application resource hash mismatch: ' + name)
        dependencies = verify_dependency_archive(archive, root, manifest)
        native_policy = None
        if 'native_dependency_lock_sha256' in manifest:
            native_policy = json.loads(archive.read(root + '/python/native-dependencies.json'))
            if (native_policy.get('schema') != 1 or native_policy.get('generator') != 'exteraless-native-dependencies-v1'
                    or native_policy.get('lock_sha256') != manifest['native_dependency_lock_sha256']
                    or native_policy.get('support_sha256') != manifest['support']['sha256']
                    or native_policy.get('actual_cpython') != manifest['actual_cpython']
                    or native_policy.get('target') != target or native_policy.get('frameworks') != native_frameworks
                    or native_policy.get('diagnostic_only')):
                raise ValueError('Native dependency policy does not match the staged production inputs')
            if {entry['package'] for entry in native_frameworks} != set(native_policy.get('admitted_packages', [])):
                raise ValueError('Native frameworks do not match the admitted package inventory')
        for name in names:
            if ('ExteralessPythonBridge.framework/' in name or
                    ('CPythonRuntimeImplementation' in name and name.endswith(('.so', '.dylib')))):
                raise ValueError('The C bridge must be statically linked: ' + name)
            if '/python-stdlib/' in name or '/python/compat-manifest.json' in name:
                if not name.startswith(root + '/python-stdlib/') and not name.startswith(root + '/python/'):
                    raise ValueError('Runtime resources embedded outside the main app: ' + name)
            if '/PlugIns/' in name and ('/python/' in name or '/python-stdlib/' in name):
                raise ValueError('Python resources duplicated in an extension: ' + name)
            for module in framework_names:
                fragment = '/{}.framework/'.format(module)
                if fragment in name and not name.startswith(root + '/Frameworks/{}.framework/'.format(module)):
                    raise ValueError('Python framework is not in the main Frameworks directory: ' + name)

        binary_info = {}

        def binary(name):
            if name not in binary_info:
                binary_info[name] = macho_loads(archive, name, spec['platform_id'])
            return binary_info[name]

        python_path = root + '/Frameworks/Python.framework/Python'
        python = binary(python_path)
        if python['filetype'] != 6 or python['install_name'] != '@rpath/Python.framework/Python':
            raise ValueError('Python must be a dynamic framework with its relocatable install name')
        for module in framework_names:
            prefix = root + '/Frameworks/{}.framework/'.format(module)
            info = plistlib.loads(archive.read(prefix + 'Info.plist'))
            platform_name = 'iPhoneOS' if target == 'device' else 'iPhoneSimulator'
            if info.get('CFBundleExecutable') != module or info.get('CFBundleSupportedPlatforms') != [platform_name]:
                raise ValueError('Invalid embedded framework metadata: ' + module)
            if any(name.startswith(prefix + folder + '/') for name in names for folder in ('Headers', 'Modules')):
                raise ValueError('Build-only framework headers/modules were bundled: ' + module)
            binary(prefix + module)
            if module in modules:
                origin = archive.read(prefix + module + '.origin').decode('utf-8').strip()
                if origin not in expected or not origin.endswith('.fwork'):
                    raise ValueError('Invalid framework origin: ' + module)
                marker = archive.read(root + '/' + origin).decode('utf-8').strip()
                if marker != 'Frameworks/{0}.framework/{0}'.format(module):
                    raise ValueError('Broken PEP 730 framework/origin pair: ' + module)

        for entry in native_frameworks:
            if (entry['binary'] != 'Frameworks/{0}.framework/{0}'.format(entry['framework'])
                    or entry['origin'] != entry['binary'] + '.origin'
                    or not entry['marker'].startswith('python/native-vendor/')
                    or entry['marker'] not in expected or not entry['marker'].endswith('.fwork')):
                raise ValueError('Invalid native extension bundle paths')
            if (archive.read(root + '/' + entry['marker']).decode('utf-8').strip() != entry['binary']
                    or archive.read(root + '/' + entry['origin']).decode('utf-8').strip() != entry['marker']):
                raise ValueError('Broken native PEP 730 framework/origin pair')

        ui_path = root + '/Frameworks/TelegramUIFramework.framework/TelegramUIFramework'
        if '@rpath/Python.framework/Python' not in binary(ui_path)['loads']:
            raise ValueError('TelegramUIFramework does not link the dynamic Python runtime')
        if '@loader_path/..' not in binary(ui_path)['rpaths']:
            raise ValueError('TelegramUIFramework is missing its sibling-framework rpath')

        def walk(entry, executable, inherited=()):
            seen, queue = set(), [(entry, tuple(inherited))]
            while queue:
                name, parent_paths = queue.pop()
                if name in seen:
                    continue
                seen.add(name)
                info = binary(name)
                loader_dir, executable_dir = posixpath.dirname(name), posixpath.dirname(executable)
                paths = tuple(_expand_path(path, loader_dir, executable_dir) for path in info['rpaths']) + parent_paths
                for dependency in info['loads']:
                    if dependency.startswith(('/usr/lib/', '/System/Library/')):
                        continue
                    if dependency.startswith('@rpath/'):
                        candidates = [posixpath.normpath(path + '/' + dependency[len('@rpath/'):]) for path in paths]
                    else:
                        candidates = [_expand_path(dependency, loader_dir, executable_dir)]
                    resolved = next((candidate for candidate in candidates if candidate in names), None)
                    if resolved is None:
                        # Swift runtime dylibs may be supplied by the OS dyld cache.
                        if dependency.startswith('@rpath/libswift') and dependency.endswith('.dylib'):
                            continue
                        raise ValueError('Unresolved embedded dependency {} from {}'.format(dependency, name))
                    queue.append((resolved, paths))
            return seen

        app_info = plistlib.loads(archive.read(root + '/Info.plist'))
        main = root + '/' + app_info['CFBundleExecutable']
        reached = walk(main, main)
        if python_path not in reached or ui_path not in reached:
            raise ValueError('The main executable does not reach TelegramUIFramework and Python')
        extension_report = {}
        for extension in EXTENSIONS:
            bundle = root + '/PlugIns/' + extension + '.appex'
            info = plistlib.loads(archive.read(bundle + '/Info.plist'))
            executable = bundle + '/' + info['CFBundleExecutable']
            if '@executable_path/../../Frameworks' not in binary(executable)['rpaths']:
                raise ValueError('Extension cannot resolve the shared app frameworks: ' + extension)
            linked = walk(executable, executable)
            extension_report[extension] = {'loads_python': python_path in linked, 'rpaths_resolved': True}
        core = root + '/Frameworks/TelegramCoreFramework.framework/TelegramCoreFramework'
        if python_path in walk(core, main):
            raise ValueError('TelegramCore acquired a CPython dependency')
        main_paths = [_expand_path(path, root, root) for path in binary(main)['rpaths']]
        for module in modules:
            walk(root + '/Frameworks/{0}.framework/{0}'.format(module), main, main_paths)
        for entry in native_frameworks:
            walk(root + '/' + entry['binary'], main, main_paths)
    return {'status': 'valid', 'actual_cpython': manifest['actual_cpython'],
            'support_sha256': manifest['support']['sha256'], 'target': target,
            'frameworks': framework_names, 'resource_files': len(expected) + len(application_assets),
            'application_resources': application_assets,
            'extensions': extension_report, 'checked_macho_files': len(binary_info),
            'dependencies': dependencies,
            'native_dependencies': native_policy,
            'client_source_patches': manifest.get('client_source_patches'),
            'runtime_execution_verified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', type=Path, required=True)
    parser.add_argument('--staging-manifest', type=Path, required=True)
    parser.add_argument('--target', choices=('device', 'simulator'), default='device')
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(args.staging_manifest.read_text(encoding='utf-8'))
    report = verify_runtime_ipa(args.ipa, manifest, args.target)
    write_report(args.report, report)
    print('Runtime IPA verified: {} frameworks, {} resources, six extension rpath chains'.format(
        len(report['frameworks']), report['resource_files']))


if __name__ == '__main__':
    main()
