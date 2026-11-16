# Independent native SDK five-child execution — 3daf8d97

**Actual run: FAILED in child4, archive metadata bootstrap.** Three SDK children
completed and passed the parent's checks; the archive child exited1; the Elyx
developer child was not started. **There is no five-child acceptance.**

The cause is a native test-fixture configuration omission: `python/vendor` is
absent from its metadata interpreter's compatibility paths. The locked PyYAML
bundle was successfully staged. A two-fixture, tool-only correction is proposed
below, without changing shared production sources.

## Execution identity

One manual verification run was dispatched:
[`43794176737`](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43794176737).
The sole job ran on2026-11-16 from **02:46:33Z to02:49:13Z** (160s), including
successful full evidence upload. One dispatch, one own-run watch, no rerun.

| Field | Value |
|---|---|
| Exact published source | `3daf8d97bb35b02120cbeae95e94ee8c9362bdb9` |
| Verification commit | `d08dcc6d84bec1e796b3d315e90441cb6b271598` |
| Isolated verification branch | `verify/native-sdk-five-3daf8d97-3a69dbfd` |
| Workflow | Existing `.github/workflows/python-framework.yml` dispatch path |
| Verification workflow SHA-256 | `fc20baa9d17f95f195e0a44ab3bee4228353b87d22ffbe65c59952ff6192b357` |
| Runner / Xcode | `macos-26` / `/Applications/Xcode_26.6.app/Contents/Developer` |
| Job / child limits | 20 minutes / 30 seconds for each of five SDK children |
| Actual C source SHA-256 | `2d4ea9f3f7f43da2c8c621c90df153a73a15509218639c24e9a7dee1a50326a2` |
| Fresh C object SHA-256 | `4a847f9dd083bb4d27c1f94e44b37d27775873e0ecf91359f135aeae7fb19d43` |
| Fresh native executable SHA-256 | `1553577afe1f2eb2c28d0ef546c67ab6d210be9ffc862c616be782a210b5644f` |
| Uploaded full artifact | `native-sdk-five-3daf8d97-43794176737` |

The verification commit has exactly one changed path: the workflow. Its parent
is the source revision above, and checkout in CI explicitly selects that source
revision. The verification ref inherits the existing repository's public
visibility; it is an isolated, unmerged execution branch.

The branch was constructed with a TEMP `GIT_INDEX_FILE`, `read-tree`,
`hash-object`, `write-tree` and `commit-tree`. Main HEAD and index were identical
immediately before and after its construction: HEAD
`53cab85a9de5d9845f3c4b4d33718b808c602d74`, index SHA-256
`f39f14de663a3e9854f646998262721c6bf1cbe85d1fae4c95e4273c65d64eb9`.
The separate source-owner advance to that HEAD is not part of this gate's inputs.

## Actual execution and completion markers

Host: **macOS26.7.2 arm64**, **Xcode26.6 /17F113**, Apple Swift6.3.3,
macOS26.5 SDK; linked **CPython3.12.10**. Both actual Swift/C builds succeeded.
The embedding prerequisite completed its two OWN_GIL worker checks, UTF-8/NUL
results, exception recovery, bootstrap-failure cleanup and process finalization.

| SDK child | Observed result | Native duration | Exact marker present |
|---|---|---:|---|
| Initial SDK / baseline | Completed; parent's semantic reader passed | bounded30s; final elapsed field not written | `EXTERALESS_SWIFT_PLUGIN_PROBE_OK` |
| TL | Passed | 2.869s | `EXTERALESS_SWIFT_SDK_TL_PROBE_OK` |
| HNS | Passed | 1.249s | `EXTERALESS_SWIFT_SDK_HNS_PROBE_OK` |
| Archive | **Failed**, exit1; `inspect-install-enable` | bounded30s; immediate import failure, not timeout | absent |
| Elyx developer | **Not started** | — | absent |

The parent reuses `swift-plugin-smoke.json` as its aggregate progress report. It
sets `ok=false, phase=archive-lifecycle` before child4. The initial child's
completion marker, all30 other required semantic flags, and the parent's advance
through TL/HNS are retained; the final baseline elapsed field is written only
after child5, so no precise baseline duration is invented here. The aggregate
was preserved as failed. `verify_native_sdk_cohort.py` was skipped after the
failure and `five-child-acceptance.json` was not generated.

### Teardown evidence reached in this run

- Initial SDK: one process initialization/finalization, both real plugin owners
  drained; transport counts167 and31, zero final handles/callback leases/legacy
  services/mock calls. The first owner recorded `darwin_family_fd_paths=true`.
  Native binding uninstall and terminal DTO cleanup passed.
- TL/HNS: their published semantic readers passed, including owner epochs,
  terminal/FIFO release and zero final handles/leases/mock-service state.
- Archive failure: its sole metadata inspector was OWN_GIL and destroyed;
  process initialization/finalization counts were1/1, handles/leases/legacy/mock
  counts were zero, loaded plugins and unexpected effects were empty. The full
  archive lifecycle `cleanup` flag correctly remains false.
