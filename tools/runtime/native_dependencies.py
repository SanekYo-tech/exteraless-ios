"""Pinned native candidates, PEP 730 staging and strict production admission.

Creating a framework proves packaging, not OWN_GIL compatibility. A package is
admitted only when both its reviewed lock policy and real device-platform probe
evidence permit it. The current Pillow/lxml candidates are not admitted.
"""

import base64
import csv
from email.parser import BytesParser
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import sys
import tarfile
import types
import zipfile

from pinned_download import digest, fetch


ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = ROOT / 'python/runtime/new-native-dependency-lock.json'
GENERATOR = 'exteraless-native-dependencies-v1'
CHUNK = 1024 * 1024
MAX_FILES = 20000
MAX_UNPACKED = 128 * 1024 * 1024
MAX_FILE = 32 * 1024 * 1024
BUILD_SUFFIXES = {'.c', '.h', '.hpp', '.cpp', '.pyx', '.pxd', '.pxi', '.a', '.o', '.pyc', '.pyo'}


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode('utf-8')


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(json_bytes(value))


def read_lock(path=LOCK_PATH):
    lock = json.loads(Path(path).read_text(encoding='utf-8'))
    if (lock.get('schema') != 1 or lock.get('abi') != 'cp312'
            or lock.get('actual_cpython') != '3.12.16'
            or lock.get('targets') != ['device', 'simulator']):
        raise ValueError('Unsupported native dependency ABI/platform lock')
    for artifact in lock['artifacts'].values():
        if (not re.fullmatch(r'[0-9a-f]{64}', artifact.get('sha256', ''))
                or type(artifact.get('size')) is not int or not 0 < artifact['size'] <= 96 * 1024 * 1024):
            raise ValueError('Native artifact needs a checksum and bounded size')
    names = set()
    for package in lock['packages']:
        if package['name'] in names or package['recipe'] not in ('ios-wheel', 'lxml-static'):
            raise ValueError('Duplicate or unsupported native dependency recipe')
        names.add(package['name'])
        if package.get('production_eligible') and package.get('own_gil') != 'supported':
            raise ValueError('A native dependency cannot be eligible without reviewed OWN_GIL support')
    return lock


def safe_path(name):
    if not name or '\\' in name or '\0' in name or name.startswith('/'):
        raise ValueError('Unsafe native archive path: ' + repr(name))
    parts = name.rstrip('/').split('/')
    if any(not part or part in ('.', '..') or ':' in part or part.endswith(('.', ' ')) for part in parts):
        raise ValueError('Unsafe native archive path: ' + name)
    return PurePosixPath(*parts)


def unpack_zip(path, output):
    """Data-only extraction, also used for fresh host import probes."""
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    total, seen = 0, set()
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_FILES:
            raise ValueError('Native wheel has too many files')
        for info in entries:
            relative = safe_path(info.orig_filename)
            mode = stat.S_IFMT(info.external_attr >> 16)
            if mode not in (0, stat.S_IFREG, stat.S_IFDIR) or info.flag_bits & 1:
                raise ValueError('Native wheel has a link/special/encrypted entry')
            if info.is_dir():
                continue
            key = str(relative).casefold()
            if key in seen or info.file_size > MAX_FILE:
                raise ValueError('Duplicate or oversized native wheel entry')
            seen.add(key)
            total += info.file_size
            if total > MAX_UNPACKED:
                raise ValueError('Native wheel exceeds the unpacked size limit')
            destination = output.joinpath(*relative.parts)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(info) as source, destination.open('xb') as target:
                shutil.copyfileobj(source, target, CHUNK)
    return output


def unpack_source(path, output):
    """Extract pinned native build sources; no external links or host paths."""
    with tarfile.open(path, 'r:*') as archive:
        entries = archive.getmembers()
        if len(entries) > MAX_FILES or sum(item.size for item in entries) > MAX_UNPACKED:
            raise ValueError('Native source archive exceeds extraction limits')
        for item in entries:
            safe_path(item.name)
            if item.size > MAX_FILE or not (item.isfile() or item.isdir()):
                raise ValueError('Native source archive has an oversized/special entry')
        archive.extractall(output, filter='data')


