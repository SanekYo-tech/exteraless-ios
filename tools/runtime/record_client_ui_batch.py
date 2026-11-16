"""Bind bounded recording to one compiled cohort; diagnostics never admit native failure."""

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def write_json(path, value):
    """Publish a complete observation, including while handling an interruption."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            stream.write(json.dumps(value, indent=2, sort_keys=True) + '\n')
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def file_digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def prior_native_guest_released(native_path, *, timeout=20):
    """Observe cleanup; never terminate or delete a guest owned by another step."""
    inventory = json.loads(subprocess.check_output(
        ['xcrun', 'simctl', 'list', 'devices', '--json'], text=True, timeout=timeout))['devices']
    devices = [device for entries in inventory.values() for device in entries]
    if any(device.get('state') != 'Shutdown' for device in devices):
        raise ValueError('Diagnostic recording requires all previous simulators to be shut down')
    path = native_path.parent / 'simulator.json'
    if not path.exists():
        return 'native-guest-not-created'
    record = read_json(path)
    if (record.get('deleted') is not True or not record.get('udid')
            or any(device.get('udid') == record['udid'] for device in devices)):
        raise ValueError('Native test simulator cleanup is incomplete')
    return 'native-guest-deleted'


def postcheck_main(argv):
    """Private, read-only workers. Cleanup/native hashing need no mutable UI imports."""
    parser = argparse.ArgumentParser()
    parser.add_argument('runtime_root')
    parser.add_argument('check', choices=('identity', 'native', 'cleanup'))
    parser.add_argument('snapshot', type=Path)
    parser.add_argument('result', type=Path)
    parser.add_argument('seconds', type=float)
    args = parser.parse_args(argv)
    result = {'check': args.check, 'status': 'failed'}
    try:
        snapshot = read_json(args.snapshot)
        if args.check == 'identity':
            sys.path.insert(0, args.runtime_root)
            import client_ui_harness
            from client_ui_harness_inputs import harness_inputs, require_build_identity
            from native_test_plan import build_plan
            telegram = Path(snapshot['telegramRoot'])
            value = require_build_identity(snapshot['build'], build_plan(telegram)[0], harness_inputs(telegram),
                client_ui_harness.load_packaging(telegram).load_staging_manifest(telegram), Path(snapshot['ipa']))
        elif args.check == 'native':
            value = file_digest(snapshot['nativeTests'])
            if value != snapshot['nativeResultsSha256']:
                raise ValueError('Native evidence changed during recording')
        else:
            value = prior_native_guest_released(Path(snapshot['nativeTests']), timeout=max(0.01, min(20, args.seconds)))
        result.update(status='passed', value=value)
    except BaseException as error:
        result.update(errorType=type(error).__name__, error=str(error))
    write_json(args.result, result)
    return 0 if result['status'] == 'passed' else 1


# The pre-launch copy of this bootstrap also works after the original driver or
# wrapper path disappears. Do not move mutable UI imports above this dispatch.
if __name__ == '__main__' and sys.argv[1:2] == ['--postcheck']:
    raise SystemExit(postcheck_main(sys.argv[2:]))

import client_ui_harness as driver
from client_ui_harness_domains import batch_name, selected_scenarios
from client_ui_harness_inputs import harness_inputs, require_build_identity
from native_test_plan import build_plan, digest, verify_native_results
from verify_client_ui_batches import verify_batch

ENVELOPE_SECONDS = (120, 150, 180, 600)
FINALIZATION_SECONDS = 30
OUTER_MARGIN_SECONDS = 5
RECORDER_GRACE_SECONDS = 8
INTERRUPT_GRACE_SECONDS = 1
INTERRUPT_SECONDS = 3
CHECK_SECONDS = 20
REAP_SECONDS = 1


class Recording:
    """Only this recorder and its three read-only postchecks are owned here."""
    def __init__(self, args, selected):
        self.args = args
        self.started = time.monotonic()
        self.deadline = self.started + args.envelope_seconds - OUTER_MARGIN_SECONDS
        self.recording_deadline = self.deadline - FINALIZATION_SECONDS
        self.processes = []
        self.ordinary_receipt = None
        self.payload = {
            'schema': 1, 'mode': 'diagnostic-native-failure' if args.diagnostic_native_failure else 'ordinary-recording-state',
            'nativeAcceptance': False, 'visualReview': 'pending-recorded-frame-review', 'phase': 'preflight',
            'requestedScenarios': list(selected), 'envelopeSeconds': args.envelope_seconds,
            'finalizationReserveSeconds': FINALIZATION_SECONDS, 'outerMarginSeconds': OUTER_MARGIN_SECONDS,
            'wrapperProcessId': os.getpid(), 'wrapperProcessGroup': os.getpgrp() if os.name == 'posix' else None,
            'interruptedSignal': None, 'receivedSignals': [], 'innerDeadlineExceeded': False,
            'recorderReturnCode': None, 'recorderReaped': False, 'children': [], 'processErrors': [],
            'postchecks': {name: {'status': 'not-run'} for name in ('identity', 'native', 'cleanup')},
            'batchVerification': {'status': 'not-run'},
        }
        stem = 'diagnostic' if args.diagnostic_native_failure else 'recording'
        self.receipt = args.output / (stem + ('-identity.json' if args.diagnostic_native_failure else '-state.json'))
        self.emergency_receipt = args.output / (stem + '-interrupted.json')

    def save(self, *, emergency=False):
        value = dict(self.payload)
        checks = {name: dict(check) for name, check in value['postchecks'].items()}
        if emergency:
            for check in checks.values():
                if check['status'] in ('not-run', 'running'):
                    check.update(status='unfinished', error='Wrapper interrupted before this postcheck completed')
        value['postchecks'] = checks
        value['postchecksComplete'] = all(check['status'] in ('passed', 'failed') for check in checks.values())
        value['cohortUnchanged'] = not value['interruptedSignal'] and all(check['status'] == 'passed' for check in checks.values())
        value['postcheckErrors'] = [dict(check, check=name) for name, check in checks.items() if check.get('error')]
        value['elapsedSeconds'] = round(time.monotonic() - self.started, 3)
        write_json(self.emergency_receipt if emergency else self.receipt, value)

    def interrupted(self, signum, _frame):
        first = self.payload['interruptedSignal'] is None
        self.payload['interruptedSignal'] = self.payload['interruptedSignal'] or signum
        self.payload['receivedSignals'] = (self.payload['receivedSignals'] + [signum])[:8]
        self.payload['phase'] = 'interrupted'
        if first:
            # The soft deadline may already have expired when owned-exec sends
            # TERM. Use its existing 5s grace for a 3s emergency reap, once only.
            self.deadline = time.monotonic() + INTERRUPT_SECONDS
            self.payload['interruptionBudgetSeconds'] = INTERRUPT_SECONDS
        try:
            if first:
                # Publish BEFORE waiting, hashing sources or querying simctl. This
                # immutable fallback survives the outer owned-exec's 5s SIGKILL.
                self.save(emergency=True)
                if not self.receipt.exists():
                    self.save()
        except OSError as error:
            self.payload['processErrors'].append('Interrupted receipt: ' + str(error))
        finally:
            for process, observed in self.processes:
                if not observed['reaped']:
                    self.send(process, observed, signum)

    @contextmanager
    def signals(self):
        previous = {number: signal.signal(number, self.interrupted) for number in (signal.SIGTERM, signal.SIGINT)}
        try:
            yield
        finally:
            try:
                self.stop(self.processes, grace=0)
                if self.payload['interruptedSignal']:
                    self.payload['phase'] = 'interrupted'
                    if self.ordinary_receipt is not None:
                        self.ordinary_receipt.unlink(missing_ok=True)
                    try:
                        self.save()
                    except OSError as error:
                        print('Interrupted receipt update failed: ' + str(error), file=sys.stderr)
            finally:
                for number, handler in previous.items():
                    signal.signal(number, handler)
            if self.payload['interruptedSignal']:
                raise SystemExit(128 + self.payload['interruptedSignal'])

    def spawn(self, command, role, *, stdout=None):
        # A child group, not an escaped session: capture its ID immediately and
        # forward wrapper signals explicitly. Every exit path kills/reaps it.
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stdout,
            stderr=subprocess.STDOUT if stdout is not None else None,
            **({'process_group': 0} if os.name == 'posix' else {}))
        observed = {'role': role, 'pid': process.pid, 'processGroup': process.pid if os.name == 'posix' else None,
                    'returnCode': None, 'reaped': False, 'groupClosed': False, 'sentSignals': []}
        self.processes.append((process, observed))
        self.payload['children'].append(observed)
        if self.payload['interruptedSignal']:
            self.send(process, observed, self.payload['interruptedSignal'])
        return process, observed

    def poll(self, child):
        process, observed = child
        code = process.poll()
        if code is not None:
            observed.update(returnCode=code, reaped=True)
            if observed['role'] == 'recorder':
                self.payload.update(recorderReturnCode=code, recorderReaped=True)
        return code

    def send(self, process, observed, signum):
        if observed['groupClosed'] or (signum != getattr(signal, 'SIGKILL', 9) and observed['sentSignals']):
            return True  # Do not interrupt the driver's own finally with a second TERM.
        try:
            if observed['processGroup'] is not None:
                os.killpg(observed['processGroup'], signum)
            elif not observed['reaped']:
                if signum == getattr(signal, 'SIGKILL', 9):
                    process.kill()
                else:
                    os.kill(observed['pid'], signum)
            observed['sentSignals'].append(int(signum))
            return True
        except (ProcessLookupError, PermissionError):
            # ESRCH: the owned group is already gone after the leader was
            # reaped. EPERM: a busy runner recycled the PID into another
            # user's process; our own group members are already dead.
            return True
        except OSError as error:
            self.payload['processErrors'].append(observed['role'] + ': ' + str(error))
            return False

    def stop(self, children, *, grace):
        children = [child for child in children if not child[1]['groupClosed']]
        for child in children:
            if self.poll(child) is None:
                self.send(*child, signal.SIGTERM)
        until = min(self.deadline - REAP_SECONDS, time.monotonic() + grace)
        while any(self.poll(child) is None for child in children):
            if self.payload['interruptedSignal']:
                until = min(until, time.monotonic() + INTERRUPT_GRACE_SECONDS)
            if time.monotonic() >= until:
                break
            time.sleep(max(0, min(0.05, until - time.monotonic())))
        for process, observed in children:
            # Kill the owned group even if its leader has exited, so a worker's
            # simctl child (or a recorder child in that group) cannot outlive it.
            stopped = self.send(process, observed, getattr(signal, 'SIGKILL', 9))
            try:
                process.wait(timeout=max(0.01, min(REAP_SECONDS, self.deadline - time.monotonic())))
            except subprocess.TimeoutExpired:
                self.payload['processErrors'].append(observed['role'] + ': child reap deadline exceeded')
            self.poll((process, observed))
            observed['groupClosed'] = stopped and observed['reaped']

    def wait_recording(self, child):
        while self.poll(child) is None and not self.payload['interruptedSignal']:
            remaining = self.recording_deadline - time.monotonic()
            if remaining <= 0:
                self.payload['innerDeadlineExceeded'] = True
                break
            time.sleep(min(0.05, remaining))
        if self.payload['innerDeadlineExceeded'] or self.payload['interruptedSignal']:
            self.save()
        self.stop([child], grace=INTERRUPT_GRACE_SECONDS if self.payload['interruptedSignal'] else RECORDER_GRACE_SECONDS)


def run_checks(run, directory, worker, snapshot, runtime_root, names, deadline, results):
    """Observe independent checks concurrently, within one finite finalization budget."""
    pending, logs = {}, []
    try:
        for name in names:
            if run.payload['interruptedSignal'] or time.monotonic() >= deadline:
                results[name] = {'status': 'unfinished', 'error': 'No remaining postcheck budget'}
                continue
            results[name] = {'status': 'running'}
            result = directory / (name + '-result.json')
            command = [sys.executable, '-B', str(worker), '--postcheck', str(runtime_root), name,
                       str(snapshot), str(result), str(max(0.01, deadline - time.monotonic()))]
            try:
                log = (directory / (name + '.log')).open('w', encoding='utf-8')
                logs.append(log)
                pending[name] = (run.spawn(command, 'postcheck-' + name, stdout=log), result)
            except OSError as error:
                results[name] = {'status': 'failed', 'errorType': type(error).__name__, 'error': str(error)}
        while pending:
            for name, (child, result_path) in list(pending.items()):
                code = run.poll(child)
                if code is None:
                    continue
                try:
                    result = read_json(result_path)
                    if result.get('check') != name or result.get('status') not in ('passed', 'failed'):
                        raise ValueError('Invalid postcheck result')
                    if code != (0 if result['status'] == 'passed' else 1):
                        raise ValueError('Postcheck result disagrees with its process exit')
                    results[name] = dict(result, workerReturnCode=code)
                except Exception as error:
                    results[name] = {'status': 'failed', 'errorType': type(error).__name__,
                                     'error': str(error), 'workerReturnCode': code}
                run.stop([child], grace=0)
                del pending[name]
            if run.payload['interruptedSignal'] or time.monotonic() >= min(deadline, run.deadline):
                for name in pending:
                    results[name] = {'status': 'unfinished' if run.payload['interruptedSignal'] else 'timed-out',
                                     'error': 'Wrapper interrupted' if run.payload['interruptedSignal'] else 'Postcheck deadline exceeded'}
                break
            if pending:
                time.sleep(min(0.05, max(0, min(deadline, run.deadline) - time.monotonic())))
    finally:
        run.stop([child for child, _ in pending.values()], grace=0)
        for name, (child, _) in pending.items():
            results[name]['workerReturnCode'] = child[1]['returnCode']
        for log in logs:
            log.close()


def record(args):
    selected = selected_scenarios(args.scenario, driver.SCENARIOS)
    if args.envelope_seconds not in ENVELOPE_SECONDS:
        raise ValueError('Use the existing 120/150/180/600-second owned recording envelope')
    args.output = args.output.resolve()
    if args.output.exists() and (not args.output.is_dir() or any(args.output.iterdir())):
        raise ValueError('Recording output must be fresh; stale evidence cannot be reused')
    run = Recording(args, selected)
    failure, child, evidence = None, None, None
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with run.signals(), tempfile.TemporaryDirectory(prefix='.' + args.output.name + '-checks-', dir=args.output.parent) as temporary:
        directory = Path(temporary)
        try:
            telegram = args.telegram_root.resolve()
            staging_path = telegram / 'build-input/exteraless/runtime-staging.json'
            if args.staging_manifest.resolve() != staging_path:
                raise ValueError('Use the staged runtime from the claimed acceptance workspace')
            build, native = read_json(args.build_report), read_json(args.native_tests)
            staging = driver.load_packaging(telegram).load_staging_manifest(telegram)
            plan, _ = build_plan(telegram)
            identity = require_build_identity(build, plan, harness_inputs(telegram), staging, args.ipa)
            if args.diagnostic_native_failure:
                if native.get('status') != 'failed' or native.get('native_execution_verified') is not False:
                    raise ValueError('Diagnostic fallback requires an explicit failed native result')
            else:
                evidence = verify_native_results(native, plan, identity)
            # Capture every receipt input and the worker bootstrap BEFORE launch.
            # Failure publication never reopens driver.__file__ or other sources.
            driver_path = Path(driver.__file__).resolve()
            driver_sha = digest(driver_path)
            native_sha = digest(args.native_tests)
            wrapper_path = Path(__file__).resolve()
            worker = directory / 'postcheck.py'
            worker.write_bytes(wrapper_path.read_bytes())
            snapshot = directory / 'snapshot.json'
            write_json(snapshot, {'build': build, 'telegramRoot': str(telegram), 'ipa': str(args.ipa.resolve()),
                                  'nativeTests': str(args.native_tests.resolve()), 'nativeResultsSha256': native_sha})
            command = [sys.executable, str(driver_path), '--ipa', str(args.ipa.resolve()),
                       '--staging-manifest', str(staging_path), '--telegram-root', str(telegram), '--output', str(args.output)]
            for scenario in selected:
                command += ['--scenario', scenario]
            run.payload.update(acceptanceIdentity=identity, nativeStatus=native['status'], nativeResultsSha256=native_sha,
                driverSha256=driver_sha, driverPath=str(driver_path), command=command, domainSources=build['domainSources'])
            if run.payload['interruptedSignal'] or time.monotonic() >= run.recording_deadline:
                raise TimeoutError('No recording budget remains after preflight')
            if args.diagnostic_native_failure:
                prior = {}
                run_checks(run, directory, worker, snapshot, wrapper_path.parent, ('cleanup',),
                           min(run.recording_deadline, time.monotonic() + CHECK_SECONDS), prior)
                run.payload['priorCleanupObservation'] = prior['cleanup']
                if prior['cleanup']['status'] != 'passed':
                    raise ValueError(prior['cleanup'].get('error', 'Native cleanup was not verified'))
                run.payload['priorNativeCleanup'] = prior['cleanup']['value']
                (directory / 'cleanup-result.json').unlink()
            if run.payload['interruptedSignal'] or time.monotonic() >= run.recording_deadline:
                raise TimeoutError('No recording budget remains after preflight')
            run.payload['phase'] = 'recording'
            child = run.spawn(command, 'recorder')
            run.wait_recording(child)
        except BaseException as error:
            failure = error
            run.payload['recordingError'] = {'type': type(error).__name__, 'error': str(error)}
        finally:
            try:
                run.stop(run.processes, grace=INTERRUPT_GRACE_SECONDS if run.payload['interruptedSignal'] else RECORDER_GRACE_SECONDS)
                if child is not None and not run.payload['interruptedSignal']:
                    run.payload['phase'] = 'finalizing'
                    run.save()
                    run_checks(run, directory, worker, snapshot, wrapper_path.parent, ('identity', 'native', 'cleanup'),
                        min(run.deadline - REAP_SECONDS, time.monotonic() + CHECK_SECONDS), run.payload['postchecks'])
                if child is not None and run.payload['recorderReturnCode'] == 0 and not run.payload['interruptedSignal']:
                    verify_batch(read_json(args.output / 'acceptance.json'), selected, build['packaging'], batch_name(selected, driver.SCENARIOS))
                    run.payload['batchVerification'] = {'status': 'passed'}
            except Exception as error:
                failure = failure or error
                run.payload['finalizationError'] = {'type': type(error).__name__, 'error': str(error)}
                if run.payload['batchVerification']['status'] == 'not-run':
                    run.payload['batchVerification'] = {'status': 'failed', 'errorType': type(error).__name__, 'error': str(error)}
            passed = (failure is None and run.payload['recorderReturnCode'] == 0 and run.payload['recorderReaped']
                and not run.payload['innerDeadlineExceeded'] and not run.payload['interruptedSignal']
                and not run.payload['processErrors'] and all(item['status'] == 'passed' for item in run.payload['postchecks'].values())
                and run.payload['batchVerification']['status'] == 'passed')
            run.payload['phase'] = 'interrupted' if run.payload['interruptedSignal'] else ('complete' if passed else 'failed')
            run.save()
        # Known recorder failure wins over independent postcheck failures. A
        # wrapper interruption has its own explicit shell signal status.
        if run.payload['interruptedSignal']:
            raise SystemExit(128 + run.payload['interruptedSignal'])
        if run.payload['recorderReturnCode'] not in (None, 0):
            raise subprocess.CalledProcessError(run.payload['recorderReturnCode'], command)
        if run.payload['innerDeadlineExceeded']:
            raise SystemExit(124)
        if failure is not None:
            raise failure
        if not passed:
            raise ValueError('Recording postchecks or batch verification failed; inspect ' + str(run.receipt))
        if not args.diagnostic_native_failure:
            receipt = {'schema': 1, 'acceptanceIdentity': identity, 'nativeResultsSha256': native_sha,
                       'nativeEvidence': evidence, 'requestedScenarios': list(selected), 'batch': batch_name(selected, driver.SCENARIOS),
                       'command': command, 'driverSha256': driver_sha, 'domainSources': build['domainSources']}
            with (args.output / 'batch-identity.json').open('x', encoding='utf-8') as stream:
                run.ordinary_receipt = args.output / 'batch-identity.json'
                stream.write(json.dumps(receipt, indent=2, sort_keys=True) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('ipa', 'staging-manifest', 'telegram-root', 'output', 'build-report', 'native-tests'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--scenario', action='append', required=True)
    parser.add_argument('--envelope-seconds', type=int, choices=ENVELOPE_SECONDS, required=True,
                        help='Existing owned-exec slot; reserves 30s finalization plus a 5s outer margin')
    parser.add_argument('--diagnostic-native-failure', action='store_true',
                        help='Collect source-bound diagnostic frames after native failure; cannot create an acceptance receipt')
    args = parser.parse_args()
    try:
        record(args)
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode if error.returncode > 0 else 128 - error.returncode) from error


if __name__ == '__main__':
    main()
