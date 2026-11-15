# Ghost toggle: final admission handoff

**Status: source-closed** for the legacy per-field writer and the two batch writers'
locked/default-presence defects. This handoff records source integration and local
source checks; fresh Core or native execution is pending.

## Exact files

| File | Change |
|---|---|
| `swift/ExteralessCore/Sources/ExteralessCore/PrivacyGhostModeMutation.swift` | New shared synchronous mutation API. |
| `swift/ExteralessCore/Tests/ExteralessCoreTests/PrivacyGhostModeMutationTests.swift` | Nine real-file Core regression tests. |
| `telegram-ios/submodules/TelegramCore/Sources/State/ExteralessOutgoingPrivacy.swift` | Only `exteralessToggleGhostMode(account:)`: replace the per-field `set` loop. |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift` | Only `ExteralessClientSettingsWorker.toggleGhost(context:operation:completion:)`: use the shared API with the captured snapshot. |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Pills/ExteralessPillRuntime.swift` | Only `ExteralessPillRuntime.toggleGhost(completion:)`: use the shared API inside `lease.withCurrent`. |
| `docs/wave-2/ghost-toggle-final-admission.md` | This additive handoff. |

## API and mutation contract

```swift
public enum PrivacyGhostModeMutation {
    @discardableResult
    public static func toggle(
        in settings: ClientSettings,
        expectedBefore: ClientSettingsSnapshot? = nil
    ) throws -> Bool
}
```

- `before` is one immutable snapshot: the supplied `expectedBefore`, or one cache
  read. `PrivacyPolicy(values: before.values)` selects the target and supplies
  `ghostModeChanges(enabled: !policy.ghostModeActive)`.
- Every unlocked field receives that target, including the inverse polarity of
  `sendOfflinePacketAfterOnline`. The original policy ignores locked fields when
  computing active state and keeps their values when producing changes.
- All five values and all five `Locked` flags enter the affected CAS set. An
  unchanged stored dependency goes into `values` with its exact previous value;
  an absent dependency goes into `resetting`. Thus absent defaults stay absent,
  explicit stored defaults stay stored, and locked values/presence are preserved.
- Exactly one `applyPublic(values, resetting: resets, expected: before)` performs
  the operation. Its existing disk value/presence CAS, atomic replacement, cache
  publication, durability errors and observation semantics remain authoritative.
- The result is the successful batch's captured projected `ghostModeActive`.
  All-locked is a guarded no-edit operation returning **true**. A synchronous
  observer's subsequent edit cannot replace the first operation's return value.
- Errors propagate. Pre-replace failure preserves the old complete state;
  post-replace durability failure can expose the complete committed state while
  still throwing, as required by `ClientSettings`.

The helper executes synchronously on each existing worker. The Settings worker
retains both context/operation checks, including the check after snapshot capture.
Pills retains `lease.withCurrent`, cancellation handling and the existing guarded
main-queue completion. The native Privacy UI/PeerInfo path retains its worker
`runOn`, storage-error forwarding, and status-request continuation reached only
after a successful local mutation; existing network-error handling is retained.

## Core fixtures

All fixtures use actual `ClientSettings` files, isolated temporary durability
roots and an injected secret backend. Expected toggle values are explicit test
data. Disk bytes, stored-key presence and observer snapshots are checked directly.

| Test | Contract |
|---|---|
| `testBothDirectionsAndResetWriteAndObserveOneCompleteGeneration` | All five values toggle both ways; one replacement and one complete observation per edit; disabling stores explicit defaults; reset removes overrides; next toggle survives reopen. |
| `testMixedLockedValuesKeepAbsenceExplicitDefaultsAndOverrides` | Locked absent/default/non-default values and explicit/absent lock flags retain presence; unlocked values change both ways; unrelated setting survives. |
| `testAllLockedReturnsActiveWithoutAReplacementOrObservation` | Repeated all-locked calls return true with identical bytes, values and presence, zero replacements and zero observations. |
| `testPreAndPostReplaceFailuresExposeOnlyWholeStates` | Real pre/post-rename fault seams propagate errors and publish only the complete old/committed state; retry starts from the actual state; temporary files are removed. |
| `testStaleLockValuesRejectEveryGhostLock` | A second store changes each of the five stored lock values; stale CAS rejects without a local replacement. |
| `testStaleValuesRejectUnlockedAndAllLockedSnapshots` | Each ghost value is externally edited with fixed presence, both unlocked and all-locked; even a planned no-edit rejects stale values. |
| `testPresenceOnlySetAndResetRejectEveryGhostDependency` | External default insertion and reset for all ten dependencies reject stale presence while effective values remain equal. |
| `testSuppliedBeforeIsNotReplacedByARefreshedCache` | Explicit expected snapshot remains authoritative after local reload of an external edit. |
| `testResultBelongsToThisProjectionEvenIfAnObserverTogglesAgain` | Reentrant observer performs another real toggle; the first return value still identifies its own projection. |

Fault injection uses the existing `ClientSettingsFileHooks(beforeFileReplace:)`
and the separate internal initializer's `afterFileReplace:` argument. The hooks
only count/throw and never re-enter a store. External-writer cases use a second
real store between snapshot capture and CAS, with no sleeps or scheduling races.
There are 36 bounded external-writer cases and two failure cases with tiny files;
the intended test-run budget is <=30 s after compilation, not measured locally.

Targeted execution when a Swift host is available:

```sh
swift test --package-path swift/ExteralessCore --filter PrivacyGhostModeMutationTests
```

## Verification and coordinator handoff

- Local: `python docs/wave-2/tests/privacy_source_fixtures.py` — **10 passed**
  (0.013 s; existing static privacy contracts).
- Local: scoped `git diff --check`, whitespace checks including the two new Swift
  files, and comparison against HEAD outside each of the three toggle functions —
  passed. Source search finds exactly those three native helper call sites.
- Read-only evaluation of the existing stage `source_inventory` and the Core
  `Sources/ExteralessCore/**/*.swift` glob includes the new helper. Existing
  `Package.swift` discovers the new test file; Stage/BUILD edits are unnecessary.
- Known prior macOS baseline: **671 Core tests passed**, recorded in
  `docs/wave-2/runtime-native-acceptance.md`. That run predates these nine tests.
  This Windows host has no Swift/Swiftc or installed WSL; the new Swift tests,
  their duration, and native Privacy UI/PeerInfo/Pills execution are unverified.
- Pin refresh belongs to the coordinator after final composition: the worker edit
  changes the raw SHA of `ExteralessClientRuntime.swift`, the Config root source.
  Derive the Config-pinned manifest/receipts from that final Root raw SHA.
