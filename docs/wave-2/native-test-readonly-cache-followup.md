# Native read-only cache — execution-salt fix after 43827361709 / f1c

**Implemented:** a phase-owned HTTP read-only view of the existing claimed Bazel
AC/CAS. A nonempty loopback `--remote_cache` retains the app build's cache-enabled
execution salt while `--disk_cache=` and `--remote_upload_local_results=false`
suppress new cache copies. The same endpoint and options cover native aquery,
the full compile and every run-only invocation.

## Observed failure being corrected

`build/artifacts/client-ui-43827361709/native-tests/` establishes:

| Measurement | Actual value |
| --- | ---: |
| Pressure recovery time | 25.038s |
| Deleted eligible files / logical bytes | 7120 / 10008895479 |
| Retained eligible cache | 8589767745 bytes |
| Free after recovery | 22386737152 bytes |
| Free after compile timeout | 21632634880 bytes |
| Actual compiler budget after preparation | 785.0162014169999s |
| Last reported action progress | 2926 / 8887 |

Capacity passed and the compiler log contains repeated absl/protobuf tool
compilation. The native result is `build/analysis deadline exceeded`, with no
native execution. The old effective empty disk cache and empty remote cache
changed Bazel's cache-enabled salt bit. This followup corrects that mode change.

Completed-run evidence SHA-256:

- `compile/console.log`: `d195b3e733cc2f0464d2bbc7af6afafba4d5544becadc8eaac1d026d6e169c21`
- `compile/command.json`: `4807af5f69f22bb92aa973aa9cddd43fdd2abe1ebe3749df31097ffde4b932ac`
- `disk-capacity.json`: `67ae0050a2469cb398aad30fcc91e63c6b89ffe19a4e0fd0ada8d4b5e2ec7669`
- `disk-after-compile.json`: `cacc8665bc020a0883aadc514be8f2529c18ce1fc32372961d579481951bcb3d`

## Bazel 9.2.0 source proof

Exact downloaded/copied source files, their hashes, extracted methods and the
before/after salt inputs are retained under
`build/wave-2-dependencies/native-test-readonly-cache-f1c/` in
`bazel-reference-sha256.json`, `bazel-additional-reference-sha256.json` and
`bazel-source-proof.json`.

