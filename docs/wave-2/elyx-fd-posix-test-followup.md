# Elyx FD POSIX fixture followup

**2026-11-16: overall CI FAILURE — Host/test compilation passed, the 47-case Host command timed out at 30 seconds (exit 137), and the independent Foundation ingress suite passed all 7 cases with zero failures/skips.** Host stdout was empty, so its actual testcase progress and the blocked testcase are unknown. No Host runtime pass is claimed from the zero recorded events.

## Immutable identity and sole fixture change

- Branch: `ci/elyx-fd-test-20261116-40bf925c`.
- Commit: `a707e85bcf4ce8bce39029829acf7577b5d8950c`.
- Direct parent: `a5720a43e05ff0e9f73103b3c5f1359af4f8b1dd`.
- Tree: `ab8a47057cdd4468e1873f4035c9d1b7474fe870`.
- [Manual run 43781210777](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43781210777), event `workflow_dispatch`, actual conclusion **`failure`**.
- Single job: [133018651825](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43781210777/job/133018651825), `Sealed Elyx Host 47 + Foundation ingress 7 (POSIX)`.
- Run created `2026-11-16T00:34:53Z`, completed `2026-11-16T00:37:04Z`; job elapsed 116 seconds.

Exactly two paths differ from the parent:

| Path | Parent SHA-256 | Followup SHA-256 |
|---|---|---|
| `swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperFilesTests.swift` | `12dddc14329807020d93278d7301ec42113fbd7d51d5ecf307c10666c0fb58b8` | `66c284f7fdd5bda12d6d18bb801f6bcaaefa96475d5cecd8533aa3fc2f39ce80` |
| `docs/wave-2/elyx-posix-source-pins.json` | `527614b24f228ae6787b884b4643c5113dcb01b1793c436cb57722377237ecef` | `34e76456f5c79faca3f06e7bb775fccb5d38a972949083282d9e78acc8d72e95` |

The complete copied test file was compared against the parent plus this exact one-line substitution at line 391:

```diff
-        while (rig.registry.outstandingCount != 0 || !(try children(rig.staging)).isEmpty), ProcessInfo.processInfo.systemUptime < deadline {
+        while try (rig.registry.outstandingCount != 0 || !children(rig.staging).isEmpty), ProcessInfo.processInfo.systemUptime < deadline {
```

Raw and canonical SHA-256 are identical (`66c284f7…`), size **48,221 bytes**, Git blob `516c34156c90defdcb52a5f0947031dc40b92163`. Hashes were checked before/after copying and after private indexing. The filesystem predicate, two-second deadline, sleep interval and final assertions remain unchanged.

All **183 other pin records** remain byte-identical. The entire native implementation tree is inherited unchanged: `swift/PluginHost/Sources` tree `1587120c7e56bb41a1f80a46b3648b827c29b5fe`. The qualified Descriptor retains SHA-256 `3ee9582d0042bff01220e45fee5f7e85819a1bd77f5e4145c7906a94aff580f9`.

