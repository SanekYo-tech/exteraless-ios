# CI cleanup correction review — 735be8e5 / 79fedf4f

## Findings and evidence

1. **Remove the output-base reset.** `735be8e5` added an unqualified
   `shutil.rmtree(child)` for directories containing `execroot`, without a Bazel
   shutdown or a known disposable-output phase. A workspace sentinel and a name
   test do not make current materialized outputs disposable. The function,
   directory enumeration and `reset` CLI action are removed.
2. **Do not report EPERM as cleanup success.** `79fedf4f` grouped
   `PermissionError` with `ProcessLookupError`, asserting PID recycling without
   evidence. ESRCH reports absence; EPERM reports denied signaling. Neither
   a reaped leader nor EPERM establishes that every owned group member exited.
   Generic historical `OSError`/`groupClosed=false` information also does not
   establish which errno or permission condition occurred. The correction keeps
   generic errors generic, records the actual errno/type when present, leaves
   `groupClosed=false` on denial, and blocks ordinary acceptance. It preserves
   the actual recorder exit, failed sidecar and independent postcheck results.
3. **Sequential steps are not a shutdown receipt.** The old recordings helper
   returned `assumed-idle-post-native-step`; elapsed idle time was not measured
   and the server could still exist. The new path requires terminal native
   evidence, closed HTTP-cache evidence and an actual successful owned shutdown.

Read-only inspection of the existing local run
`build/artifacts/client-ui-43852504839/native-tests/` found:

| Receipt | Observation | SHA-256 |
|---|---|---|
| `disk-capacity.json` | One measured base, `1345af8f7ac8ab04c017d273343e133f`; free after recovery 21,478,535,168 bytes; kept cache 5,951,805,045 bytes | `c74ae78b81b13c62a0e7f9bf748916efb9774d548793ce778f45084d349b46ff` |
| `disk-after-compile.json` | Same measured base; free 139,485,184 bytes | `c509f51e6afb1d114a33dff1a53ae9a372cbe3e3ec57a9bda9ddb6727a6fb506` |
| `readonly-cache.json` | `stopped`, no error, zero workers/connections, root FD closed | `52a3a7dc980cb1da63bea676c2a6f78b2b8b11e53541143c47fbeaa7ae448e51` |
| `result.json` | `failed`, `native_execution_verified=false`, native compile command failed | `f337d58dcd8adbfd3e3337589a18c8128d03439404fc36ae56052356dc681a89` |
| `source-identity.json` | Generation `43852504839-1`; **131,808 bytes**, larger than a 4 KiB ownership marker | `6d02062353af80361154d42472a92a60498d93a5cddbe82433e8361008ffe897` |

These receipts establish disk exhaustion, not the previously asserted
“3+ accumulated output bases / 60–80 GB” cause. The bounded tree inventories
are incomplete lower bounds. They neither count all historical bases nor
justify deleting the one actual base. No old receipt is relabelled successful.

## Implemented recordings capacity contract

- Invocation stays inside `client_ui_harness_workspace.py exec`, holding the
  existing generation lock across selection, `info`, shutdown and reclamation.
  The helper itself does not reacquire that non-reentrant outer lock.
- Require explicit `--run-output` and its exact
  `--native-results .../native-tests/result.json`. Require matching generation
  in the existing source, capacity and service receipts, and the original
  owned/cache/native-output paths. Reject missing, wrong-phase, unfinished,
  relocated, symlinked or oversized evidence. Receipt reads have a **1 MiB**
  bound; small ownership/claim metadata keeps its **4 KiB** bound.
- Preserve the actual terminal native result in `build/frame-capacity.json`;
  only passed/verified or failed/unverified terminal pairs are admitted. This is
  a capacity/phase gate, not an alternative native-acceptance verifier.
- Require the current complete-readonly-HTTP mode/flags, `status=stopped`, an
  explicit null service error, zero workers/connections and a closed root FD.
  An errored/unknown/missing close receipt refuses cleanup, even if free space
  already passes. The service receipt is rechecked after shutdown.
