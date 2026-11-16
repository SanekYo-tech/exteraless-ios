# NEO-03 — independent diagnostic-recording review

2026-11-16. HEAD: `b06bb00064157eb2df3d21a3cf0166e8e33cd259` plus the coordinator's working-tree changes.

**Verdict: NEO-03 is not fully source-closed: three P2 failure-path gaps remain. No P1 or diagnostic-to-native/ordinary-admission bypass was found in the reviewed chain.** The opt-in workflow, single recording cohort and strict ordinary admission are source-closed. Native execution and recorded-frame acceptance are not established by this source/tooling review.

Reviewed changes: `tools/runtime/record_client_ui_batch.py`, `.github/workflows/client-ui-harness.yml`, `tools/ci/tests/test_client_ui_recording_fallback.py`, `docs/wave-2/uikit-diagnostic-recording-fallback.md`. Adjacent files were read for their producer/consumer contracts; cache/native-driver/Composer owners' WIP is not assessed. This review authors only this document.

## P2 / DRF-01 — the actual owned-envelope SIGTERM bypasses the new finalizer

**Location:** `tools/runtime/record_client_ui_batch.py:59–83,105`.

The wrapper has no SIGTERM handler. `subprocess.run(command, check=False)` also leaves the recording child in the wrapper's process group. The production timeout path is concrete:

1. `client_ui_harness_workspace.py:181–189` runs the wrapper through `client_ui_harness.command`.
2. `client_ui_harness.py:86–93` creates that process group and invokes `stop_process` on timeout.
3. `client_ui_harness.py:66–76` sends **SIGTERM to the whole group**, waits five seconds, then escalates to SIGKILL.
4. The recording driver installs its own SIGTERM handler (`client_ui_harness.py:421–423`), but its parent `record_client_ui_batch.py` still has `SIG_DFL`. Termination of that parent does not execute Python `finally`.

Thus an owned recording timeout can retain partial driver output **without either postcheck or `diagnostic-identity.json`**. This is the configured timeout mechanism, not an assumed filesystem attacker or an arbitrary uncatchable kill.

**Local reproduction:** an isolated child entered the real `recorder.main()` with the existing fixture, created recording output in its mocked recording call, then raised SIGTERM while inside that call. Observed handler: `SIG_DFL`; the enclosing Python finalizer was not reached; the output survived but the diagnostic sidecar did not. This was a Windows process probe; the macOS group-delivery route above is established from source, not a native run.

By contrast, a **child-only** `CompletedProcess(returncode=-15)` while the wrapper survives correctly runs both cleanup observations and retains `recorderReturnCode=-15`. Testing only that return value misses the actual envelope path.

**Required correction:** give the wrapper an owned, bounded child/signal lifecycle and retain enough finalization time inside the existing outer envelope to reap the recorder, perform the postchecks and publish its receipt. The outer timeout grants only five seconds before escalation; merely adding an exception-raising handler to the current `subprocess.run` is not a complete fix. Retain the original signal/return-code evidence and the current 30-second app limit. Add a bounded process-level probe for wrapper/group interruption, not only a mocked negative child return value.

## P2 / DRF-02 — losing a bound driver path also loses the failure receipt

**Location:** `tools/runtime/record_client_ui_batch.py:64–83`, especially line 81.

The postcheck deliberately re-reads the bound inputs to detect drift. However, the supposedly unconditional diagnostic finalizer then re-opens `Path(driver.__file__)` to calculate `driverSha256`. If that input was moved or removed during recording, the postcheck fails as intended, and the receipt construction **fails a second time before opening the sidecar**. Partial recordings and the known recorder return code lose their identity receipt precisely on the path-change case this guard is supposed to explain.

**Local reproduction:** point `driver.__file__` at an owned temporary copy; have the input snapshot read that copy; after producing output, rename the copy and return recorder code 7. The real wrapper raises `FileNotFoundError`, retains `acceptance.json`, but creates **no `diagnostic-identity.json`**. No repository source was moved or edited.

There is a related finalization gap at lines 65–70: a source/native identity exception skips the after-recording simulator observation. A separate source-drift probe observed one cleanup call instead of two. `cohortUnchanged=false` remains fail-closed, but the promised independent after-cleanup observation has not happened.

