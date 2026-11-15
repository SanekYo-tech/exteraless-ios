# Privacy extras remediation — A–D and SC07 caller binding

The four source defects from `privacy-extras-integration.md:59–204` are fixed in
the owner helpers. The already-applied Root/AppDelegate/PasscodeUI/notification
integration remains coordinator-owned. The prior Core/source CI results are not
execution evidence for these changes or the actual native initialization race.

## Changes / fixture matrix

| Finding | Production fix | Meaningful bounded fixtures | Status |
|---|---|---|---|
| A · raw-primary unlock before root install | `ExteralessPrivacyExtrasIntegration` supplies **`ExteralessClientRuntime.shared.accountPresentationReady(for:)`** to `exteralessAwaitHiddenAccountPresentation`, alongside actual primary identity and foreground. The public native wait keeps 5.0 seconds. Opaque consumed authorization still passes through `finishUnlock`; only existing PasscodeUI may unlock after its lifecycle check. | Native `testAActualWaitDoesNotFinishAtRawPrimaryBeforeInstalledRoot`, `testAReadyStateCannotReviveRetiredAuthorizationAndBackgroundFailsClosed`, `testAWaitTimeoutAndDisposalDoNotCompleteLateOnReadiness`. These drive the actual production signal implementation; raw B alone produces no completion, installed B permits one continuation, a retired grant still fails, timeout/background/cancel cannot revive it. | Source fixed; native execution/frames pending |
| B · incomplete evaluation treated as allow | `FilteringDecision.notificationDisposition` returns **suppress before awaitMessage before allow**. Both native message consumers call `exteralessNotificationMessageDecision`; main batch admits only `.allow`, extension retains `.awaitMessage`. `exteralessFilteringAlbum` uses the actual peer + **message namespace** + thread + group key. | Pure `FilteringNotificationRemediationTests` (3 methods) uses a one-operation real NFA budget, the existing bounded input limit, invalid-rule and known-hide priority. Native `testBBothNativeNotificationConsumersRejectIncompleteActualEvaluation` drives both production consumers and the real delivery gate without Keychain; `testBActualAlbumScopeIncludesMessageNamespaceAndThread` makes a local/thread peer's blocked text unable to filter the cloud album. | Source fixed; fixtures pending execution |
| C · absent reveal/failure invalidation; same-ID object replacement | Private `configurationRevision` advances only for private configuration publication. The policy's presentation callback feeds `HiddenAccountPresentationLock`, which has an independent revision and ordered/coalesced drain. Consume/reveal, cancellation and failed finish/abandon wake existing subscribers. `HiddenAccountSnapshot` compares **`ObjectIdentifier(actual Account)`** only for identities present in both snapshots; replacement retires the old attempt, selecting existing A→B does not. Filtering leases also replace only for a different Account object. | Pure nesting/cross-thread reentry, concurrent monotonic revisions, same-account reveal/failure, expected A→B, actual object replacement and stale-cancellation/finish fixtures. Native `testCNativeChangesPublishSameAccountRevealAndFailedFinish` observes the real helper signal; `testCNativeReloadObserverCanReadFromAnotherThreadOutsideAllStateLocks` covers direct reload and nested **configure → reload** with a 0.5 s reader bound. | Source fixed; fixtures pending execution |
| D · unknown loader equated with empty, or panic trapping empty app | `HiddenAccountSnapshot.hasAccountSnapshot` starts false and becomes true only from native `update` or confirmed `clearContext`. Before that, stored account-code keys retain alternate routing even without a panic code. Confirmed available empty snapshots route to ordinary native PIN/biometry despite a stored panic code. No account/attempt is fabricated; unavailable storage remains closed. | Pure loader/live/retired/confirmed-empty matrices. Native `testDNativeColdStoreAndConfirmedEmptyRoutingNeverMutatePrivateCodes` invokes the actual helper factory/bootstrap/reload/update/clear and compares injected secret bytes; `testDConfirmedClearBeforeConfigureIsNotLostToGlobalPanicCode` exercises the Root-before-integration path. | Source fixed; fixtures pending execution |
| SC07 · actual durability root | Stable signatures below pass the **actual OS-provisioned container** unchanged to `ClientSettings`. Configure cache compares requested root, storage URL, keychain scope and role; a new root is validated by a new store instead of being silently memoized as the old root. Root/scope cache fields commit only after successful validation. | Native `testDurabilityRootAndKeychainScopeParticipateInActualConfigureCache`: nil OS-temp inference, explicit OS temp root, same-root idempotence, invalid-root rejection and recovery, scope change. | Source fixed; coordinator supplies existing container URL |

