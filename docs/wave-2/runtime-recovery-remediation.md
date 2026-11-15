# TBF-05: continue an owned cold startup after Tools recovery

Source remediation for `reviews/tools-backup-followup.md:176–202`. The review is
read-only. **Coordinator APPLIED the complete Runtime source segment** of
`runtime-recovery-shared.patch`; its postimages are verified in current source.
The **BUILD segment is pending with the Build owner**. The coordinator will include
the Host helper and six Host tests in CI; no execution result has been supplied.

## Shipping helper and handoff

New source:
`swift/PluginHost/Sources/PluginHost/PluginRuntimeStartupContinuation.swift`.

The composition creates one continuation after assembling the fresh Host's
providers. The continuation owns that same Host's ordinary startup:

```swift
let continuation = PluginRuntimeStartupContinuation(host: host)
try await continuation.run(
    isCurrent: { capturedAccountGenerationIsCurrent },
    policy: { .init(engineEnabled: currentEngineEnabled, safeMode: currentSafeMode) },
    recoverBeforeStart: { /* existing ExteralessToolsHostMaintenance adapter */ },
    prepare: { currentPolicy in /* native early-start recovery policy, once */ },
    complete: { started in /* hooks, healthy timer, app_start, once */ }
)
```

`Phase.recoveryBlocked` preserves the pending cold startup. A Runtime-owned
maintenance operation captures a native `Maintenance` receipt from that exact
continuation. After its actual Host lease has finished successfully, it calls:

```swift
try continuation.acknowledgeMaintenance(receipt, recovered: recovered)
```

Foreign/replayed receipts are rejected. `recovered: false` preserves the block.
For success, the helper requires the real Host maintenance gate to have reopened.
Because that Host's lease captured `wasRunning == false`, `finish(resume: true)`
is data-only even when the current manager policy is master-off or safe mode.

The receipt permits another **existing conservative recovery check**, under the
real fresh-Host lease. It is not a journal/write witness. This also protects a
`.rolledBack` service outcome which did not retire an ambiguous journal, or a
journal appearing before a delayed startup. The Core recovery/reconciliation
algorithms and live data writers are not changed by this fix.

After that check, current account generation, manager policy and Runtime
maintenance admission are rechecked across suspension points. Engine-off leaves
the continuation pending. Safe mode is passed to the one ordinary `host.start`.
`hasAttemptedStart` is latched before that call and never reset, including a partial
initialization failure. Native preparation and synchronous remaining stages each
execute at most once. The helper contains no Host factory, terminal stop or
process-finalization operation.

## Applied Runtime behavior

The applied coordinator patch:

1. Rotates a native startup scope on account replacement/clear and termination.
2. Makes `startup` represent active work and clears it in the task's `defer`.
   A stored Host can only use its continuation; provider construction is guarded
   by `host == nil` and is performed once.
3. Moves the existing startup tail to `continueColdStartup`. It retains native
   automatic-safe-mode persistence, disabled-plugin notices, hooks and `app_start`.
   The healthy timer is scheduled after ordinary startup actually succeeds.
4. Captures the continuation receipt and account generation in the existing
   manager-aware maintenance lease. After successful same-owner lease completion,
   it releases that root's file gate, checks the captured account generation, and
   schedules/awaits continuation of the same Host.
5. Clears the resolved recovery error at the owned handoff; the new startup task
   publishes its actual success or failure. A Python initialization failure does
   not recreate Tools journal debt. A failed recovery confirmation does.
6. Lets a subsequently enabled master switch continue an already-prepared cold
   Host through this route. The running-Host branch retains nonterminal maintenance.
   The no-Host Tools lease has no cold continuation and does not initiate startup.

The maintenance `defer` checks its operation ID before clearing root state, since
a newer maintenance operation may start during the continuation await. Account
retirement during reconciliation records the data result but starts no Python.
A subsequent current-account request can obtain its own startup scope.

The current postimage contains `PluginConfigAuthority` forwarding, the atomic
`pinnedSet` writer, and the HNS-F02 `PluginUISettingsReadExecution` token with
expected-owner/worker-guard forwarding and post-result checks. The Runtime segment
of `runtime-recovery-shared.patch` is now an applied-source record; the remaining
BUILD segment can be selected with `--include=telegram-ios/Tests/Exteraless/BUILD`.

## Postimage check: initial startup guard

Checked in `ExteralessPluginRuntime.swift` on 2026-11-15, **source only**:

- `107–144`: `startup == nil` is an active-task guard. Both initial and continuation
  tasks clear the field in `defer` (`127`, `139`), including the recovery-failure
  path. The existing-continuation branch (`120–132`) precedes the new-Host-only
  `host == nil, startupError == nil` guard (`133`).
- `677–703`: manager-aware maintenance awaits the preceding startup task before
  acquiring the native lease and capturing the same-Host continuation receipt.
  The helper's operation is also cleared in its `run` defer before that task ends.
