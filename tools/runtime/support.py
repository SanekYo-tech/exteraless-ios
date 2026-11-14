"""Pinned CPython iOS support: streaming download, inspection and app staging.

No interpreter or plugin is executed by this tool. Native extension modules
are moved into individual frameworks using the PEP 730 .fwork/.origin layout.
Signing is a separate operation (ad-hoc only for the simulator smoke app).
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import tarfile
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = ROOT / 'python/runtime/support-lock.json'
TEST_EXTENSIONS = {'_ctypes_test', '_xxtestfuzz', 'xxlimited', 'xxlimited_35', 'xxsubtype'}


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def read_lock(path=LOCK_PATH):
    lock = json.loads(Path(path).read_text(encoding='utf-8'))
    if lock['python'] != '3.12' or not re.fullmatch('[0-9a-f]{64}', lock['sha256']):
        raise ValueError('Unexpected runtime version or missing archive checksum')
    return lock


def download(lock, cache):
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / lock['archive']
    if target.exists():
        if digest(target) != lock['sha256']:
            raise ValueError('Cached support archive checksum mismatch: {}'.format(target))
        return target
    temporary = target.with_suffix('.download')
    try:
        request = urllib.request.Request(lock['url'], headers={'User-Agent': 'exteraless-runtime-build'})
        with urllib.request.urlopen(request, timeout=60) as response, temporary.open('wb') as output:
            shutil.copyfileobj(response, output, length=1024 * 1024)
        if digest(temporary) != lock['sha256']:
            raise ValueError('Downloaded support archive checksum mismatch')
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target


def inspect_archive(path, lock):
    if digest(path) != lock['sha256']:
        raise ValueError('Support archive checksum mismatch')
    with tarfile.open(path, 'r:gz') as archive:
        members = archive.getmembers()
        names = {member.name.rstrip('/') for member in members}
        for member in members:
            rel = PurePosixPath(member.name)
            if rel.is_absolute() or '..' in rel.parts:
                raise ValueError('Archive contains an unsafe member path')
        framework = lock['framework']
        info = plistlib.loads(archive.extractfile(framework + '/Info.plist').read())
        libraries = {entry['LibraryIdentifier']: entry for entry in info['AvailableLibraries']}
        if framework + '/' + lock['stdlib'] + '/encodings/__init__.py' not in names:
            raise ValueError('The support archive does not contain its standard library')
        slices = {}
        for target, spec in lock['slices'].items():
            entry = libraries.get(spec['library'])
            if not entry or spec['architecture'] not in entry['SupportedArchitectures']:
                raise ValueError('Required XCFramework slice is missing: ' + target)
            variant = 'simulator' if target == 'simulator' else None
            if entry['SupportedPlatform'] != 'ios' or entry.get('SupportedPlatformVariant') != variant:
                raise ValueError('XCFramework platform mismatch: ' + target)
            base = framework + '/' + spec['library']
            if base + '/' + entry['BinaryPath'] not in names:
                raise ValueError('Python framework binary is missing: ' + target)
            header = archive.extractfile(base + '/Python.framework/Headers/patchlevel.h').read().decode('utf-8')
            match = re.search(r'#define\s+PY_VERSION\s+"([^"]+)"', header)
            if not match or not match[1].startswith('3.12.'):
                raise ValueError('Python headers have an unexpected version')
            dyn = base + '/lib-' + spec['architecture'] + '/python3.12/lib-dynload/'
            modules = {PurePosixPath(name).name.split('.')[0] for name in names if name.startswith(dyn) and name.endswith('.so')}
            missing = set(lock['required_extensions']) - modules
            if missing:
                raise ValueError('{} lacks extension modules: {}'.format(target, sorted(missing)))
            slices[target] = {'python': match[1], 'library': spec['library'], 'extensions': sorted(modules)}
    return {'release': lock['release'], 'sha256': lock['sha256'], 'slices': slices}


def extract_archive(path, destination, lock):
    report = inspect_archive(path, lock)
    destination = Path(destination)
    if destination.exists() and any(destination.iterdir()):
        raise ValueError('Extraction destination must be empty: {}'.format(destination))
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, 'r:gz') as archive:
        # Preserve internal relative symlinks; reject links escaping the output.
        archive.extractall(destination, filter='data')
    return report


def stage_application(framework, app, target, lock, bundle_id):
    framework, app = Path(framework), Path(app)
    spec = lock['slices'][target]
    source = framework / spec['library']
    destination = app / 'Frameworks/Python.framework'
    home = app / 'python-stdlib'
    if destination.exists() or home.exists():
        raise ValueError('Python is already staged in {}'.format(app))
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source / 'Python.framework', destination, symlinks=True,
                    ignore=shutil.ignore_patterns('Headers', 'Modules', '_CodeSignature'))
    python_info_path = destination / 'Info.plist'
    if python_info_path.is_file():
        python_info = plistlib.loads(python_info_path.read_bytes())
        python_info['CFBundleSupportedPlatforms'] = ['iPhoneSimulator' if target == 'simulator' else 'iPhoneOS']
        python_info_path.write_bytes(plistlib.dumps(python_info))

    def stdlib_ignores(directory, names):
        ignored = {'__pycache__'}
        if Path(directory).name == 'python3.12':
            ignored.add('test')  # CPython's own ~27 MiB test suite, not unittest.
        return ignored.intersection(names)

    shutil.copytree(framework / 'lib', home / 'lib', symlinks=True, ignore=stdlib_ignores)
    specific = source / ('lib-' + spec['architecture'])
    shutil.copytree(specific, home / 'lib', dirs_exist_ok=True, symlinks=True)
    dynload = home / 'lib/python3.12/lib-dynload'
    installed = []
    template = plistlib.loads((framework / 'build/iOS-dylib-Info-template.plist').read_bytes())
    for extension in sorted(dynload.glob('*.so')):
        name = extension.name.split('.')[0]
        if name.startswith('_test') or name in TEST_EXTENSIONS:
            extension.unlink()
            continue
        module_framework = app / 'Frameworks' / (name + '.framework')
        if module_framework.exists():
            raise ValueError('Duplicate extension framework: ' + name)
        module_framework.mkdir()
        binary = module_framework / name
        shutil.move(str(extension), binary)
        binary.chmod(0o755)
        info = dict(template, CFBundleExecutable=name, CFBundleIdentifier=bundle_id + '.' + name.replace('_', '-'))
        info['CFBundleSupportedPlatforms'] = ['iPhoneSimulator' if target == 'simulator' else 'iPhoneOS']
        (module_framework / 'Info.plist').write_bytes(plistlib.dumps(info))
        marker = extension.with_suffix('.fwork')
        marker.write_text(binary.relative_to(app).as_posix() + '\n', encoding='utf-8')
        (module_framework / (name + '.origin')).write_text(marker.relative_to(app).as_posix() + '\n', encoding='utf-8')
        privacy = dynload / (name + '.xcprivacy')
        if privacy.exists():
            shutil.move(str(privacy), module_framework / 'PrivacyInfo.xcprivacy')
        installed.append(name)
    missing = set(lock['required_extensions']) - set(installed)
    if missing:
        raise ValueError('Incomplete runtime staging: ' + ', '.join(sorted(missing)))
    # Build-time libpython symlinks are not runtime modules.
    for link in home.rglob('libpython*.dylib'):
        link.unlink()
    return {'target': target, 'home': 'python-stdlib', 'extension_frameworks': installed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lock', type=Path, default=LOCK_PATH)
    commands = parser.add_subparsers(dest='command', required=True)
    fetch = commands.add_parser('fetch')
    fetch.add_argument('--cache', type=Path, required=True)
    fetch.add_argument('--extract', type=Path)
    fetch.add_argument('--report', type=Path, required=True)
    stage = commands.add_parser('stage')
    stage.add_argument('--framework', type=Path, required=True)
    stage.add_argument('--app', type=Path, required=True)
    stage.add_argument('--target', choices=['device', 'simulator'], required=True)
    stage.add_argument('--bundle-id', required=True)
    args = parser.parse_args()
    lock = read_lock(args.lock)
    if args.command == 'fetch':
        archive = download(lock, args.cache)
        report = extract_archive(archive, args.extract, lock) if args.extract else inspect_archive(archive, lock)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        print('Verified CPython support:', archive)
    else:
        print(json.dumps(stage_application(args.framework, args.app, args.target, lock, args.bundle_id), indent=2))


if __name__ == '__main__':
    main()
