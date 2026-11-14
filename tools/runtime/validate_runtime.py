"""Build bounded native embedding probes and run the simulator one on macOS.

Uses the exact same built-in C bridge on Windows (check_host_embedding.py),
iOS device and simulator. Does not build Telegram or execute any plugins.
"""

import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import zipfile

from support import ROOT, digest, read_lock, stage_application


BUNDLE_ID = 'com.exteraless.python-smoke'
EXECUTABLE = 'ExteralessPythonSmoke'


def run(*args, timeout=180, capture=False):
    return subprocess.run([str(arg) for arg in args], check=True, timeout=timeout,
                          text=True, stdout=subprocess.PIPE if capture else None)


def build_target(framework, output, target, lock):
    spec = lock['slices'][target]
    folder = output / target
    folder.mkdir(parents=True)
    app = folder / (EXECUTABLE + '.app')
    app.mkdir()
    sdk = run('xcrun', '--sdk', spec['sdk'], '--show-sdk-path', capture=True).stdout.strip()
    common = ['-target', spec['target'], '-isysroot', sdk, '-Os']
    native = ROOT / 'python/runtime'
    includes = ['-I', str(framework / spec['library'] / 'Python.framework/Headers'),
                '-I', str(native / 'include'), '-I', str(native / 'smoke')]
    objects = []
    for source in (ROOT / 'python/bridge/_exteraless_bridge.c', native / 'register_bridge.c', native / 'smoke/runtime_probe.c'):
        obj = folder / (source.stem + '.o')
        run('xcrun', '--sdk', spec['sdk'], 'clang', *common, *includes,
            '-std=c11', '-Werror=implicit-function-declaration', '-c', source, '-o', obj)
        objects.append(obj)
    library = folder / 'libExteralessPythonBridge.a'
    run('xcrun', 'libtool', '-static', '-o', library, *objects[:2])
    run('xcrun', '--sdk', spec['sdk'], 'clang', *common, *includes, '-fobjc-arc',
        native / 'smoke/main.m', objects[2], library,
        '-F', framework / spec['library'], '-framework', 'Python',
        '-framework', 'Foundation', '-framework', 'UIKit',
        '-Wl,-rpath,@executable_path/Frameworks', '-o', app / EXECUTABLE)
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': BUNDLE_ID, 'CFBundleExecutable': EXECUTABLE,
        'CFBundleName': EXECUTABLE, 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.1',
        'MinimumOSVersion': '15.0', 'UIDeviceFamily': [1, 2],
        'CFBundleSupportedPlatforms': ['iPhoneSimulator' if target == 'simulator' else 'iPhoneOS'],
        'LSRequiresIPhoneOS': True, 'UILaunchScreen': {},
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
    }))
    manifest = stage_application(framework, app, target, lock, BUNDLE_ID)
    if target == 'simulator':
        # The simulator uses ad-hoc signatures only; no Apple signing identity.
        for item in sorted((app / 'Frameworks').glob('*.framework')):
            run('codesign', '--force', '--sign', '-', '--timestamp=none', item)
        run('codesign', '--force', '--sign', '-', '--timestamp=none', app)
    return app, library, manifest


def simulator_probe(app, output):
    devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '-j', capture=True).stdout)['devices']
    candidate = None
    for runtime, entries in sorted(devices.items(), reverse=True):
        if '.iOS-' not in runtime:
            continue
        for item in entries:
            if item.get('isAvailable') and item.get('deviceTypeIdentifier') and item['name'].startswith('iPhone'):
                candidate = (runtime, item['deviceTypeIdentifier'])
                break
        if candidate:
            break
    if candidate is None:
        raise RuntimeError('No installed iPhone simulator runtime is available on this runner')
    runtime, device_type = candidate
    udid = run('xcrun', 'simctl', 'create', 'Exteraless Python Probe', device_type, runtime, capture=True).stdout.strip()
    try:
        run('xcrun', 'simctl', 'boot', udid)
        run('xcrun', 'simctl', 'bootstatus', udid, '-b', timeout=240)
        run('xcrun', 'simctl', 'install', udid, app)
        run('xcrun', 'simctl', 'launch', '--console', '--terminate-running-process', udid, BUNDLE_ID, '--ci-exit', timeout=90)
        container = Path(run('xcrun', 'simctl', 'get_app_container', udid, BUNDLE_ID, 'data', capture=True).stdout.strip())
        report = json.loads((container / 'Documents/runtime-smoke.json').read_text(encoding='utf-8'))
        if report.get('ok') is not True or report.get('own_gil_interpreters') != 2 or report.get('platform') != 'ios':
            raise RuntimeError('Simulator embedding checks did not pass: {}'.format(report))
        (output / 'simulator-smoke.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        return report
    finally:
        subprocess.run(['xcrun', 'simctl', 'shutdown', udid], check=False, timeout=60)
        subprocess.run(['xcrun', 'simctl', 'delete', udid], check=False, timeout=60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--support', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Apple SDK validation requires the macOS runner')
    if args.output.exists() and any(args.output.iterdir()):
        parser.error('Output must be empty to avoid reusing stale smoke results')
    args.output.mkdir(parents=True, exist_ok=True)
    lock = read_lock()
    framework = args.support / lock['framework']
    device, device_lib, device_manifest = build_target(framework, args.output, 'device', lock)
    simulator, sim_lib, sim_manifest = build_target(framework, args.output, 'simulator', lock)
    runtime_report = simulator_probe(simulator, args.output)
    run('xcodebuild', '-create-xcframework',
        '-library', device_lib, '-headers', ROOT / 'python/runtime/include',
        '-library', sim_lib, '-headers', ROOT / 'python/runtime/include',
        '-output', args.output / 'ExteralessPythonBridge.xcframework')
    ipa = args.output / 'ExteralessPythonSmoke-unsigned.ipa'
    with zipfile.ZipFile(ipa, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(device.rglob('*')):
            if path.is_file():
                archive.write(path, 'Payload/' + device.name + '/' + path.relative_to(device).as_posix())
    report = {
        'support': {'release': lock['release'], 'sha256': lock['sha256']},
        'xcode': run('xcodebuild', '-version', capture=True).stdout.strip(),
        'bridge_source_sha256': digest(ROOT / 'python/bridge/_exteraless_bridge.c'),
        'device': device_manifest, 'simulator': sim_manifest, 'smoke': runtime_report,
        'device_ipa_sha256': digest(ipa), 'device_installation_verified': False,
    }
    (args.output / 'runtime-manifest.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print('Runtime validation complete: device compiled; simulator ran CPython + built-in bridge')


if __name__ == '__main__':
    main()
