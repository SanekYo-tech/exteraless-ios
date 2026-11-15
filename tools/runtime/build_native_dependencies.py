"""macOS component build/probe for pinned cp312 iOS native dependency candidates.

Build and execution are separate phases. The result is diagnostic until every
extension passes the reviewed OWN_GIL admission policy. No IPA is postprocessed.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile

import native_dependencies as native
from pinned_download import digest, fetch
from prepare_telegram_runtime import extract_support, inventory, prune_build_resources
import support
from validate_runtime import select_simulator


ROOT = Path(__file__).resolve().parents[2]
EXECUTABLE = 'NativeDependencyProbe'
BUNDLE_ID = 'com.exteraless.native-dependencies'
SOURCES = ('tools/runtime/build_native_dependencies.py', 'tools/runtime/native_dependencies.py',
           'tools/runtime/native_dependency_probe.c', 'tools/runtime/native_dependency_checks.py',
           'tools/runtime/pinned_download.py', 'tools/runtime/prepare_telegram_runtime.py',
           'tools/runtime/support.py', 'tools/runtime/validate_runtime.py',
           'telegram-ios/build-system/Make/RuntimePackaging.py')


def run(command, *, log, cwd=None, env=None, timeout=300, capture=False):
    command = [str(part) for part in command]
    log.write('COMMAND ' + json.dumps(command) + '\n')
    log.flush()
    return subprocess.run(command, check=True, cwd=cwd, env=env, timeout=timeout,
                          text=True, stdout=subprocess.PIPE if capture else log, stderr=log)


def source_fingerprint():
    return {name: digest(ROOT / name) for name in SOURCES}


def package_candidates(output):
    with tarfile.open(output / 'native-candidates.tar.gz', 'w:gz') as archive:
        for path in sorted((output / 'candidates').iterdir()):
            archive.add(path, arcname=path.name)


def build_lxml(package, lock, cache, work, app, framework, target, flags, env, log, transport):
    """Compile the release's generated C plus pinned static libxml2/libxslt.

    No host Python headers, Cython regeneration, runtime pip, system/Homebrew
    libxml2 or automatic source downloads are used by this recipe.
    """
    source_root = work / 'sources'
    source_root.mkdir(parents=True)
    for key in [package['source_artifact'], *package['library_artifacts']]:
        archive = fetch(lock['artifacts'][key], cache / 'downloads', transport=transport)
        native.unpack_source(archive, source_root)
    lxml = source_root / ('lxml-' + package['version'])
    xml = source_root / lock['artifacts']['libxml2-source']['filename'].removesuffix('.tar.xz')
    xslt = source_root / lock['artifacts']['libxslt-source']['filename'].removesuffix('.tar.xz')
    prefix = work / 'prefix'
    compiler_env = dict(env, CFLAGS=shlex.join(flags + ['-O1', '-fPIC']),
                        LDFLAGS=shlex.join(flags), CPPFLAGS='')
    xml_build = work / 'libxml2-build'
    xml_build.mkdir()
    run(['/bin/sh', xml / 'configure', '--host=aarch64-apple-darwin', '--prefix=' + str(prefix),
         '--disable-shared', '--enable-static', '--without-python'], cwd=xml_build,
        env=compiler_env, log=log)
    # The release Makefiles also contain target-platform programs/docs/tests.
    # Build/install only the native libraries, public headers and config scripts.
    run(['make', '-j2', 'libxml2.la'], cwd=xml_build, env=compiler_env, log=log, timeout=600)
    run(['make', 'install-libLTLIBRARIES', 'install-binSCRIPTS', 'install-pkgconfigDATA'],
        cwd=xml_build, env=compiler_env, log=log)
    run(['make', '-C', 'include/libxml', 'install'], cwd=xml_build, env=compiler_env, log=log)
    xslt_build = work / 'libxslt-build'
    xslt_build.mkdir()
    compiler_env.update(
        LIBXML_CFLAGS='-I' + shlex.quote(str(prefix / 'include/libxml2')),
        LIBXML_LIBS='-L' + shlex.quote(str(prefix / 'lib')) + ' -lxml2 -lz -liconv -lm',
        XML2_CONFIG=str(prefix / 'bin/xml2-config'),
        PKG_CONFIG_PATH=str(prefix / 'lib/pkgconfig'),
    )
    run(['/bin/sh', xslt / 'configure', '--host=aarch64-apple-darwin', '--prefix=' + str(prefix),
         '--disable-shared', '--enable-static', '--without-python', '--without-crypto',
         '--with-libxml-prefix=' + str(prefix)], cwd=xslt_build, env=compiler_env, log=log)
    for subdir in ('libxslt', 'libexslt'):
        run(['make', '-C', subdir, '-j2'], cwd=xslt_build, env=compiler_env, log=log, timeout=600)
        run(['make', '-C', subdir, 'install'], cwd=xslt_build, env=compiler_env, log=log)
    vendor = app / 'python/native-vendor'
    for path in sorted((lxml / 'src/lxml').rglob('*')):
        if path.is_file() and path.suffix not in native.BUILD_SUFFIXES and 'tests' not in path.parts:
            destination = vendor / 'lxml' / path.relative_to(lxml / 'src/lxml')
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
    dist_info = 'lxml-' + package['version'] + '.dist-info'
    (vendor / dist_info).mkdir()
    shutil.copyfile(lxml / 'PKG-INFO', vendor / dist_info / 'METADATA')
    (vendor / dist_info / 'INSTALLER').write_text('exteraless-ios-source-build\n')
    (vendor / dist_info / 'WHEEL').write_text(
        'Wheel-Version: 1.0\nGenerator: exteraless-ios-source-build\nRoot-Is-Purelib: false\n'
        'Tag: cp312-cp312-ios_15_0_arm64_' + ('iphoneos' if target == 'device' else 'iphonesimulator') + '\n')
    frameworks = []
    for module in ('etree', 'objectify'):
        binary = work / (module + '.cpython-312-' + ('iphoneos' if target == 'device' else 'iphonesimulator') + '.so')
        run([env['CC'], *flags, '-O1', '-fPIC', '-fno-strict-aliasing',
             '-I', framework / 'Headers', '-I', lxml / 'src', '-I', lxml / 'src/lxml/includes',
             '-I', prefix / 'include/libxml2', '-I', prefix / 'include',
             '-bundle', lxml / ('src/lxml/' + module + '.c'),
             '-F', framework.parent, '-framework', 'Python',
             prefix / 'lib/libexslt.a', prefix / 'lib/libxslt.a', prefix / 'lib/libxml2.a',
             '-lz', '-liconv', '-lm', '-Wl,-rpath,@loader_path/..', '-o', binary],
            log=log, env=env, timeout=600)
        frameworks.append(native.install_extension(binary, 'lxml/' + binary.name, app, package, target, BUNDLE_ID))
    native.rewrite_record(vendor, dist_info, package['import_roots'])
    return frameworks


def build(args):
    lock = native.read_lock()
    pylock = support.read_lock()
    if pylock['sha256'] != lock['support_sha256']:
        raise ValueError('Native build and CPython support pins disagree')
    args.output.mkdir(parents=True, exist_ok=True)
    with (args.output / 'build.log').open('w', encoding='utf-8') as log:
        xcode = run(['xcodebuild', '-version'], log=log, capture=True).stdout.strip()
        key_data = {'native_lock': digest(native.LOCK_PATH), 'support': pylock['sha256'],
                    'sources': source_fingerprint(), 'xcode': xcode}
        key = hashlib.sha256(json.dumps(key_data, sort_keys=True).encode()).hexdigest()
        previous = args.output / 'build-manifest.json'
        if previous.exists():
            report = json.loads(previous.read_text())
            if report['cache_key'] != key:
                raise ValueError('Native output belongs to different build inputs; use a fresh --output')
            for target, value in report['targets'].items():
                root = args.output / target / (EXECUTABLE + '.app')
                if inventory(root) != value['files']:
                    raise ValueError('Cached native candidate was modified')
            print('Verified cached native candidate build:', key)
            return
        archive = fetch({'filename': pylock['archive'], 'url': pylock['url'], 'sha256': pylock['sha256']},
                        args.cache / 'downloads', transport=args.transport)
        support.inspect_archive(archive, pylock)
        extracted = args.output / 'support'
        if extracted.exists():
            raise ValueError('Incomplete native build output; use a fresh --output')
        extract_support(archive, extracted, pylock)
        report = {'schema': 1, 'cache_key': key, 'inputs': key_data, 'targets': {},
                  'actual_cpython': lock['actual_cpython'], 'execution_verified': False,
                  'admitted_packages': []}
        for target in lock['targets']:
            spec = pylock['slices'][target]
            folder = args.output / target
            folder.mkdir()
            app = folder / (EXECUTABLE + '.app')
            support.stage_application(extracted / pylock['framework'], app, target, pylock, BUNDLE_ID)
            prune_build_resources(app / 'python-stdlib')
            framework = extracted / pylock['framework'] / spec['library'] / 'Python.framework'
            version = re.search(r'#define\s+PY_VERSION\s+"([^"]+)"', (framework / 'Headers/patchlevel.h').read_text())
            if not version or version[1] != lock['actual_cpython']:
                raise ValueError('Native build needs the same CPython 3.12.16 headers')
            sdk = run(['xcrun', '--sdk', spec['sdk'], '--show-sdk-path'], log=log, capture=True).stdout.strip()
            clang = run(['xcrun', '--sdk', spec['sdk'], '--find', 'clang'], log=log, capture=True).stdout.strip()
            flags = ['-target', spec['target'], '-isysroot', sdk]
            env = dict(os.environ, CC=clang, CXX=clang + '++',
                       AR=run(['xcrun', '--find', 'ar'], log=log, capture=True).stdout.strip(),
                       RANLIB=run(['xcrun', '--find', 'ranlib'], log=log, capture=True).stdout.strip(),
                       MACOSX_DEPLOYMENT_TARGET='', IPHONEOS_DEPLOYMENT_TARGET=lock['minimum_ios'])
            frames = []
            for package in lock['packages']:
                work = folder / package['name']
                work.mkdir()
                if package['recipe'] == 'ios-wheel':
                    artifact = lock['artifacts'][package['artifacts'][target]]
                    wheel = fetch(artifact, args.cache / 'downloads', transport=args.transport)
                    frames.extend(native.stage_wheel(wheel, work / 'wheel', app, package, target, BUNDLE_ID))
                else:
                    frames.extend(build_lxml(package, lock, args.cache, work, app, framework,
                                             target, flags, env, log, args.transport))
            run([clang, *flags, '-std=c11', '-O1', '-I', framework / 'Headers',
                 ROOT / 'tools/runtime/native_dependency_probe.c', '-F', framework.parent,
                 '-framework', 'Python', '-framework', 'Foundation',
                 '-Wl,-rpath,@executable_path/Frameworks', '-o', app / EXECUTABLE], log=log)
            shutil.copyfile(ROOT / 'tools/runtime/native_dependency_checks.py', app / 'native_dependency_checks.py')
            (app / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': BUNDLE_ID, 'CFBundleExecutable': EXECUTABLE,
                'CFBundleName': EXECUTABLE, 'CFBundlePackageType': 'APPL',
                'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
                'CFBundleSupportedPlatforms': ['iPhoneOS' if target == 'device' else 'iPhoneSimulator'],
                'MinimumOSVersion': lock['minimum_ios'], 'UIDeviceFamily': [1, 2],
            }))
            policy = native.policy_document(lock, digest(native.LOCK_PATH), target, frames)
            policy['diagnostic_only'] = True
            native.write_json(app / 'python/native-dependencies.json', policy)
            report['targets'][target] = {'frameworks': frames, 'files': inventory(app)}
        native.write_json(previous, report)
        # Framework/resource inputs only: no unsigned app ZIP is amended.
        candidate = {'schema': 1, 'native_lock_sha256': digest(native.LOCK_PATH),
                     'support_sha256': lock['support_sha256'], 'actual_cpython': lock['actual_cpython'],
                     'execution_verified': False, 'targets': {}, 'admitted_packages': []}
        for target, data in report['targets'].items():
            app = args.output / target / (EXECUTABLE + '.app')
            destination = args.output / 'candidates' / target
            for entry in data['frameworks']:
                frame = 'Frameworks/' + entry['framework'] + '.framework'
                shutil.copytree(app / frame, destination / frame)
            shutil.copytree(app / 'python', destination / 'python')
            candidate['targets'][target] = {'frameworks': data['frameworks'], 'files': inventory(destination)}
        native.write_json(args.output / 'candidates/native-inputs.json', candidate)
        package_candidates(args.output)
    print('Native candidates built; actual OWN_GIL execution remains unverified')


def run_probe(command, log):
    process = subprocess.Popen([str(value) for value in command], stdout=log, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        code = process.wait(timeout=20)
        if code:
            raise RuntimeError('Native dependency probe exited with status ' + str(code))
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
        raise RuntimeError('Native dependency probe exceeded 20 seconds')


def probe(args):
    lock = native.read_lock()
    report = json.loads((args.output / 'build-manifest.json').read_text())
    if report['inputs']['sources'] != source_fingerprint() or report['inputs']['native_lock'] != digest(native.LOCK_PATH):
        raise ValueError('Native inputs changed after compilation')
    source = args.output / 'simulator' / (EXECUTABLE + '.app')
    if inventory(source) != report['targets']['simulator']['files']:
        raise ValueError('Compiled simulator candidate was modified')
    app = args.output / 'probe' / source.name
    if app.exists():
        raise ValueError('Probe output must be fresh')
    shutil.copytree(source, app)
    with (args.output / 'probe.log').open('w', encoding='utf-8') as log:
        for framework in sorted((app / 'Frameworks').glob('*.framework')):
            run(['codesign', '--force', '--sign', '-', '--timestamp=none', framework], log=log, timeout=30)
        run(['codesign', '--force', '--sign', '-', '--timestamp=none', app], log=log, timeout=30)
        sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], log=log, capture=True, timeout=30).stdout.strip()
        devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'],
                                 log=log, capture=True, timeout=30).stdout)['devices']
        runtime, template = select_simulator(devices, sdk, args.simulator_device)
        udid = run(['xcrun', 'simctl', 'clone', template['udid'], 'Exteraless Native Dependencies'],
                   log=log, capture=True, timeout=30).stdout.strip()
        results = []
        try:
            for package in lock['packages']:
                modules = [entry['module'] for entry in report['targets']['simulator']['frameworks']
                           if entry['package'] == package['name']]
                for mode in ('main', 'own-gil'):
                    path = args.output / (package['name'] + '-' + mode + '-ios.json')
                    run_probe(['xcrun', 'simctl', 'spawn', '--standalone', udid, app / EXECUTABLE,
                               app, package['name'], ','.join(modules), mode, path], log)
                    data = json.loads(path.read_text())
                    if data.get('native_completed') is not True or data.get('actual_cpython') != lock['actual_cpython']:
                        raise RuntimeError('Incomplete or wrong-version native probe')
                    if mode == 'main' and not all(item.get('ok') is True for item in data['results']):
                        raise RuntimeError('Native main-interpreter fixture failed: ' + package['name'])
                    if mode == 'own-gil':
                        if package['own_gil'] == 'unsupported':
                            if (data.get('own_gil_supported') or not all(item.get('error_type') == 'ImportError'
                                    and ('does not support loading in subinterpreters' in item.get('error', '')
                                         or 'Interpreter change detected' in item.get('error', '')) for item in data['results'])):
                                raise RuntimeError('Native ABI constraint was not reproduced: ' + package['name'])
                        else:
                            native.validate_admission(lock, package, data)
                    data.update(execution='simctl spawn --standalone', application_installation_verified=False,
                                probe_timeout_seconds=20, native_lock_sha256=digest(native.LOCK_PATH),
                                binary_sha256s={target: {entry['module']: entry['binary_sha256']
                                    for entry in report['targets'][target]['frameworks'] if entry['package'] == package['name']}
                                    for target in lock['targets']})
                    native.write_json(path, data)
                    results.append(data)
        finally:
            run(['xcrun', 'simctl', 'delete', udid], log=log, timeout=30)
    native.write_json(args.output / 'native-execution.json', {
        'schema': 1, 'actual_cpython': lock['actual_cpython'], 'runtime': runtime,
        'results': results, 'execution_verified': True, 'admitted_packages': [],
        'meaning': 'Main operations and OWN_GIL constraints checked; unsupported packages are not admitted',
    })
    candidate_path = args.output / 'candidates/native-inputs.json'
    candidate = json.loads(candidate_path.read_text())
    candidate.update(execution_verified=True, evidence={item['package']: item for item in results if item['mode'] == 'own-gil'})
    candidate['admitted_packages'] = [package['name'] for package in lock['packages']
                                     if package['production_eligible'] and candidate['evidence'][package['name']]['own_gil_supported']]
    native.write_json(candidate_path, candidate)
    package_candidates(args.output)
    print('Real iOS native dependency checks completed; admission is distinct from successful diagnostics')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', choices=('build', 'probe'), required=True)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--transport', choices=('curl', 'urllib'), default='curl')
    parser.add_argument('--simulator-device', default='iPhone 17')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Native cross-compilation/probes require macOS and Xcode')
    args.output, args.cache = args.output.resolve(), args.cache.resolve()
    try:
        (build if args.phase == 'build' else probe)(args)
    except Exception as error:
        native.write_json(args.output / 'component-failure.json', {
            'phase': args.phase, 'error': str(error), 'execution_verified': False,
            'native_lock_sha256': digest(native.LOCK_PATH),
        })
        raise


if __name__ == '__main__':
    main()
