# Native cache completeness + NEO-01 — b06bb000 followup

**Implemented:** complete-AC admission before HTTP200, native
`--remote_download_outputs=all`, and removal of the run-only startup environment
override. **Verification completed:** authorized Linux run **43846695323** passed
all eight real Bazel cases and25 protocol/POSIX/NEO-01 tests. The job took33s.
Runtime, driver and test postimages match the preceding frozen handoff. Native
37/434 and UIKit20 acceptance remain coordinator-run gates.

## Actual native evidence

Source run: `43834798503 / b06bb000`;
`build/artifacts/client-ui-43834798503/native-tests/`.

- Capacity recovery passed: free **21475733504 bytes**,1170 files /
  **8197566875 logical bytes** reclaimed in12.740s; kept cache3893257022 bytes.
- The first build summary reports **7386 action-cache hits /540 remote-cache
  hits**, elapsed219.593s (`compile/console.log:613–615`). Cache-enabled reuse
  therefore occurred.
- Lost inputs include generated PNGs (`:224`), `.a` libraries (`:245`),
  `PresentationStrings.h` (`:249`) and later `.swiftmodule`/`.o` inputs.
- Five `Found transient remote cache error, retrying the build...` messages
  appear. The adapter reports40818 HTTP200 responses,562 misses and125 rejected
  connections; actual503 warnings also exist. Its final workers/connections/root
  descriptor are closed. These counters are not successful native methods.

Evidence SHA-256:

| File | SHA-256 |
| --- | --- |
| `readonly-cache.json` | `45d4d73ae3083e7b0e9a0577e112b0ae5c025f7b028a4bf3fc3ba21b7aea153b` |
| `disk-capacity.json` | `cbee31c5dcf0716704b24ec7f3dba2af4b4d82dd4b5e151626823c25c137d7cf` |
| `compile/console.log` | `b18b2238738c364bcf5669fcf106b4d30ee7afefc1dda67409f3d27c7d9f6ac4` |
| `result.json` | `7d7809a298363436128201b6bc95447c568399351e8ece9a45036af323fdd253` |

The old HTTP adapter served existing AC bytes without checking their referenced
CAS. In contrast, pinned Bazel9.2 `DiskCacheClient.checkActionResult`, lines200–247,
checks output files, Tree files and stdout/stderr, and converts missing references
to a miss. HTTP's default `remote_download_outputs=toplevel` permits intermediate
outputs to remain remote-only. Together these mechanisms explain why an orphan
hit can fail later at its consumer. The artifact does not identify which specific
GC/restore event removed every listed missing digest.

## Applied completeness contract

`native_test_cache.py` now identifies mode
`claimed-bazel-ac-cas-complete-readonly-http-v2`.

Before **GET or HEAD /ac** returns200, it reads the bounded binary protobuf
ActionResult and validates:

- every `OutputFile` digest's regular single-link CAS leaf and exact size;
- each `OutputDirectory.tree_digest`, the bounded Tree bytes and their SHA-256,
  all root/child FileNode references, and DirectoryNode links to embedded
  `Tree.children` by serialized-directory digest;
- optional `root_directory_digest` equality to the Tree root;
- referenced stdout and stderr; inline bytes cannot hide missing CAS and must
  match a supplied digest;
- the three REAPI output-symlink variants and Directory symlinks as metadata.
  Their target strings are never followed to select a local file.

Embedded Directory children need not exist as separate CAS blobs. The canonical
empty SHA-256/zero-size blob is implicit, as in Bazel. Root-directory-only output
encoding, unknown fields/types, duplicate singular fields, truncated/invalid wire
data, invalid digests and missing closure members are cache misses.

**Incomplete/malformed/budget-exceeded AC returns404, not a fatal server error.**
Normal CAS payload hashes remain the responsibility of Bazel's enabled
`--remote_verify_downloads`; the adapter checks their existence and size. It
hashes only bounded Tree/Directory metadata and supplied inline content. An AC
filename is the **Action digest**, not a content hash of the ActionResult.

The schema is the actual Bazel9.2 vendored REAPI v2 file:

`third_party/remoteapis/build/bazel/remote/execution/v2/remote_execution.proto`