1. [`RemoteModule.computeActionExecutionSalt`, lines1203–1223](https://github.com/bazelbuild/bazel/blob/9.2.0/src/main/java/com/google/devtools/build/lib/remote/RemoteModule.java#L1203-L1223)
   fingerprints only `isRemoteCacheEnabled()` and the default execution-property
   map. The URL, port, instance name and upload switch are absent. The existing
   execution-property settings are inherited by the new command construction.
2. [`RemoteOptions.isRemoteCacheEnabled`, lines800–809](https://github.com/bazelbuild/bazel/blob/9.2.0/src/main/java/com/google/devtools/build/lib/remote/options/RemoteOptions.java#L800-L809)
   returns true for a nonempty disk cache **or** nonempty remote cache. Both the
   app disk mode and the new HTTP mode therefore supply the same salt input.
3. [`DiskCacheClient`](https://github.com/bazelbuild/bazel/blob/9.2.0/src/main/java/com/google/devtools/build/lib/remote/disk/DiskCacheClient.java)
   stores `ActionResult` bytes using `actionKey.digest()` in AC (lines255–260);
   `toPath` uses the digest hash verbatim beneath its two-hex shard (lines304–312).
   SHA-256 is an old-style digest rooted directly at `ac`/`cas` (constructor and
   `DigestUtil.isOldStyleDigestFunction`).
4. [`HttpCacheClient`](https://github.com/bazelbuild/bazel/blob/9.2.0/src/main/java/com/google/devtools/build/lib/remote/http/HttpCacheClient.java)
   downloads AC through the same `ActionKey` (lines621–630) and CAS using its
   content digest. `AbstractHttpHandler.constructPath`, lines95–103, appends
   `ac/` or `cas/` followed by the same hash. There is **no HTTP key rehash**.
   AC filenames are hashes of the Action, not hashes of the ActionResult bytes.
5. `RemoteExecutionService.buildSalt`, lines370–385, derives the per-spawn salt
   from the existing execution requirements/workspace/scrubber, independently
   of the endpoint. Both disk-only and HTTP cache capabilities leave the command
   output-path version fallback identical.
6. `HttpDownloadHandler` requires HTTP/1.1 and Content-Length or chunking. The
   adapter returns HTTP/1.1 with the exact Content-Length. `HttpCacheClient`
   converts404 to `CacheNotFoundException`; `RemoteSpawnCache`, lines182–200,
   handles missing AC or a missing referenced CAS blob by continuing to local
   execution. This covers dangling AC entries left by pressure GC.
7. `Utils.shouldUploadLocalResultsToRemoteCache`, lines544–548, honors the upload
   switch. `CombinedCacheClientFactory.isDiskCache` requires a nonempty disk
   path. The native command therefore has neither a writable disk backend nor
   permitted remote uploads. HTTP mutation methods also return405.

The complete native options added after the existing app-derived arguments are:

```text
--disk_cache=
--remote_upload_local_results=false
--remote_cache=http://127.0.0.1:<owned ephemeral port>
--remote_executor=
--remote_instance_name=
--remote_accept_cached=true
--remote_verify_downloads=true
--remote_max_connections=8
--remote_timeout=30s
--remote_retries=0
```

`native_args()` applies these identically to all three command types. Existing
download-output settings, debug metadata, execution properties, build resources
and action requirements are inherited. Spawns marked non-remotely-cacheable keep
their Bazel policy; this adapter does not override those markings. Materialized
outputs can retain their local action-cache validity through the equal salt.

**Evidence level:** salt/key equivalence is verified against pinned Bazel source;
HTTP behavior is executed locally. Reuse and compile completion with this mode
still require the coordinator's next Apple native gate.

## Ownership, bounds and lifecycle

`tools/runtime/native_test_cache.py` provides only the context used by the native
runner. It binds IPv4 `127.0.0.1` on port0 and retains the allocated listener.
It serves only `/ac/<64 lowercase hex>` and `/cas/<64 lowercase hex>` from:

`/Users/runner/Library/Caches/exteraless-bazel-disk`

The existing `--cache`/environment equality, cache marker, repository, source
generation and root device/inode must verify before binding. Production holds a
root directory FD, opens each parent relative to it with `O_NOFOLLOW|O_DIRECTORY`,
and opens a regular single-link leaf with `O_NOFOLLOW`. Leaf device/inode/size/mtime
are checked around opening/streaming; ownership/generation are checked per read
and at phase completion. CAS content-digest verification remains enabled in
Bazel. Path traversal, encoded/extended routes, symlinks, hardlinks and foreign
Host headers cannot select outside files.

- At most8 request workers and200000 admitted requests per phase.
- Headers at most8192 bytes /32 fields; request line at most1024 bytes.
- GET bodies stream from the held descriptor in at most256 KiB chunks.
-30s total request deadline;5s bounded listener/worker cleanup.
- GET/HEAD only; mutations405, malformed requests400/431, denied paths403,
  missing entries404, exhausted request quota429, concurrent saturation503.
- The listener starts before aquery with reads paused. After preflight and the
  existing quiescent pressure-GC/capacity gate, reads are enabled. Cleanup occurs
  after the final class/simulator finalizer, and on compiler/validator exceptions
  or the runner's handled interruption. The context closes sockets, workers and
  cache descriptors; no separately surviving daemon is started.

The pressure policy,20 GiB floor,30 GiB optional goal,8 GiB cap,60s recovery budget
and deletion quotas remain intact. Native compile/execution envelopes remain
900s/900s inside the existing outer envelope; native logic retains30s. The
37-target/434-method inventory and20 UIKit scenes are unchanged.

## Receipts and tests

`native-tests/readonly-cache.json` and `NATIVE_READONLY_CACHE` record the mode,
ephemeral loopback endpoint, exact flags, resource limits, HTTP response/byte
counters and final connection/worker/root-FD cleanup state. `hits` counts HTTP200
responses. No request headers, credentials or cache bodies are logged.
`disk-capacity.json` also records the effective flags and `readOnlyCache` mode.
These paths are covered by the existing native-tests artifact upload.

The new helper is included in both the native tool hashes and the compiled
cohort's harness fingerprint. The workflow adds its regression module to the
existing bounded checks.

Local command (25s subprocess bound;30s tool bound):

```text
python -X utf8 -B -m unittest tools.runtime.tests.test_native_test_cache tools.runtime.tests.test_native_test_disk tools.ci.tests.test_native_test_workflow tools.ci.tests.test_native_input_identity -v
```

**41 passed;2 POSIX-only skips on Windows;43 total in6.342s**. Full output and
the6.862s process receipt are `gated-tests-final.log` / `gated-tests-final.json`.
Tests exercise actual loopback HTTP, exact binary AC/CAS GET/HEAD, multi-chunk
reads, misses/dangling CAS, mutation and traversal rejection, junction/hardlink
and changed-leaf refusal, stale generations, quotas/concurrency/header deadlines,
cleanup during a stalled request and successful rebinding after an exception.
Fixture source/output/IPA/user files retain their hashes and mtimes.

Windows HTTP tests inject a test-only file opener with lstat/fstat/reparse guards;
production requires POSIX dirfd/no-follow APIs. The Mac gate uses the unmodified
production reader and also executes the explicit POSIX read/unlink tests.
Existing pressure regressions, method watchdogs, source identity and both hosts'
resource validators pass. AST/graph checks preserve18 pressure/safety definitions
and confirm37 targets /434 methods /20 scenes plus the new helper fingerprint.

## Frozen implementation postimages

| Path | SHA-256 |
| --- | --- |
| `tools/runtime/native_test_cache.py` | `b9fe9ae16e56d1cfdea1467296ff7eb117857f229def509b5044995a353732b1` |
| `tools/runtime/native_test_disk.py` | `92833f5fd8778d470ca696e11825edb5f8eaa5a3c7ebff943ba5133f9b16b633` |
| `tools/runtime/run_native_integration_tests.py` | `a9febf776ff1a6236dcccfe6f106100ae4acf8b1212d1539260a01c945c69d0a` |
| `tools/runtime/client_ui_harness_inputs.py` | `10719ab44244001df198d37437ae1597224aadde69308eff9f792a6f01adecbe` |
| `tools/runtime/tests/test_native_test_cache.py` | `c4806f0a2477ff3bae76c4b5dd767c429420938ecce145c46815374bfc16e588` |
| `tools/runtime/tests/test_native_test_disk.py` | `b11200b6a5dee3f2e83d23147fd3ba020150c45865a23d4893115b36bef22dcc` |
| `.github/workflows/client-ui-harness.yml` | `63932340ed73dcf47d8ea94546a4da0bf49eaac1b60dfa4196f3ef1b6d9e3f9e` |

Delivery manifests also pin this document. The completed-run evidence and earlier
pressure-GC/remediation documents remain immutable. Coordinator retains ownership
of dispatch and native acceptance; this session performed no CI operations,
commit/push or Apple/Rust build.