- Actual `NativeBridgeBinding` / C buffer-copy/free paths and Swift engine
  `EXLPythonBufferFree` defers executed; the SDK executable uses the existing
  CPython debug allocator build flag. It does not emit per-allocation native
  malloc/free counters. The fifth child's FD/capability/stage/authority teardown
  assertions were **not reached**, so this receipt cannot claim their completion.

## First failure: native fixture omitted the sealed vendor root

Authoritative native error, `swift-sdk-archive-smoke.json`:

```text
phase: inspect-install-enable
runtimeFailure("EXLPythonRunScript: UnsupportedSurfaceError(\"Elyx needs the app's bundled PyYAML/SDK provider\")")
```

The native observer recorded the actual metadata bootstrap and subsequent call:

```python
import sys
sys.path[:0] = ["<checkout>/python", "<checkout>/python/sdk"]
import exteraless_runtime as _exteraless_runtime
_exteraless_runtime.metadata_json("<owned-run>/input/owned.elyx")
```

The causal chain is specific to the fixture's startup configuration:

1. `tools/runtime/fixtures/swift_sdk_archive_probe.swift:56–60` supplies only
   `arguments[5]` and `arguments[5] + "/sdk"` as compatibility directories.
2. `PythonRuntime.swift:100–103` serializes precisely those roots for metadata
   inspection. CPython is isolated with site imports disabled; the parent driver
   also removes `PYTHONPATH` from the child environment.
3. `_archives.py:575–585` calls the preserved `elyx_runtime` package. Its
   `archive.py:26` / `metadata.py:30` require `yaml` during package import, even
   before an owned JSON-metadata archive can be inspected.
4. The `ImportError` is wrapped at `_archives.py:581–582`. A bounded20s,
   import-only local reproduction against the same Git bytes preserved the
   exact cause: **`ModuleNotFoundError: No module named 'yaml'`**. It opened no
   archive and is not an additional native execution result.

PyYAML6.0.3 is present in the successfully hash-verified twelve-package bundle:

| Dependency proof | SHA-256 |
|---|---|
| Published dependency lock | `222da84eea828044f5af0e8d034945662fd74aae6414bc91f67d6311f14ef924` |
| Actual staged bundle | `d7fe1f9be22ef7bf3bff75b5d462ebe756039c86226c56948007bed06aef8990` |

The earlier source-plugin children reach configured
`ProvidedDependencies.restore_path`; the archive metadata inspector fails before
that setup. Production `PythonRuntimeConfiguration.standard(bundle:)` already
includes `python/vendor` at `PythonRuntime.swift:81–86`. This finding therefore
supports a **fixture-path correction**, not a production C/SDK/Host change.

### Proposed minimal tool-only correction — not applied

Add the existing sealed vendor root to both native Elyx fixture configurations:

```diff
--- a/tools/runtime/fixtures/swift_sdk_archive_probe.swift
+++ b/tools/runtime/fixtures/swift_sdk_archive_probe.swift
@@ -57,1 +57,1 @@
-                stdlibDirectories: [arguments[3], arguments[4]], compatibilityDirectories: [arguments[5], arguments[5] + "/sdk"],
+                stdlibDirectories: [arguments[3], arguments[4]], compatibilityDirectories: [arguments[5], arguments[5] + "/sdk", arguments[5] + "/vendor"],
--- a/tools/runtime/fixtures/swift_sdk_elyx_developer_probe.swift
+++ b/tools/runtime/fixtures/swift_sdk_elyx_developer_probe.swift
@@ -177,1 +177,1 @@
-                stdlibDirectories: [arguments[3], arguments[4]], compatibilityDirectories: [arguments[5], arguments[5] + "/sdk"],
+                stdlibDirectories: [arguments[3], arguments[4]], compatibilityDirectories: [arguments[5], arguments[5] + "/sdk", arguments[5] + "/vendor"],
```

The fifth fixture has the same omission in source; it was not executed in this
run. The full-context proposal is retained under the local evidence root as
`proposed-elyx-fixture-vendor-roots.patch`, SHA-256
`02200537f021f51e0ebccbd052b136c27988ee0e17f2624ebe50c6408a1f3c0f`.
Read-only `git apply --check --whitespace=error` passed against the exact captured
3daf tree. It has two substitutions and changes no timeout, assertion, provider,
loader or native bridge. Native execution after this correction still requires
the fixture owner's join and a newly authorized run.

For an exact native reproduction, stage the locked dependencies and run the
published parent commands below from a fresh3daf checkout and empty output.
The full failing executable argv and PID3488 are retained in
`swift-sdk-archive-console-launcher.json`; its enforced deadline is30s.

## Input preflight and execution path

- Read the committed native final-input handoff and Elyx closure from section616.
- Captured **1,433 files** from the requested Git revision with line-ending
  conversion disabled, and byte-compared every captured file with its Git blob.
- The narrower CI checkout retained **1,417 raw Git source copies**. All were
  independently rechecked after download, together with **374/374 build inputs**,
  their artifact mappings, and the fresh C objects/executable. No source drift
  was found. The generated actual Root registration is part of that build seal.