def framework_name(module):
    if not re.fullmatch(r'[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*', module):
        raise ValueError('Invalid extension module name: ' + module)
    return 'exl_' + module.replace('.', '_')[:80] + '_' + hashlib.sha256(module.encode()).hexdigest()[:10]


def macho_info(path, platform):
    sys.path.insert(0, str(ROOT / 'telegram-ios/build-system/Make'))
    from RuntimePackaging import macho_loads

    class FileArchive:
        def getinfo(self, name):
            return types.SimpleNamespace(filename=name, file_size=Path(name).stat().st_size)

        def open(self, entry):
            return Path(entry.filename if hasattr(entry, 'filename') else entry).open('rb')

    return macho_loads(FileArchive(), str(path), platform)


def install_extension(source, relative, app, package, target, bundle_id):
    """Move a real Mach-O extension into a uniquely named framework."""
    relative = safe_path(str(relative))
    leaf = relative.name.split('.')[0]
    module = '.'.join((*relative.parts[:-1], leaf))
    if relative.parts[0] not in package['import_roots']:
        raise ValueError('Extension is outside the locked package: ' + module)
    name = framework_name(module)
    platform = 2 if target == 'device' else 7
    info = macho_info(source, platform)
    if info['filetype'] not in (6, 8):
        raise ValueError('Extension must be a dynamic Mach-O image')
    for dependency in info['loads']:
        if not (dependency.startswith(('/usr/lib/', '/System/Library/'))
                or dependency == '@rpath/Python.framework/Python'):
            raise ValueError('Native dependency requires an explicit framework mapping: ' + dependency)
    framework = Path(app) / 'Frameworks' / (name + '.framework')
    framework.mkdir(parents=True)
    binary = framework / name
    shutil.copyfile(source, binary)
    binary.chmod(0o755)
    marker_relative = PurePosixPath('python/native-vendor') / relative.with_suffix('.fwork')
    marker = Path(app).joinpath(*marker_relative.parts)
    marker.parent.mkdir(parents=True, exist_ok=True)
    binary_relative = PurePosixPath('Frameworks', name + '.framework', name)
    marker.write_bytes((str(binary_relative) + '\n').encode())
    (framework / (name + '.origin')).write_bytes((str(marker_relative) + '\n').encode())
    (framework / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': bundle_id + '.native.' + name.replace('_', '-'),
        'CFBundleExecutable': name, 'CFBundleName': name, 'CFBundlePackageType': 'FMWK',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': package['version'],
        'CFBundleSupportedPlatforms': ['iPhoneOS' if target == 'device' else 'iPhoneSimulator'],
        'MinimumOSVersion': '15.0',
    }))
    return {'package': package['name'], 'module': module, 'framework': name,
            'binary': str(binary_relative), 'marker': str(marker_relative),
            'origin': str(PurePosixPath('Frameworks', name + '.framework', name + '.origin')),
            'binary_sha256': digest(binary), 'platform': platform, 'rpaths': info['rpaths'],
            'loads': info['loads']}


def rewrite_record(vendor, dist_info, roots):
    records = io.StringIO(newline='')
    writer = csv.writer(records, lineterminator='\n')
    paths = [path for path in Path(vendor).rglob('*') if path.is_file()
             and path.relative_to(vendor).parts[0] in [*roots, dist_info]
             and path.relative_to(vendor).as_posix() != dist_info + '/RECORD']
    for path in sorted(paths):
        sha = base64.urlsafe_b64encode(bytes.fromhex(digest(path))).rstrip(b'=').decode()
        writer.writerow((path.relative_to(vendor).as_posix(), 'sha256=' + sha, path.stat().st_size))
    writer.writerow((dist_info + '/RECORD', '', ''))
    (Path(vendor) / dist_info / 'RECORD').write_bytes(records.getvalue().encode())