## Locking detail (the suggested nested-lock hunk was not copied)

`ExteralessHiddenAccounts` previously called `publish()` while holding its recursive
state lock. Releasing a newly nested lock around `changesPromise.set` would still
invoke public callbacks under the outer acquisition.

The actual state mutex is now `HiddenAccountPresentationLock`:

1. Its `NSRecursiveLock` tracks every acquisition, including state getters and
   `configure → reload`. A policy callback only increments the presentation revision
   and marks it dirty while any outer state acquisition remains.
2. At the outermost release, the revision is queued **before** releasing the state
   mutex. The drain runs **after** that release. This preserves writer order even
   when a second thread gets the state mutex before the first begins delivery.
3. The drain's separate lock is released before calling the ValuePromise/public
   observer. Reentrant publications are coalesced by the current drain instead of
   recursing or publishing an older revision after a newer one.
4. `HiddenAccountPolicy` releases its own mutex before requesting presentation
   invalidation. Native outer-lock depth still defers actual delivery when the
   mutation came from `updatePolicy`, configure, reload or settings mutation.

There is no callback from `updatePolicy` that publishes under a surviving native
state lock. Configuration revision is not reused as a UI revision. A display-only
invalidation does not call `policy.update` or cancel an authorization. Successful
finish relies on the subsequent real AppLock state emission, avoiding an empty
hidden-root repaint between finish and unlock. Failed/stale finish publishes
without clearing a newer opaque continuation.

The new global cancellation branch is conditional on actual Account-object
replacement. Existing confirmed teardown still cancels; shared PasscodeUI's
non-nil owned-attempt cancellation remains unchanged. Expected A→B preserves both
objects and the consumed grant. No newly introduced path invokes native panic or
logout during cancellation, snapshot loading, readiness changes, or tests.

## Stable API / coordinator boundary

Owned TelegramCore API:

```swift
public func configure(
    basePath: String,
    accessGroup: String,
    isMainApp: Bool,
    keychainScope: String? = nil,
    durabilityRootURL: URL? = nil
) throws
```

Owned TelegramUI helper:

```swift
func exteralessPrivacyExtrasConfigure(rootPath: String, durabilityRootURL: URL) throws
```

The implementation forwards `durabilityRootURL` to
`ClientSettings(storageURL:secretStore:durabilityRootURL:)`. Production callers
supply the existing `FileManager.containerURL(...)` result, **not** the
`telegram-data` child. Nil remains supported for isolated fixtures where Core can
infer the OS temporary/home root. The injected storage factory is internal to
TelegramCore and used only by native fixtures; the default constructor still uses
the entitled device-only Keychain backend.

No additional shared hunk is required for A–D: A now reads the installed-root
signal the app integrator already supplied. Existing PasscodeUI keeps the opaque
attempt/authorization/lifecycle rechecks. Root/AppDelegate/Share/NotificationService
container argument insertion remains with the coordinator as agreed. The earlier
post-commit replay invalidation handoff remains with its shared owner.

## Owned files in this remediation

- Core: `HiddenAccountPolicy.swift`, new `HiddenAccountRuntimeState.swift`, new
  `FilteringPolicyNotifications.swift` under `swift/ExteralessCore/Sources/ExteralessCore/`.
