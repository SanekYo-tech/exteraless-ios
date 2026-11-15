# FPP-01 remediation — ChatIntegration

Source fix for the P1 in `feed-player-pills.md:13–25`. The original review is unchanged.

- `ExteralessChatIntegration.open` no longer calls `update`, `clearContext`, or assigns
  the domain context. It first checks the immutable AccountContext identity.
- Account update registers fresh Settings callbacks capturing that activation's lease.
  Registration replaces callbacks by ID using the existing Settings registry contract.
  A retained old callback cannot borrow a new epoch after A → B → A.
- Feed, fallback Player, Bookmarks, Link Filter and the added Deletion Defaults screen
  are zero-argument **lazy factories**.
  `ChatContextPresentationScope.open` checks identity + epoch **before invoking a factory**;
  it rechecks before registration/presentation in case creation changed the account.
- `clearContext` retires the scope and invalidates only its existing weak screen set.
  Stale actions do not activate a context, create a controller, clear URL state, or
  invalidate any B screen. A live old window does not grant admission.

## Bounded proof fixtures

`swift/ExteralessCore/Tests/ExteralessCoreTests/ChatContextPresentationScopeTests.swift`
drives the **same scope used by the native integration**, with injected screen/factory
spies, no Account, network or UIKit construction:

1. A → B → four invocations of saved A: zero new A factories/presentations, zero B
   invalidations, B remains current; A's fake window remains alive.
2. Clear, then reactivate the same A identity: the old epoch is rejected both times,
   with zero factories; a newly leased A action is accepted.
3. A factory synchronously activates B: stale A is not published; only A is invalidated.

Tests are written, **not executed in this Windows session** (Swift toolchain absent).
The final read-only source contract check passed for all five constructors, including
Deletion Defaults. Constructors occur inside lazy
factory closures; the identity/epoch admission precedes `factory()`; `open` contains
no account update, clear or context assignment. This is source evidence, not XCTest.
Bounded coordinator command:
`swift test --package-path swift/ExteralessCore --jobs 1 --filter ChatContextPresentationScopeTests`.

No Root/App, Feed, Player or Pills implementation file was edited for this remediation.
Apple build and native runtime confirmation remain required before review closure.
