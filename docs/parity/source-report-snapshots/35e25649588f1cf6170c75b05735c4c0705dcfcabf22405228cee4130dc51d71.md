# Elyx NFD-02 load preflight and platform-selector POSIX CI

**2026-11-16: PASS — [manual Python-only run 43774694321](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43774694321). Actual discovery: 50 cases; execution: 50 passed, 0 failures, 0 errors, 0 skipped, 19.238 seconds.** This is a new immutable NFD-02/platform cohort; previous receipts remain unchanged.

## Immutable source identity

- Branch: `ci/elyx-load-preflight-posix-20261116-c18be733`.
- Commit: `ff0c9fbd1a84930533c9c735b6a0977347160d81`.
- Direct parent: `0ad00c3ef8e856d3a95cd33d43a059c4bc0c648f`.
- Tree: `794c385b3dee9188e0d2e157ab286891038d1463`.
- [Full immutable pin manifest](https://github.com/SanekYo-tech/exteraless-ios/blob/ff0c9fbd1a84930533c9c735b6a0977347160d81/docs/wave-2/elyx-posix-source-pins.json), SHA-256 `c8aba257d549fae7dcf9332e0444cb32a269f3a1c9ece9aa6decceaf5b5f60de`.

Exactly four current-worktree source/test paths were captured. Their raw hashes matched the explicit owner receipts before copying and after private indexing; all four raw and Git-canonical SHA-256 values are identical:

| Fresh path | SHA-256 | Bytes | Git blob |
|---|---|---:|---|
| `python/exteraless_runtime/_archives.py` | `7238088539f31c414307e1f9e8b986940a87d4525ce6b31e5020b09871b555da` | 69918 | `d6a703af7d8631e9aaa50de7edf675f82a921312` |
| `python/exteraless_runtime/_audit_paths.py` | `da7fcc6c4c5ea4cef9fbb7576f26f858eb63276961569a7fe1d8f6aef0b8b40e` | 19990 | `2760ebf7ec57f1a463ea4bc4f21434e4c7c49df2` |
| `tools/compat/tests/test_ios_elyx_source_authority.py` | `d0a4b5a51ad04c9e582c0c74453a8b924d7629b449574e9f5679f674c022ba23` | 20496 | `058a2336652e119b39974e82188a4324fea35f2f` |
| `tools/compat/tests/test_ios_elyx_platform.py` | `27500bfa24b106ae4bc742a3adc2bfa2a39c7a881c0b5d6ef5e26b09df46e96d` | 7628 | `d52606d9fa810cc16568327a9184d6a171359b16` |

Handoff receipt SHA-256:

- `docs/wave-2/elyx-nfd02-inputs.json`: `3d81fa189e30fa98d90c7abc9551b2709e2af8d6a5da8bf2c20b9cea47d342fe` — authoritative for `_archives.py` and the source-authority tests.
- `docs/wave-2/elyx-archive-p2-inputs.json`: `2bc190ed5a1b4854f038fdd86ee938d10584ef2f6271632eedab1aecd2640cc6` — authoritative for `_audit_paths.py` and the platform tests. The newer NFD-02 archive hash is used rather than this older receipt's archive hash.

The only other commit changes are the owned branch-only workflow and pin manifest: six changed paths total. The manifest contains **167 pins**, with **162 parent records unchanged**. The C bridge, SDK, other Python runtime files, virtualjava, dependency lock/vendor tool and all Swift/Host sources were inherited from the parent. No native-provider, Startup/TLS/Root or other main-worktree changes were refreshed.

Inherited C source SHA-256: `2d4ea9f3f7f43da2c8c621c90df153a73a15509218639c24e9a7dee1a50326a2`. The workflow rebuilds that exact C source from scratch; it adds no native descriptor-binding or GIL changes.

## Bounded manual gate

The existing `.github/workflows/compat-tests.yml` path is replaced only on the verification branch with one `workflow_dispatch` Python job. Workflow SHA-256: `eada0a09c1780e633f8e7389c423702672904fa472a29950911ad0040ff4a384`.

- Ubuntu 24.04, Python 3.12; outer job bound 10 minutes.
- Pinned pytest 8.3.5 and setuptools 77.0.3; existing checksum-locked pure dependency bundle. `PYTHONPATH=python/vendor` exposes pinned pure PyYAML 6.0.3.
- Fresh `setup.py build_ext --inplace --force` with a 120-second hard bound.
- Explicit five-module pytest discovery, 30-second hard bound; actual discovered node IDs are retained.
- Pytest execution, 120-second hard bound; existing isolated `-I -S -B` workers retain their 20-second bounds.
- `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1`, UTF-8, no foreign plugin/corpus imports or plugin network execution.

Only these modules are executed:

```text
tools/compat/tests/test_ios_elyx_archives.py
tools/compat/tests/test_ios_elyx_p1.py
tools/compat/tests/test_ios_elyx_source_authority.py
tools/compat/tests/test_ios_runtime.py
tools/compat/tests/test_ios_elyx_platform.py
```

The gate compares actual JUnit node IDs against actual pytest discovery, requires all five modules, zero failures/errors/skips, and the named POSIX and new policy witnesses. The handoff's approximate total of 50 is informational, not a hardcoded acceptance condition. A discovery difference is retained and must be explained.

## Actual results and artifacts

- Run: [43774694321](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43774694321), event **`workflow_dispatch`**, head SHA **`ff0c9fbd1a84930533c9c735b6a0977347160d81`**, actual conclusion **`success`**.
- Exactly one Python job: [132998223007](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43774694321/job/132998223007), **success**. No Swift job was created.
- Created `2026-11-15T23:25:10Z`; completed `2026-11-15T23:26:04Z`. Job elapsed 50 seconds.
- Runtime: **CPython 3.12.16**, GCC 13.3.0, Ubuntu 24.04 Linux x86_64.
- Actual pytest discovery and JUnit agree on exactly **50 distinct node IDs** across the five requested modules. Discovery matches the handoff approximation; there is no count discrepancy to explain.
- **50 passed, 0 failures, 0 errors, 0 skipped**, **19.238 seconds**. Root error cases: **none**; recorded `failure_details` is `[]`.
- **167/167 source pins verified** in the runner and the downloaded manifest matches this commit's pin receipt.

| Executed module | Discovered / passed | Failed | Errors | Skipped |
|---|---:|---:|---:|---:|
| `test_ios_elyx_archives.py` | 13 | 0 | 0 | 0 |
| `test_ios_elyx_p1.py` | 9 | 0 | 0 | 0 |
| `test_ios_elyx_source_authority.py` | 10 | 0 | 0 | 0 |
| `test_ios_runtime.py` | 13 | 0 | 0 | 0 |
| `test_ios_elyx_platform.py` | 5 | 0 | 0 | 0 |
| **Total** | **50** | **0** | **0** | **0** |

This includes all three new policy cases (`load_policy_requires`, `load_policy_python`, `load_policy_dependencies`), all five platform cases, the two positive source-authority POSIX cases (`namespace_replace`, `verified_sdk`), and all five P1 POSIX scenarios (`fd_extract_swap`, `fd_cleanup_swap`, `fd_replacements`, `raw_os_paths`, `two_owners`). No expected case was dropped or skipped.

The inherited C source was rebuilt successfully from scratch (five-second step), producing `_exteraless_bridge.cpython-312-x86_64-linux-gnu.so` with SHA-256 `d4c3ddfa5d1b9db4162de5a002ce31a3d539cdf4dfa9f9e9d30b9f99034880f9`. The pinned pure bundle SHA-256 is `d7fe1f9be22ef7bf3bff75b5d462ebe756039c86226c56948007bed06aef8990`; PyYAML resolved from `python/vendor/yaml/__init__.py` with the checked 6.0.3 pure-Python implementation.

Artifact **`elyx-load-preflight-python-43774694321`** uploaded and downloaded successfully: **18 evidence files**, 14-day retention. These contain raw JUnit, native Python console output, actual discovery, counts and empty failure details, C-build logs, dependency report, source-pin manifest and checksums.

| Downloaded evidence | SHA-256 |
|---|---|
| `archive.xml` | `2130f96d2178051d984426ff055d3478690da7d42887b466441772078cbb653c` |
| `pytest.log` | `ccad33746d96fb93891ef32d463e69803682f986aeaaf1e7d7027a5ecc7d1e38` |
| `collection.log` | `34d4a381430e5f73372b7d4d3c6804f3c3e0d476c8a1c67b483138c74545edf7` |
| `collected-nodeids.json` | `14ff52a797211e7ae67fa7c51ebb84a4fc8b674fe887ca2be954b7ff54388e24` |
| `counts.json` | `edb096a085482db9f4a4cc18742e7ad52b9f3ed6d67a8a3f6bca3338c8c53f14` |
| `c-build.log` | `b17fef5bc3a2c71f59a512c1c34064ca4d616952f937f4ebdad01bfa6dd9e05c` |
| `sources.sha256` | `c8e3fdfa51d766d934d83d58d3e5603b1c0cde08625406d6ab0807f4a84c2262` |
| `source-check.log` | `e930d5bc23d4cc78d18f88907e654d3d57e81d012834fa5269c121b7bfb69c9e` |
| `cohort-sha.txt` | `376461dc5aba2af88e4c209f24cbac5b0f30ebe90afc53926a7030314f521dc8` |
| `elyx-posix-source-pins.json` | `c8aba257d549fae7dcf9332e0444cb32a269f3a1c9ece9aa6decceaf5b5f60de` |

## Scope and preserved evidence

NFD-02 changes a load preflight shared by opaque-FD inspection and `ArchiveAdapter._load_record`, so the complete small archive/P1/authority/runtime cohort is deliberately re-executed alongside the new platform module. The source-authority tests use an explicit **FD-backed contract recorder**; they are not production native registry or C/provider integration acceptance.

The positive `namespace_replace` / `verified_sdk`, five P1 OS scenarios and platform `posix_fd` case target real Linux POSIX operations. Darwin/iOS selector cases use explicitly counted stand-ins on Linux; they do **not** demonstrate native Darwin/iOS `F_GETPATH`, root-alias or kqueue behavior. Apple execution remains a separate gate.

No Swift tests run in this workflow. The prior 53-case Host PASS and original 42-case Python PASS keep their separate immutable receipts. Native FD-provider NFD-01/NFD-03 startup/registry closure, actual C/CPython provider linkage, private Root startup, Apple/UIKit and the app build are outside this gate. The unrelated running app workflow was not queried or cancelled.

All previous local receipts were retained byte-for-byte at capture:

| Receipt | SHA-256 |
|---|---|
| `elyx-posix-ci.md` | `181f3fd0e0c0a79e0f9b17778fdd690b60a4fa08a391e55a9bd1da3bc168620f` |
| `elyx-posix-host-followup.md` | `293f7eba6ee63aea1a21b924faef8cb977ecf24a9760ed3b7b0d24f9217be75f` |
| `elyx-posix-host-final.md` | `76952ff195824704f41abdc8d8ecf5b59f25e477380c49d91876ac90bf70e4dd` |
| `elyx-fd-provider-posix-ci.md` | `76b50d643df276c62565bbdbb61fd488a8052a00a27d9b5837ff35039d1d294c` |

## Caller-state custody

A private temporary `GIT_INDEX_FILE` was populated from the immutable parent, with only the four authorized files plus workflow/pins inserted. Every resulting blob was checked against the tree before `commit-tree -p 0ad00c3e...` and a new CI-branch `update-ref`. No checkout, main-index staging, source edits, main commit or main push was performed by this agent. Caller HEAD/index are read-only observations and are not asserted immutable against the coordinator's independent work.

Preparation, prepublication and post-CI observations recorded HEAD `31287b9204aef5384b85d75f97f233dccf230409` and index SHA-256 `379e420b82d3c9265444917da651a58a79eec10ea54e73ce66ec79d2dfe82dff`. This new receipt is the only authored caller-worktree file for the task. Only the new verification branch was pushed and manually dispatched.

Frozen inputs, sanitized push/watch logs, actual GitHub metadata and downloaded artifacts are retained under `C:\Users\sasha\AppData\Local\Temp\opencode\elyx-load-preflight-posix-20261116-c18be733`. Local actionlint 1.7.12, helper/embedded Python syntax, four frozen Python AST checks, exact six-path delta and `git diff --check` passed. One run-scoped foreground watcher operates inside a background shell, with a 15-minute watch bound and at most three discovery/API attempts.