- Select only existing
  `telegram-ios/build-input/bazel-9.2.0-darwin-arm64`, verify its SHA-256 against
  the staged `versions.json`, and refuse a missing or mismatched binary.
  No `locate_bazel`, download, cache copy, replacement or chmod is performed.
- Run actual `info output_base` and `shutdown`, using the native startup options,
  exact owned user root, source cwd and `--noblock_for_lock`. Each subprocess is
  capped at **15s**. `info` must match the native receipt's real output base;
  shutdown must return zero before any cache inventory/deletion. Record actual
  commands, exit codes, errors and timings. A timeout leaves its exit unknown.
- The helper has an **85s** total budget inside the outer **90s** envelope;
  reclamation uses at most **45s** of the remaining time. The existing quotas,
  fixed cache claim, generation/inode checks and POSIX no-follow leaf unlink
  remain in force. Only claimed SHA-256 AC/CAS leaves can be deleted.
- Keep the recordings **4 GiB floor / 6 GiB target / 1 GiB cache cap** and native
  **20 GiB floor / 30 GiB target / 8 GiB cap**. Free-space readiness uses measured
  filesystem bytes, never deleted-byte estimates. Purpose and truthful failure
  fields are persisted in the frame sidecar, including pre-reclamation failure;
  the native receipts are not overwritten. Invalid/unowned output paths are
  refused before publishing to them.

The pressure policy, complete-AC admission and cache-enabled execution salt
remain intact. Existing real Bazel proof
`build/wave-2-dependencies/native-cache-completeness-b06bb000/continuation-3/verification-entry.json`
was reread and its **16 artifact hashes rechecked locally, all matching**:
SHA-256 `2fedd6fee7daff0dbf9b9b16907bdc0703e1a22c2218b36ee630c935f938f31f`.
It retains run **43846695323 / 219080d9**, eight cases, the required failing
orphan negative control, successful complete-AC fallback, kept-output reuse
and seven closed HTTP server lifetimes. This review did not rerun Bazel or CI.

## Required coordinator workflow hunk — not applied here

Apply with this helper change, before another dispatch. The current workflow's
`reset` invocation is intentionally no longer accepted. The recordings capacity
step should run only for a terminal native branch intended for recording; frame
tools must require that capacity step's success.

```diff
--- a/.github/workflows/client-ui-harness.yml
+++ b/.github/workflows/client-ui-harness.yml
@@
-      - name: Reset accumulated Bazel output bases
-        timeout-minutes: 10
-        run: >-
-          python -u tools/runtime/client_ui_harness_workspace.py exec
-          --root "$OWNED_ROOT" --repository "$GITHUB_REPOSITORY" --generation "$WORKSPACE_GENERATION"
-          --seconds 540 -- python -B tools/runtime/native_test_disk.py reset
-          --owned-root "$OWNED_ROOT" --repository "$GITHUB_REPOSITORY" --generation "$WORKSPACE_GENERATION"
-          --bazel-root "$BAZEL_USER_ROOT"
-          --output "$CLIENT_UI_RUN_DIR/build/output-base-reset.json"
-
@@
       - name: Reclaim remaining action cache for recordings
         id: recording_capacity
-        if: ${{ !cancelled() && steps.app_build.outcome == 'success' }}
+        if: ${{ !cancelled() && steps.app_build.outcome == 'success' && (steps.native.outcome == 'success' || (inputs.diagnostic_recordings && steps.native.outcome == 'failure')) }}
         timeout-minutes: 2
         run: >-
           python -u tools/runtime/client_ui_harness_workspace.py exec
           --root "$OWNED_ROOT" --repository "$GITHUB_REPOSITORY" --generation "$WORKSPACE_GENERATION"
           --seconds 90 -- python -B tools/runtime/native_test_disk.py recordings
           --owned-root "$OWNED_ROOT" --repository "$GITHUB_REPOSITORY" --generation "$WORKSPACE_GENERATION"
           --cache "$BAZEL_DISK_CACHE" --bazel-root "$BAZEL_USER_ROOT"
+          --run-output "$CLIENT_UI_RUN_DIR"
+          --native-results "$CLIENT_UI_RUN_DIR/native-tests/result.json"
           --output "$CLIENT_UI_RUN_DIR/build/frame-capacity.json"
@@
       - name: Install checksum-pinned CI frame tools
         id: frame_tools
-        if: ${{ !cancelled() && steps.app_build.outcome == 'success' && (steps.native.outcome == 'success' || (inputs.diagnostic_recordings && steps.native.outcome == 'failure')) }}
+        if: ${{ !cancelled() && steps.app_build.outcome == 'success' && steps.recording_capacity.outcome == 'success' && (steps.native.outcome == 'success' || (inputs.diagnostic_recordings && steps.native.outcome == 'failure')) }}
@@
-            ${{ env.CLIENT_UI_RUN_DIR }}/build/output-base-reset.json
```

