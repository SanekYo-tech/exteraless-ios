# Elyx FD POSIX typecheck followup

**2026-11-16: actual CI FAILURE at test-target compilation.** The descriptor's `S_IFREG` diagnostic is gone; the next blocker is `PluginElyxDeveloperFilesTests.swift:391:51`, a throwing `||` expression missing an enclosing `try`. **Host tests executed: 0/47 intended; ingress tests executed: 0/7 intended.**

## Immutable successor and exact delta

- Branch: `ci/elyx-fd-typecheck-20261116-019de759`.
- Commit: `a5720a43e05ff0e9f73103b3c5f1359af4f8b1dd`.
- Direct parent: `ecaa9d851174dcb02862bc347a4dbc85e474897e`.
- Tree: `e7b5c0334855c95b1a1541dbcc94174e52691ab4`.
- [Predecessor receipt](elyx-fd-final-posix-ci.md) remains unchanged, including its actual compiler failure.

Exactly two paths differ:

| Path | Parent SHA-256 | Successor SHA-256 |
|---|---|---|
| `swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperDescriptor.swift` | `42c3dbadc270cb37347325aebcccfe4ef64cc54047ada1569106ca3c6d1f7bf4` | `3ee9582d0042bff01220e45fee5f7e85819a1bd77f5e4145c7906a94aff580f9` |
| `docs/wave-2/elyx-posix-source-pins.json` | `c60fff83a6882348fe052ae1950f29934f16ced9d5e80a002ff8f645c136ed25` | `527614b24f228ae6787b884b4643c5113dcb01b1793c436cb57722377237ecef` |

The entire copied descriptor was compared against the parent plus this exact `checkLocked` edit. The resulting source diff is **6 added / 1 removed lines**:

```diff
         var original = stat(), copied = stat()
+        #if canImport(Darwin)
+        let typeMask = UInt32(Darwin.S_IFMT), regularFile = UInt32(Darwin.S_IFREG)
+        #else
+        let typeMask = UInt32(Glibc.S_IFMT), regularFile = UInt32(Glibc.S_IFREG)
+        #endif
         guard fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY, fstat(fd, &copied) == 0,
               fstat(entry.backing.descriptor, &original) == 0, copied.st_dev == original.st_dev, copied.st_ino == original.st_ino,
               copied.st_size == original.st_size, copied.st_size == claims.byteCount,
-              UInt32(copied.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG) else { throw PluginElyxDeveloperError.stale("native read fd custody changed") }
+              UInt32(copied.st_mode) & typeMask == regularFile else { throw PluginElyxDeveloperError.stale("native read fd custody changed") }
```

The CoreFoundation import and boolean-type validation remain present. Raw and canonical descriptor SHA-256 are identical (`3ee9582d…`), size **36,357 bytes**, Git blob `704342580517e67556aedcec7c85df82e9ab72d0`. Hashes were checked before/after copy and after private indexing.