- Native Core: `ExteralessHiddenAccounts.swift`, `ExteralessFiltering.swift`,
  `ExteralessFilteringNotifications.swift`, new `ExteralessHiddenAccountPresentation.swift`
  under `TelegramCore/Sources/ExteralessPrivacyExtras/`.
- UI: `PrivacyExtras/ExteralessPrivacyExtrasIntegration.swift` and
  `PrivacyExtras/ExteralessNativeHiddenSettingsAuthorization.swift` only.
- New pure fixtures: `HiddenAccountRemediationTests.swift` (8 methods) and
  `FilteringNotificationRemediationTests.swift` (3 methods).
- New native fixtures: `TelegramCore/Tests/ExteralessPrivacyExtrasRemediationTests.swift`
  (10 methods). They use synthetic messages/identity tokens, temporary files, an
  injected secret store/storage factory and injected gate dependencies. They never
  construct an Account/AccountManager or call real Keychain/passcode/logout/panic.
- This report. No shared pipeline source or BUILD was edited in this remediation.

Existing recursive source/test globs pick up the new files. The native test library
uses ExteralessCore and SwiftSignalKit; build ownership can verify its explicit
Core dependency. The UI remains free of Postbox imports/access, and TelegramCore
has no PasscodeCore/UIKit/Display dependency introduced by these changes.

## Verification status

Scoped tracked-file `git diff --check` passed. Bounded read-only checks also passed
for all 13 remediation source/test/report files: UTF-8/whitespace, native/UI import
boundaries, actual root-ready wiring and five-second production wait, shared
three-state notification decision and namespace key, publication drain outside both
locks, actual object-token comparison, snapshot routing, durability-root forwarding
and cache identity, and the 8 + 3 + 10 new fixture methods. These are source checks,
not execution of Swift. The new native fixture has no production `.shared` helper,
PasscodeCredentialStore, AccountManager, logout or panic-effect invocation.

The 21 added fixtures are new proof obligations, not covered by the earlier
80/280-test receipts. `Get-Command swift, swiftc` returned no compiler in this Windows
session, so no new XCTest or UIKit result is claimed. No CI/commit/push or live-account
operation was performed.

Coordinator/native verification after build should run only the new Core suites
and `ExteralessPrivacyExtrasRemediationTests` first, with bounded test-process
timeouts. The one-operation NFA fixtures contain no catastrophic regex. Native
timer fixtures shorten only the internal fixture clock to 0.05 s; the exported
production wait remains 5.0 s. Cross-thread lock fixtures wait at most 0.5 s, so a
regression produces a failure instead of hanging the test process.

The coordinator's UTF-16 Zalgo **projection/sourceOffsets** fix is preserved and
matches the current HEAD source; this remediation does not edit
`FilteringTextPolicy.swift` or its existing tests. Preserved LF-source SHA-256:
`2546593c4319f96ee6efc16b04eb80b63991cabd7d99068bdd41c79a9365f690`.

### Remaining native/frame evidence

Record synthetic A→B with primary ready before the installed root, slow root and
timeout, same-account reveal, same-identity Account replacement, cancellation and
background. The native cover must stay until the actual target root is installed;
old-account content must never flash. A retired authorization must remain rejected
even if that root later becomes ready. Same-account reveal and failed finish must
refresh the one-way Dialogs projection without touching credentials or read state.

For notifications, use the bounded incomplete/reversed case in both foreground
and service-extension/deadline paths: no title, body, sound, attachment or sender
intent can be presented, and a different message namespace cannot join its album.
For D, record loading versus a confirmed logged-out app with a stored panic code;
ordinary PIN/biometry remains the stock route only after confirmation. Any effect
recording must remain injected/synthetic. Independent privacy review and labelled
frames are still required; this report grants no native/visual pass.

## Independent-review follow-up — PR01 / PR03 / PR06 / PR12 / PR13

Source basis: read-only `reviews/privacy-retention.md` (A–D marked source-closed
there). This follow-up edits only PrivacyExtras helpers, their Core/native fixtures
and this handoff/typed contract. It does not change the independent report or
Root/AppDelegate/ApplicationContext/Share/NotificationService/Account sources.