## Local verification and limits

Windows tooling checks; every test subprocess invocation had a **30s** outer
limit. Recording cases were split into bounded groups, not run as one long suite.

| Tests | Result |
|---|---|
| `tools.runtime.tests.test_native_test_disk` | 32 passed / 1 POSIX-only skip; final 32-case invocation 8.910s, added outer-lock case 0.184s |
| `tools.runtime.tests.test_native_test_cache` | 24 passed / 1 POSIX-only skip, 5.665s |
| `tools.ci.tests.test_client_ui_recording_fallback` | 25 passed / 2 POSIX-only skips; process groups of 10/10/3 took 21.042/14.871/3.146s; added bootstrap-copy case 0.666s; signal-errno cases separately passed |
| `test_native_test_workflow` + `test_native_input_identity` | 9 passed, 1.040s |

Total unique checks: **90 passed / 4 skipped / 94 discovered**, no failures.
`git diff --check` passed for the changed tracked helpers/tests.
The real POSIX group-signal/negative-exit and dirfd paths are explicitly skipped
on Windows, not claimed as observed. EPERM fault injection exercises a denied
signal after real fixture-child exit; it is not a PID-recycling reproduction.
The Bazel subprocess results and capacity readings in new policy tests are
explicit fixtures, not a new Mac/Bazel receipt.

Meaningful regressions cover EPERM versus ESRCH versus generic OSError, unknown
group closure, failed-sidecar/exit preservation, prelaunch bootstrap-copy error,
wrong source phase, large valid and oversized receipts, stale generation/path,
missing or failed HTTP closure, missing/mismatched existing binary, wrong actual
output base, failed/timed-out shutdown, changing receipts, free-pass and pressured
reclamation, removed reset CLI and the real outer OS generation lock.

The required native **37 targets / 434 methods**, **20 scenes**, and **30s** logic
and app contracts remain unchanged. This delivery is ready for coordinator
review/commit, not an Apple/native/visual acceptance claim. No CI, network,
subagent, commit or push was used; production startup, launch smoke, unsigned
archive-copy WIP and historical outputs were not edited.

## Coordinator integration

The required UIKit workflow edits are applied. The normal-app launch workflow
does not have native-test terminal/HTTP-close receipts, so its main-branch
post-native reclamation call is removed; the launch driver checks4 GiB free
space read-only instead. Its already-running baseline snapshot remains unchanged.
The device-build workflow now queues rather than cancels the active same-ref
UIKit job. This prevents recurrence of the earlier cross-workflow cancellation.

Coordinator verification:48 disk/workflow/input/launch checks (one POSIX skip)
and five focused recording failure checks (one POSIX skip) passed. YAML dependency
references resolve. The normal first-launch recording and physical-device
black-screen diagnosis remain independent, unfinished evidence scopes.
