# Elyx FD cancellation fixtures — native Host acceptance

**2026-11-16: PASS — [Host-only run 43784959730](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43784959730), all 47 native cases passed with zero failures/errors/skips in 0.453 seconds, under the unchanged 30-second limit.** The two fixture wait cycles were corrected without changing production source. A separate coordinator-supplied main log independently confirms the identical 47-case subset inside a 273-case Host pass.

## Diagnosis retained unchanged

[Direct hang diagnosis](elyx-fd-hang-diagnostics.md) remains immutable: source `a707e85bcf4ce8bce39029829acf7577b5d8950c`, diagnostic commit `e4ad2699b7ad8abc363b7a7e31723fa6561c3602`, run `43783761287`.

It identified `testCancelledLoadWaiterCannotRecycleRetainedDescriptor` by actual unbuffered native start events, reproduced it alone at ten seconds, and saved LLDB all-thread stacks. The source cycle was `waiter.value → reply → finish → code after waiter.value`; plain `OneShotResult.awaitValue` is not cancellation-aware. Activation 6 and Transaction 12 passed independently; the uncompleted Files subset was not promoted to a 47-case pass.

## Exact authorized followup

- Branch: `ci/elyx-fd-cancellation-20261116-37c498ed`.
- Commit: `d21379e332d1449fc54065179d1f90a317ccbb4c`.
- Direct parent: `e4ad2699b7ad8abc363b7a7e31723fa6561c3602`.
- Tree: `85a3392053d46b9c32769ff56d723c18e2a62e53`.
- Test file: `swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperFilesTests.swift`.
- Test raw/canonical SHA-256: `762f265f93cd1ab95757eb9dcf76fdc26567820c370f6d49afefbace63f3bf2a`; **48,580 bytes**; Git blob `17a31bab0895f745aa87a4f913f380345029288e`.

The entire current test file was compared against the immutable parent plus exactly the coordinator's supplied changes:

```swift
private func elyxAwaitCancellable<Value: Sendable>(_ reply: OneShotResult<Value>) async throws -> Value {
    try await withTaskCancellationHandler(operation: {
        try await reply.awaitValue()
    }, onCancel: {
        reply.fail(CancellationError())
    })
}
```

Two waits use this helper; both tests add an early `defer { finish.succeed(()) }`. All testcase identities, FD-retention assertions, outstanding-count/cleanup assertions, filesystem controls and deadlines remain unchanged. Raw hashes were checked before/after copying and after private indexing.

Only this test file, the owned Host-only workflow and its pin manifest differ from the diagnostic parent. The entire production tree remains `swift/PluginHost/Sources` = `1587120c7e56bb41a1f80a46b3648b827c29b5fe`; Python, tools, ingress/TelegramUI and the original owner seal remain inherited. Active ModeABA/Root/Prefs work was not refreshed.

