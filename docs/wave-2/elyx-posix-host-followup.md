# Elyx bounded POSIX Host followup

**2026-11-16: actual Swift-only followup FAILURE at compilation. New blocker: `BridgeServices.swift:1032:119`. Zero Host tests executed.** Original Python evidence remains **42 passed, 0 skipped** in the predecessor run; Python was not rerun.

## Immutable successor

- Branch: `ci/elyx-posix-host-20261116-0ba564e7`.
- Commit: `ec1131cf5af720cb88f13d11881fcaad6d3aa0f6`.
- Direct parent: `ff9134924cdc1c41aeecb2af1f4cf194a1963550`.
- Tree: `feb9ed5d569c4aaa667ccbe53dbafb265e344ded`.
- Original BASE: `4bcf80a0d7160264accbb6b415facde82cf87928`.
- [Original receipt](elyx-posix-ci.md) is preserved: SHA-256 `181f3fd0e0c0a79e0f9b17778fdd690b60a4fa08a391e55a9bd1da3bc168620f`.
- Original Python evidence remains [run 43768124344](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43768124344), **42 passed, 0 skipped, 20.270 seconds**. Its JUnit SHA-256 remains `3cca73f59a6d0db4c0ac3da2e3f102e8b7806a57291cf5da4000d74628e36a86`. Python tests and the C build are not repeated by this one-job successor.

## Exact delta from the parent

Only these three paths differ:

| Path | Parent SHA-256 | Successor SHA-256 |
|---|---|---|
| `swift/PluginHost/Sources/PluginHost/PluginCallbackDispatcher.swift` | `907f1c8f5efe3b167040c73d10c619b8bbe48cd7dd8fc5477b2cc1b4f441f76a` | `8fafbadf870bd85729d51629aceba85589763dbc08263b9940c06bd3c65c2c74` |
| `.github/workflows/compat-tests.yml` | `3c5c3dfaf4ec66ec92c0acf0f8151b7d67fb090f0f8af77fae7e385415700add` | `1070311494e3920aed61972e3fa07984a94b249f9aa79260b8ecf1d31251e40a` |
| `docs/wave-2/elyx-posix-source-pins.json` | `e906b30c7f56528ba4ac034284bbf927e54824dc07d49096b61bafe59fc00ff3` | `76f691280ce75e4d5270b2d804abfa7b7d844d289ac0583582fe4a7f79e19f2a` |

The coordinator's entire authorized source change, at lines 80–81:

```diff
-        host?.permissions.futurePredicate(pluginId, requiring: permissions) ?? { false }
+        guard let host = self.host else { return { false } }
+        return host.permissions.futurePredicate(pluginId, requiring: permissions)
```

The whole copied dispatcher was compared with the parent plus exactly this replacement. Its raw and canonical SHA-256 are identical; size **10,006 bytes**, Git blob `919ec6e5e349ec1f22603573b60584cac33118c3`. The source hash was verified before/after copying, after private indexing and against the committed tree.

