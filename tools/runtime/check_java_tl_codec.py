"""Compile shipping Foundation TL code, then run the seven Java-value codec cases.

The author-owned pytest supplies actual Python adapter output to one freshly
compiled executable (20s codec / 30s isolated child). The entire pytest process
group has a 30s bound, separate from the 240s compiler budget. This is a
Foundation codec control; it creates no SDK plugin or simulator process.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

from check_swift_components import run_phase, write_json

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = 'telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime'
COMPILE_SOURCES = (
    RUNTIME + '/TLCodec.swift', RUNTIME + '/TLSchemaGenerated.swift',
    'tools/compat/tests/fixtures/java_values/native_codec.swift',
)
TEST_SOURCE = 'tools/compat/tests/test_java_value_regressions.py'
TEST_NAME = 'test_java_bytes_through_native_tl_codec'
BUILD_TIMEOUT = 240
TEST_TIMEOUT = 30


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_fingerprint(root):
    files = {root / name for name in (*COMPILE_SOURCES, TEST_SOURCE,
        'tools/compat/tests/fixtures/java_values/schema.json', 'python/runtime/tl-schema.json',
        'tools/runtime/check_java_tl_codec.py', 'tools/runtime/check_swift_components.py')}
    for package in ('python/virtualjava', 'python/exteraless_runtime'):
        sources = set((root / package).rglob('*.py'))
        if not sources:
            raise ValueError('Missing Java adapter sources: ' + package)
        files.update(sources)
    return {path.relative_to(root).as_posix(): digest(path) for path in sorted(files)}


def validate_pytest_result(path):
    root = ET.parse(path).getroot()
    cases = list(root.iter('testcase'))
    if (len(cases) != 1 or cases[0].get('name') != TEST_NAME
            or any(list(root.iter(tag)) for tag in ('failure', 'error', 'skipped'))):
        raise ValueError('The named Java native TL test must execute once and pass without skips')
    return {'test': TEST_SOURCE + '::' + TEST_NAME, 'passed': True, 'codec_cases': 7}


def check_codec(root, output):
    report_path = output / 'java-tl-codec.json'
    report = {'ok': False, 'native_execution_verified': False, 'phase': 'sources',
              'probe': 'java-values-foundation-tl-codec', 'expected_codec_processes': 1,
              'build_timeout_seconds': BUILD_TIMEOUT, 'pytest_timeout_seconds': TEST_TIMEOUT,
              'codec_timeout_seconds': 20, 'isolated_child_timeout_seconds': 30,
              'boundary': 'Python Java adapter -> Foundation TL encode/decode; no UIKit or SDK plugin',
              'native_c_transport': 'not-run; separate platform-matching extension/receipt required'}
    write_json(report_path, report)
    try:
        inputs = source_fingerprint(root)
        schema = json.loads((root / 'python/runtime/tl-schema.json').read_text(encoding='utf-8'))
        report.update(source_sha256=inputs,
                      source_fingerprint=hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest(),
                      tl_schema={key: schema[key] for key in ('sourceSHA256', 'nativeLayoutHash')},
                      compile_sources=list(COMPILE_SOURCES), phase='toolchain')
        write_json(report_path, report)
        report['xcode_version'] = subprocess.check_output(['xcodebuild', '-version'], text=True, timeout=15).strip()
        if report['xcode_version'].splitlines()[0] != 'Xcode 26.6':
            raise ValueError('The Python Framework component requires actual Xcode 26.6')
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True, timeout=15).strip()
        report['swift_version'] = subprocess.check_output(['xcrun', '--sdk', 'macosx', 'swiftc', '--version'],
                                                        text=True, timeout=15).strip()
        executable = output / 'java-values-codec'
        report.update(sdk=sdk, phase='build')
        write_json(report_path, report)
        with tempfile.TemporaryDirectory(prefix='.java-tl-codec-compile-', dir=output.parent) as scratch:
            command = ['xcrun', '--sdk', 'macosx', 'swiftc', '-parse-as-library', '-Onone', '-sdk', sdk,
                       '-module-cache-path', str(Path(scratch) / 'module-cache'),
                       *(str(root / name) for name in COMPILE_SOURCES), '-o', str(executable)]
            report['build_seconds'] = run_phase(command, output, 'build', BUILD_TIMEOUT, cwd=root)
        if source_fingerprint(root) != inputs:
            raise ValueError('Java/native codec sources changed during compilation')
        report.update(executable_sha256=digest(executable), phase='test')
        write_json(report_path, report)
        junit = output / 'pytest.xml'
        env = dict(os.environ, EXTERALESS_JAVA_TL_CODEC=str(executable), PYTEST_DISABLE_PLUGIN_AUTOLOAD='1',
                   PYTHONDONTWRITEBYTECODE='1', PYTEST_ADDOPTS='')
        command = [sys.executable, '-B', '-m', 'pytest', TEST_SOURCE + '::' + TEST_NAME,
                   '-q', '-p', 'no:cacheprovider', '-o', 'addopts=', '--junitxml', str(junit),
                   '--basetemp', str(output / 'pytest-temp')]
        report['test_seconds'] = run_phase(command, output, 'test', TEST_TIMEOUT, env=env, cwd=root)
        report['result'] = validate_pytest_result(junit)
        if source_fingerprint(root) != inputs or digest(executable) != report['executable_sha256']:
            raise ValueError('Compiled Java/native codec identity changed during execution')
        report.update(ok=True, native_execution_verified=True, phase='complete')
    except (OSError, ValueError, subprocess.SubprocessError, ET.ParseError, KeyboardInterrupt) as error:
        report['error'] = str(error)
        raise
    finally:
        write_json(report_path, report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        parser.error('The Foundation Java codec control requires macOS arm64 / Xcode 26.6')
    output = args.output.expanduser().resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('--output must be fresh to exclude stale executables and pytest results')
    output.mkdir(parents=True, exist_ok=True)
    def interrupted(signum, frame):
        raise KeyboardInterrupt('Java codec step interrupted by signal ' + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    check_codec(ROOT, output)
    print('Java adapter/Foundation TL: seven native codec cases passed; ' + str(output))


if __name__ == '__main__':
    main()
