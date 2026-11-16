"""Compile the bounded IntegrationTests map, then run real XCTest classes serially.

Execution is macOS/arm64/Xcode 27.1 only, inside the claimed harness workspace.
The 30-second clock starts at XCTest's native suite-start event, not at Bazel,
simulator boot, bundle installation or runner startup. Missing/partial/skipped
XCTest observations are failures. No acceptance-harness scene/driver is changed.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import queue
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

from native_test_plan import build_plan, digest, verify_native_results
from native_test_disk import Limits as DiskLimits, checked_workspace, recover_capacity, observe_after_compile
from native_test_cache import ReadOnlyCache

ROOT = Path(__file__).resolve().parents[2]
ANSI = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
SUITE = re.compile(r"Test Suite '([^']+)' (started|passed|failed)")
CASE = re.compile(r"Test Case '(?:-\[([\w.]+) (test\w+)\]|([\w.]+)\.(test\w+)(?:\(\))?)' (started|passed|failed|skipped)")


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def output(command, *, timeout=20, check=True):
    result = subprocess.run([str(value) for value in command], text=True, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=check)
    return result.stdout.strip()


def select_runtime(types, runtimes, contract):
    devices = [item for item in types if item.get('name') == contract['device']]
    if len(devices) != 1:
        raise ValueError('The exact iPhone 17 device type is required')
    identifier = devices[0]['identifier']
    matches = [item for item in runtimes if item.get('isAvailable') is True
               and item.get('version') == contract['os_version']
               and re.fullmatch(r'com\.apple\.CoreSimulator\.SimRuntime\.iOS-27-\d+(?:-\d+)?', item.get('identifier', ''))
               and (not item.get('supportedDeviceTypes') or identifier in {
                   entry['identifier'] for entry in item['supportedDeviceTypes']})]
    if len(matches) != 1:
        raise ValueError('An available generic iOS {} runtime for {} is required; no SDK/runtime fallback'.format(
            contract['os_version'], contract['device']))
    return identifier, matches[0]['identifier']


class LogicClock:
    def __init__(self, case, contract, started):
        self.case, self.contract, self.started = case, contract, started
        self.logic_start = None
        self.logic_end = None
        self.started_methods, self.passed_methods, self.failures = set(), set(), []

    def observe(self, line, now):
        line = ANSI.sub('', line)
        suite = SUITE.search(line)
        if suite:
            name, state = suite.groups()
            if state == 'started' and self.logic_start is None:
                self.logic_start = now
            if name.split('.')[-1] == self.case['class'] and state in ('passed', 'failed'):
                self.logic_end = now
                if state == 'failed':
                    self.failures.append('XCTest suite failed')
        case = CASE.search(line)
        if case:
            first_class, first_method, second_class, second_method, state = case.groups()
            name, method = first_class or second_class, first_method or second_method
            if self.logic_start is None:
                self.logic_start = now
            if name.split('.')[-1] != self.case['class'] or method not in self.case['methods']:
                self.failures.append('Unexpected XCTest case: ' + name + '/' + method)
                return
            if state == 'started':
                if method in self.started_methods:
                    self.failures.append('Retried/duplicate XCTest case: ' + method)
                self.started_methods.add(method)
            elif state == 'passed':
                if method in self.passed_methods:
                    self.failures.append('Duplicate XCTest result: ' + method)
                self.passed_methods.add(method)
            else:
                self.failures.append(method + ': ' + state)

    def deadline(self):
        if self.logic_end is not None:
            return self.logic_end + self.contract['finalization_seconds'], 'runner finalization'
        if self.logic_start is not None:
            return self.logic_start + self.contract['logic_seconds'], 'XCTest logic'
        return self.started + self.contract['preparation_seconds'], 'runner preparation'

    def finish(self):
        required = set(self.case['methods'])
        if (not required or self.logic_start is None or self.logic_end is None or self.failures
                or self.started_methods != required or self.passed_methods != required):
            raise ValueError('Missing/partial/skipped native XCTest evidence: ' + repr({
                'class': self.case['class'], 'missing': sorted(required - self.passed_methods), 'failures': self.failures}))
        seconds = self.logic_end - self.logic_start
        if seconds > self.contract['logic_seconds']:
            raise ValueError('XCTest logic exceeded its 30-second budget')
        return {'class': self.case['class'], 'started_methods': sorted(self.started_methods),
                'passed_methods': sorted(self.passed_methods),
                'logic_seconds': round(seconds, 3), 'preparation_seconds': round(self.logic_start - self.started, 3)}


def stop_client(process, cancel_test=None):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGINT)  # Bazel forwards cancellation to its server/test action.
    try:
        if cancel_test is not None:
            cancel_test()  # Stop logic on the owned guest at the deadline, before waiting on Bazel.
    finally:
        if process.poll() is None:
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)


def run_logged(command, cwd, directory, timeout, *, case=None, contract=None, cancel_test=None):
    directory.mkdir(parents=True, exist_ok=True)
    write_json(directory / 'command.json', {'command': [str(value) for value in command], 'timeout_seconds': timeout})
    started = time.monotonic()
    clock = LogicClock(case, contract, started) if case else None
    events = queue.Queue(maxsize=512)
    process = subprocess.Popen([str(value) for value in command], cwd=cwd, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
                               start_new_session=True, env=dict(os.environ, PYTHONUNBUFFERED='1', NSUnbufferedIO='YES'))
    def reader():
        try:
            for line in iter(lambda: process.stdout.readline(65536), ''):
                events.put((time.monotonic(), line))
        finally:
            events.put((time.monotonic(), None))
    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    finished = False
    logged = 0
    try:
        with (directory / 'console.log').open('w', encoding='utf-8') as log:
            while not finished or process.poll() is None:
                now = time.monotonic()
                deadline, phase = clock.deadline() if clock else (started + timeout, 'build/analysis')
                deadline = min(deadline, started + timeout)
                if now >= deadline:
                    raise TimeoutError(phase + ' deadline exceeded')
                try:
                    observed, line = events.get(timeout=min(0.1, deadline - now))
                except queue.Empty:
                    continue
                if line is None:
                    finished = True
                    continue
                logged += len(line.encode('utf-8'))
                if logged > (8 if clock else 128) * 1024 * 1024:
                    raise ValueError('Native test/compiler log exceeded its bounded size')
                log.write(line)
                log.flush()
                # Preserve the last compiler/test events in the Actions log if
                # the runner disappears before the artifact-upload step.
                print(line, end='', flush=True)
                if clock:
                    clock.observe(line, observed)
        if process.wait(timeout=5) != 0:
            raise RuntimeError('Native test command failed; inspect ' + str(directory / 'console.log'))
        return clock.finish() if clock else {'seconds': round(time.monotonic() - started, 3)}
    except BaseException:
        stop_client(process, cancel_test)
        raise
    finally:
        process.stdout.close()
        thread.join(timeout=1)


def own_device(record):
    devices = json.loads(output(['xcrun', 'simctl', 'list', 'devices', '--json']))['devices']
    for runtime, items in devices.items():
        for device in items:
            if device.get('udid') == record['udid']:
                if (runtime != record['runtime'] or device.get('name') != record['name']
                        or device.get('deviceTypeIdentifier') != record['device_type']):
                    raise ValueError('Test simulator ownership changed; refusing cleanup')
                return device
    return None


def shutdown_device(record):
    device = own_device(record)
    if device and device.get('state') != 'Shutdown':
        output(['xcrun', 'simctl', 'shutdown', record['udid']], timeout=20)


def require_single_simulator(record):
    devices = json.loads(output(['xcrun', 'simctl', 'list', 'devices', 'booted', '--json']))['devices']
    if any(device.get('state') == 'Booted' and device.get('udid') != record['udid']
           for items in devices.values() for device in items):
        raise ValueError('Native tests require only the freshly owned simulator to be active')


def copy_case_evidence(telegram, label, destination):
    package, name = label[2:].split(':', 1)
    source = telegram / 'bazel-testlogs' / package / name
    for relative in ('test.log', 'test.xml', 'test.outputs/outputs.zip'):
        path = source / relative
        if path.is_file():
            target = destination / Path(relative).name
            shutil.copyfile(path, target)


def prepare_native_disk(args, bazel_startup, cache_configuration=None):
    """Recheck generation before querying/stopping only this owned Bazel server."""
    started = time.monotonic()
    checked_workspace(args.owned_root, args.repository, args.generation, args.bazel_root)
    query = [*bazel_startup, '--noblock_for_lock', 'info', 'output_base']
    bazel_output = Path(output(query, timeout=10))
    def quiesce(timeout):
        command = [*bazel_startup, '--noblock_for_lock', 'shutdown']
        began = time.monotonic()
        output(command, timeout=timeout)
        return {'command': command, 'status': 'owned-server-shutdown-complete',
                'seconds': round(time.monotonic() - began, 3)}
    remaining = 60 - (time.monotonic() - started)
    if remaining <= 0:
        raise TimeoutError('Native disk phase exhausted its 60-second resource budget')
    report = recover_capacity(args.owned_root, args.repository, args.generation, args.cache,
        args.bazel_root, bazel_output, args.output, quiesce=quiesce,
        cache_configuration=cache_configuration, limits=DiskLimits(phase_seconds=remaining))
    report['phaseSecondsIncludingBazelInfo'] = round(time.monotonic() - started, 3)
    write_json(args.output / 'disk-capacity.json', report)
    return bazel_output


def native_args(line, command, cache):
    """One effective cache/platform resource mode for native aquery/build/run-only."""
    index = 1 + len(line.get_startup_bazel_arguments())
    startup = command[:index] + ['--host_jvm_args=-Xmx4096m', '--max_idle_secs=30'] + command[index:]
    return startup + ['--jobs=2', '--local_resources=cpu=2', '--local_resources=memory=6000'] + cache.flags


def execute(args, plan, paths):
    # Finish inside the owned workspace's 2100s hard envelope, with time reserved
    # for cancellation, simulator identity checks and deletion.
    overall_deadline = time.monotonic() + 2000
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        raise ValueError('Native XCTest execution requires macOS arm64 / pinned Xcode 27.1')
    from client_ui_harness_workspace import read_generation, verify_workspace
    owned = verify_workspace(args.owned_root, args.repository)
    generation = read_generation(owned, args.repository)
    telegram = args.telegram_root.resolve()
    if (generation['generation'] != args.generation or not generation['ready']
            or telegram != owned.resolve() / 'telegram-ios'
            or args.bazel_root.resolve() != owned.resolve() / 'bazel-user-root'):
        raise ValueError('Native tests must use the claimed source generation and Bazel workspace')
    contract = plan['contract']
    actual = output(['xcodebuild', '-version']).splitlines()[0].removeprefix('Xcode ')
    if actual != contract['xcode']:
        raise ValueError('Actual Xcode must equal the app pin ' + contract['xcode'])
    sdk = output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'])
    if int(sdk.split('.')[0]) != 27:
        raise ValueError('The actual iOS 27 SDK is required')
    device_type, runtime = select_runtime(
        json.loads(output(['xcrun', 'simctl', 'list', 'devicetypes', '--json']))['devicetypes'],
        json.loads(output(['xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes'], contract)
    app = json.loads(args.app_build_report.read_text(encoding='utf-8'))
    from client_ui_harness_build import APPLICATION, HARNESS
    if (app.get('status') != 'built' or app.get('configuration') != 'debug_sim_arm64'
            or set(app.get('targets', [])) != {APPLICATION, HARNESS}):
        raise ValueError('The full simulator app/harness build must complete before native tests')
    os.chdir(telegram)
    sys.path.insert(0, str(telegram / 'build-system/Make'))
    from BazelLocation import locate_bazel
    from Make import BazelCommandLine, resolve_configuration
    from RuntimePackaging import load_staging_manifest, validate_runtime_actions
    from UnsignedBuild import prepare_unsigned_rules, validate_unsigned_actions
    from types import SimpleNamespace
    staging = load_staging_manifest(telegram)
    from client_ui_harness_inputs import harness_inputs, require_build_identity
    identity = require_build_identity(app, plan, harness_inputs(telegram), staging, Path(app['ipa']))
    if app.get('packaging', {}).get('clientSourcePatches') != staging['client_source_patches']:
        raise ValueError('Full simulator build and native-test source patch identities differ')
    write_json(args.output / 'source-identity.json', {'plan': plan, 'commit': os.environ.get('GITHUB_SHA'),
        'generation': args.generation, 'xcode': actual, 'sdk': sdk,
        'tool_sha256': {name: digest(Path(__file__).with_name(name)) for name in (
            'run_native_integration_tests.py', 'native_test_plan.py', 'client_ui_harness_workspace.py',
            'native_bundle_resources.py', 'native_test_disk.py', 'native_test_cache.py')},
        'client_source_patches': staging['client_source_patches'], 'acceptanceIdentity': identity})
    for logical, path in paths.items():
        relative = logical.replace('@exteraless//', 'external/exteraless/').replace(':', '/')
        target = args.output / 'sources' / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    prepare_unsigned_rules(telegram)
    bazel = locate_bazel(base_path=str(telegram), cache_host_or_path=None, cache_dir=str(args.cache))
    line = BazelCommandLine(bazel, False, False, str(args.bazel_root))
    resolve_configuration(str(telegram), line, SimpleNamespace(unsigned=True,
        configurationPath=str(telegram / 'build-system/exteraless-configuration.json')), None)
    line.set_unsigned()
    line.set_configuration('debug_sim_arm64')
    line.set_build_number('1')
    line.add_cache_dir(str(args.cache))
    labels = [target['label'] for target in plan['targets']]
    deadline = min(time.monotonic() + args.compile_seconds, overall_deadline - 330)
    # Binding before aquery supplies one endpoint for the entire phase. Reads
    # stay paused until the verified, quiescent pressure-GC/capacity gate finishes.
    with ReadOnlyCache(owned, args.repository, args.generation, args.cache,
                       report=args.output / 'readonly-cache.json') as cache:
        # A hard-killed process may miss finally; keep raw aquery OUTSIDE the
        # uploaded evidence directory as well as deleting it normally.
        with tempfile.TemporaryDirectory(prefix='.native-tests-private-', dir=args.output.parent) as private:
            graph = Path(private) / 'actions.json'
            try:
                query = native_args(line, line.get_unsigned_test_preflight_arguments(labels), cache)
                with graph.open('w', encoding='utf-8') as stream, (args.output / 'analysis.log').open('w', encoding='utf-8') as log:
                    subprocess.run(query, cwd=telegram, stdout=stream, stderr=log, check=True,
                                   timeout=min(300, max(1, deadline - time.monotonic())))
                validate_unsigned_actions(graph)
                validate_runtime_actions(graph, staging)
            finally:
                for name in ('unsigned-preflight.json', 'runtime-preflight.json'):
                    if (Path(private) / name).is_file():
                        shutil.copyfile(Path(private) / name, args.output / name)
        bazel_startup = [bazel, *line.get_startup_bazel_arguments(), '--host_jvm_args=-Xmx4096m', '--max_idle_secs=30']
        bazel_output = prepare_native_disk(args, bazel_startup, cache.configuration())
        cache.enable_reads()
        compile_failed = True
        try:
            run_logged(native_args(line, line.get_test_arguments(labels, build_only=True), cache) + ['--keep_going'],
                       telegram, args.output / 'compile', max(1, deadline - time.monotonic()))
            compile_failed = False
        finally:
            try:
                observe_after_compile(args.owned_root, args.repository, args.generation, args.cache,
                                      args.bazel_root, bazel_output, args.output)
            except Exception as error:
                print('NATIVE_DISK post-compile measurement failed: ' + str(error), flush=True)
                if not compile_failed:
                    raise
        cache.check()
        from native_test_resources import verify_test_host_resources
        host_resources = verify_test_host_resources(telegram, plan)
        write_json(args.output / 'native-bundle-resources.json', host_resources)
        require_build_identity(app, build_plan(telegram)[0], harness_inputs(telegram),
                                load_staging_manifest(telegram), Path(app['ipa']))
        if time.monotonic() >= overall_deadline - 330:
            raise TimeoutError('Native test envelope has no room for simulator preparation and cleanup')
        record = {'name': 'EXL-NativeTests-' + str(uuid.uuid4()), 'runtime': runtime, 'device_type': device_type}
        record['udid'] = output(['xcrun', 'simctl', 'create', record['name'], device_type, runtime])
        uuid.UUID(record['udid'])
        write_json(args.output / 'simulator.json', record)
        results = []
        try:
            require_single_simulator(record)
            output(['xcrun', 'simctl', 'boot', record['udid']], timeout=30)
            output(['xcrun', 'simctl', 'bootstatus', record['udid'], '-b'], timeout=150)
            deadline = min(time.monotonic() + args.execution_seconds, overall_deadline - 150)
            for target in plan['targets']:
                for case in target['classes']:
                    if time.monotonic() >= deadline:
                        raise TimeoutError('Native integration execution envelope expired')
                    require_single_simulator(record)
                    # The manifest binds each class to its actual host. Composer's
                    # fixtures need the scene/root created by ComposerHarness.
                    host_bundle_id = target['host_bundle_id']
                    output(['xcrun', 'simctl', 'uninstall', record['udid'], host_bundle_id], check=False)
                    if output(['xcrun', 'simctl', 'get_app_container', record['udid'], host_bundle_id, 'app'], check=False):
                        raise ValueError('The previous test-host installation could not be removed')
                    directory = args.output / 'runs' / ('{:02d}-{}'.format(len(results) + 1, case['class']))
                    # A single-class BUILD filter already selects this exact class;
                    # avoid unioning it with a second copy in the runner's options.
                    test_filter = None if target['build_test_filter'] else case['class']
                    command = native_args(line, line.get_test_arguments(target['label'], run_only=True, test_filter=test_filter,
                        test_arguments=['--destination=platform=ios_simulator,id=' + record['udid']],
                        test_environment=['STARTUP_TIMEOUT_SEC=150'], test_timeout=270, streamed=True), cache)
                    try:
                        result = run_logged(command, telegram, directory, max(1, deadline - time.monotonic()),
                                            case=case, contract=contract, cancel_test=lambda: shutdown_device(record))
                    finally:
                        copy_case_evidence(telegram, target['label'], directory)
                    require_single_simulator(record)
                    result.update(target=target['label'], source=case['source'], host=target['host'], host_bundle_id=host_bundle_id)
                    results.append(result)
                    write_json(args.output / 'completed-classes.json', results)
            require_build_identity(app, build_plan(telegram)[0], harness_inputs(telegram),
                                   load_staging_manifest(telegram), Path(app['ipa']))
        finally:
            shutdown_device(record)
            if own_device(record):
                output(['xcrun', 'simctl', 'delete', record['udid']], timeout=20)
            record['deleted'] = True
            write_json(args.output / 'simulator.json', record)
        result = {'status': 'passed', 'configuration': 'debug_sim_arm64', 'classes': results,
                  'passed_methods': sum(len(item['passed_methods']) for item in results),
                  'source_fingerprint': plan['source_fingerprint'], 'acceptanceIdentity': identity,
                  'native_execution_verified': True, 'host_resources': host_resources,
                  'visual_review': 'recording remains a separate step'}
        verify_native_results(result, plan, identity)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--telegram-root', type=Path, default=ROOT / 'telegram-ios')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--declarations-only', action='store_true')
    parser.add_argument('--owned-root', type=Path)
    parser.add_argument('--repository')
    parser.add_argument('--generation')
    parser.add_argument('--cache', type=Path)
    parser.add_argument('--bazel-root', type=Path)
    parser.add_argument('--app-build-report', type=Path)
    parser.add_argument('--compile-seconds', type=int, default=900)
    parser.add_argument('--execution-seconds', type=int, default=900)
    args = parser.parse_args()
    if not 1 <= args.compile_seconds <= 900 or not 1 <= args.execution_seconds <= 900:
        parser.error('Compilation and execution envelopes must each be 1...900 seconds')
    if not args.declarations_only and any(getattr(args, name) is None for name in (
            'owned_root', 'repository', 'generation', 'cache', 'bazel_root', 'app_build_report')):
        parser.error('Execution requires the claimed workspace/generation, cache and completed full-sim report')
    args.telegram_root = args.telegram_root.resolve()
    args.output = args.output.resolve()
    if args.output.exists() and any(args.output.iterdir()):
        parser.error('Native test evidence directory must be fresh')
    args.output.mkdir(parents=True, exist_ok=True)
    result = {'status': 'not-run', 'native_execution_verified': False}
    write_json(args.output / 'result.json', result)
    def interrupted(signum, frame):
        raise KeyboardInterrupt('Native test step interrupted by signal ' + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    try:
        plan, paths = build_plan(args.telegram_root, source_checkout=args.declarations_only)
        write_json(args.output / 'plan.json', plan)
        if args.declarations_only:
            result['status'] = 'declarations-checked'
        else:
            result.update(execute(args, plan, paths), native_execution_verified=True)
    except BaseException as error:
        result.update(status='failed', error=str(error))
        raise
    finally:
        write_json(args.output / 'result.json', result)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