- Verified all **36 SDK modules** against their committed Original hashes and
  against the actual local Original Python bytes, without importing them.
- Checked the sealed descriptor ABI, NFD-02 `_archives.py` postimage, ten Elyx
  inputs, actual21-group Root registration, Core package, four TL codec sources,
  C header/module maps and the published five-child readers.
- The twelve pure dependencies are staged by `vendor_dependencies.py` using its
  existing lock and hash validation. The driver/emitter path requires no pytest.
- The workflow directly runs `check_swift_embedding.py`, then
  `check_swift_plugin_embedding.py --python "$(command -v python)" --python-root
  "$GITHUB_WORKSPACE/python" --output "$RUNNER_TEMP/python-plugin"`, then
  `verify_native_sdk_cohort.py --directory "$RUNNER_TEMP/python-plugin"`.

The five SDK children are initial SDK, TL, HNS, archive lifecycle and Elyx
developer. All retain their published30-second deadlines and semantic readers.
Compilation has separate existing tool budgets. The embedding prerequisite is
reported separately from the five SDK children.

The workflow collected the complete `python-plugin` directory, raw source
copies, build-input/source mappings, executable/C-object hashes, embedding and
driver logs, native JSON reports, and a bounded failure-phase JSON when needed.
It uploaded the full directory, including hidden fixture artifacts. Four native
SDK JSON reports exist; the unstarted fifth report was not fabricated.

Local control/evidence root:
`C:/Users/sasha/AppData/Local/Temp/opencode/native-five-3daf8d97-3a69dbfd/`.
Exactly one own-run `gh run watch --exit-status` was started. This verification
has no Host-test prerequisite and makes no unfiltered Host-suite or UIKit claim.

## Retained artifact and checksums

[Artifact14194061659](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43794176737/artifacts/14194061659)
contains **84,230,063 compressed bytes**, retained through2026-11-23.
GitHub-reported archive digest:
`cee467701814941974d0147c15c699ba2e2c8b824ec7a57ad7f532a85336b6db`.
The unpacked local files were checked individually against their source/report
seals; this is distinct from recomputing the compressed archive digest.

The full build log includes the fresh C compilation and actual Host/Core/TL/
Config fixture Swift link. Native stdout is retained verbatim. The archive
console contains only its launcher command because the actual engine error is
returned in the native JSON report; it was not truncated by the collector.

| Artifact-relative receipt | SHA-256 |
|---|---|
| `build-inputs.json` | `c4610e96d6ed36fe20ba937c0661fa6af7b5c1d018ebff1af1dafaa074a73c50` |
| `swift-plugin-build.log` | `a437932277ed6eae732acdf4a107aba269127cb0150569323b901a2fe68dd54e` |
| `swift-plugin-smoke.json` | `3e6296764de13048417f9f8b7e7a6991d731a3488df4399bf04ca8e6151f91f5` |
| `swift-sdk-tl-smoke.json` | `52cd87d7e9e8721ca32d89d59634365add0ce989668346a03436bfbb9049aea2` |
| `swift-sdk-hns-smoke.json` | `4d383ced1fd911717a4aa68d791cd1983043228b6a98ba35346071a868dc7a36` |
| `swift-sdk-archive-smoke.json` | `7ca94fdfa86d8b93f98aeacb7f6aa1de02ace451ac47bfd0e23d7d1750bde6d5` |
| `verification/failure.json` | `dab8dbba8a14967ef75c14ba36c361de4487a2136dab7cd3b8e6b37546285978` |
| `verification/source-provenance.json` | `941fb5b1a4dcc528c3fb0062d8ec36a8939eabf7f927951b895301f34ac02323` |
| `verification/source-map.json` | `55db23d3fab7cf98a5508680eac64d55830bb7ab1670e5493e84d6a767bf60fb` |
| `verification/engine/swift-engine-smoke.json` | `26ad31236f1d77d602c9e6df3ef55eed2190e4ddd20cb9113d7f96d2aed1af53` |

The local `artifact-review.json` records the downloaded source/binary audit;
`failure-analysis.json` records the cause, partial-child counts, proposal
pre/postimage hashes and all receipt hashes. `metadata-import-repro.json` has
SHA-256 `f3e827233da7c4f3c2a6a43ecf506c6f2029fb8d621c6e019920e0e322ad57d0`.

**Scope:** actual macOS Swift/C/CPython execution with owned local fixtures and
the existing headless service boundaries. No Windows C recorder supplied the
gate result. No external plugin, production account/network operation, full
Apple app/simulator build, signing or device installation was part of this run.
The separate ArchiveDescriptorTests path witness and other owners' FD/Ingress/
Mode/Listener or UIKit runs were neither invoked nor used as this gate's result.

## Coordinator fixture join

The two proposed compatibility-directory substitutions are applied. The actual
production caller uses `PythonRuntimeConfiguration.standard(bundle: .main)`,
whose vendor root was already present. The fixture change preserves metadata
isolation, archive plugin-root exclusion, provider validation and30-second bounds.
A subsequent complete gate must execute archive and developer children before
five-child acceptance can be claimed.
