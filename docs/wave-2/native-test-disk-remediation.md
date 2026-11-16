# Native test disk recovery — functional ENOSPC remediation

The recovery is implemented in `tools/runtime/native_test_disk.py` and invoked
by `run_native_integration_tests.py` **after the native aquery/validators finish,
before the complete37-target compile**. The prior ENOSPC report and snapshots
remain separate. No runner cleanup or CI launch was performed from this Windows
session; the new code will perform the authorized cache reclamation on the runner.

## Boundaries and ownership

The only reclaimable root is the explicit CI action cache:

`/Users/runner/Library/Caches/exteraless-bazel-disk`

It must equal the `--cache` argument and `BAZEL_DISK_CACHE` when that environment
variable is present. The helper validates every path component by lstat, rejects
symlinks/reparse points and traversal, and accepts only the known action-cache
root layout. It does not resolve an arbitrary symlink into an approved path.

After the fresh source generation and cache restore, the workflow performs a
non-deleting `claim` step before building the app:

- cache marker: `.exteraless-native-action-cache.json`, binding the exact root,
  repository, schema and `exteraless-bazel-9.2.0-sha256-actions-v1` storage key;
- workspace claim: `.native-test-cache-claim.json`, additionally binding source
  generation, workspace and the actual cache device/inode.

An existing marker from another repository/namespace, a replaced cache root,
unready/stale generation, malformed store, symlink shard or non-digest leaf fails
closed. A marker can be introduced only at the fixed known cache root; this is
not a general directory-adoption or file-shredding interface.

The retained trees are:

| Path | Treatment |
| --- | --- |
| `/Users/Shared/exteraless-client-ui-harness` | Verify workspace sentinel/generation; measure |
| Its `bazel-user-root/<actual output_base>` | Query exact path from the owned Bazel server; measure and retain |
| `telegram-ios` source and staged runtime | Retain |
| `$CLIENT_UI_RUN_DIR/build/ClientUIHarness.ipa` | Retain the already verified same-cohort IPA |
| `$CLIENT_UI_RUN_DIR/native-tests` and other run evidence | Measure; write only diagnostic receipts |
| Python/support/download caches, Xcodes and simulators | Not reclamation candidates |

The existing outer workspace lock still spans the native stage. Generation and
cache-claim checks run before recovery and again before each candidate deletion.
When reclamation is needed, a bounded `--noblock_for_lock shutdown` must complete
for the exact owned Bazel server. A busy/failing/timed-out shutdown prevents
deletion. No other server is cancelled.

## Capacity, LRU and bounded deletion

- Enforced free-space floor: **20 GiB** (`21474836480` bytes) on the owned output
  and run volumes. This is a precompile reserve, not a prediction that future
  outputs cannot exceed it.
- Recovery target: **30 GiB** (`32212254720` bytes).
- After recovery, retained eligible AC/CAS data must be at most **8 GiB**.
- Resource phase: at most **60s**, including the output-base query and owned
  server shutdown; cache inventory at most200000 entries; deletion at most100000
  files /64 GiB. Every cutoff and partial outcome is recorded.
- If the initial output/run free space already reaches20 GiB, report it and
  perform **no deletion** or shutdown, even if the cache is larger than8 GiB.

Only regular, single-link SHA-256 files under `ac/<two hex>/<digest>` and
`cas/<two hex>/<digest>` are candidates. Their order uses mtime: Bazel's disk
client refreshes mtime on both storage and retrieval. Temporary uploads, GC
metadata, ownership markers, directories, hardlinks and changed entries are
retained. Complete candidate inventory precedes any deletion.

The production unlink path uses POSIX directory FDs opened with
`O_DIRECTORY|O_NOFOLLOW`, opens each parent relative to the retained FD, checks
device/inode/size/mtime again, and unlinks exactly one leaf using `dir_fd`.
Replacing a leaf with a symlink cannot redirect deletion to its target.

The helper checks **actual `disk_usage().free`**, not `deletedBytes`, after each
successful unlink. APFS snapshots/shared extents therefore cannot produce a
false capacity success. If the writable output volume differs from the cache
volume, reclamation is refused when it cannot address the measured deficit.
Insufficient free space or a cache still over its eligible-data cap fails before
compilation with measured free/minimum/kept-cache bytes and cutoff details.

## Bazel 9.2 flag verification and tradeoff