def stage_wheel(wheel, scratch, app, package, target, bundle_id):
    tree = unpack_zip(wheel, scratch)
    metadata_files = list(tree.glob('*.dist-info/METADATA'))
    if len(metadata_files) != 1:
        raise ValueError('Native wheel must contain exactly one distribution')
    metadata = BytesParser().parsebytes(metadata_files[0].read_bytes())
    if (metadata['Name'].lower() != package['name'] or metadata['Version'] != package['version']):
        raise ValueError('Native wheel metadata does not match the lock')
    wheel_info = BytesParser().parsebytes((metadata_files[0].parent / 'WHEEL').read_bytes())
    expected = 'cp312-cp312-ios_13_0_arm64_' + ('iphoneos' if target == 'device' else 'iphonesimulator')
    if wheel_info.get_all('Tag') != [expected] or wheel_info['Root-Is-Purelib'] != 'false':
        raise ValueError('Native wheel ABI/platform tag mismatch')
    vendor = Path(app) / 'python/native-vendor'
    frameworks = []
    for path in sorted(tree.rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(tree)
        if relative.parts[0] not in [*package['import_roots'], metadata_files[0].parent.name]:
            raise ValueError('Unexpected root in native wheel: ' + str(relative))
        if path.suffix == '.so':
            frameworks.append(install_extension(path, PurePosixPath(relative.as_posix()), app, package, target, bundle_id))
        elif path.suffix in ('.dylib', '.dll', '.pyd'):
            raise ValueError('Unmapped native library: ' + str(relative))
        elif path.suffix not in BUILD_SUFFIXES and not {'test', 'tests', '__pycache__'}.intersection(relative.parts):
            destination = vendor / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
    if not frameworks or package['probe_import'] not in {entry['module'] for entry in frameworks}:
        raise ValueError('Native wheel is missing its required extension')
    rewrite_record(vendor, metadata_files[0].parent.name, package['import_roots'])
    return frameworks


def policy_document(lock, lock_sha256, target, frameworks=(), admitted=()):
    return {'schema': 1, 'generator': GENERATOR, 'actual_cpython': lock['actual_cpython'],
            'abi': lock['abi'], 'target': target, 'architecture': 'arm64',
            'lock_sha256': lock_sha256, 'support_sha256': lock['support_sha256'],
            'import_root': 'python/native-vendor', 'admitted_packages': list(admitted),
            'frameworks': list(frameworks),
            'constraints': [{key: package[key] for key in ('name', 'version', 'own_gil', 'reason')}
                            for package in lock['packages'] if package['name'] not in admitted],
            'debugger_constraints': lock['debugger_constraints']}


def validate_admission(lock, package, evidence):
    if not package['production_eligible'] or package['own_gil'] != 'supported':
        raise ValueError('Native package is not admitted for OWN_GIL plugins: ' + package['name'])
    if (evidence.get('actual_cpython') != lock['actual_cpython'] or evidence.get('platform') != 'ios'
            or evidence.get('check_multi_interp_extensions') != 1
            or evidence.get('own_gil_interpreters') != 2 or evidence.get('own_gil_supported') is not True
            or evidence.get('native_completed') is not True or evidence.get('package') != package['name']
            or evidence.get('mode') != 'own-gil' or len(evidence.get('results', [])) != 2
            or not all(item.get('ok') is True for item in evidence['results'])):
        raise ValueError('Native admission requires completed iOS OWN_GIL execution evidence')


def stage_application_policy(app, target, *, lock_path=LOCK_PATH, bundle=None):
    """Stage policy and, only when validated, native framework/resource inputs."""
    app = Path(app)
    lock = read_lock(lock_path)
    lock_sha = digest(lock_path)
    frameworks, admitted = [], []
    if bundle is not None:
        bundle = Path(bundle)
        payload = json.loads((bundle / 'native-inputs.json').read_text(encoding='utf-8'))
        if (payload.get('schema') != 1 or payload.get('native_lock_sha256') != lock_sha
                or payload.get('support_sha256') != lock['support_sha256']
                or payload.get('actual_cpython') != lock['actual_cpython']
                or payload.get('execution_verified') is not True):
            raise ValueError('Native inputs require the matching completed component build/probe')
        admitted = payload.get('admitted_packages', [])
        if not admitted:
            raise ValueError('The candidate bundle admits no packages for OWN_GIL plugins')
        packages = {package['name']: package for package in lock['packages']}
        for name in admitted:
            if name not in packages:
                raise ValueError('Unknown admitted native package: ' + name)
            validate_admission(lock, packages[name], payload.get('evidence', {}).get(name, {}))
        data = payload['targets'][target]
        frameworks = [entry for entry in data['frameworks'] if entry['package'] in admitted]
        if {entry['package'] for entry in frameworks} != set(admitted):
            raise ValueError('Native input frameworks do not match the admitted package set')
        names = [entry['framework'] for entry in frameworks]
        if len(names) != len(set(names)):
            raise ValueError('Native frameworks have duplicate names')
        vendor_roots = set()
        for name in admitted:
            package = packages[name]
            vendor_roots.update(package['import_roots'])
            vendor_roots.add(name.replace('-', '_') + '-' + package['version'] + '.dist-info')
            expected = {entry['module']: entry['binary_sha256'] for entry in frameworks if entry['package'] == name}
            proof = payload['evidence'][name]
            if proof.get('binary_sha256s', {}).get(target) != expected:
                raise ValueError('Native execution evidence is not bound to these framework bytes')
            if any(set(item.get('modules', {})) != set(expected) for item in proof['results']):
                raise ValueError('Native execution did not cover every admitted extension module')
        for entry in frameworks:
            expected_binary = 'Frameworks/{0}.framework/{0}'.format(framework_name(entry['module']))
            if (entry['binary'] != expected_binary or entry['origin'] != expected_binary + '.origin'
                    or not entry['marker'].startswith('python/native-vendor/') or not entry['marker'].endswith('.fwork')
                    or any(entry[key] not in data['files'] for key in ('binary', 'origin', 'marker'))):
                raise ValueError('Invalid native framework/marker paths')
        for name, sha in data['files'].items():
            relative = safe_path(name)
            if name == 'python/native-dependencies.json':
                continue  # Recreate the production policy below, without diagnostic_only.
            if name.startswith('python/native-vendor/'):
                if len(relative.parts) < 4 or relative.parts[2] not in vendor_roots:
                    continue
            elif any(name.startswith('Frameworks/' + frame + '.framework/') for frame in names):
                pass
            elif any(name.startswith('Frameworks/' + entry['framework'] + '.framework/') for entry in data['frameworks']):
                continue
            else:
                raise ValueError('Unexpected native bundle resource: ' + name)
            source = bundle / target / str(relative)
            if not source.is_file() or source.is_symlink() or digest(source) != sha:
                raise ValueError('Native input checksum mismatch: ' + name)
            destination = app / str(relative)
            if destination.exists():
                raise ValueError('Native input would overwrite an existing app file: ' + name)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
        for entry in frameworks:
            if (entry['framework'] != framework_name(entry['module'])
                    or digest(app / entry['binary']) != entry['binary_sha256']):
                raise ValueError('Native module/framework identity mismatch')
            macho_info(app / entry['binary'], 2 if target == 'device' else 7)
            if ((app / entry['marker']).read_text().strip() != entry['binary']
                    or (app / entry['origin']).read_text().strip() != entry['marker']):
                raise ValueError('Native PEP 730 marker/origin mismatch')
    policy = policy_document(lock, lock_sha, target, frameworks, admitted)
    write_json(app / 'python/native-dependencies.json', policy)
    return policy
