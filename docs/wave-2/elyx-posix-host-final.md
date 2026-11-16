# Elyx bounded POSIX Host final verification

**2026-11-16: bounded POSIX Host gate PASS — [manual run 43771162142](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43771162142), 53 passed, 0 failures/errors/skips, including seven real POSIX archive-descriptor cases.** Final CI commit `0ad00c3ef8e856d3a95cd33d43a059c4bc0c648f` contains an owned reporter-only correction on the already-passing source cohort `b3212761874998442ff99d8fd027430fb6521900`. Original Python remains 42 passed / 0 skipped in its separate immutable run.

## Immutable identity and exact source delta

- Branch: `ci/elyx-posix-host-final-20261116-63eac409`.
- Commit: `b3212761874998442ff99d8fd027430fb6521900`.
- Direct parent: `ec1131cf5af720cb88f13d11881fcaad6d3aa0f6`.
- Tree: `6e661ed6f8e16c2a9d9b0ba8f0875960a699d487`.
- Original archive cohort: `ff9134924cdc1c41aeecb2af1f4cf194a1963550`.

Exactly two paths differ from the direct parent:

| Path | Parent SHA-256 | Executed snapshot SHA-256 |
|---|---|---|
| `swift/PluginHost/Sources/PluginHost/BridgeServices.swift` | `2b9d428135e67213a47e64f780d595f3ca92ebdbb300e6c042e915d581d0957e` | `99073359cebca56ff2847ec2a54a78a44d0f40ba719f22eac62a09ea2edc1393` |
| `docs/wave-2/elyx-posix-source-pins.json` | `76f691280ce75e4d5270b2d804abfa7b7d844d289ac0583582fe4a7f79e19f2a` | `36ce622510f4d4dd33b387b0b9f7a58c99d93e08db9c992917d839a81b03102a` |

The coordinator's authorized `nativeEffectLease` change at lines 1032–1037 is the entire source diff:

```diff
-        let permissionCurrent: @Sendable () -> Bool = permissions?.futurePredicate(pluginId, requiring: [permission]) ?? { true }
+        let permissionCurrent: @Sendable () -> Bool
+        if let permissions = self.permissions {
+            permissionCurrent = permissions.futurePredicate(pluginId, requiring: [permission])
+        } else {
+            permissionCurrent = { true }
+        }
```

The full copied file was compared against the parent plus exactly that replacement. Raw and canonical SHA-256 both equal `99073359cebca56ff2847ec2a54a78a44d0f40ba719f22eac62a09ea2edc1393`; size **54,908 bytes**; Git blob `3a9c219fac35534ea950931e14f0d6fc4c70ef25`. Hashes were verified before/after copying and after private indexing. The legacy nil-permissions fixture fallback remains `{ true }`.

All **121 other original working-source records** and **165 of 166 total pin records** are inherited byte-for-byte from `ec1131cf`. The first dispatcher fix is preserved with SHA-256 `8fafbadf870bd85729d51629aceba85589763dbc08263b9940c06bd3c65c2c74`. No other current-main files, provider implementations or new provider tests were captured. The entire Host test tree remains `2506c388019551b39f609075417a7711e55a856c`.