Pinned Bazel9.2.0 source was read directly, with local copies/hashes retained in
`build/wave-2-dependencies/native-test-disk-remediation/bazel-reference-sha256.json`.

- [`RemoteExecutionService.getWriteCachePolicy`](https://github.com/bazelbuild/bazel/blob/9.2.0/src/main/java/com/google/devtools/build/lib/remote/RemoteExecutionService.java)
  gates remote uploads separately; disk writes depend on `useDiskCache()` and
  `Spawns.mayBeCached(spawn)`. **`--remote_upload_local_results=false` alone does
  not stop disk-cache writes in this version.**
- [`CombinedCacheClientFactory.isDiskCache`](https://github.com/bazelbuild/bazel/blob/9.2.0/src/main/java/com/google/devtools/build/lib/remote/CombinedCacheClientFactory.java)
  requires a nonempty `diskCache` path. The effective native-phase override is
  **`--disk_cache=`**, paired with `--remote_upload_local_results=false` for any
  separately configured remote cache.
- [`RemoteOptions`](https://github.com/bazelbuild/bazel/blob/9.2.0/src/main/java/com/google/devtools/build/lib/remote/options/RemoteOptions.java)
  identifies disk GC as an idle/background task. Its GC-size option is not used
  as a substitute for synchronous precompile reclamation.
- [`DiskCacheClient`](https://github.com/bazelbuild/bazel/blob/9.2.0/src/main/java/com/google/devtools/build/lib/remote/disk/DiskCacheClient.java)
  defines the AC/CAS layout, mtime LRU behavior and external-GC compatibility.

The same native cache override is appended last to **aquery, compile and run-only**
commands. App-build cache settings stay on their original path; the native phase
does not write a second action-cache copy of its new outputs. The output-base
files, debug symbols and retained IPA stay on disk.

Important cost: `RemoteModule.computeActionExecutionSalt` changes its cache-enabled
bit when disk/remote caching is disabled. Bazel may consequently reexecute actions
whose files are already materialized; this implementation does not falsely promise
unchanged incremental cache hits. The full compile/run-only topology and source
validators remain active. If this extra materialization or the37 test bundles do
not fit, the measured failure/fallback below is the next capacity decision.

## Live diagnostics and failure fallback

`native-tests/disk-capacity.json` contains `df -kP`, actual capacity per path,
bounded du-like statistics, completeness flags, quiescence, deletion/kept counts,
limits and the final outcome. `NATIVE_DISK` and `NATIVE_DISK_TREES` lines mirror
the useful measurements to the live console. Tree walks skip links and report
lower bounds when time/entry/depth limits are reached.

`disk-after-compile.json` is measured even on compiler failure. It does not remove
anything or replace the original compile error. A failed initial receipt write
caused by ENOSPC is surfaced live, and the helper retries the receipt after recovery.

The observed cache ZIP was6032618460 bytes (~5.62 GiB); its compressed length is
not treated as reclaimable filesystem space. If the eligible cache is exhausted
and free space is still below20 GiB, the report includes actual `deficitBytesByPath`
and retained-tree sizing. The fallback is to provision/enlarge the reported owned
output/run volume, preferably to the30 GiB reserve plus expected new bundle growth.
No source/output/IPA/results deletion, debug-symbol removal, target skipping or
validator relaxation is used to force a green result.

## Verification and workflow

The native step has a35-minute outer cap; its existing owned2100s envelope,
37-target compile,434-method map, twenty recording scenes and30s native logic/app
limits remain. The claim receipt is uploaded explicitly; disk reports are already
under the uploaded native-tests directory. No cache tree or cache ZIP is added to
the evidence artifact. The new helper is included in the compiled cohort's tooling
fingerprint and native source-identity receipt.

Local validation: **18 tests passed, one POSIX-only dirfd test skipped on Windows**,
in1.562s. Real temporary-file fixtures cover no-delete with adequate space, LRU
selection, unrelated/source/output/IPA preservation, hardlinks, Windows junction
refusal, stale generation before commands, busy-server refusal, scan/delete/time
quotas and a simulated allocation-retention case where unlinking bytes does not
increase free space. The POSIX unlink test is included in the Mac workflow.

No production Host/build source, historical ENOSPC handoff, native provider graph,
CI run, commit/push or Root/config pins were changed by this remediation.