**Required correction:** snapshot the launched driver's path/hash before recording and use that in the receipt; run the cleanup observation independently of source/native postcheck failure. Preserve the observed failures and `cohortUnchanged=false` without depending on reopening the missing input to describe it.

Minimal coordinator-only hunks, **not applied**:

```diff
--- a/tools/runtime/record_client_ui_batch.py
+++ b/tools/runtime/record_client_ui_batch.py
@@
     native_sha = digest(args.native_tests)
-    command = [sys.executable, str(Path(driver.__file__).resolve()), '--ipa', str(args.ipa.resolve()),
+    driver_path = Path(driver.__file__).resolve()
+    driver_sha = digest(driver_path)
+    command = [sys.executable, str(driver_path), '--ipa', str(args.ipa.resolve()),
@@
-            require_build_identity(build, build_plan(telegram)[0], harness_inputs(telegram),
-                                   driver.load_packaging(telegram).load_staging_manifest(telegram), args.ipa)
-            if digest(args.native_tests) != native_sha:
-                raise ValueError('Native evidence changed during recording')
-            if diagnostic:
-                prior_native_guest_released(args.native_tests)
+            try:
+                require_build_identity(build, build_plan(telegram)[0], harness_inputs(telegram),
+                                       driver.load_packaging(telegram).load_staging_manifest(telegram), args.ipa)
+                if digest(args.native_tests) != native_sha:
+                    raise ValueError('Native evidence changed during recording')
+            finally:
+                if diagnostic:
+                    prior_native_guest_released(args.native_tests)
             cohort_unchanged = True
@@
-                           'driverSha256': digest(Path(driver.__file__)), 'domainSources': build['domainSources']}
+                           'driverSha256': driver_sha, 'domainSources': build['domainSources']}
@@
-               'driverSha256': digest(Path(driver.__file__)), 'domainSources': build['domainSources']}
+               'driverSha256': driver_sha, 'domainSources': build['domainSources']}
```

These are the local path-loss/cleanup corrections; DRF-01 still requires the bounded signal lifecycle described above.

## P2 / DRF-03 — the executable boundary does not preserve the recorder's exit code

**Location:** `tools/runtime/record_client_ui_batch.py:84,105` and `tools/ci/tests/test_client_ui_recording_fallback.py:112–120`.

`result.check_returncode()` raises `CalledProcessError`, which `main()` leaves uncaught. Python therefore exits with **1**, irrespective of a recorder exit such as 7. The new test checks the exception's `returncode` attribute rather than the executable's return code, so it passes despite this mismatch with the requested original-exit-status contract.

**Local reproduction:** invoke the real `recorder.main()` in a separate Python process with a fixture recorder returning 7 and all postchecks passing. The parent observes `returncode=1`; the retained sidecar correctly contains `recorderReturnCode=7`. The job still fails, but exact status preservation is only implemented in the JSON field. This is an existing CLI behavior left open by the new guarantee, not a newly introduced green-job path.

Minimal coordinator-only CLI hunk, **not applied**:

```diff
--- a/tools/runtime/record_client_ui_batch.py
+++ b/tools/runtime/record_client_ui_batch.py
@@
     args = parser.parse_args()
-    record(args)
+    try:
+        record(args)
+    except subprocess.CalledProcessError as error:
+        raise SystemExit(error.returncode if error.returncode > 0 else 128 - error.returncode) from error
```

Negative child codes map to the shell convention, e.g. `-15 → 143`; the sidecar should retain the raw `-15`. Also preserve a known recorder failure when a postcheck fails: currently that exception bypasses line 84 entirely. The bounded-lifecycle correction should collect postcheck errors, publish them, and then propagate the known recording failure rather than replacing its return status. The CLI hunk alone covers the successful-postcheck case.

## Producer/consumer and workflow closure

