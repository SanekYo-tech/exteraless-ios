"""Real Python children and real mutable files; no Apple tools or recordings."""

import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
import record_client_ui_batch as recorder
import client_ui_harness_inputs as inputs
import native_test_plan
from tools.ci.tests import test_client_ui_batches as batches


def write(path, value):
    path.write_text(json.dumps(value), encoding='utf-8')


def source_inputs(root, build):
    fingerprint = hashlib.sha256(b''.join((root / name).read_bytes() for name in ('source.txt', 'driver.py', 'wrapper.py'))).hexdigest()
    return {'fingerprint': fingerprint, 'domain_sources': build['domainSources']}


def configure(root):
    config = recorder.read_json(root / 'config.json')
    build = recorder.read_json(root / 'build.json')
    recorder.__file__ = str(root / 'wrapper.py')
    recorder.driver.__file__ = str(root / 'driver.py')
    recorder.build_plan = native_test_plan.build_plan = lambda *_args, **_kwargs: (build['nativeTestPlan'], {})
    def harness(_telegram):
        if sys.argv[1:2] == ['--postcheck'] and sys.argv[3] == 'identity':
            write(root / 'identity-check-ready.json', {'pid': os.getpid()})
            time.sleep(config.get('identity_delay', 0))
        return source_inputs(root, build)
    recorder.harness_inputs = inputs.harness_inputs = harness
    recorder.driver.load_packaging = lambda _: SimpleNamespace(
        load_staging_manifest=lambda _: recorder.read_json(root / 'staging.json'))
    original = subprocess.check_output
    def inventory(command, **kwargs):
        if command[:4] != ['xcrun', 'simctl', 'list', 'devices']:
            return original(command, **kwargs)
        with (root / 'inventory-calls.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps({'pid': os.getpid(), 'timeout': kwargs['timeout']}) + '\n')
        time.sleep(config.get('inventory_delay', 0))
        return (root / 'inventory.json').read_text(encoding='utf-8')
    subprocess.check_output = inventory
    for name, value in config.get('budgets', {}).items():
        setattr(recorder, name, value)
    if config.get('envelope_seconds', 600) not in recorder.ENVELOPE_SECONDS:
        recorder.ENVELOPE_SECONDS = (*recorder.ENVELOPE_SECONDS, config['envelope_seconds'])
    return config


def wrapper_main(root):
    config = configure(root)
    if sys.argv[1:2] == ['--postcheck']:
        raise SystemExit(recorder.postcheck_main(sys.argv[2:]))
    if config.get('signal_bridge'):
        # Windows os.kill(SIGTERM) uses TerminateProcess, not a Python handler.
        # Exercise the handler in the wrapper; it still kills/reaps a REAL child
        # using os.kill. POSIX whole-group delivery has its own separate test.
        def interrupt():
            while not (root / 'interrupt-now').exists():
                time.sleep(0.01)
            signal.raise_signal(signal.SIGTERM)
        threading.Thread(target=interrupt, daemon=True).start()
    recorder.main()


def driver_main(root):
    config = recorder.read_json(root / 'config.json')
    if config.get('ignore_term'):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    elif config.get('zero_on_term'):
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    descendant = None
    if config.get('descendant'):
        descendant = subprocess.Popen([sys.executable, '-B', '-c',
            'import signal,time; from pathlib import Path; signal.signal(signal.SIGTERM, signal.SIG_IGN); '
            + 'Path(' + repr(str(root / 'descendant-ready')) + ').touch(); time.sleep(60)'])
        until = time.monotonic() + 3
        while not (root / 'descendant-ready').exists():
            if time.monotonic() >= until:
                raise TimeoutError('Toy descendant did not install its handler')
            time.sleep(0.01)
    write(root / 'driver-ready.json', {'pid': os.getpid(),
        'processGroup': os.getpgrp() if os.name == 'posix' else None,
        'descendant': descendant.pid if descendant else None})
    if config.get('loop'):
        while True:
            time.sleep(0.02)
    output = root / 'recordings'
    output.mkdir()
    report = recorder.read_json(root / 'baseline.json')
    if config.get('missing_recording'):
        report['recordings'].pop()
    write(output / 'acceptance.json', report)
    if config.get('change_source'):
        (root / 'source.txt').write_text('changed while recording', encoding='utf-8')
    if config.get('change_native'):
        with (root / 'native-tests/result.json').open('a', encoding='utf-8') as stream:
            stream.write('\n')
    if config.get('lose_driver'):
        (root / 'driver.py').rename(root / 'driver-moved.py')
    if config.get('lose_wrapper'):
        (root / 'wrapper.py').rename(root / 'wrapper-moved.py')
    if config.get('active_after'):
        write(root / 'inventory.json', {'devices': {'runtime': [{'state': 'Booted', 'udid': 'left-running'}]}})
    if config.get('die_by_signal'):
        os.kill(os.getpid(), signal.SIGTERM)
    raise SystemExit(config.get('exit_code', 0))


def process_alive(pid):
    if os.name == 'nt':
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.GetExitCodeProcess.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
        kernel.GetExitCodeProcess.restype = wintypes.BOOL
        kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return False
        try:
            code = wintypes.DWORD()
            if not kernel.GetExitCodeProcess(handle, ctypes.byref(code)):
                raise OSError('GetExitCodeProcess failed')
            return code.value == 259
        finally:
            kernel.CloseHandle(handle)
    stat = Path('/proc') / str(pid) / 'stat'
    if stat.exists() and stat.read_text().rsplit(')', 1)[-1].split()[0] == 'Z':
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class RecordingFixture:
    def __init__(self, *, native_passed=False, diagnostic=True):
        approved = Path(os.environ.get('LOCALAPPDATA', '')) / 'Temp/opencode'
        self.temporary = tempfile.TemporaryDirectory(prefix='recording-process-', dir=approved if approved.is_dir() else None)
        self.root = Path(self.temporary.name)
        self.config = {'envelope_seconds': 600}
        self.diagnostic = diagnostic
        self.process = None
        self.build, native, baseline, _, _, _ = batches.SerialUIBatchChecks().fixtures()
        self.telegram = self.root / 'telegram-ios'
        self.telegram.mkdir()
        self.ipa = self.root / 'harness.ipa'
        self.ipa.write_bytes(b'owned packaging fixture')
        (self.root / 'source.txt').write_text('compiled source fixture', encoding='utf-8')
        for name, entry in (('driver', 'driver_main'), ('wrapper', 'wrapper_main')):
            (self.root / (name + '.py')).write_text(
                'import sys\nfrom pathlib import Path\nsys.path.insert(0, ' + repr(str(ROOT)) + ')\n'
                'from tools.ci.tests.client_ui_recording_process_fixture import ' + entry + '\n'
                + entry + '(Path(' + repr(str(self.root)) + '))\n', encoding='utf-8')
        staging = {'source_files': {'owned-input': 'c' * 64}}
        self.identity = inputs.acceptance_identity(self.build['nativeTestPlan'], source_inputs(self.root, self.build),
                                                  staging, recorder.file_digest(self.ipa))
        self.build['acceptanceIdentity'] = self.identity
        self.build['packaging']['ipaSha256'] = self.identity['ipaSha256']
        self.driver_sha = recorder.file_digest(self.root / 'driver.py')
        self.build['driverSha256'] = self.driver_sha
        native['acceptanceIdentity'] = self.identity
        if not native_passed:
            native = {'status': 'failed', 'native_execution_verified': False, 'error': 'owned compile fixture'}
        baseline['bundle'] = copy.deepcopy(self.build['packaging'])
        (self.root / 'native-tests').mkdir()
        for name, value in (('build.json', self.build), ('native-tests/result.json', native),
                            ('baseline.json', baseline), ('staging.json', staging), ('inventory.json', {'devices': {}})):
            write(self.root / name, value)

    def __enter__(self):
        return self

    def command(self):
        command = [sys.executable, '-B', str(self.root / 'wrapper.py'), '--envelope-seconds', str(self.config['envelope_seconds'])]
        paths = {'ipa': self.ipa, 'telegram-root': self.telegram,
                 'staging-manifest': self.telegram / 'build-input/exteraless/runtime-staging.json',
                 'output': self.root / 'recordings', 'build-report': self.root / 'build.json',
                 'native-tests': self.root / 'native-tests/result.json'}
        for name, value in paths.items():
            command += ['--' + name, str(value)]
        for scenario in ('core-light', 'core-dark', 'sdk-ui'):
            command += ['--scenario', scenario]
        if self.diagnostic:
            command.append('--diagnostic-native-failure')
        return command

    def start(self):
        write(self.root / 'config.json', self.config)
        self.process = subprocess.Popen(self.command(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, start_new_session=os.name == 'posix')
        return self.process

    def finish(self, timeout=12):
        output, error = self.process.communicate(timeout=timeout)
        return subprocess.CompletedProcess(self.command(), self.process.returncode, output, error)

    def run(self):
        self.start()
        return self.finish()

    def wait_json(self, name, timeout=5):
        until = time.monotonic() + timeout
        path = self.root / name
        while time.monotonic() < until:
            try:
                return recorder.read_json(path)
            except (OSError, ValueError):
                if self.process and self.process.poll() is not None:
                    output, error = self.process.communicate()
                    raise AssertionError('Wrapper exited before ' + name + ': ' + output + error)
                time.sleep(0.01)
        raise AssertionError('Fixture handshake timed out: ' + name)

    def receipt(self):
        name = 'diagnostic-identity.json' if self.diagnostic else 'recording-state.json'
        return recorder.read_json(self.root / 'recordings' / name)

    def inventories(self):
        path = self.root / 'inventory-calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def __exit__(self, *_):
        if self.process and self.process.poll() is None:
            if os.name == 'posix':
                os.killpg(self.process.pid, signal.SIGTERM)
            else:
                self.process.terminate()
            try:
                self.process.communicate(timeout=4)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.communicate(timeout=2)
        # A failed test must not leave its own toy child running.
        if (self.root / 'driver-ready.json').exists():
            ready = recorder.read_json(self.root / 'driver-ready.json')
            if process_alive(ready['pid']) or (ready['descendant'] and process_alive(ready['descendant'])):
                try:
                    if ready['processGroup']:
                        os.killpg(ready['processGroup'], signal.SIGKILL)
                    else:
                        os.kill(ready['pid'], signal.SIGTERM)
                except ProcessLookupError:
                    pass
        self.temporary.cleanup()