SHA-256: `9d2723bc91bd7fe154b52118cdc1818daa547c303d01cc346d7bf8fb6caa9cbc`.
The retrieved copy/URL are under
`build/wave-2-dependencies/native-cache-completeness-b06bb000/bazel-9.2-reference/`.

Bounds per AC check:16 MiB ActionResult,16 MiB per Tree,32 MiB total metadata,
262144 wire fields,65536 unique digest references,8192 directories,128 directory
levels and5s, inside the existing30s HTTP request deadline. Reads use the existing
held-root/no-follow leaf opener and256 KiB chunks. Receipts add completeness
limits, `acChecked`, `acReferencesChecked`, `acMisses` and bounded `acMissReasons`.

`cache_flags()` now applies `--remote_download_outputs=all` identically to aquery,
build and run-only via the existing `native_args()`. This materializes reused
intermediates before consumer execution. The nonempty loopback remote cache,
empty remote instance/executor, disabled uploads and enabled download verification
retain the previously verified cache-enabled salt/key mapping.

## NEO-01 joined

`run_native_integration_tests.py` removes only
`test_environment=['STARTUP_TIMEOUT_SEC=150']` from run-only construction.
The actual Make implementation ignores this argument for build-only; the pinned
Apple rule embeds `ctx.configuration.test_env` in its generated executable.

The regression executes the real `get_test_arguments` fixture for all three
phases, extracts the pinned `_get_template_substitutions` function, expands the
same template and verifies equal wrapper text. It also verifies that the former
run-only override produces a different wrapper. `--check_up_to_date` remains active.

Pinned rules_apple revision: `485016eb5b0948cc17307064e7977a6d68e94046`.
Canonical-LF source hashes:

- `ios_test_runner.template.sh`:
  `770b0ce52417f0a120bdcfa1dc91b0e9b9bb933c2618ae77ec878b75410429c7`;
  actual `${STARTUP_TIMEOUT_SEC:-150}` default.
- `apple_test_rule_support.bzl`:
  `1e2ffeb0b6b5e9e7eb978d148c753a69f14ccd4d6d7d13e52b582ed412ea2c58`.

Coordinator check name:
`tools.runtime.tests.test_native_test_cache.NativeCacheCommandTests.test_native_test_environment_keeps_the_pinned_generated_wrapper_stable`.
It is discovered by the already listed `tools.runtime.tests.test_native_test_cache`.
There is no new runtime module/input-list entry: existing cache and driver hashes
already participate in the compiled source identity.

## Real Linux/Bazel verification and preserved diagnostic failures

All three jobs used only the isolated `compat-tests.yml` on verification branches,
with a5-minute job cap; the third run received separate coordinator authorization.
Private `GIT_INDEX_FILE`/commit-tree construction retained
main HEAD/index. Main workflow files and Make were not edited. The real Linux
Bazel9.2 binary SHA-256 was
`7668a95db1250f12c40407251e4e203b4ec8bf39bc495d2f485b2d8c99048694`.

1. [43842436032](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43842436032),
   verification commit `e2f90e3bef304f1996e10f5100d2fedc6760bc65`:
   **24 Linux tests passed**. Real disk seed, kept-output disk→HTTP reuse and warm
   HTTP hits passed. The corrupt-CAS case was rejected with a digest-mismatch
   warning and real producer recomputation, but the probe incorrectly required
   a nonzero build exit and stopped. That failed receipt is preserved.
2. [43843567823](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43843567823),
   verification commit `f14196a3eca9b00e0b97526ef1e765cca8e46380`:
   **25 Linux tests passed**, including POSIX and NEO-01. Cases01–05 passed their
   checks: disk seed, salt-stable kept output, real complete HTTP hits, historical
   toplevel remote-only producer, and corrupt-CAS rejection/recomputation with
   correct output bytes. Case06 reproduced the historical orphan failure:
   **AC200 + CAS404 → consumer exit1, `Unexpected lost inputs ... produced.txt`**.
   The probe expected Apple's other error wording and stopped. Its predicate is
   now corrected and checked against this actual downloaded log.
3. [43846695323](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43846695323),
   verification commit `219080d9bda82acb1e4c63bcdf23c989ee059d27`, branch
   `verify/native-cache-completeness-b06bb000-final`: **PASS**. All eight cases
   completed in order;25 Linux tests passed in2.468s. The job took33s and the
   eight Bazel processes totaled19.761s. The held runtime/driver/test/probe sources
   were byte-identical to the preceding delivery.

