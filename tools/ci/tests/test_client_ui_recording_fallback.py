"""Source-bound diagnostics: real bounded Python processes, never native/frame PASS."""

import copy
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sys
import time
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/runtime'))
from native_test_plan import verify_native_results
from verify_client_ui_batches import verify
from tools.ci.tests import test_client_ui_batches as batches
from tools.ci.tests.client_ui_recording_process_fixture import RecordingFixture, process_alive, write
import record_client_ui_batch as recorder


class RecordingSignalChecks(unittest.TestCase):
    def run_stop(self, error):
        run = recorder.Recording(SimpleNamespace(envelope_seconds=120, diagnostic_native_failure=False,
                                               output=Path('unused-fixture-output')), ['core-light'])
        process = Mock(pid=12345)
        process.poll.return_value = process.wait.return_value = 0
        observed = {'role': 'recorder', 'pid': process.pid, 'processGroup': process.pid,
                    'returnCode': None, 'reaped': False, 'groupClosed': False, 'sentSignals': []}
        with patch.object(recorder.os, 'killpg', create=True, side_effect=error) as kill:
            run.stop([(process, observed)], grace=0)
        kill.assert_called_once_with(process.pid, getattr(signal, 'SIGKILL', 9))
        return run, observed

    def test_eperm_is_denied_unknown_group_cleanup_not_pid_recycling(self):
        run, child = self.run_stop(PermissionError(errno.EPERM, 'Operation not permitted'))
        self.assertTrue(child['reaped'])
        self.assertFalse(child['groupClosed'])
        self.assertEqual(child['sentSignals'], [])
        self.assertEqual(child['signalErrors'][0]['errno'], errno.EPERM)
        self.assertEqual(child['signalErrors'][0]['errorType'], 'PermissionError')
        self.assertTrue(run.payload['processErrors'])

    def test_esrch_plus_reaped_leader_allows_closed_group(self):
        run, child = self.run_stop(ProcessLookupError(errno.ESRCH, 'No such process'))
        self.assertTrue(child['reaped'])
        self.assertTrue(child['groupClosed'])
        self.assertEqual(run.payload['processErrors'], [])

    def test_unspecified_oserror_stays_unknown_without_invented_permission_errno(self):
        run, child = self.run_stop(OSError('unknown signaling failure'))
        self.assertFalse(child['groupClosed'])
        self.assertIsNone(child['signalErrors'][0]['errno'])
        self.assertEqual(child['signalErrors'][0]['errorType'], 'OSError')
        self.assertTrue(run.payload['processErrors'])


