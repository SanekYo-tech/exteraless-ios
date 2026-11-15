# PR03 — main notification admission contract

Stable helper API for the app integrator. The helper implementation is owned by
PrivacyExtras; `ApplicationContext.swift` wiring remains app-integrator-owned.
No change to the service-extension delivery gate is required for this contract.

## Types and entry point (TelegramCore)

```swift
public enum ExteralessNotificationPresentationEffect: Hashable, Sendable {
    case sound, vibration, enqueue
}

public struct ExteralessNotificationRevision: Equatable, Sendable {
    public let filtering: UInt64
    public let hidden: UInt64
}

public final class ExteralessNotificationAdmission {
    public let batchId: UUID
    public let accountIdentity: PrivacyExtrasAccountIdentity
    public let revision: ExteralessNotificationRevision

    public func isCurrent(account: Account) -> Bool
    @discardableResult
    public func performIfCurrent(account: Account,
        effect: ExteralessNotificationPresentationEffect,
        _ action: () -> Void) -> Bool
    public func cancel()
}

public struct ExteralessAdmittedNotificationBatch {
    public let messages: ExteralessNotificationMessageBatch
    public let admission: ExteralessNotificationAdmission
}

public func exteralessPrivacyExtrasNotifications(
    account: Account,
    source: Signal<ExteralessNotificationMessageBatch, NoError>
) -> Signal<ExteralessAdmittedNotificationBatch, NoError>
```

The existing helper changes its return type in place. The message tuple stays
`([Message], PeerGroupId, Bool, MessageHistoryThreadData?)`; no new Postbox import is
needed by a caller already consuming it. `batchId` is an opaque per-batch UUID,
not a peer/message ID or an account slot. The full native account identity and
Account object are bound before the batch leaves the filtering transaction.

## Required ApplicationContext changes

Carry the **same** `admission` through every EngineData/lock-state async hop:

```swift
|> mapToSignal { delivery in
    let messageList = delivery.messages
    let admission = delivery.admission
    return engine.data.get(/* existing ChatListIndex map */)
    |> map { indices in
        let filtered = /* existing messageList.filter using indices */
        return (filtered, admission)
    }
}
// Existing main-queue delivery remains.
// In next: retain admission alongside messageList.
// The nested appLockContext.isCurrentlyLocked callback captures that admission.
```

After the final existing lock/lifecycle/context checks, replace each immediate
effect call with its own guard (using **strongSelf.context.account**, not a stale
captured Account to substitute for the receiver):

```swift
admission.performIfCurrent(account: strongSelf.context.account, effect: .sound) {
    serviceSoundManager.playIncomingMessageSound()
}
admission.performIfCurrent(account: strongSelf.context.account, effect: .vibration) {
    serviceSoundManager.playVibrationSound()
}
admission.performIfCurrent(account: strongSelf.context.account, effect: .enqueue) {
    strongSelf.notificationController.enqueue(/* existing item */)
}
```

Keep the native muted/imported/service-message/chat-visible/restriction/preview
conditions. An optional early `isCurrent(account:)` can drop expensive work, but it
does not replace the effect guards. Do not cache its Bool across a callback, and do
not create or recapture an admission on main. This is **not a MainActor sync token**.

`action` is nonescaping and synchronous. Do not schedule a later presentation
inside it; guard again at that later boundary instead. A successful call admits
that immediate effect under the checked policy; a subsequent policy change
revokes subsequent effects rather than attempting to undo an already-played sound.

## Revocation and exactly-once rules

- Admission records filtering and hidden-state revisions while evaluating the
  actual account's batch. Changes during evaluation produce no admitted output.
- Every effect rechecks both revisions, account identity/object and live native
  notification eligibility. Hide/unhide ABA, changed filters, account retirement,
  or receiver mismatch cannot grant an old batch a new lifetime.
- Sound, vibration and enqueue are each admitted at most once per batch. A
  repeated callback cannot replay an effect; revocation prevents all remaining
  effects. No UI callback runs while an admission/state mutex is held.
- A newer source batch retires its predecessor. Disposing the source subscription
  revokes outstanding admission, including callbacks already downstream. Explicit
  `cancel()` is idempotent. Empty/fully filtered/incomplete batches grant no effects.
- Native extension delivery keeps its existing gate. This adds the analogous
  revocation boundary to the main-app path, preserving all protocol/read finalizers.

## Acceptance fixture

Hold EngineData/lock completion after helper output, change either matching-filter
policy or hidden-account policy, then release it while the app is unlocked. The
injected sound/vibration/enqueue recorder must remain empty. Repeat with source
disposal, next-batch supersession, same record/user with a different Account object,
and late duplicate completion. The unchanged-policy control admits each effect
exactly once. Use tiny synthetic data; no network, actual sound, notification UI,
Keychain account, panic or logout runs in the fixture.

Implementation/test status is appended to `privacy-extras-remediation.md`; this
contract alone is not a native/runtime pass.

The declared helper API is now implemented in `ExteralessNotificationAdmission.swift`
and the typed `exteralessPrivacyExtrasNotifications` source. The ApplicationContext
consumer conversion remains with the app owner; its old raw-array consumer must
not be compiled as though the admission value were an array.
