"""Build bounded native embedding probes and run the simulator one on macOS.

Uses the exact same built-in C bridge on Windows (check_host_embedding.py),
iOS device and simulator. Does not build Telegram or execute any plugins.
"""

import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time
import zipfile

from support import ROOT, digest, read_lock, stage_application


BUNDLE_ID = 'com.exteraless.python-smoke'
EXECUTABLE = 'ExteralessPythonSmoke'


def run(*args, timeout=180, capture=False):
    if not capture:
        print('Runtime step:', ' '.join(str(arg) for arg in args), flush=True)
    start = time.monotonic()
    try:
        return subprocess.run([str(arg) for arg in args], check=True, timeout=timeout,
                              text=True, stdout=subprocess.PIPE if capture else None)
    finally:
        if not capture:
            print('Runtime step elapsed: {:.1f}s'.format(time.monotonic() - start), flush=True)


def completed_report(path, timeout=10):
    """Wait briefly for an atomic report, not just simctl accepting a launch.

    Bounded to ten seconds in CI; a missing or partial report is never success.
    The app writes native_completed only AFTER Py_FinalizeEx has returned.
    """
    deadline = time.monotonic() + timeout
    latest = None
    while True:
        try:
            latest = json.loads(Path(path).read_text(encoding='utf-8'))
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        if latest and latest.get('native_completed'):
            return latest
        if time.monotonic() >= deadline:
            raise RuntimeError('Probe produced no completed report; last phase: {}'.format(latest))
        time.sleep(0.1)


def collect_probe_diagnostics(udid, output, report_path, error):
    (output / 'probe-failure.json').write_text(json.dumps({'error': str(error)}, indent=2), encoding='utf-8')
    if report_path is not None and report_path.is_file():
        shutil.copyfile(report_path, output / 'simulator-smoke.json')
    try:
        with (output / 'simulator.log').open('w', encoding='utf-8') as log:
            subprocess.run(['xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--last', '5m',
                            '--style', 'compact', '--predicate',
                            'process == "ExteralessPythonSmoke" OR eventMessage CONTAINS[c] "ExteralessPythonSmoke"'],
                           stdout=log, stderr=subprocess.STDOUT, timeout=45, check=False)
    except (OSError, subprocess.TimeoutExpired) as diagnostic_error:
        print('Could not finish simulator log capture:', diagnostic_error)
    folders = [Path.home() / 'Library/Logs/DiagnosticReports',
               Path.home() / 'Library/Developer/CoreSimulator/Devices' / udid / 'data/Library/Logs/CrashReporter']
    for folder in folders:
        for crash in list(folder.glob(EXECUTABLE + '*'))[:5]:
            if crash.is_file() and crash.stat().st_size < 4 * 1024 * 1024:
                shutil.copy2(crash, output / crash.name)


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


def select_simulator(devices, sdk_version):
    """Use a generic iOS runtime supported by the selected Xcode SDK.

    A reverse string sort selected iOS-27-2-iPhone19-4 (iPhone Duo) with
    Xcode 27.1. That device never started our process. Hardware-specific
    runtime variants and runtimes newer than the active SDK are excluded.
    """
    if not re.fullmatch(r'\d+(?:\.\d+){0,2}', sdk_version):
        raise ValueError('Unrecognized simulator SDK version: ' + sdk_version)

    def version(parts):
        return tuple(int(part) for part in parts) + (0,) * (3 - len(parts))

    sdk = version(sdk_version.split('.'))
    candidates = []
    for runtime, entries in devices.items():
        match = re.fullmatch(r'com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+(?:-\d+){0,2})', runtime)
        if not match:
            continue
        release = version(match[1].split('-'))
        if not (15, 0, 0) <= release <= sdk:
            continue
        phones = [item for item in entries
                  if item.get('isAvailable') and item.get('deviceTypeIdentifier')
                  and item.get('name', '').startswith('iPhone ')
                  and item.get('state') == 'Shutdown']
        if phones:
            # Prefer the ordinary numbered model over Pro/Max/Air variants.
            phones.sort(key=lambda item: (not bool(re.fullmatch(r'iPhone \d+', item['name'])), item['name']))
            candidates.append((release, runtime, phones[0]))
    if not candidates:
        raise RuntimeError('No generic iPhone runtime compatible with SDK {}; available: {}'.format(
            sdk_version, ', '.join(sorted(devices))))
    _, runtime, template = max(candidates, key=lambda item: item[0])
    return runtime, template


def simulator_probe(app, output):
    sdk_version = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version', capture=True).stdout.strip()
    devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '-j', capture=True).stdout)['devices']
    (output / 'simulator-inventory.json').write_text(json.dumps({
        'sdk_version': sdk_version, 'devices': devices,
    }, indent=2), encoding='utf-8')
    runtime, template = select_simulator(devices, sdk_version)
    print('Selected simulator: {} / {} (SDK {})'.format(runtime, template['name'], sdk_version), flush=True)
    # Clone the runner's pre-created device data instead of creating another
    # fully cold device. The original simulator is never booted or modified.
    udid = run('xcrun', 'simctl', 'clone', template['udid'], 'Exteraless Python Probe', capture=True).stdout.strip()
    (output / 'simulator-environment.json').write_text(json.dumps({
        'sdk_version': sdk_version,
        'runtime': runtime, 'device_type': template['deviceTypeIdentifier'],
        'template': template['name'], 'probe_udid': udid,
        'execution': 'simctl spawn (component probe, not an installation test)',
        'app_bytes': sum(path.stat().st_size for path in app.rglob('*') if path.is_file()),
        'app_files': sum(1 for path in app.rglob('*') if path.is_file()),
    }, indent=2), encoding='utf-8')
    report_path = None
    try:
        run('xcrun', 'simctl', 'bootstatus', udid, '-b', timeout=360)
        # Fail at the infrastructure boundary if even a system process cannot
        # launch. Its output is retained independently of the Python probe.
        with (output / 'simulator-health.log').open('w', encoding='utf-8') as log:
            subprocess.run(['xcrun', 'simctl', 'spawn', udid, 'launchctl', 'version'],
                           stdout=log, stderr=subprocess.STDOUT, timeout=30, check=True)
        report_path = output / 'native-report.json'
        command = ['xcrun', 'simctl', 'spawn', udid, str(app / EXECUTABLE), '--headless-report', str(report_path)]
        print('Running simulator component probe; output goes to probe-console.log', flush=True)
        with (output / 'probe-console.log').open('w', encoding='utf-8') as log:
            launched = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=90)
        report = completed_report(report_path)
        if launched.returncode != 0 or report.get('native_exit_status') != 0 or report.get('ok') is not True or report.get('own_gil_interpreters') != 2 or report.get('platform') != 'ios':
            raise RuntimeError('Simulator embedding checks did not pass: {}'.format(report))
        report['execution'] = 'simctl spawn'
        report['application_installation_verified'] = False
        (output / 'simulator-smoke.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        return report
    except Exception as error:
        collect_probe_diagnostics(udid, output, report_path, error)
        raise
    finally:
        for operation in ('shutdown', 'delete'):
            try:
                subprocess.run(['xcrun', 'simctl', operation, udid], check=False, timeout=60)
            except (OSError, subprocess.TimeoutExpired) as error:
                print('Simulator cleanup:', error)


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
