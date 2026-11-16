# Diagnostic recording failure closure — DRF-01 / DRF-02 / DRF-03

2026-11-16. Implementation handoff against `b06bb00064157eb2df3d21a3cf0166e8e33cd259` plus the shared working tree.

**All three DRF fixes are implemented. Workflow integration requires the coordinator's nine `--envelope-seconds` arguments below.** Local verification: **40 PASS, 2 POSIX-only SKIP**. This establishes source/tooling behavior with real Python child processes; native execution and recorded-frame acceptance are not claimed.

## Implementation

### DRF-01 — bounded child lifecycle and interrupted evidence

`tools/runtime/record_client_ui_batch.py` now owns the recorder's PID/process group and the bounded read-only check workers. On POSIX, each child gets a captured process group in the wrapper's session (`process_group=0`). Wrapper signals are forwarded to those owned groups. Graceful termination, group kill and bounded `wait()` retain raw return codes and reap observations. The existing driver continues to own its simulator and its internal commands.

For an envelope **E**, the recording cutoff is **E−35 seconds from wrapper entry**, including preflight time. Normal finalization has a 30-second reserve and a five-second margin before the outer envelope. Recorder termination has at most eight seconds of grace; the three postchecks run concurrently for at most twenty seconds, clipped to remaining finalization time, with bounded reaping.

On SIGTERM/SIGINT, the handler first publishes an atomic, source-independent fallback:

- diagnostic mode: `diagnostic-interrupted.json`;
- ordinary mode: `recording-interrupted.json`.

It also creates the normal state sidecar immediately if it does not yet exist. The immutable fallback records the interrupted signal, captured PID/group identities, the child status known at that instant, and **unfinished** checks. Publication happens before waiting for cleanup, reading source inputs or querying simulator inventory.

The first signal gives emergency termination/reaping **three seconds within the existing outer five-second signal grace**, even when the wrapper's soft deadline has already elapsed. Repeated signals do not extend that budget. An interrupted wrapper starts no further expensive postchecks. Running check workers are stopped/reaped; already completed observations remain available. A later SIGKILL therefore cannot erase the earlier honest fallback or turn an unfinished check into a completed one.

### DRF-02 — captured source metadata and independent postchecks

The launched driver path/hash, command, compiled identity, domain sources and native-result digest are captured before launch. Failure receipts use those in-memory values. They do not reopen a disappeared driver path.

The wrapper also snapshots its own worker bootstrap before launch. Native-result hashing and simulator inventory can execute from this copy without importing the mutable UI/source modules. Their execution remains possible when the original wrapper or driver path disappears.

Three separate, deadline-bounded read-only processes observe:

1. `postchecks.identity`: the current plan/harness/staging/IPA against the captured compiled build;
2. `postchecks.native`: unchanged native-result bytes;
3. `postchecks.cleanup`: native guest deletion, when a native guest receipt exists, and no active simulators.

A source exception or stalled source pass cannot suppress the independent native/cleanup observations. Inventory's subprocess timeout is bounded by the worker's remaining allowance; the parent additionally enforces the shared deadline on the entire worker group.

`postchecksComplete` means every check returned a passed/failed observation, **not** that they passed. Timed-out/interrupted checks remain incomplete. `cohortUnchanged` is conservatively false after any failed/incomplete check or wrapper interruption. The individually named check statuses and `postcheckErrors` distinguish source drift from cleanup failure. `children` retains PID/group, raw worker/recorder return codes, sent signals, reaping and group-cleanup observations.

### DRF-03 — executable exit status and admission

Exit precedence is explicit:

| Observed condition | Wrapper CLI exit |
|---|---:|
| Wrapper SIGTERM | `143`, with the raw child result separately retained |
| Wrapper SIGINT | `130` |
| Recorder exits `7`, including a failed postcheck | `7` |
| Recorder dies by POSIX signal, e.g. raw `-15` | `128 - (-15) = 143` |
| Inner deadline expires but recorder exits zero | `124` |
| Recorder exits zero and a postcheck or batch verification fails | `1` |

Ordinary `batch-identity.json` is emitted only after strict native admission, a successfully reaped zero-exit recorder, every postcheck passing and full `verify_batch` success. Interruption revokes a just-created receipt owned by this invocation. Diagnostic/state/interrupted JSON always has `nativeAcceptance=false` and cannot substitute for an ordinary receipt, including with a later fabricated passed native JSON.

Preflight rejects unfinished/incorrect native evidence, wrong IPA identity and stale output before recorder launch. Identity/native preflight rejection performs no simulator-inventory operation. Source-bound diagnostics still use the actual `client_ui_harness.py` and its existing semantic/recorded-frame checks.

## Required coordinator workflow edit

`.github/workflows/client-ui-harness.yml` remains coordinator-owned. The new argument is **required**, so all nine existing recording commands need it before dispatch. Append it directly after `tools/runtime/record_client_ui_batch.py`, before the conditional diagnostic flag:

```diff
-          --seconds 600 -- "$CLIENT_UI_RUN_DIR/frame-env/bin/python" -u tools/runtime/record_client_ui_batch.py
+          --seconds 600 -- "$CLIENT_UI_RUN_DIR/frame-env/bin/python" -u tools/runtime/record_client_ui_batch.py --envelope-seconds 600
```

Apply the same one-line change with each command's existing outer `--seconds` value:

| Recording output suffix | Required argument | Preflight + recording cutoff | Wrapper soft finish |
|---|---|---:|---:|
| `baseline` | `--envelope-seconds 600` | 565s | 595s |
| `domains` | `--envelope-seconds 600` | 565s | 595s |
| `final-visuals` | `--envelope-seconds 600` | 565s | 595s |
| `supplements/reset-1` | `--envelope-seconds 180` | 145s | 175s |
| `supplements/reset-2` | `--envelope-seconds 180` | 145s | 175s |
| `supplements/reset-3` | `--envelope-seconds 180` | 145s | 175s |
| `supplements/reset-4` | `--envelope-seconds 120` | 85s | 115s |
| `supplements/trust-secondary` | `--envelope-seconds 150` | 115s | 145s |
| `supplements/map-attribution` | `--envelope-seconds 150` | 115s | 145s |

Occurrence counts: **600 ×3, 180 ×3, 120 ×1, 150 ×2**. These are arguments to the recording wrapper, not to `client_ui_harness_workspace.py`. The existing outer seconds/minutes, nine serial slots, twenty scenarios and 30-second app limit supply the enclosing contract. No second recording cohort is introduced. The native-success-only final joins and failed-native job outcome retain their existing workflow conditions.

## Checks and observed inventories

Commands executed locally, each under a bounded tool timeout:

```text
python -B -m unittest tools.ci.tests.test_client_ui_recording_fallback -v
  21 tests / 23.611s: 19 PASS, 2 POSIX-only SKIP

python -B -m unittest tools.ci.tests.test_client_ui_batches tools.ci.tests.test_client_ui_supplements tools.ci.tests.test_client_ui_map tools.ci.tests.test_native_input_identity -v
  21 tests / 0.751s: 21 PASS
```

After the final emergency-deadline/inventory assertions, four affected process tests passed again in **5.136s**: Windows handler interruption, interruption during a slow postcheck, strict ordinary PASS, and bounded postcheck timeout. The preceding implementation iteration also completed its focused suite; these reruns are not added to the unique **40 PASS / 2 SKIP** total. Four bounded test commands were used in all.

The process fixture launches the actual wrapper CLI and real CPython recorder/check children. It uses real temporary source/native files, filesystem renames, PID liveness checks, timeout/termination and a fixture simulator-inventory response. Its ten original test cases retain their coverage; eleven additional cases cover the new process/evidence boundaries.

| Local observation | Verified inventory/result |
|---|---|
| Valid diagnostic invocation | Two inventory observations: before and after recording; five owned child entries including recorder and check workers |
| Ordinary native-PASS fixture | One after-recording inventory observation; four owned child entries |
| Wrong IPA / failed-native ordinary mode / unfinished native | Zero inventory observations and no recorder child |
| Active or undeleted prior native guest | One inventory observation; recorder never starts |
| Driver or wrapper path renamed, recorder exit 7, guest left active | Two inventory observations; original driver SHA retained; independent identity/cleanup errors; CLI remains 7 |
| Recorder interrupted before postchecks | One prior inventory observation; immediate unfinished fallback, final child reaped and CLI 143 |
| Identity worker stalls | Native and cleanup checks complete independently; inventory timeout is clipped to the test's one-second check allowance; stalled worker is killed/reaped |
| Stale output or incomplete `recordings` | No new ordinary receipt |
| Diagnostic receipt supplied to ordinary join with valid replacement native evidence | Join rejects the diagnostic receipt |

Local platform was Windows / Python 3.14.8. WSL reported that the Linux subsystem is not installed. Windows `os.kill(pid, SIGTERM)` invokes `TerminateProcess`; it cannot exercise POSIX whole-group delivery or produce a negative signal return code. The Windows probes deliver the wrapper's Python handler via `signal.raise_signal(SIGTERM)` and exercise real child termination/reaping through `os.kill`. The two explicitly skipped POSIX tests exercise actual `os.killpg` of the wrapper group with a TERM-ignoring child/descendant and actual negative child-signal exit mapping. They are ready for the normal POSIX unit-test environment; no local POSIX, Apple or CI execution is claimed.

Python AST parsing and whitespace checks passed for all three code postimages. The original independent review remains immutable.

## Owned postimages

Inventory: **four authored paths** — two updated code/test files, one new test-only process fixture, and this new closure document. There is no new production helper outside the existing wrapper's source-identity inventory.

| Source/test path | Lines | Bytes | SHA-256 |
|---|---:|---:|---|
| `tools/runtime/record_client_ui_batch.py` | 441 | 24714 | `f337bbaef3b05788b8d78857043bdfc3acf53e56b8684c0423cf25428c176865` |
| `tools/ci/tests/test_client_ui_recording_fallback.py` | 321 | 18624 | `a18919afb623b08701139d3c9f4990fc167f10d3faed56b392f0cdb54c4172d0` |
| `tools/ci/tests/client_ui_recording_process_fixture.py` | 262 | 12218 | `7f55396e6e94882189d2f648a2cda2df62b695ea98dc8f0815571617c0211617` |

Original review SHA-256: `a736092151333652e45138d3358057aba6acc235b50e4420ceb20b5b6db27f04` (`reviews/diagnostic-recording-fallback-review.md`).

**Handoff:** DRF-01/02/03 implementation and local source/tooling checks are complete. Coordinator action is the nine workflow arguments above; full native/recorded-frame acceptance remains a subsequent gate.