All **183 other pin records** remain byte-for-byte identical. The full 184-file [successor manifest](https://github.com/SanekYo-tech/exteraless-ios/blob/a5720a43e05ff0e9f73103b3c5f1359af4f8b1dd/docs/wave-2/elyx-posix-source-pins.json) records the explicit coordinator override of this one historical sealed postimage. The original owner seal remains unchanged as provenance; its older descriptor hash is not represented as the new postimage.

No other current-main source was refreshed. Host tests, Python/C, tooling, ingress/TelegramUI inputs, model helpers, and the original owner seal remain inherited from `ecaa9d85`, including the same 47/7 exact native case identities. Active Root/Prefs/ModeABA work was not included.

## Unchanged manual workflow and limits

Workflow SHA-256 remains `3f4493a07795fb64c8c8b081994aa5ec51a62726e164eda311f8f06d5da86a17`: one manual `workflow_dispatch` job, Ubuntu 24.04, existing cached Swift 6.4.2, 25-minute job bound.

- Compile complete Host/test target: **180 seconds** maximum.
- Execute the exact Files 29 + Activation 6 + Transaction/Host 12 selection: **30 seconds** maximum.
- Supplied Foundation ingress driver: **120 seconds** compile and **30 seconds** for seven tests.
- The same nonempty native-XCTest reporter validates each sealed case's start/finish events, complete suite summary, zero failures/skips and log-linked JUnit. Its source and the ingress log observer were inherited unchanged.
- Prior Python 50-case and general Host 53-case gates are not executed by this workflow.

## Actual result and artifacts

- [Manual run 43780298237](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43780298237), actual conclusion **`failure`**, event **`workflow_dispatch`**, head SHA `a5720a43e05ff0e9f73103b3c5f1359af4f8b1dd`.
- Single job: [133015721462](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43780298237/job/133015721462), `Sealed Elyx Host 47 + Foundation ingress 7 (POSIX)`.
- Created `2026-11-16T00:25:40Z`; completed `2026-11-16T00:27:20Z`. Job elapsed 96 seconds.
- **184/184 source checks passed**, including the sole updated descriptor pin. Swift 6.4.2's compiler identity was verified against the same frontend SHA-256 `76db9f3dd8487a14ae39374509620e33af02f10da5dc42247406657832e4e9da`.
- Compilation advanced to `PluginHostTests-product`, then failed after a 14-second build step (`00:27:01Z`–`00:27:15Z`). There is no remaining `ambiguous use of 'S_IFREG'` diagnostic in this run's compiler log.
- Neither XCTest command started. The full Host/test build failure prevented the unchanged workflow's dependent ingress step. There are **no testcase-level pass/failure/skip counts and no JUnit**. The reporter retained explicit missing-native-log JSON with expected counts 47 and 7.

### Exact next compiler error

`swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperFilesTests.swift:391:51`, inside `testCancelledWaiterRetainsActualInspectorFDThroughCompletion`:

```swift
while (rig.registry.outstandingCount != 0 || !(try children(rig.staging)).isEmpty), ProcessInfo.processInfo.systemUptime < deadline {
    try await Task.sleep(nanoseconds: 1_000_000)
}
```

```text
error: operator can throw but expression is not marked with 'try'
note: call is to 'rethrows' function, but argument function can throw
```

This test file is inherited unchanged from the sealed parent, SHA-256 `12dddc14329807020d93278d7301ec42113fbd7d51d5ecf307c10666c0fb58b8`. It is a compiler error in the fixture's short-circuit expression, not a native runtime assertion or a missing test result being treated as a pass. No test source, filter or workflow was changed to bypass it.

Artifact **`elyx-fd-final-posix-43780298237`** uploaded and downloaded successfully: **16 evidence files**, 14-day retention. Native error context, full frontend command, explicit no-execution summaries, seal and checksums are preserved:

| Evidence | SHA-256 |
|---|---|
| `host/build.log` | `75d3ef20ac025b5339911bd2b76f531ec10cb6ef976554a6946b7febbd35e4dd` |
| `host/counts.json` — expected 47, no native execution | `ef7476a91e0c0ab3ca03e930620a9d4925a4159a0a0daacd4de257404005526e` |
| `ingress/counts.json` — expected 7, no native execution | `2ebef9483fc7ad9428c604d7a0ddb7ea337b95740e93790a605e4a45d6bc3563` |
| `summary.json` | `90d0f96758dcef4360163117db94c7fa10984081999148bc0caa9d4b763fd84c` |
| `source-check.log` | `fa19869da0d855a5147369314aab7db54c8b2f8fc826ea66e061466e32f0f6a7` |
| `sources.sha256` | `577a16a6cf684526487354409fbf3f05c586afe6cac20215806cbb1c06dee379` |
| `cohort-sha.txt` | `cd24d1d042f1e5d30a51a0f42076f484fedff04f6c7a0cc9bee37d500e818e41` |
| `elyx-posix-source-pins.json` | `527614b24f228ae6787b884b4643c5113dcb01b1793c436cb57722377237ecef` |

## Custody and boundaries

The verification commit was built from the immutable parent using a private temporary index, `hash-object --path`, `update-index --cacheinfo`, `write-tree` and `commit-tree -p ecaa9d85...`, then a new CI branch ref. No main checkout/reset, main-index staging, production-source edit, main commit or main push was performed by this agent. Caller state is observational, independent of coordinator commits.

Preparation and prepublication/post-CI observations recorded main HEAD `6de4ac36fefb54890a3dd043044e5a021a3d0e76` and index SHA-256 `dec54bf89631091bf4472e1056606e20431f873c3d3beb5bb8bff20f978d83c8`. This new receipt is the only authored caller-worktree file for the task. Only the new verification branch was pushed and manually dispatched; the run-scoped background watcher was bounded to 30 minutes with at most three discovery/API attempts.

All earlier receipts were preserved byte-for-byte, including the predecessor report SHA-256 `d51655f9ee16ef78ad9ee92cb027bba7f91d32ef2bc8b25fcf1aefce829f71e8`. Frozen inputs, sanitized transport/watch logs and downloaded evidence are under `C:\Users\sasha\AppData\Local\Temp\opencode\elyx-fd-posix-typecheck-20261116-019de759`.

Coverage retains the predecessor's explicit fixture scope: real native provider/registry/filesystem and Host/TLS paths, fixture archive inspector/Python engine recording, and production Foundation ingress with invocation outcome recorders. **Actual C/CPython fifth-child linkage, private application Root startup, live account/listener/UIKit and Darwin-specific rename/kqueue execution remain separate gates.** No unrelated app CI run was queried or cancelled.