- `744–773`: successful same-owner finish reopens the real Host lease, sets
  `toolsRecoveryRequired` to false, acknowledges the receipt and clears the old
  recovery error. It clears `settingsMaintenanceID` before calling `start()` and
  checks the captured account generation, account availability and termination.
- The acknowledged helper is `.pendingRecovery` with no active operation, so
  `canContinue` is true. With the current engine policy enabled, the retained
  `startup == nil` guard therefore admits this same-Host continuation. Master-off
  deliberately leaves it pending; `setRuntimeMode` has the cold-Host branch at
  `830–847` for a later enable.

The original completed-task obstruction is closed in the applied source. Failed
reconciliation/account retirement still does not authorize startup. These are
postimage/control-flow findings, not an executed Keep-current or native-pass claim.

Current Runtime SHA-256:
`6998d97a25376dcdc8f9b965ef5fcc4f1a3309b309b30fd74e9c90ed13f019ee`.

## Regression fixtures

### Host / SwiftPM — six tests

`swift/PluginHost/Tests/PluginHostTests/PluginRuntimeStartupContinuationTests.swift`
uses the existing `MaintenanceTestEngine`/Host fixture and the shipping helper:

- Blocked cold recovery, real `wasRunning=false` lease completion, same Host,
  concurrent/repeated continuations, one initialization/preparation/completion;
  actual install/settings manager operations work afterwards.
- Failed reconciliation preserves the block and zero initializations.
- Retired/replaced account generation cannot start, including account availability
  returning while the old request still carries its retired generation.
- Current master/safe-mode policy is reread after preparation; a later allowed
  continuation does not repeat completed stages.
- Foreign, premature and replayed maintenance receipts cannot clear or reintroduce
  the recovery block.
- An actual fake-engine initialization failure is published and cannot be retried
  as recovery; no second initialization or finalize occurs.

Manual waits are finite (1 s native maintenance, 2 s fixture barriers). The
ordinary successful startup fixtures use no external plugin; the one manager
positive control loads only the existing self-owned fake-engine fixture.

### Native adapter + real journal — two tests

`telegram-ios/Tests/Exteraless/RuntimeRecoveryContinuationTests.swift` calls the
**shipping `ExteralessToolsHostMaintenance` adapter**, the shipping continuation,
and actual Core `inspectRecovery` / `reconcileKeepingCurrent` with a fake engine:

- Ambiguous v2 journal -> cold-start refusal -> Keep current -> evidence retained,
  active journal retired, identical client/plugin bytes -> one ordinary start and
  working subsequent manager maintenance, with zero finalize/reinitialize.
- Changed review fails reconciliation without startup; a later valid reconciliation
  followed by account retirement still starts no Python.

The fixtures use isolated temporary files, an injected no-credentials store and
synthetic scope identities. They install no plugins and access no real accounts.

## Build needs and verification

- The new helper is automatically included by `swift/PluginHost/Package.swift`
  and `swift/PluginHost/BUILD.bazel`'s existing source glob. No application dependency
  is added for the Runtime callsite: it already imports PluginHost.
- The pending BUILD segment adds
  `//Tests/Exteraless:RuntimeRecoveryContinuationTests` and its test library to the
  existing native test BUILD. It links TelegramUI, PluginHost and ExteralessCore
  to exercise the actual public Tools adapter, using the existing Runner/test host.
- Coordinator: from `swift/PluginHost`, run `swift build --build-tests`, then
  `swift test --skip-build --filter PluginRuntimeStartupContinuationTests`
  with a **30 s test-process limit**. Preserve the existing Host
  regression cohort.
- On the configured Mac, run the new target via the repository-supported
  `build-system/Make/Make.py test --target //Tests/Exteraless:RuntimeRecoveryContinuationTests`
  with the normal configuration/codesigning arguments from `telegram-ios/CLAUDE.md`.
  Compile/link time is separate from the bounded fixture execution. The full
  `Telegram/Telegram` build is required to verify the shared Runtime composition.

Read-only checks passed against the current working source:

```text
git apply --reverse --check --include=telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift docs/wave-2/runtime-recovery-shared.patch
git apply --check --include=telegram-ios/Tests/Exteraless/BUILD docs/wave-2/runtime-recovery-shared.patch
```

The first confirms all Runtime postimages; the second confirms the remaining
BUILD hunk is applicable. Source-order checks also confirmed the startup-task
defers, lease/ack/gate/start ordering, SDK authority/atomic pins and F02 read token.
Local Swift/Xcode execution is unavailable in this Windows environment.
**The eight tests are supplied, not reported passing.** Host CI is coordinator-owned;
native target wiring is Build-owner-owned. Actual startup/error publication still
requires compilation and native execution of the applied composition.

Historical pre-application preflight passed for both hunks and all five owned files.
In-memory patch application preserved the then-current SDK authority/atomic-pins
methods and settings read/action section byte-for-byte. Runtime SHA-256 before
coordinator application (not the current postimage):
`6ed178c0fa45272c8a59aeaf019c74a00821416de32216a65aa71153bfe21a85`.
This fingerprint records the checked source, not a Swift/native test result.