Current `bazel_cache_completeness_probe.py` retains every materialized output;
it mutates/removes only the known toy CAS leaf between server lifetimes and
changes only the toy consumer seed to invalidate that consumer. No live native
output is copied into the cache or repaired by the wrapper.

### Final eight-case receipt

| Case | Actual exit | New genrule execution events | Bazel process seconds |
| --- | ---: | --- | ---: |
|01 disk seed |0| producer, consumer |4.239|
|02 kept-output disk→HTTP reuse |0| none |2.083|
|03 complete HTTP cache hit |0| none |2.182|
|04 historical toplevel warm cache |0| none |2.231|
|05 corrupt CAS rejected, correct local fallback |0| producer |2.285|
|06 historical orphan failure (required negative control) |**1**| none |2.183|
|07 complete AC404 miss and local fallback |**0**| **producer, consumer** |2.279|
|08 materialized producer reused after GC |**0**| **consumer only** |2.279|

Case06 remains a mandatory cohort condition. Its nonzero return and the actual
lost-input diagnostic are checked; the successful overall job does not discard
this negative control. Case05 includes the expected digest-mismatch warning,
actual producer reexecution and a verified correct output hash.

Case07's HTTP receipt records **three `missing-cas` AC misses, zero hits and zero
response-body bytes**. GET and HEAD returned404; real Bazel executed both
genrules and produced the expected consumer bytes. The deleted CAS stayed absent
and the retained AC hash stayed identical, proving disabled cache writes.
Case08's log reports one action-cache hit and one local execution; its trace adds
only `consumer`. The probe asserts the kept producer's inode/mtime are identical.
All seven HTTP server lifetimes finished with zero connections/workers, a closed
root descriptor and no service error.

Final extracted artifact:
`build/artifacts/native-cache-proof-43846695323/`.
The independently checked, frozen entry is
`build/wave-2-dependencies/native-cache-completeness-b06bb000/continuation-3/verification-entry.json`
(SHA-256 `2fedd6fee7daff0dbf9b9b16907bdc0703e1a22c2218b36ee630c935f938f31f`).
It pins every case log, actual return/event map, source hashes and cleanup receipt.
The two earlier failed jobs, receipts and the preceding ZIP remain immutable;
the new success is a separate entry.

Local final gates: **50 passed,2 POSIX-only skips;52 tests in10.220s** (process
10.749s). The POSIX read path additionally passed in Linux; pressure-GC unlink
retains its existing Mac test.
Command: `python -X utf8 -B -m unittest tools.runtime.tests.test_native_test_cache tools.runtime.tests.test_native_test_disk tools.ci.tests.test_native_test_workflow tools.ci.tests.test_native_input_identity -v`.
Logs, commands, source checks, immutable prior artifacts and dispatch receipts
are under `build/wave-2-dependencies/native-cache-completeness-b06bb000/`;
the final manifests and delivery are in its `continuation-3/` directory.

The20 GiB floor,8 GiB cap, pressure-GC60s bound,37/434/20 inventory and30s native
logic cap are retained. Runtime33, Apple compilation/recording and other owners'
fixtures were not rerun or modified by this followup.

## Postimages

| Delivery path | SHA-256 |
| --- | --- |
| `tools/runtime/native_test_cache.py` | `cd23da6d68764cdd7bac6c85e76a0f8a10743a5535514a894291be1cb3cffc20` |
| `tools/runtime/tests/test_native_test_cache.py` | `c42be10467a02a2557faab21cd0a992712822e7593acb5867cdfdce84b5997c0` |
| `tools/runtime/tests/bazel_cache_completeness_probe.py` | `fecd0c63eda5db95cc0b6dc23c1d1f7848f116e9ff8e639e4006020053f4c0c1` |
| `tools/runtime/run_native_integration_tests.py` | `e6e0ae9e4d92400f82c7500774ede02b4965dcd64bffeb3c4385aa0464416c56` |

The delivery manifest also pins this document. Previous pressure/read-only-cache
handoffs and completed-run receipts remain unchanged.