| Contract | Reviewed result |
|---|---|
| Actual native failure schema | `run_native_integration_tests.py:441–457` initially writes `status=not-run, native_execution_verified=false`, and writes `failed` after a caught failure. The new diagnostic predicate matches its real failure output and rejects the unfinished initial output. Successful native evidence still requires `verify_native_results` in ordinary mode. |
| Built IPA and domain manifest | `client_ui_harness_build.py:269–296` reads the manifest from the actual IPA, compares it with the build snapshot and freezes the verified IPA. `require_build_identity` binds plan, harness/domain sources, staging sources and IPA bytes. The driver compares running domain manifests with the IPA manifest (`client_ui_harness.py:435–461`). No manifest-field producer/consumer mismatch was found. |
| Actual `recordings` field | `client_ui_harness.py:369–404,474–491` produces an ordered list with `scenario` and `frameCount`, after H.264/ffprobe/frame-sheet checks. This matches `verify_batch:22–45`; the driver cannot report successful completion merely because `scenarios` exists. `recorded-awaiting-visual-review` remains the final recorded status. |
| Diagnostic admission isolation | Diagnostic mode returns before ordinary receipt creation; its sidecar lacks ordinary `nativeEvidence`/`batch` admission fields. `verify_client_ui_batches.verify` first verifies complete native evidence and then exact ordinary receipts/native bytes. A real diagnostic sidecar was rejected both with the failed native fixture and with subsequently supplied valid native evidence. |
| Native/recording completeness | `verify_native_results:96–124` still requires every class/method in the compiled source plan and the fixed phase budgets: all 434 methods in the stated NEO cohort. Base and supplement joins retain the full 20-scene/9-device contract and required frame evidence. Frame review remains separate. |
| One recording cohort | There are nine existing serial recording steps: `3+3+2+3+3+3+1+1+1=20`. Each chooses one output root according to native outcome, uses the same retained IPA and existing owned-exec budget, and invokes the real recording driver through the wrapper. No second recording set or changed 30s app logic was introduced. |
| Workflow prerequisites/failure result | `!cancelled()` supplies an explicit status condition; successful app build and frame tools remain prerequisites. The nine recording conditions do not depend on a sibling recording's success, so independent batches can proceed after its failure. Native has no `continue-on-error`; later successful collection cannot turn its failed job result green. Both joins require native success and read ordinary `evidence/`. |
| Early/stale/changed evidence | Wrong IPA or unfinished native output stops before any recorder or simulator-inventory call. The real driver's stale-output preflight exits 2 before simulator commands. Native-result byte changes during recording block ordinary receipts in both modes; the diagnostic sidecar records `cohortUnchanged=false`. The workflow's fresh `mktemp` root and driver empty-directory check prevent reuse of old successful output. |
| Artifact retention | `always()` upload includes `diagnostic-recordings/` and `native-tests/`, including failed/partial output when available. Receipt loss in DRF-01/02 is therefore material: upload cannot retain a sidecar that was never written. |

## Local verification and reviewed bytes

**Nine new bounded review probes**, in two `python -B` in-memory runs: 6 probes / 1.314s and 3 probes / 0.234s. Both commands had 30s external bounds. The probes assert the observed counterexamples as well as admission rejection; their passing execution does not mean the three defects are fixed. The coordinator's existing 27-test result is not counted as a new review run. All probe filesystem changes were confined to owned temporary fixtures.

Observed counterexamples: wrapper SIGTERM loses finalization/sidecar; temporary driver-path loss loses sidecar; child 7 becomes CLI 1; source drift skips the second cleanup observation. Positive counterexamples: surviving-wrapper child exits 7/-15 retain honest sidecars; early preflight invokes no simulator calls; stale output invokes no simulator commands; native-byte drift creates no ordinary receipt; diagnostic identity cannot substitute at the final join.

SHA-256 of reviewed inputs:

| File | SHA-256 |
|---|---|
| `tools/runtime/record_client_ui_batch.py` | `b12acfac615425196eff4384cb863cdcf341ac870a943272c3b0d69d6df84d39` |
| `.github/workflows/client-ui-harness.yml` | `ec8eeb9eaf977ed2c7b30fd0b4b3f71aaae9779ea0d0502ee9012008aca6c918` |
| `tools/ci/tests/test_client_ui_recording_fallback.py` | `c6838cb3573371a5c46215f09767a9047900ea19b3eac43a93f9db21aea94bd2` |
| `docs/wave-2/uikit-diagnostic-recording-fallback.md` | `30670475ecc57260dacb0f7401af8367e452efdf8c98608400c4cf5276b5103f` |

**Scoped closure:** the collection/admission graph is sound for ordinary recorder completion, including a nonzero child exit. NEO-03 remains open for the three failure-path guarantees above. Native methods and actual frames were not executed or accepted by this review.