class DiagnosticRecordingChecks(unittest.TestCase):
    def assert_reaped(self, receipt):
        self.assertTrue(receipt['recorderReaped'])
        for child in receipt['children']:
            self.assertTrue(child['reaped'], child)
            self.assertTrue(child['groupClosed'], child)
            self.assertFalse(process_alive(child['pid']), child)

    def test_failed_native_requires_explicit_collection_mode(self):
        with RecordingFixture(diagnostic=False) as state:
            result = state.run()
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn('Required native XCTest snapshot did not pass', result.stderr)
            self.assertFalse((state.root / 'driver-ready.json').exists())
            self.assertEqual(state.inventories(), [])
            self.assertFalse(state.receipt()['nativeAcceptance'])

    def test_diagnostic_frames_never_receive_native_acceptance_receipt(self):
        with RecordingFixture() as state:
            result = state.run()
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = state.receipt()
            self.assertTrue(receipt['cohortUnchanged'])
            self.assertTrue(receipt['postchecksComplete'])
            self.assertEqual(receipt['recorderReturnCode'], 0)
            self.assertFalse(receipt['nativeAcceptance'])
            self.assertEqual(receipt['mode'], 'diagnostic-native-failure')
            self.assertNotIn('nativeEvidence', receipt)
            self.assertFalse((state.root / 'recordings/batch-identity.json').exists())
            self.assertEqual(len(state.inventories()), 2)
            self.assert_reaped(receipt)
            with self.assertRaises(ValueError):
                verify_native_results(json.loads((state.root / 'native-tests/result.json').read_text()),
                                      state.build['nativeTestPlan'], state.identity)

    def test_native_pass_uses_the_existing_strict_acceptance_path(self):
        with RecordingFixture(native_passed=True, diagnostic=False) as state:
            result = state.run()
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads((state.root / 'recordings/batch-identity.json').read_text())
            self.assertEqual(receipt['acceptanceIdentity'], state.identity)
            self.assertEqual(receipt['driverSha256'], state.driver_sha)
            self.assertEqual(receipt['nativeEvidence']['methods'], 2)
            self.assertFalse((state.root / 'recordings/diagnostic-identity.json').exists())
            self.assertEqual(len(state.inventories()), 1)
            self.assert_reaped(state.receipt())

    def test_diagnostic_flag_cannot_hide_a_passed_or_unfinished_native_record(self):
        for status, verified in (('passed', True), ('not-run', False), ('failed', True)):
            with self.subTest(status=status), RecordingFixture() as state:
                write(state.root / 'native-tests/result.json', {'status': status, 'native_execution_verified': verified})
                result = state.run()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('explicit failed native result', result.stderr)
                self.assertFalse((state.root / 'driver-ready.json').exists())
                self.assertEqual(state.inventories(), [])

    def test_preflight_rejects_another_ipa_without_launching_recorder(self):
        with RecordingFixture() as state:
            state.ipa.write_bytes(b'other build')
            result = state.run()
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn('compiled acceptance snapshot', result.stderr)
            self.assertFalse((state.root / 'driver-ready.json').exists())
            self.assertEqual(state.inventories(), [])

    def test_recorder_failure_keeps_its_exit_and_diagnostic_identity(self):
        with RecordingFixture() as state:
            state.config['exit_code'] = 7
            result = state.run()
            self.assertEqual(result.returncode, 7, result.stderr)
            receipt = state.receipt()
            self.assertEqual(receipt['recorderReturnCode'], 7)
            self.assertTrue(receipt['cohortUnchanged'])
            self.assert_reaped(receipt)

    def test_denied_cleanup_keeps_failed_sidecar_and_blocks_ordinary_acceptance(self):
        with RecordingFixture(native_passed=True, diagnostic=False) as state:
            state.config['deny_reaped_signals'] = True
            result = state.run()
            self.assertEqual(result.returncode, 1, result.stderr)
            receipt = state.receipt()
            self.assertEqual(receipt['phase'], 'failed')
            self.assertEqual(receipt['recorderReturnCode'], 0)
            self.assertTrue(receipt['recorderReaped'])
            self.assertTrue(receipt['processErrors'])
            self.assertTrue(all(child['reaped'] and not child['groupClosed'] for child in receipt['children']))
            self.assertTrue(all(error['errno'] == errno.EPERM for child in receipt['children'] for error in child['signalErrors']))
            self.assertFalse((state.root / 'recordings/batch-identity.json').exists())

    def test_denied_cleanup_preserves_nonzero_recorder_exit_and_diagnostic_sidecar(self):
        with RecordingFixture() as state:
            state.config.update(deny_reaped_signals=True, exit_code=7)
            result = state.run()
            self.assertEqual(result.returncode, 7, result.stderr)
            receipt = state.receipt()
            self.assertEqual(receipt['phase'], 'failed')
            self.assertEqual(receipt['recorderReturnCode'], 7)
            self.assertTrue(receipt['processErrors'])
            self.assertTrue(any(not child['groupClosed'] for child in receipt['children']))
            self.assertFalse((state.root / 'recordings/batch-identity.json').exists())

    def test_bootstrap_copy_error_stays_prelaunch_failure_with_unknown_postchecks(self):
        with RecordingFixture() as state:
            state.config['bootstrap_copy_error'] = True
            result = state.run()
            self.assertEqual(result.returncode, 1, result.stderr)
            receipt = state.receipt()
            self.assertEqual(receipt['recordingError']['type'], 'PermissionError')
            self.assertIn('bootstrap copy denied', receipt['recordingError']['error'])
            self.assertEqual(receipt['phase'], 'failed')
            self.assertEqual(receipt['children'], [])
            self.assertIsNone(receipt['recorderReturnCode'])
            self.assertFalse(receipt['recorderReaped'])
            self.assertFalse(receipt['postchecksComplete'])
            self.assertFalse(receipt['cohortUnchanged'])
            self.assertTrue(all(check['status'] == 'not-run' for check in receipt['postchecks'].values()))
            self.assertEqual(state.inventories(), [])
            self.assertFalse((state.root / 'driver-ready.json').exists())
            self.assertFalse((state.root / 'recordings/batch-identity.json').exists())

    def test_postcheck_still_runs_after_failed_recording(self):
        for changed in ('source', 'native'):
            with self.subTest(changed=changed), RecordingFixture() as state:
                state.config.update(exit_code=7, **{'change_' + changed: True})
                result = state.run()
                self.assertEqual(result.returncode, 7, result.stderr)
                receipt = state.receipt()
                self.assertFalse(receipt['cohortUnchanged'])
                self.assertEqual(receipt['recorderReturnCode'], 7)
                self.assertEqual(receipt['postchecks']['cleanup']['status'], 'passed')
                self.assertEqual(len(state.inventories()), 2)
                self.assertFalse((state.root / 'recordings/batch-identity.json').exists())
                self.assert_reaped(receipt)

    def test_active_or_not_deleted_native_guest_blocks_diagnostic_launch(self):
        for state_value, deleted, present in (('Booted', True, False), ('Shutdown', False, False), ('Shutdown', True, True)):
            with self.subTest(state=state_value, deleted=deleted, present=present), RecordingFixture() as state:
                write(state.root / 'native-tests/simulator.json', {'udid': 'native-id', 'deleted': deleted})
                write(state.root / 'inventory.json', {'devices': {'runtime': [
                    {'udid': 'native-id' if present else 'other-id', 'state': state_value}]}})
                result = state.run()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertFalse((state.root / 'driver-ready.json').exists())
                self.assertFalse(state.receipt()['nativeAcceptance'])

    def test_postcheck_detects_guest_left_running_by_failed_recorder(self):
        with RecordingFixture() as state:
            state.config.update(exit_code=9, active_after=True)
            result = state.run()
            self.assertEqual(result.returncode, 9, result.stderr)
            receipt = state.receipt()
            self.assertFalse(receipt['cohortUnchanged'])
            self.assertEqual(receipt['postchecks']['identity']['status'], 'passed')
            self.assertEqual(receipt['postchecks']['cleanup']['status'], 'failed')
            self.assertIn('previous simulators', receipt['postchecks']['cleanup']['error'])
            self.assert_reaped(receipt)

    def test_workflow_collection_is_opt_in_and_final_join_requires_native_success(self):
        workflow = (ROOT / '.github/workflows/client-ui-harness.yml').read_text(encoding='utf-8')
        self.assertRegex(workflow, r'diagnostic_recordings:[\s\S]*?type: boolean\s+default: false')
        steps = re.split(r'(?m)^      - name: ', workflow)[1:]
        recordings = [step for step in steps if step.startswith('Record ')]
        self.assertEqual(len(recordings), 9)
        self.assertEqual(sum(len(re.findall(r'--scenario\s+\S+', step)) for step in recordings), 20)
        for step in recordings:
            self.assertIn("steps.app_build.outcome == 'success'", step)
            self.assertIn("steps.frame_tools.outcome == 'success'", step)
            self.assertIn("inputs.diagnostic_recordings && steps.native.outcome == 'failure'", step)
            self.assertIn('--diagnostic-native-failure', step)
            self.assertIn('$CLIENT_UI_RECORDING_ROOT/', step)
        native = next(step for step in steps if step.startswith('Compile and run required native'))
        self.assertNotIn('continue-on-error', native)
        joins = [step for step in steps if step.startswith('Verify all ')]
        self.assertEqual(len(joins), 2)
        for step in joins:
            condition = next(line for line in step.splitlines() if line.strip().startswith('if:'))
            self.assertIn("steps.native.outcome == 'success'", condition)
            self.assertNotIn('diagnostic_recordings', condition)
        self.assertIn('${{ env.CLIENT_UI_RUN_DIR }}/diagnostic-recordings/', workflow)

    def test_lost_driver_path_retains_launched_hash_exit_and_independent_cleanup(self):
        for path in ('driver', 'wrapper'):
            with self.subTest(path=path), RecordingFixture() as state:
                state.config.update(exit_code=7, active_after=True, **{'lose_' + path: True})
                result = state.run()
                self.assertEqual(result.returncode, 7, result.stderr)
                receipt = state.receipt()
                self.assertEqual(receipt['driverSha256'], state.driver_sha)
                self.assertEqual(receipt['driverPath'], str((state.root / 'driver.py').resolve()))
                self.assertEqual(receipt['recorderReturnCode'], 7)
                self.assertEqual(receipt['postchecks']['identity']['errorType'], 'FileNotFoundError')
                self.assertEqual(receipt['postchecks']['native']['status'], 'passed')
                self.assertEqual(receipt['postchecks']['cleanup']['status'], 'failed')
                self.assertEqual({error['check'] for error in receipt['postcheckErrors']}, {'identity', 'cleanup'})
                self.assertEqual(len(state.inventories()), 2)
                self.assert_reaped(receipt)

    def test_zero_recorder_with_failed_postcheck_exits_one_without_ordinary_identity(self):
        with RecordingFixture(native_passed=True, diagnostic=False) as state:
            state.config['change_source'] = True
            result = state.run()
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(state.receipt()['recorderReturnCode'], 0)
            self.assertEqual(state.receipt()['postchecks']['cleanup']['status'], 'passed')
            self.assertFalse((state.root / 'recordings/batch-identity.json').exists())

    def test_incomplete_recordings_cannot_emit_ordinary_identity(self):
        with RecordingFixture(native_passed=True, diagnostic=False) as state:
            state.config['missing_recording'] = True
            result = state.run()
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(state.receipt()['batchVerification']['status'], 'failed')
            self.assertFalse((state.root / 'recordings/batch-identity.json').exists())

    def test_stale_output_is_rejected_before_simulator_or_child_actions(self):
        with RecordingFixture() as state:
            output = state.root / 'recordings'
            output.mkdir()
            previous = b'{"old": "receipt"}\n'
            (output / 'batch-identity.json').write_bytes(previous)
            result = state.run()
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn('stale evidence', result.stderr)
            self.assertEqual((output / 'batch-identity.json').read_bytes(), previous)
            self.assertEqual(state.inventories(), [])
            self.assertFalse((state.root / 'driver-ready.json').exists())

    def test_diagnostic_receipt_cannot_join_with_a_later_passed_native_file(self):
        with RecordingFixture() as state:
            self.assertEqual(state.run().returncode, 0)
            _, native, _, domains, visuals, receipts = batches.SerialUIBatchChecks().fixtures()
            native['acceptanceIdentity'] = state.identity
            native_sha = hashlib.sha256((json.dumps(native, indent=2, sort_keys=True) + '\n').encode()).hexdigest()
            for report in (domains, visuals):
                report['bundle'] = copy.deepcopy(state.build['packaging'])
            for receipt in receipts:
                receipt.update(acceptanceIdentity=state.identity, nativeResultsSha256=native_sha, driverSha256=state.driver_sha)
            baseline = json.loads((state.root / 'baseline.json').read_text())
            verify(state.build, native, baseline, domains, visuals, receipts, native_results_sha256=native_sha)
            receipts[0] = state.receipt()
            with self.assertRaisesRegex(ValueError, 'Recording batch source/staging/native evidence identity differs'):
                verify(state.build, native, baseline, domains, visuals, receipts, native_results_sha256=native_sha)

    def test_postcheck_timeout_reaps_workers_and_still_observes_cleanup(self):
        with RecordingFixture() as state:
            state.config.update(identity_delay=10, budgets={'CHECK_SECONDS': 1})
            result = state.run()
            self.assertEqual(result.returncode, 1, result.stderr)
            receipt = state.receipt()
            self.assertFalse(receipt['postchecksComplete'])
            self.assertEqual(receipt['postchecks']['identity']['status'], 'timed-out')
            self.assertEqual(receipt['postchecks']['native']['status'], 'passed')
            self.assertEqual(receipt['postchecks']['cleanup']['status'], 'passed')
            self.assertTrue(all(0 < item['timeout'] <= 1 for item in state.inventories()))
            self.assert_reaped(receipt)

    def test_inner_deadline_stops_and_reaps_real_child_inside_envelope(self):
        with RecordingFixture() as state:
            state.config.update(loop=True, ignore_term=True, envelope_seconds=4,
                budgets={'FINALIZATION_SECONDS': 2, 'OUTER_MARGIN_SECONDS': 0.2, 'RECORDER_GRACE_SECONDS': 0.2,
                         'CHECK_SECONDS': 1, 'REAP_SECONDS': 0.3})
            began = time.monotonic()
            result = state.run()
            receipt = state.receipt()
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertTrue(receipt['innerDeadlineExceeded'])
            self.assertLess(receipt['elapsedSeconds'], 4)
            self.assertLess(time.monotonic() - began, 7)
            self.assert_reaped(receipt)
            self.assertFalse((state.root / 'recordings/batch-identity.json').exists())

    def test_signal_during_slow_postcheck_publishes_unknown_and_reaps_workers(self):
        with RecordingFixture() as state:
            state.config.update(identity_delay=10, signal_bridge=os.name != 'posix')
            process = state.start()
            state.wait_json('identity-check-ready.json')
            began = time.monotonic()
            if os.name == 'posix':
                os.killpg(process.pid, signal.SIGTERM)
            else:
                (state.root / 'interrupt-now').touch()
            emergency = state.wait_json('recordings/diagnostic-interrupted.json')
            self.assertLess(time.monotonic() - began, 2)
            self.assertEqual(emergency['postchecks']['identity']['status'], 'unfinished')
            self.assertFalse(emergency['postchecksComplete'])
            self.assertEqual(emergency['recorderReturnCode'], 0)
            result = state.finish()
            self.assertEqual(result.returncode, 143, result.stderr)
            self.assertLess(time.monotonic() - began, 5)
            self.assert_reaped(state.receipt())

    def check_interruption(self, *, whole_group):
        with RecordingFixture() as state:
            state.config.update(loop=True, ignore_term=True, signal_bridge=not whole_group, descendant=whole_group)
            process = state.start()
            ready = state.wait_json('driver-ready.json')
            began = time.monotonic()
            if whole_group:
                os.killpg(process.pid, signal.SIGTERM)
            else:
                (state.root / 'interrupt-now').touch()
            emergency = state.wait_json('recordings/diagnostic-interrupted.json')
            self.assertLess(time.monotonic() - began, 2)
            self.assertEqual(emergency['interruptedSignal'], signal.SIGTERM)
            self.assertFalse(emergency['nativeAcceptance'])
            self.assertFalse(emergency['postchecksComplete'])
            self.assertTrue(all(check['status'] == 'unfinished' for check in emergency['postchecks'].values()))
            result = state.finish()
            receipt = state.receipt()
            self.assertEqual(result.returncode, 143, result.stderr)
            self.assertEqual(receipt['interruptedSignal'], signal.SIGTERM)
            self.assertLess(time.monotonic() - began, 5)
            self.assert_reaped(receipt)
            self.assertEqual(len(state.inventories()), 1)
            self.assertFalse((state.root / 'recordings/batch-identity.json').exists())
            if whole_group:
                self.assertEqual(receipt['wrapperProcessGroup'], process.pid)
                child = next(child for child in receipt['children'] if child['role'] == 'recorder')
                self.assertEqual(child['processGroup'], ready['pid'])
                until = time.monotonic() + 2
                while process_alive(ready['descendant']) and time.monotonic() < until:
                    time.sleep(0.02)
                self.assertFalse(process_alive(ready['descendant']))

    @unittest.skipUnless(os.name == 'nt', 'Windows handler delivery; POSIX has a whole-group probe')
    def test_windows_handler_interruption_retains_fallback_and_reaps_real_child(self):
        self.check_interruption(whole_group=False)

    @unittest.skipUnless(os.name == 'posix', 'Requires real POSIX process-group signal delivery')
    def test_posix_whole_wrapper_group_sigterm_reaps_child_and_descendant(self):
        self.check_interruption(whole_group=True)

    @unittest.skipUnless(os.name == 'posix', 'Windows TerminateProcess does not return a negative signal code')
    def test_real_signal_child_exit_maps_negative_status_to_shell_status(self):
        with RecordingFixture() as state:
            state.config['die_by_signal'] = True
            result = state.run()
            self.assertEqual(result.returncode, 143, result.stderr)
            self.assertEqual(state.receipt()['recorderReturnCode'], -signal.SIGTERM)
            self.assert_reaped(state.receipt())


if __name__ == '__main__':
    unittest.main()
