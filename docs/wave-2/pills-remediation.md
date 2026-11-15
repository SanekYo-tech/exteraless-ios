# PillStack remediation — FPP-09 / FPP-10

Review: [reviews/feed-player-pills.md](reviews/feed-player-pills.md).
Both fixes are implemented in source. New regression suites have **not executed
locally**: `swift` is unavailable on this Windows host. The earlier 23 Pill Core
tests in the coordinator's green 280-test `b142` baseline do not prove these fixes.

Bounded local source checks passed: lexical/whitespace validation of the five
changed/new Swift files, independent action/pre-factory identity gate, single
pending-value/timer and uniform 250ms bound/cancellation wiring, all ten new test
references, current 31-test Pill Core count, and parity JSON. `git diff --check`
also passed. These checks do not execute the new Swift tests or UIKit.

## FPP-09 — independent, account-checked Settings entry

- `ExteralessClient/Pills/ExteralessPillIntegration.swift:13–20` registers the unique
  action **`pills.status` / Status Pills** in **Chats · Status pills**. Registration
  does not depend on active IDs, valid rate configuration, provider availability
  or header height. It remains reachable after the final pill is hidden.
- The action calls `ExteralessPillSettingsActionGate.open` before evaluating
  `ExteralessPillSettingsController(context:)`. That small main-actor gate requires
  the exact current context object and a valid current runtime lease. It never
  calls `update(context:)` or creates a replacement runtime for a saved old action.
- Thus the FPP-01 sequence A → B → saved action A is rejected before any controller
  factory/presentation. After `clearContext()` the same action is also rejected.
  The current B context/screens are not modified by the rejection.
- Original independent route: Android Java
  `app/exteraless/settings/OpenExteraAppearanceActivity.java:551–553` opens
  `PillStackSettingsActivity` without requiring a visible pill.

Native admission fixtures in `telegram-ios/Tests/Exteraless/PillSettingsEntryContractsTests.swift`:

1. `testCurrentAccountFactoryRunsForEmptyInvalidAndDormantLayouts` — factory and
   presentation remain admitted independently of layout payload/state.
2. `testSavedActionCannotRecreateRetiredAccountAfterSwitchOrClear` — real object
   identity/factory spies: A → B → old A, then clear; no new factory/presentation,
   B remains current, invalid lease does not evaluate its factory.

Build-owner binding: compile that test file with
`ExteralessClient/Pills/ExteralessPillSettingsAction.swift` in a Foundation/XCTest
native contract target. This tests the production admission helper without an
Account, location/network operation or UIKit screen construction. The registered
action and actual controller factory are verified by their source callsite;
end-to-end Settings/table interaction still needs a native UI run.

## FPP-10 — bounded latest-value trailing delivery in stable Core registry

`swift/ExteralessCore/Sources/ExteralessCore/PillPluginRegistry.swift`:

- Replaces drop-only `admit()` with one latest pending `PillModel` and one trailing
  timer per subscription. The first model still delivers immediately; updates
  inside the interval coalesce to the newest model at `last + 250,000,000 ns`.
- Every phase uses the same rate bound: ready/failed have no guaranteed/unbounded
  bypass. A synchronous loading → ready/failed burst ends loading without requiring
  another producer event. New updates do not push out the scheduled deadline.
- Native account/registry/owner-identity gates are rechecked at delivery. Token
  cancellation and unregister/replacement cancel the pending timer, clear the
  pending model and release consumer closures. The timer also carries its own
  identity to reject a cancelled scheduled invocation.
- Callouts/cancellation and client closure release are outside the delivery lock.
  Reentrant publication retains only the latest model; no per-update task queue is
  built. The public registry/provider/DTO API is unchanged.
- The internal `PillPluginDeliveryTiming` seam supplies a manual monotonic clock
  for exact deadline tests. Production uses a utility DispatchQueue/DispatchWorkItem.
  The deadline is at most 250ms after an update inside the window; actual OS thread
  scheduling/frame presentation is not claimed as a measured 250ms device SLA.

Eight new Core fixtures in `PillPluginRegistryTests.swift` use finite **native**
`PillPluginProvider.start` callbacks and do not depend on PluginPillBridge/Python:

| Regression | Evidence pinned |
|---|---|
| `testSynchronousLoadingReadyUsesOneTrailingDeliveryAt250Milliseconds` | Only loading before 249,999,999ns; ready at exactly 250,000,000ns; timer removed. |
| `testSynchronousLoadingFailureEndsLoadingWithoutAnotherProviderEvent` | A synchronous failed DTO terminates loading at the trailing deadline. |
| `testLiveSchedulerDeliversCachedReadyAfterSynchronousStart` | Production utility scheduler delivers the trailing value (one-second fixture timeout). |
| `testTerminalBurstsCoalesceLatestWithoutBypassingFourHertz` | Ready/failed burst plus 32 updates retains one timer/latest value and emits only once per 250ms. |
| `testCancellationBeforeTrailingRemovesPendingModelAndTimer` | Cancel before deadline removes timer and suppresses both trailing and late producer publications. |
| `testOwnerUnloadBeforeTrailingNeverPublishesTerminalModel` | Unregister invalidates pending terminal output. |
| `testSameIdReplacementCannotDeliverPreviousOwnersTrailingModel` | Same integer ID/new owner emits only its new trailing model; old pending/late values cannot cross. |
| `testAccountRetirementSuppressesPendingTrailingDelivery` | Retired account lease produces no trailing ready. |

The three previous registry tests remain. The total Pill Core fixture count is now
31 (previous 23 + eight new regressions). Run the `PillPluginRegistryTests` filter
under an external **30-second bound**; the fake-clock tests do not sleep, and the
live-scheduler smoke has a one-second wait. No CI was dispatched here.

## Native follow-through

The five-method PluginPill bridge wire/callback/mapping contract is retained. These
fixes operate in stable Core and the independent Settings entry, not in an optional
bridge-only delivery path. FPP-05 remains with Feed owner. Existing root/panel
assembly and the Network-owner passive RTT forwarding are not prerequisites for
the new Core regression fixtures.

Native UI evidence still required after build:

- Hide last pill, leave its screen, open **Settings → Status Pills**, enable Cache:
  the entry remains present and the header returns without a blank reserved gap.
- Invoke a retained Settings action from A after switching to B/clearing context:
  no screen/transition for A; B remains the active domain.
- Publish loading then ready/failed within one start: inspect recorded frames for
  the final value after the trailing slot and no stuck loading. Cancel/unload before
  that slot: no old terminal value appears on the new/hidden header.

No UIKit frame pass, new XCTest pass, account action, real provider request,
external plugin execution, commit/push or CI run is claimed by this remediation.
