# Elyx FD Host timeout — direct native diagnosis

**2026-11-16: the first hanging testcase is reproduced directly and in isolation:** `PluginHostTests.PluginElyxDeveloperFilesTests/testCancelledLoadWaiterCannotRecycleRetainedDescriptor`. It is a fixture wait cycle; increasing the process deadline is not required. The diagnostic run remains **failure**, not a partial-cohort green result.

## Immutable execution identity

- Source parent: `a707e85bcf4ce8bce39029829acf7577b5d8950c`.
- Workflow-only diagnostic commit: `e4ad2699b7ad8abc363b7a7e31723fa6561c3602`.
- Branch: `ci/elyx-fd-hang-diag-20261116-5ae310d4`.
- [Manual run 43783761287](https://github.com/SanekYo-tech/exteraless-ios/actions/runs/43783761287), actual conclusion **`failure`**.
- Job: `133026679865`; run `2026-11-16T01:01:13Z`–`01:03:14Z`.
- Native build: **20.31 seconds**, bounded to 180 seconds. Direct diagnostic step: `01:02:44Z`–`01:03:11Z`, inside its five-minute limit.
- Only `.github/workflows/compat-tests.yml` and `docs/wave-2/elyx-posix-source-pins.json` differ from the source parent. Every production/test byte is unchanged; the later coordinator cancellation fix is absent from this diagnostic snapshot.
- Workflow SHA-256: `160507e35be1e49a13f9cc9252459e3971d069b02552665b36ebdf92aff7ad03`.
- [184-file pin manifest](https://github.com/SanekYo-tech/exteraless-ios/blob/e4ad2699b7ad8abc363b7a7e31723fa6561c3602/docs/wave-2/elyx-posix-source-pins.json), SHA-256 `ecdf9316f17ae5fa04a5a68ca9fa26a9177818cdd8457bef50d1a6a1c42241e5`; all 184 source checks passed.

## Actual binary and discovery

`swift build --show-bin-path` identified the real product directory. The executable was **not named `PluginHostPackageTests.xctest`** in this Swift 6.4.2 build:

```text
/home/runner/work/exteraless-ios/exteraless-ios/swift/PluginHost/.build/out/Products/Debug-linux-x86_64/PluginHostTests-test-runner
```

Runner size: **1,186,584 bytes**; SHA-256 **`3a9daa411296277bafdb6171441a21de7292b27efc56bdfafd928e1eef3345e6`**, identical before/after all direct processes. LLDB also identified the loaded `PluginHostTests.so` implementation image; its separate binary hash was not captured. All implementation source inputs are covered by the source pins.

The runner was queried once each with `--list-tests` and `--dump-tests-json`, through `stdbuf -o0 -e0`, with separate 10-second bounds. Both completed. There were **273 discovered native IDs**, from which the exact **47 sealed Host IDs** were verified and retained in `selected-47-ids.json`. Selectors came from that actual discovery.

## Three fresh direct processes

Let `BIN` be the exact executable above. Each group ran without `swift test`, with its own 15-second cap and separately marked command/group boundaries:

```sh
stdbuf -o0 -e0 "$BIN" PluginHostTests.PluginElyxDeveloperFilesTests
stdbuf -o0 -e0 "$BIN" PluginHostTests.PluginElyxDeveloperActivationTests
stdbuf -o0 -e0 "$BIN" PluginHostTests.PluginElyxDeveloperTests
```

| Group | Sealed cases | Actual result | Process elapsed |
|---|---:|---|---:|
| Files | 29 | 1 passed; next case started and hung; 27 not reached | 15.004 s, killed at cap |
| Activation | 6 | **6 passed**, no failures/skips | 0.032 s |
| Transaction/Host | 12 | **12 passed**, no failures/skips | 0.114 s |

The Files log contains exactly this native prefix:

```text
Test Case 'PluginElyxDeveloperFilesTests.testBridgeReadinessAndMetadataFailurePrecedePublication' passed (0.113 seconds)
Test Case 'PluginElyxDeveloperFilesTests.testCancelledLoadWaiterCannotRecycleRetainedDescriptor' started at 2026-11-16 01:02:45.949
```

There is no finish event for that case. The three processes cover the requested 47-ID inventory, but only **19 distinct cases completed**, one was observed blocked, and 27 were not reached. No assertion failure or test skip was observed. These are incomplete execution results, not 47 passes. No other hanging case was observed in the completed groups; the unreached Files cases remain unproven.

## Minimal isolated reproduction and bounded native stacks

The one permitted focused repeat used the exact discovered native selector:

```sh
SWIFT_BACKTRACE=enable=yes,interactive=no,threads=all \
  stdbuf -o0 -e0 "$BIN" \
  PluginHostTests.PluginElyxDeveloperFilesTests/testCancelledLoadWaiterCannotRecycleRetainedDescriptor
```

It again emitted a start without a finish and reached its **10-second cap**. SIGABRT ended it with return code **-6** after **10.264 seconds**; a two-second SIGKILL fallback was armed. No deadline was increased.

The runtime reported `unable to locate swift-backtrace; disabling backtracing`. The already installed Swift-toolchain **LLDB** was therefore the useful stack evidence: one batch attachment to the verified child PID, no debugger installation or symbol download, completed successfully in **0.870 seconds** within a four-second cap:

```sh
sudo -n /home/runner/swift-6.4.2/usr/bin/lldb --batch --no-lldbinit -p 4183 \
  -o 'thread backtrace all' -o 'process detach' -o quit
```

The retained thread dump shows the main thread inside `libXCTest.awaitUsingExpectation(_:)` / `XCTMain`; dispatch workers are waiting, and an interpreter worker is idle in `InterpreterMailbox.serve` at `SubinterpreterManager.swift:189`. The async continuation's source line is not reconstructed from that native stack. The exact blocked case is established by two unbuffered native executions; the wait-cycle explanation below comes from the corresponding immutable source.

## Source-level cycle for the confirmed case

In source `a707e85b`, `PluginElyxDeveloperFilesTests.swift:413` defines the confirmed method:

- Lines 426–432: detached producer waits on `finish.awaitValue()` before calling `reply.succeed(())`.
- Line 436: `waiter` waits on plain `reply.awaitValue()`.
- Lines 438–439: the test cancels `waiter` and then awaits `waiter.value`.
- Line 443: `finish.succeed(())` is scheduled only after that await completes.
- `SubinterpreterManager.swift:112–125`: `OneShotResult.awaitValue` stores a checked continuation, with no cancellation handler. Cancelling the task alone does not complete this promise.

Thus `waiter.value → reply → finish → code after waiter.value` is cyclic. This confirms the coordinator's first predicted cancellation case. The analogous inspector-wait cycle at `testCancelledWaiterRetainsActualInspectorFDThroughCompletion` was source-traced, but was **not reached** by this Files group and was not separately rerun. The coordinator's later test-only fix is a distinct verification successor, not part of this immutable diagnosis.

## Retained evidence

Artifact **`elyx-fd-hang-diagnostics-43783761287`** uploaded/downloaded successfully: **20 files**, 14-day retention. No empty XML was merged or represented as a pass.

| Evidence | SHA-256 |
|---|---|
| `diagnostics.json` — every command, PID, bound, duration and outcome | `06a3d3fe3147654d23712527c18c8a84a5683761b037bc7ba63c5e4d4e72d9a8` |
| `list-tests.log` | `01ba77a3c320460b66748982cd7f07f261b8d38c6ef8359a6177189282bbb53a` |
| `dump-tests-json.log` | `c32a1aec05ba136abd681b1a3d8bf8065610738a23fb8818b29ba0f712c972fa` |
| `selected-47-ids.json` | `b9ea9b22fa4e0d28e03423d85d37bbb0b87caf2b947e4cd0a7664e21437ac83c` |
| Files group log | `dd4e840828fa6e8be72246e1bf5ec7f407d7881312c32b306d531e0a53bee5b1` |
| Activation group log | `a95aebaa95704618a361af52ebf4d8b443f4201f820c3431cc451dbb9dceb8d6` |
| Transaction group log | `215461a69e6d4df13afad9c7d1cfaa5fa317ca27ca4104408bdb71860691362f` |
| Focused case log | `7cede8dd1f5f66b81748fc0bb0797b6cdf539a18abf4758f40c666fef17d5399` |
| LLDB all-thread backtrace | `c40a5b1036aeeeaaf2905e849058d448d62769d63e17a6dd9508d18aab3d613d` |

Local immutable inputs and downloaded evidence: `C:\Users\sasha\AppData\Local\Temp\opencode\elyx-fd-hang-diagnostics-20261116-5ae310d4`. The source/test trees were inherited from `a707e85b`; no current-main source was copied or instrumented. Only a private Git index, a new verification branch, workflow/pins and this new receipt were authored. Earlier receipts and raw logs remain unchanged.

Caller before/after-CI observations remained HEAD `6de4ac36fefb54890a3dd043044e5a021a3d0e76`, index SHA-256 `dec54bf89631091bf4472e1056606e20431f873c3d3beb5bb8bff20f978d83c8`; no caller reset/staging was performed. Python 50, ingress 7, the general Host 53 gate and unrelated app CI were not rerun or queried. C/CPython/Root and Darwin-specific execution boundaries remain unchanged.
