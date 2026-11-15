"""Compile complete Swift packages, then run their unfiltered tests with a deadline.

SwiftPM discovers every Sources/Tests file, including the new actor/lifecycle
surfaces. Compilation has its own budget; --skip-build keeps the 30-second test
deadline independent of a cold compiler cache. A timeout kills the owned process
group, including an XCTest child blocked behind a Swift actor or native worker.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ('ExteralessCore', 'PluginHost', 'PluginHooks')
BUILD_TIMEOUT = 240
TEST_TIMEOUT = 30


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def package_fingerprint(package):
    files = {package / 'Package.swift'}
    if (package / 'Package.resolved').is_file():
        files.add(package / 'Package.resolved')
    for directory in ('Sources', 'Tests'):
        found = [path for path in (package / directory).rglob('*')
                 if path.is_file() and not any(part.startswith('.') for part in path.relative_to(package).parts)]
        if not any(path.suffix == '.swift' for path in found):
            raise ValueError('Missing Swift package inputs: ' + str(package / directory))
        files.update(found)
    return {path.relative_to(package).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(files)}


def run_phase(command, output, phase, timeout, *, env=None, cwd=None):
    started = time.monotonic()
    with (output / (phase + '.log')).open('w', encoding='utf-8') as log:
        log.write('COMMAND ' + json.dumps(command) + '\n')
        log.flush()
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True, env=env, cwd=cwd)
        write_json(output / (phase + '-launcher.json'), {'pid': process.pid, 'command': command, 'timeout_seconds': timeout})
        try:
            result = process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            # Even if the launcher has exited, its XCTest child may still own the
            # group. Never fall back to killing unrelated Swift/XCTest processes.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
            raise
        if result:
            raise subprocess.CalledProcessError(result, command)
    return round(time.monotonic() - started, 3)


def check_package(package, output):
    inputs = package_fingerprint(package)
    report_path = output / 'swift-component-tests.json'
    report = {
        'ok': False, 'probe': 'swift-package-tests', 'package': package.name,
        'execution_platform': sys.platform, 'source_sha256': inputs,
        'swift_source_files': sum(name.startswith('Sources/') and name.endswith('.swift') for name in inputs),
        'swift_test_files': sum(name.startswith('Tests/') and name.endswith('.swift') for name in inputs),
        'unfiltered': True, 'jobs': 2, 'build_timeout_seconds': BUILD_TIMEOUT,
        'test_timeout_seconds': TEST_TIMEOUT, 'phase': 'toolchain',
    }
    write_json(report_path, report)
    try:
        report['swift_version'] = subprocess.check_output(['swift', '--version'], text=True, timeout=15).strip()
        common = ['--package-path', str(package), '--jobs', '2']
        for phase, command, timeout in (
            ('build', ['swift', 'build', '--build-tests', *common], BUILD_TIMEOUT),
            ('test', ['swift', 'test', '--skip-build', *common], TEST_TIMEOUT),
        ):
            report['phase'] = phase
            write_json(report_path, report)
            report[phase + '_seconds'] = run_phase(command, output, phase, timeout)
            if package_fingerprint(package) != inputs:
                raise ValueError('Swift package sources changed during ' + phase)
        report.update(ok=True, phase='complete')
    except (OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        report['error'] = str(error)
        raise
    finally:
        write_json(report_path, report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', choices=PACKAGES, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform not in ('darwin', 'linux'):
        parser.error('Swift component execution requires the macOS or Linux toolchain runner')
    output = args.output.expanduser().resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('--output must be empty to exclude stale test results')
    output.mkdir(parents=True, exist_ok=True)
    check_package(ROOT / 'swift' / args.package, output)
    print(args.package + ': all Swift sources/tests compiled and bounded unfiltered tests passed; ' + str(output))


if __name__ == '__main__':
    main()