| Finding | Implemented helper fix | Regression fixtures | Status |
|---|---|---|---|
| **PR01 P1** chat-list trap | Completely inactive `exteralessFilterChatList` returns the original EngineChatList. A peer-inactive summary performs no preview/history lookup. Every active cursor uses `MessageIndex.upperBound(peerId:namespace:)` and matching lower bound; forum pages use native `getMessagesWithThreadId`. Thread read metadata stays scoped and retains `isMarkedUnread`. | `ExteralessFilteringSummaryReviewTests.testPR01ActualOneRowChatListOffAndOnForOrdinaryForumAndSecret`, `testPR01ActiveForumPagesStayInTheRequestedThread`. They seed a real in-memory Postbox and call the same `exteralessFilterChatList` implementation as the Account facade, not a policy-only model. They compare unchanged native messages/read/PTS/QTS/seq plus preserved list metadata. | Source fixed; native execution pending |
| **PR06 P2**, filtering part | Secret histories have separate cursors for **SecretIncoming=2** and **Local=1**. Cursor heads merge chronologically for preview; row reads and NFA operations share the caller's budget. Unread coverage is checked per namespace, with full MessageId deduplication; no numeric-ID union. Unknown preview ordering/coverage remains unknown. | `testPR06SecretIncomingAndLocalUseDistinctNativeRowsAndOneBudget` (one real incoming plus local outgoing, same numeric ID, two-row/one-row bounds); `testPR06IdenticalNumericIdsDoNotMergeUnreadAcrossNamespaces` (legacy Local incoming and SecretIncoming, same numeric ID, two separate deductions). | Source fixed; capture/delete/TTL retention part remains with retention owner |
| **PR03 P1**, helper side | The source now returns `ExteralessAdmittedNotificationBatch`, carrying immutable batch ID, full account identity/object and filtering+hidden revisions captured with evaluation. `performIfCurrent(account:effect:)` checks immediately before each synchronous sound/vibration/enqueue, each at most once. Supersession/disposal cancels outstanding admission, including downstream-held callbacks. No MainActor sync token or late recapture. | Four `FilteringNotificationAdmissionTests` methods; two controlled-stream `ExteralessPrivacyAdmissionReviewTests` PR03 cases. The paused consumer is verified reached before filter/hidden revocation; actual filter settings are changed in an isolated native runtime; all effect recorders stay empty after release. Unchanged-policy/duplicate/supersession/disposal controls are included. | Helper source fixed; **ApplicationContext typed carry/effect-guard insertion remains app-owner work** |
| **PR12 P2** premature panic notification cleanup | Removed planned-ID `panicDidBegin`. Native AccountManager transaction returns `ExteralessAdmittedPanicIdentity` only from the actual record transition. Temp/private effects and the new main-thread `panicDidAdmit(identity)` callback consume that result. Missing/ambiguous backup or environment, wrong record/user/environment produce no transition/proof/effects. The callback is captured for the already-authorized operation, so root teardown cannot lose admitted cleanup. | Two PR12 native-model fixtures construct synthetic AccountRecord values and injected effect recorders. Rejected/missing records have zero cleanup callbacks and unchanged original records; matching admission reaches only its full identity. No AccountManager instance, production panic/logout or UNUserNotificationCenter is invoked. | Source fixed; native execution pending |
| **PR13 P2** FilteringRuntime observer deadlock | FilteringRuntime now uses the same **outermost-release coalesced drain** as hidden C. Nested `setPeer → setCollection → ClientSettings.set → reload` retains RMW serialization while postponing runtime observers until the outer runtime lock is released. UInt64 `revision` is available to admission; existing UInt32 `generation`/changes retain their presentation API. | `testPR13RealNestedCollectionWriterPublishesAfterOutermostRelease` uses the actual writer and a cross-queue reader with a 0.5 s failure bound; `testPR13ConcurrentRMWKeepsEveryPeerAndMonotonicRevisions` verifies eight concurrent additions survive with monotonically published revisions. | Source fixed; native execution pending |