- Workflow SHA-256: `c16183804aeda375c8c9bf9cf5568bbb13dbf628a43d30aa403d8f8d1c03a389`.
- [184-file source-pin manifest](https://github.com/SanekYo-tech/exteraless-ios/blob/d21379e332d1449fc54065179d1f90a317ccbb4c/docs/wave-2/elyx-posix-source-pins.json), SHA-256 `87fef24cb1b95e2900ca197f970ebc6381d1cf9262de47b659dc493e02dd7172`.

## Actual bounded result

- Event `workflow_dispatch`, actual conclusion **`success`**, exact head SHA `d21379e332d1449fc54065179d1f90a317ccbb4c`.
- One job: `133030433341`, `Frozen native Host 47 with cancellable fixture waits (POSIX)`.
- Run `2026-11-16T01:13:19Z`–`01:14:52Z`; job elapsed 90 seconds.
- Complete Host/test build: **19.41 seconds**, maximum 180 seconds.
- Full 47-case native XCTest run: **0.453 seconds**, maximum 30 seconds. stdout/stderr were unbuffered with `stdbuf -o0 -e0`; the timeout was not raised.
- Files **29/29**, Activation **6/6**, Transaction/Host **12/12**; **0 failures, 0 errors, 0 skips**.
- Previously blocked `testCancelledLoadWaiterCannotRecycleRetainedDescriptor`: **passed, 0.009 seconds**.
- `testCancelledWaiterRetainsActualInspectorFDThroughCompletion`: **passed, 0.010 seconds**.
- Every native start/finish identity and downloaded JUnit case matches the exact sealed 47-ID inventory. All **184 source pins** verified; reporter errors are empty.

The retained native command is:

```sh
timeout --signal=KILL 30s stdbuf -o0 -e0 swift test --skip-build --jobs 2 \
  --filter 'PluginElyxDeveloper(ActivationTests|FilesTests|Tests)' \
  --xunit-output "$EVIDENCE/native.xml"
```

The nonempty `xctest.xml` is explicitly derived from complete native XCTest case events and links their raw log hash and commit. The separate zero-case Swift Testing XML is not counted. Ingress 7 and Python 50 were not rerun; ingress retains its previous successful native receipt.

Compiled image SHA-256 values were recorded:

- `PluginHostTests-test-runner`: `3a9daa411296277bafdb6171441a21de7292b27efc56bdfafd928e1eef3345e6`.
- `PluginHostTests.so`: `f8d868ccb9bb2d7d1bb144b786999b3c64f55230fd12769bd39d250feb92644f`.
- Verified Swift 6.4.2 frontend: `76db9f3dd8487a14ae39374509620e33af02f10da5dc42247406657832e4e9da`.

## Independent main-cohort confirmation: f704d76c

The coordinator supplied the completed [main CI run 43784503847](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43784503847) and local raw log `C:\Users\sasha\AppData\Local\Temp\opencode\compat-f704d76c-full.log`. This evidence was inspected locally; no new native run, progress query or cancellation was performed.

- Actual checkout in that log: **`f704d76c1596eb0086d08e49dd049796a0220c2f`**.
- Actual native Host summary: **273 tests, 0 failures, 5.545 seconds**.
- Exact 47-case subset: **47 distinct starts and matching passed finishes, 0 failures/skips**, including both cancellation fixtures. No result was inferred merely from the aggregate 273 count.
- The log also contains Core **712 / 0 failures / 9.176 seconds** and Hooks **30 / 0 failures / 0.356 seconds**. Those are independent main-run context, not additional executions by this agent.
- Main Host **Package.swift, entire Sources tree and entire Tests tree are byte-identical** to verification commit `d21379e3`: Sources tree `1587120c7e56bb41a1f80a46b3648b827c29b5fe`, Tests tree `14412f121f18fbc36e3e8307522a5316b7e47c6b`.
- Raw coordinator log SHA-256: `2e0df03ebda836d49822ec6d94a51374a1252bb3dcbe0a021348d5d0b1b214bd` (**945,855 bytes**).

Actual `f704d76c` source hashes for the selected native subset:

| Main source/test | SHA-256 |
|---|---|
| `swift/PluginHost/Package.swift` | `fbc50ee84590add303641563b765c189fd1de71d47d8d4939bba42146734766c` |
| `swift/PluginHost/Sources/PluginHost/BridgeServices.swift` | `73ba9424868df41d20a861fb57e5ffc0362dd7568ce7401d77b7d57a43414694` |
| `swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperDescriptor.swift` | `3ee9582d0042bff01220e45fee5f7e85819a1bd77f5e4145c7906a94aff580f9` |
| `swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperFiles.swift` | `56903232ceb9bd6c003fd4bb3b7328e5af363a4a095960969cbc697b56a6338f` |
| `swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperReadiness.swift` | `903c323a091c3596b9f3f9bce7a5914fecd2091eabecabb892e73f9a539267e1` |
| `swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperService.swift` | `10a6ee936bcb5d65fc9a046f6ec66865e9322346787069ff969d9320644cee26` |
| `swift/PluginHost/Sources/PluginHost/PluginElyxDeveloperTransaction.swift` | `739eb78e179d5130e1f2698e7627ee403f6aae646700758cd224391f2791e652` |
| `swift/PluginHost/Sources/PluginHost/PluginHost.swift` | `6e3f9692792795761cb882ba040b7f065430a2918669ecdea56aed1d19758fc9` |
| `swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperFilesTests.swift` | `762f265f93cd1ab95757eb9dcf76fdc26567820c370f6d49afefbace63f3bf2a` |
| `swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperActivationTests.swift` | `e96d851e86c12fab2ecf632fb2fdfd82b968c78ada7cbda18a276d74e897fc85` |
| `swift/PluginHost/Tests/PluginHostTests/PluginElyxDeveloperTests.swift` | `9c7bf8f9e7fda67d7af92a780b5436c5dfae8a9b62a436b4b069d77275f73927` |

`main-f704-host47-subset.json` in the local verification directory preserves all **87** committed Host package/source/test hashes, all 47 observed case results and the input-log hash. Its SHA-256 is `fa0a95d3d993d639e8c3821e090efc788c836a1d750c7d5ea486e5003ca1feca`. The coordinator-reported unrelated Python YAML-path failure in the full workflow is not relabeled as a globally successful workflow; the native Host evidence is the result validated here.

## Verification artifacts

Artifact **`elyx-fd-cancellation-43784959730`**, **15 files**, uploaded/downloaded successfully, 14-day retention:

| Evidence | SHA-256 |
|---|---|
| `xctest.xml` | `584df196f4ec530b6d05bd6156d11bb00ea3ae748c9770e2f9a238b776cdd51e` |
| `counts.json` | `15b7660305f69ca30bb51549a009527cccf74851cec8fe3731d3b588e5dc90db` |
| `test.log` | `199adcad9f6c4007157d924be382c9e72d628c77187e417ec19d2f933e9a11db` |
| `build.log` | `3dbe2bd30e2389801544c941c8a8846904bea1e91037edb463124fd6c574b71c` |
| `compiled-images.sha256` | `95077282571c293def8260c8ddf54546ca33b8df8cb8f97a5d57ddf4dd31000c` |
| `source-check.log` | `fa19869da0d855a5147369314aab7db54c8b2f8fc826ea66e061466e32f0f6a7` |
| `sources.sha256` | `c0656472d1dba7ca0206c4c5cd6689a983a59852823100e006028b8880705800` |
| `cohort-sha.txt` | `b43fe2b78d84f7f3af1fcff67f7300cf34deb1aec77dd76d39d6a23cf2bd3a18` |

Local source receipts, raw logs, JUnit, command metadata and main-subset verification are under `C:\Users\sasha\AppData\Local\Temp\opencode\elyx-fd-cancellation-posix-20261116-37c498ed`. The old diagnostic run and report were not rewritten.

## Scope and caller custody

The diagnosis and followup changed only owned verification workflow/receipts and the explicitly supplied test postimage. No main production code, main index or main ref was edited by this agent. Each snapshot used a private index and normal push of a new verification branch. Caller observations around the followup were HEAD `f704d76c1596eb0086d08e49dd049796a0220c2f`, index SHA-256 `ec9f2efa5102c83142a1f01d1b25929368292003f491ac47906ac9aeba5d015e`; independent coordinator progress was not rolled back. Earlier receipts and logs remain immutable.

These are **actual Linux XCTest component results**: real native filesystem/registry and Host/TLS paths with the documented fixture inspector, Python-engine recorder and invocation-recording boundaries. **They do not establish actual C/CPython fifth-child integration, private app Root startup, live account/listener/UIKit behavior or Darwin-specific rename/kqueue execution.** No Apple acceptance is inferred from the main CI or this followup.