[Full 184-file pin manifest](https://github.com/SanekYo-tech/exteraless-ios/blob/a707e85bcf4ce8bce39029829acf7577b5d8950c/docs/wave-2/elyx-posix-source-pins.json) records the one authorized test postimage override while preserving the original seal as history. No other main worktree file, including active ModeABA/Root/Prefs work, was refreshed.

## Actual native results

| Phase | Actual result | Bound |
|---|---|---|
| Source checks | **184/184 OK** | Within job |
| Full Host/test build | **PASS**, 21.23 seconds | 180 seconds |
| Host test command | **TIMEOUT**, exit **137**, no captured case events | 30 seconds |
| Ingress build | **PASS**, 12.06 seconds reported by Swift; 12.852 seconds helper wall time | 120 seconds |
| Ingress native XCTest | **7 passed, 0 failures, 0 errors, 0 skipped**, 0.112 seconds; 0.599 seconds helper wall time | 30 seconds |

The cached Swift **6.4.2** compiler was verified against frontend SHA-256 `76db9f3dd8487a14ae39374509620e33af02f10da5dc42247406657832e4e9da`, target `x86_64-unknown-linux-gnu`. Both previously reported compiler errors are absent; the complete Host/test target linked successfully.

### Host timeout: evidence and limits of the observation

The unchanged command was started at `00:36:16Z` and terminated at `00:36:46Z`:

```sh
timeout --signal=KILL 30s swift test --skip-build --jobs 2 \
  --filter 'PluginElyxDeveloper(ActivationTests|FilesTests|Tests)' \
  --xunit-output "$EVIDENCE/host/native.xml"
```

GitHub's actual failed-step log records `Killed` and `Process completed with exit code 137`. The captured `host/test.log` is **0 bytes**. There is no native case-start/finish event or complete suite summary from which to identify whether the stall was in discovery/startup or a particular test. No testcase name or source line is guessed.

The reporter correctly failed closed with four report errors. Its `host/counts.json` and empty `host/xctest.xml` describe **zero recorded events**, not zero tests actually entered and not a successful zero-failure run. Host testcase pass/failure/skip counts are therefore **undetermined**. The 47-case acceptance requirement remains unmet. Neither the filter nor the timeout was relaxed, and no source was modified after this observation.

### Seven actual Foundation ingress cases passed

The unchanged supplied `test_native_elyx_ingress.py` driver ran on Linux after the Host build succeeded. Its real `run_bounded` calls, observed without replacing commands, returned zero for both `swift build` and `swift test`, retaining separate 120/30-second limits.

All seven sealed identities are present in native stdout and the log-linked JUnit:

1. `testActualIngressLateSessionAndActorGuardsKeepSuccessfulPublication`
2. `testActualIngressPostPublishPersistenceOrLoadErrorKeepsKnownState`
3. `testActualIngressPreAdmissionRefusalNeverExecutesAndReportsZeroWrite`
4. `testActualIngressPreservesAllPublicationFailureOutcomesAndOriginalEnvelope`
5. `testAuthenticationPrecedesElyxCommandParsing`
6. `testNativeResponseDoesNotTurnFailedReloadIntoSuccess`
7. `testSessionRevocationAndUnknownCommandsStayExplicit`

These exercise actual Foundation ingress/protocol code and its structured error/publication envelope assertions, including `publication_outcome` and `source_changed`. The fixture's invocation outcome callbacks remain explicit recorders; its Host is unstarted. This is not C/CPython/Root-startup or end-to-end FD publication acceptance. All five copied ingress input hashes were independently matched to the immutable pin manifest, including the parent-only model helpers.

## Artifact receipts

Artifact **`elyx-fd-final-posix-43781210777`** uploaded and downloaded successfully: **25 evidence files**, 14-day retention. It contains the Host build, timeout's empty stdout and invalid/incomplete projection, separate successful ingress build/test/JUnit, the real driver command/timing record, copied-input hashes, source pins and context.

| Evidence | SHA-256 |
|---|---|
| `host/build.log` | `f4728cf63a5f92209254632be1e960a17633fa3178e8dd4643a997a0800e1be5` |
| `host/test.log` — empty after timeout | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `host/counts.json` — incomplete/report errors | `9516a0be6e3a282697a52fd7e267ac169d4ee10577128b70f28d3f9bc3cab667` |
| `host/xctest.xml` — no native testcase events | `294a651ac782fed489287aaf11fa0db3563c1d33899d98c3291a4818e0031b96` |
| `ingress/build.log` | `a75997e5580f8ec3cc7b7fc2ecbc4f7516b9b995e467c0777ef30e0e360b7ae5` |
| `ingress/test.log` | `7df386369350261f8af9e025c25820f5cc60ba182ba50890a45f766aaf54ad11` |
| `ingress/xctest.xml` | `e9e7e463513a1352c93205c79f79c53bfee44d83ff64eb441413f553368810ce` |
| `ingress/counts.json` | `7c02c06b3f115bf2ebbdda5a7356b1cfdeea450dc35cc53af4d2c2621d63cbf8` |
| `ingress/commands.json` | `2f6612b3921b6bb8e4e0d12417b9c1e131e7389fbd9c9be2e5e0cb9d782174a5` |
| `ingress/input-sha256.json` | `c9d8c9daa6b1496f507c799802f3bcaa1e2b5fa6000de75a1fe2542c03b8d849` |
| `sources.sha256` | `bcfa968439e5e1293a95fc06a7f8f2a2658ea3d2c6ccdf8de7b864d173c41bd9` |
| `source-check.log` | `fa19869da0d855a5147369314aab7db54c8b2f8fc826ea66e061466e32f0f6a7` |
| `cohort-sha.txt` | `44529e3ec1e1a69872c22018828d276f808d3800bf980aa02523ddecd0556721` |
| `elyx-posix-source-pins.json` | `34e76456f5c79faca3f06e7bb775fccb5d38a972949083282d9e78acc8d72e95` |

The full GitHub failed-step log (including exit 137), immutable inputs, native command/timing records and downloaded artifacts are retained in `C:\Users\sasha\AppData\Local\Temp\opencode\elyx-fd-posix-test-20261116-40bf925c`.

## Preserved controls and caller custody

The workflow is byte-identical to the parent, SHA-256 `3f4493a07795fb64c8c8b081994aa5ec51a62726e164eda311f8f06d5da86a17`, with its 25-minute job bound. A private `GIT_INDEX_FILE` was initialized from `a5720a43`; only the exact fixture line and pin manifest were inserted before `commit-tree` and a new CI-branch ref. Only that new branch was pushed and manually dispatched. No main staging/reset/checkout, main commit/push or production source edit was performed by this agent.

Before/after capture and CI observations recorded caller HEAD `6de4ac36fefb54890a3dd043044e5a021a3d0e76` and index SHA-256 `dec54bf89631091bf4472e1056606e20431f873c3d3beb5bb8bff20f978d83c8`. Caller progress was observational. This newly added receipt is the only authored caller-worktree file for the task; no previous receipt or log was rewritten. The predecessor receipt remains SHA-256 `bcae4bb5c77a1561a05772e1aea5ce2394acb330da2c7e0a8946cd8312ddb9bb`.

No Python 50-case or general Host 53-case rerun occurred. **Native Host/FD47 acceptance remains blocked by the timeout; actual C/CPython fifth-child integration, private app Root startup, live account/listener/UIKit and Darwin-specific rename/kqueue execution remain separate gates.** The supplied inspector/Python engine/invocation recorder boundaries remain explicit. No unrelated app CI was queried or cancelled.