The remaining **121 original working-source records** were inherited from the parent. **164 of 166 pin records** are exactly unchanged; only dispatcher and workflow records changed. No other current-main source or unfinished native FD-provider file was captured. [Complete successor pins](https://github.com/SanekYo-tech/exteraless-ios/blob/ec1131cf5af720cb88f13d11881fcaad6d3aa0f6/docs/wave-2/elyx-posix-source-pins.json) include all original inputs and the separate followup capture identity.

These trees are identical in parent and successor:

| Tree | Git tree ID |
|---|---|
| `python` | `7bae9c1b00ffbd8714a6a252c43b4b12dd8cb276` |
| `tools/compat/tests` | `a1b2050f5bd8a26de45233e7f81ba67d162b996a` |
| `tools/runtime` | `35657bc19840ddf375fe811c0417c018892329af` |
| `swift/PluginHost/Tests` | `2506c388019551b39f609075417a7711e55a856c` |
| committed Core712 `swift/ExteralessCore` | `637a8dde7485c78ef5cfdaa2559651c216d8d09e` |

## Bounded execution

The branch-only workflow has exactly one `workflow_dispatch` job: `swift-host-posix`, Ubuntu 24.04, 25-minute outer bound, the existing Swift 6.4.2 cache and pinned actions. Its entire Swift job configuration equals the predecessor's Swift job.

```sh
timeout --signal=KILL 180s swift build --build-tests --jobs 2
timeout --signal=KILL 30s swift test --skip-build --jobs 2 \
  --filter '(PluginArchive|PluginTrust|PluginSettingsPage|PluginResourcePath|PluginSendHook|PluginElyxDeveloper)' \
  --xunit-output "$EVIDENCE/host.xml"
```

The build attempts the complete original Host source and test targets; the execution filter would select 53 ready tests, including seven actual POSIX archive-descriptor witnesses. Source checks cover the same 166 pins. Logs, checksums and the count/error recorder are uploaded with `always()`; JUnit is uploaded if test execution produces it.

## Actual result and artifacts

- [Manual run 43769449668](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43769449668), actual conclusion **`failure`**; event `workflow_dispatch`, commit `ec1131cf5af720cb88f13d11881fcaad6d3aa0f6`.
- Exactly **one Swift job**, [132981868568](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43769449668/job/132981868568). No Python job was created.
- Run created `2026-11-15T22:28:08Z`, completed `2026-11-15T22:29:00Z`; job ran `22:28:11Z`–`22:29:00Z` (49 seconds).
- **166/166 checkout source pins passed**. The artifact manifest and cohort SHA were verified after download.
- Swift **6.4.2**, target `x86_64-unknown-linux-gnu`, same cached frontend as the predecessor: binary SHA-256 `76db9f3dd8487a14ae39374509620e33af02f10da5dc42247406657832e4e9da`.
- Full Host compilation failed after **9 seconds** (`22:28:49Z`–`22:28:58Z`), within the 180-second bound. The compiler command contains the original **43 ready Host Swift source files** and no excluded provider files.
- **Swift tests executed: 0; intended: 53.** The test step was skipped after compilation failed. There is **no Swift JUnit**, so no test-level pass/failure/skip count is fabricated. The always-run count recorder reports `{"error":"Host tests did not produce JUnit"}`.

### Next coordinator blocker

`swift/PluginHost/Sources/PluginHost/BridgeServices.swift:1032:119`:

```text
error: failed to produce diagnostic for expression; please submit a bug report
```

The source expression is in `nativeEffectLease(...)`:

```swift
let permissionCurrent: @Sendable () -> Bool = permissions?.futurePredicate(pluginId, requiring: [permission]) ?? { true }
```

This file was inherited unchanged, SHA-256 `2b9d428135e67213a47e64f780d595f3ca92ebdbb300e6c042e915d581d0957e`. The earlier `PluginCallbackDispatcher.swift:80:77` diagnostic is absent from this successor's compiler log. The new diagnostic is reported without changing this production source, substituting providers, switching compile mode or repeating the run.

### Artifact delta

New artifact **`elyx-posix-swift-43769449668`** uploaded and downloaded successfully (14-day retention, 11 evidence files). It contains compiler logs, platform/toolchain identities, all 166 source checksums, the full pin manifest and the explicit missing-JUnit error recorder. The predecessor's Python artifact remains the sole Python result. No new Python report or release artifact was generated.

| Swift evidence | Predecessor run SHA-256 | Followup run SHA-256 |
|---|---|---|
| `swift-build.log` | `fbf795c1aad4e224447c8c58fad7e823eeabd51cc41cb6db1cf5aef2baf8032e` | `c23035b99833b28efc18b2468c8ddd49e4479ce53e5b045d4180d13bd5967f1c` |
| `counts.json` (missing JUnit) | `e4a666034172532a2a8128774c64014eca0262d68714d9c9a87da86fe0016ece` | `e4a666034172532a2a8128774c64014eca0262d68714d9c9a87da86fe0016ece` |
| `sources.sha256` | `0a33fe739957b403a602f380b1ba135226820be938a1e935d331534af55dd238` | `ea90bf18f6e67c82a7f6d64c1f45764c89683e671fe8dbd3100825ced190e04c` |
| `source-check.log` | `4915fdaad7ca4a311e4de5784f6edadbda6f0e62874490fd5dd5f630ac4b1c17` | `4915fdaad7ca4a311e4de5784f6edadbda6f0e62874490fd5dd5f630ac4b1c17` |
| `swift-version.log` | `7c811e5cb6a9cc03cb630c6ee61c720c37c7b659f4664a7244bd4e7e4b753871` | `7c811e5cb6a9cc03cb630c6ee61c720c37c7b659f4664a7244bd4e7e4b753871` |

Pin-manifest artifact hashes are the parent/successor values in the exact-delta table above. Followup `cohort-sha.txt` SHA-256 is `2e5c4d1074a1b7968b93ce17e6465787ac751e734b6f149f3ce034238768617d`. Actual GitHub conclusion and failed-job logs are retained locally alongside these downloaded artifacts.

## Caller-state custody and scope

The successor was constructed using a separate temporary `GIT_INDEX_FILE` and `read-tree ff913492...`, followed by `hash-object --path`, `write-tree`, `commit-tree -p ff913492...` and a new CI branch ref. The main checkout and main index were never used for staging this snapshot. The main index initially matched `c70fe55b5430333ef3b2ee4e1247dd82e83a9a0a26aaa062faf4d94700096d4f`; an independent UI staging change was observed before publication. The first local prepublication guard stopped before push/dispatch. The later observed caller state is recorded separately in the temporary evidence directory; it was not restored or incorporated into the successor.

At the actual publication baseline and after CI completion, caller HEAD was `4bcf80a0d7160264accbb6b415facde82cf87928` and caller index SHA-256 was `7a903758cb0006e56c35a1fbeea5257b49d915fba2b317a9804792a40d640ec9`; these observations matched. Only the new CI branch was pushed, as a normal descendant of the preserved predecessor. Exactly one manual workflow dispatch occurred. The foreground watcher ran inside one background shell, scoped to this run, with at most three discovery/API retry attempts and a shared 30-minute watcher bound.

A later read-only receipt-validation observation recorded concurrent caller HEAD `31287b9204aef5384b85d75f97f233dccf230409` and index SHA-256 `379e420b82d3c9265444917da651a58a79eec10ea54e73ce66ec79d2dfe82dff`. Those changes were not performed by this verification agent and were not incorporated into its already-executed child commit. The original receipt still matched its recorded SHA-256.

Local evidence directory: `C:\Users\sasha\AppData\Local\Temp\opencode\elyx-posix-host-followup-20261116-0ba564e7`. The prior receipt is untouched; this new receipt is the only caller-worktree file authored for the followup. Local checks passed actionlint 1.7.12, workflow single-job/unchanged-Swift-step validation, embedded/helper Python syntax and `git diff --check`.

Coverage remains limited to the frozen ready components. `PluginElyxDeveloperFiles`, native Descriptor/Registry implementations and unfinished provider tests are excluded. **Production native FD-provider/registry, linked native CPython source-authorization acceptance, Apple/UIKit and full-app behavior are outside this gate.** Source/engine recorders in the ready transaction/lifecycle tests retain their explicit fixture scope. No unrelated CI run was queried or cancelled.