### PR03 early API contract and app-owner closure

The exact stable signatures and the ApplicationContext carry/guard placements are
in **`docs/wave-2/privacy-notification-admission-contract.md`**, published before
helper completion. `exteralessPrivacyExtrasNotifications` changes return type in
place to `Signal<ExteralessAdmittedNotificationBatch, NoError>`; there is no raw
compatibility path that silently drops admission. The app owner must carry the
same `admission` through the existing EngineData result and lock callback, and
wrap the three existing effect calls. No permission Bool may be cached across an
async hop. The extension's existing delivery gate remains independent.

The guard captures two full-width revisions before evaluating the batch and checks
again after evaluation. It uses the actual live Account object, not just a reused
record ID, and permanently revokes mismatches/ABA. Each effect closure is synchronous
and runs outside all admission/state locks. Policy changes after one admitted sound
stop subsequent effects; the contract does not claim to undo a sound already played.
The stream owns one admitted batch at a time and retires it on next batch/disposal;
completion of a preparation transaction alone does not expire its downstream lease.

### Native query / namespace details

All active fetch bounds have the **same peer and message namespace**. The 128-row
buffers are per namespace, and rows are charged when fetched, not only when a
matching thread or visible message is found. Forum fetches carry their thread ID
to Postbox instead of reading unrelated peer history and filtering it afterwards.
Secret namespace 1 and 2 may reuse integer IDs; keys remain native MessageIds and
the projected read-state entries preserve each original namespace and boundary.
Unread precision requires coverage in every counted namespace. If a shared bound
prevents sampling a stream's head, it cannot supply an invented latest preview.

The native fixtures call an internal `exteralessFilterChatList(account:postbox:list:runtime:)`
implementation also used by the public Account facade. They construct only a
temporary in-memory Postbox and native peer/message values, avoiding Account/Network
initialization. All list/history/summary queries under test are actual Postbox calls.

### Additional owned files / verification boundary

- New native helpers: `ExteralessNotificationAdmission.swift`, `ExteralessPanicAdmission.swift`.
- Updated native helpers: `ExteralessFiltering.swift`, `ExteralessFilteringSummaries.swift`,
  `ExteralessFilteringNotifications.swift`, `ExteralessHiddenAccounts.swift`.
- Updated owned UI: `ExteralessPrivacyExtrasIntegration.swift` (`panicDidAdmit`) and
  `ExteralessLocalFiltersController.swift` (inactive preview status).
- Core admission state added to `FilteringPolicyNotifications.swift`.
- New fixtures: `FilteringNotificationAdmissionTests.swift` (4),
  `ExteralessFilteringSummaryReviewTests.swift` (4),
  `ExteralessPrivacyAdmissionReviewTests.swift` (6): **14 tiny tests**.

Scoped tracked-source `git diff --check` passed during implementation. These are
new fixtures; prior A–D/80/280-test receipts do not establish their result. Local
Swift/Xcode remains unavailable, and no CI/commit/network or real-account operation
was run. The Postbox fixtures bound each wait to 3 s, the cross-queue deadlock fixture
to 0.5 s; native test process execution should remain bounded to 30 s per selected
suite after the coordinator's build. Native/visual acceptance remains pending.

Final PR-source check: **14 changed/new helper/test/contract files passed** bounded
UTF-8/whitespace and architecture checks; all history fetch bounds are peer/namespace
local, secret cursors include 1 and 2, admission is captured before batch evaluation
and carried as a typed value, panic notification cleanup consumes a post-CAS proof,
and FilteringRuntime has no direct observer publication under its recursive writer.
The fixture inventory is exactly 4 Core + 4 native summary + 6 native admission tests.
The preserved Zalgo SHA-256 still matches the A–D receipt above. These checks do not
execute Swift, SQLCipher, signals, UIKit or a real account.