[Complete immutable source pins](https://github.com/SanekYo-tech/exteraless-ios/blob/b3212761874998442ff99d8fd027430fb6521900/docs/wave-2/elyx-posix-source-pins.json) record all input hashes, byte sizes, Git blobs and the separate capture history.

## Source-fix workflow and preserved Python evidence

The source-fix commit `b3212761` inherited the branch-only `.github/workflows/compat-tests.yml` without changes: SHA-256 `1070311494e3920aed61972e3fa07984a94b249f9aa79260b8ecf1d31251e40a`. The reporter-only correction is recorded below. Both versions are `workflow_dispatch`-only, with exactly one Ubuntu 24.04 Swift job, a 25-minute outer bound, the existing pinned actions and Swift 6.4.2 cache. Native commands are identical:

```sh
timeout --signal=KILL 180s swift build --build-tests --jobs 2
timeout --signal=KILL 30s swift test --skip-build --jobs 2 \
  --filter '(PluginArchive|PluginTrust|PluginSettingsPage|PluginResourcePath|PluginSendHook|PluginElyxDeveloper)' \
  --xunit-output "$EVIDENCE/host.xml"
```

The build attempts all frozen Host sources and tests. The filter selects the same 53 ready tests; the new provider tests are absent from this snapshot. Source verification checks all 166 pins. Logs, checksums and the count/error recorder are uploaded with `always()`.

**Python is not rerun.** Its evidence remains [run 43768124344](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43768124344), **42 passed, 0 skipped, 20.270 seconds**, including all 17 formerly Windows-skipped POSIX cases. Original JUnit SHA-256: `3cca73f59a6d0db4c0ac3da2e3f102e8b7806a57291cf5da4000d74628e36a86`. The entire Python and tooling trees are inherited unchanged; this followup adds no C/GIL or runtime-default changes.

## Actual native execution: source-fix run

[Manual run 43770534123](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43770534123), commit `b3212761874998442ff99d8fd027430fb6521900`, had exactly one Swift job (`132985224200`). Actual GitHub conclusion: **`failure` at the report-collection step**, while both native compile and test steps succeeded.

- Created `2026-11-15T22:39:51Z`; completed `2026-11-15T22:40:46Z`.
- Complete Host and test build: **13.96 seconds**, inside the 180-second bound.
- Actual XCTest execution: **53 passed, 0 failed, 0 skipped, 0 unexpected**, **0.476 seconds**, inside the 30-second bound. Every expected case has a native start and passed event; the completed `Selected tests` summary confirms all 53.
- All **166 source pins** verified. Swift **6.4.2**, `x86_64-unknown-linux-gnu`, frontend SHA-256 `76db9f3dd8487a14ae39374509620e33af02f10da5dc42247406657832e4e9da`.

| Executed XCTest class | Passed | Failed | Skipped |
|---|---:|---:|---:|
| `PluginArchiveDescriptorTests` | 7 | 0 | 0 |
| `PluginArchiveHostTests` | 12 | 0 | 0 |
| `PluginElyxDeveloperTests` | 7 | 0 | 0 |
| `PluginResourcePathTests` | 2 | 0 | 0 |
| `PluginSendHookPriorityTests` | 8 | 0 | 0 |
| `PluginSettingsPageLeaseTests` | 4 | 0 | 0 |
| `PluginTrustHostTests` | 4 | 0 | 0 |
| `PluginTrustLevelTests` | 9 | 0 | 0 |
| **Total** | **53** | **0** | **0** |

The seven actual descriptor witnesses passed: replacement file inode refusal; parent swap during capture; new-file retention after capture; parent swap after capture; parent swap at unlink barrier; uncaptured-generation/unrelated-cache retention; and raw OS path descriptor anchoring. The resource-path symlink-retarget case and native archive installation/replacement/purge lifecycle cases also executed.

### Observed reporting failure

The inherited command's `--xunit-output "$EVIDENCE/host.xml"` produced **`host-swift-testing.xml` containing zero Swift Testing cases**, while this target's 53 **XCTest** cases were reported successfully to native stdout. There was no `host.xml`; the existing always-run checker consequently reported `Host tests did not produce JUnit`. This is a verification-reporting failure, not a failing Host testcase. The zero-case Swift Testing XML is not counted as XCTest acceptance.

Artifact `elyx-posix-swift-43770534123` uploaded and downloaded successfully (13 evidence files):

| Evidence | SHA-256 |
|---|---|
| `swift-build.log` | `137f6caa1407162f696f8686ef3eb8ddb0cb1fc0e8ba485866e1849833fa3a0e` |
| `swift-test.log` — complete 53-case native result | `e8c3171f45a239644f0becb6b817735d4c93a760a4b257e3183de2e04db0751c` |
| `counts.json` — original missing-JUnit error | `e4a666034172532a2a8128774c64014eca0262d68714d9c9a87da86fe0016ece` |
| `host-swift-testing.xml` — zero cases | `e76cc3c57ad3628b596be509c016268500b3acaa15331ff2ad010d8212467053` |
| `sources.sha256` | `4cd8e290fd9493f653122761e83a344bc63ab433a397fc99632e33993b34df87` |
| `cohort-sha.txt` | `556068a6dd754ea7451338c423d732c7f8b0a221429a40c9c479387164ef0512` |

## Owned reporter-only successor

- Branch: `ci/elyx-posix-report-20261116-2df0648b`.
- Commit: `0ad00c3ef8e856d3a95cd33d43a059c4bc0c648f`; direct parent `b3212761874998442ff99d8fd027430fb6521900`.
- Only workflow and pin-manifest bytes changed. All **122 working-source records**, all native build/test commands, and the entire `swift`, `python` and `tools` trees are identical to the 53-pass source-fix run.
- Workflow SHA-256: `c23d06637cc13f9f6320319875d26f36d9a7837ad755de73516b24fde91c9fd5`.
- [Reporter-successor pins](https://github.com/SanekYo-tech/exteraless-ios/blob/0ad00c3ef8e856d3a95cd33d43a059c4bc0c648f/docs/wave-2/elyx-posix-source-pins.json), SHA-256 `db329103bd42ab4bcd1e7f267c6b8e1534c7d385618ff2709bf058b1162060a9`; all 166 pins retained, only the workflow pin updated.

The owned reporter projects the **actual native XCTest start/finish events** into explicitly labeled `host-xctest.xml`, retaining the original log and its SHA-256 in JUnit properties. It requires exactly the 53 case identities from the eight pinned ready test files, exactly one start and finish per case, the complete native suite summary, and zero failures/skips. It cannot accept the empty Swift Testing XML or a truncated case stream. Reporter preflight accepted the downloaded complete 53-case native log and rejected its truncated-summary counterpart; actionlint and unchanged-native-command checks passed.

### Final successful manual run

- [Run 43771162142](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43771162142), actual GitHub conclusion **`success`**, event **`workflow_dispatch`**, head SHA **`0ad00c3ef8e856d3a95cd33d43a059c4bc0c648f`**.
- Exactly one Swift job: [132987159387](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43771162142/job/132987159387), **success**. No Python job.
- Created `2026-11-15T22:46:40Z`; completed `2026-11-15T22:48:13Z`. Job elapsed 89 seconds.
- Complete build: **17.88 seconds**, under the 180-second bound. Native XCTest: **53 passed, 0 failed, 0 errors, 0 skipped**, **0.569 seconds**, under the 30-second bound.
- The rerun reproduced exactly the same 53 case identities and per-class counts listed above. Native start/finish events, the completed suite summary, downloaded JUnit and the fixed expected inventory all agree.
- All **166 pins verified**. JUnit's source-log SHA-256 and cohort SHA properties match the downloaded native console log and this exact commit. Reporter errors: **none**.
- Artifact **`elyx-posix-swift-43771162142`** uploaded and downloaded successfully, **14 evidence files**, retention 14 days. JUnit is explicitly a projection of native XCTest events; the separate zero-case Swift Testing XML is retained without being counted.

| Final-run evidence | SHA-256 |
|---|---|
| `host-xctest.xml` — 53 native case events | `7725ba889e90e4b9bfdab596962515d294068f397ad99603a7b5105009070753` |
| `counts.json` | `23d1e270bc78f62308a3df8443f3a76f0e606f78f24ef365c587e6a0b65ee791` |
| `swift-test.log` — original native output | `98c7d2f694ad0c9ad34707322ae0cd759ab41118c92313d3ad390a7a7e3f8bdd` |
| `swift-build.log` | `cba3f962a46ec8e960464ede1e99c8550ac753ab1965e07ec80797ba646dc348` |
| `sources.sha256` | `360a9b094c7f709baefe846363aa69cb14809ec239514b9d0231aed8451b7052` |
| `source-check.log` — 166 OK entries | `4915fdaad7ca4a311e4de5784f6edadbda6f0e62874490fd5dd5f630ac4b1c17` |
| `cohort-sha.txt` | `3be028b184404537a1fb4c3e52b13195a7596844c9e6203ede617808d74df078` |
| `elyx-posix-source-pins.json` | `db329103bd42ab4bcd1e7f267c6b8e1534c7d385618ff2709bf058b1162060a9` |

The first source-fix run's historical `failure` conclusion remains recorded above. There were no failing native testcases to remediate. Relative to `ec1131cf`, the final CI commit changes only the returned `BridgeServices.swift` fix plus workflow/report metadata; relative to `b3212761`, it changes no production or test source bytes.

Whole-tree equality between `b3212761` and final CI commit `0ad00c3e` was verified: `swift` = `b372471d021f7df361db499af6c4f47507b27a55`, `python` = `7bae9c1b00ffbd8714a6a252c43b4b12dd8cb276`, `tools` = `e5b465430e7d6d2710cbd50aa3d3e1ef005b5438`. Relative to the original `ff913492` cohort, the only production-source changes across all verification successors are the two coordinator-returned permission predicate fixes.

## Read-only caller custody and coverage boundary

Only a private temporary `GIT_INDEX_FILE` was populated with `read-tree ec1131cf...`; the new source/pins were inserted with `hash-object --path` and `update-index --cacheinfo`, then `write-tree`, `commit-tree -p ec1131cf...` and a new CI branch ref created this successor. There was no checkout, main-index staging, main-branch commit or main push by this verification agent. Caller HEAD/index are observations, allowing the coordinator's independent progress; they are never restore targets or gates on this immutable parent.

The preparation observations and both completed runs' before/after publication observations recorded caller `main` HEAD `31287b9204aef5384b85d75f97f233dccf230409` and index SHA-256 `379e420b82d3c9265444917da651a58a79eec10ea54e73ce66ec79d2dfe82dff`. These were read-only observations; no main state was restored or advanced by this agent. Only normal pushes of the new CI branches and manual Swift workflow dispatches were performed.

Earlier receipts remain immutable:

| Receipt | SHA-256 |
|---|---|
| [Original POSIX receipt](elyx-posix-ci.md) | `181f3fd0e0c0a79e0f9b17778fdd690b60a4fa08a391e55a9bd1da3bc168620f` |
| [First Host followup](elyx-posix-host-followup.md) | `293f7eba6ee63aea1a21b924faef8cb977ecf24a9760ed3b7b0d24f9217be75f` |

The only caller-worktree file authored for this iteration is this new receipt. Frozen source/pin bytes, sanitized push/watch logs, actual GitHub metadata and downloaded evidence are under:

- `C:\Users\sasha\AppData\Local\Temp\opencode\elyx-posix-host-final-20261116-63eac409` — source-fix run and original native 53-case pass.
- `C:\Users\sasha\AppData\Local\Temp\opencode\elyx-posix-host-report-20261116-2df0648b` — reporter-only successor, successful gate, JUnit and checksum receipts.

Local checks passed helper syntax, exact per-commit two-path deltas, `git diff --check`, actionlint 1.7.12, unchanged native-command verification, complete-versus-truncated native-log reporter validation, and downloaded 53-case JUnit/source-pin identity checks. Each run used one scoped foreground watcher inside a background shell, with a 30-minute watcher bound and at most three discovery/API retry attempts.

**Production native FD-provider/Descriptor/Registry, linked native CPython source authorization, Apple/UIKit and full-app acceptance remain outside this gate.** The ready archive-descriptor tests use actual POSIX filesystem operations; lifecycle/transaction tests retain their documented engine/authority recorder scope. No production source was edited by this agent. No unrelated CI run was queried or cancelled.
