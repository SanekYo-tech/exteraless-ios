# NativeServices remediation: HNS-02 / HNS-03

Scope: NativeService helpers/tests and TelegramUI `ExteralessClient/PluginServices`.
Findings: `reviews/host-native-services.md`. This report covers the NativeServices
part of HNS-02 and HNS-03. It is source/fixture readiness, not a real-CPython or
UIKit runtime pass.

Coordinator CI follow-through: `43704564101 / 38d71afe` compiled and ran **158
Host tests**. The retiring-cleanup fixture failed its two reachability assertions:
it intercepted nonexistent `unload_json`, while the shipping Host calls `unload()`.
The fixture now intercepts the exact production entry. All cleanup/release assertions
remain; a new run must verify that the real cleanup branch actually executes.
The other new worker-revocation and terminal-delivery fixtures passed in that run.

## HNS-02: retiring cleanup uses the stored lease identity

`NativeServiceCleanupRoute` is now the production route for:

- `cancelOwnerTask(id) -> Bool`
- `nativeServiceCancel(id) -> Bool`
- `notificationUnsubscribe(id) -> Bool`
- `fileRemove(id) -> null`
- `intentRemove(id) -> null`

The request still contains the immutable C-injected `ownerToken`; the separate
`pluginId` argument is authoritative. The provider invokes this route before its
active-owner operations. Cleanup does **not** call `captureOwner`, read permissions,
resolve an account, or acquire a new owner capability.

Admission captures both `owner` and **`ownerWireToken: captured.wireToken`** in the
lease after the normal active-owner/token comparison. Removal compares the request
identity with that immutable stored identity **under the resource registry lock**.
No permission or `isOpen` check is needed to revoke an already-owned resource.
Missing/mismatched resources are idempotent false/null; malformed/unbound tokens
remain errors. An old token cannot cancel a replacement lease, even if the caller
submits the replacement's id. File-extension replacement is also protected.

```swift
public struct NativeServiceCleanupIdentity: Equatable, Sendable {
    public let pluginId: String
    public let ownerToken: String
    public init(pluginId: String, ownerToken: String) throws
}

// These only revoke existing resources and return whether one was removed.
NativeServiceOwnerScheduler.cancel(id: String, cleanup: NativeServiceCleanupIdentity) -> Bool
NativeServiceOperations.cancel(id: String, cleanup: NativeServiceCleanupIdentity) -> Bool
NativeServiceInterceptions.remove(id: String, cleanup: NativeServiceCleanupIdentity, file: Bool) -> Bool
```

`NativeServiceCleanupRoute.dispatch(...) -> PluginJSONValue?` is shared by the
real provider and the headless provider fixture. Unknown/non-cleanup operations
return nil, so the cleanup route cannot admit work or disclose an active owner.
The existing owner-taking native APIs remain available for internal native calls;
the bridge cleanup endpoints use the new identity-taking operations.

The generic pool's `ownerWireToken` argument defaults to nil for non-wire fixtures.
Such a lease **cannot** be removed through wire cleanup. Production and CPython
fixtures must supply the captured owner's token, never a newly looked-up owner or
an unvalidated model field.

Normal retirement still performs exactly one native close/release. Pending C release
admission keeps pool credit through `NativeServiceAcknowledgedRelease`. Once Host
has retired the interpreter, native destruction owns its final C reference sweep;
cleanup never attempts a release in a replacement interpreter. The SDK can therefore
cancel delayed tasks/subscriptions from unload while `captureOwner` returns nil.

## HNS-03: exact callback API and worker-time execution guard

The plain admission callback now has a **mandatory fifth argument**:

```swift
public typealias NativeServiceCallback<Owner: Hashable & Sendable> = @Sendable (
    Owner, Int64, String, String, NativeServiceCallbackControl
) -> Bool

public typealias NativeServiceResultCallback<Owner: Hashable & Sendable> = @Sendable (
    Owner, Int64, String, String, NativeServiceCallbackControl,
    @escaping @Sendable (NativeServiceCallbackResult) -> Void
) -> Bool

// Concrete production adapters, using the existing Host dispatcher:
NativeServiceCallbackTransport.callback(using: PluginCallbackDispatcher)
    -> NativeServiceCallback<PluginHost.CallbackOwner>
NativeServiceCallbackTransport.result(using: PluginCallbackDispatcher)
    -> NativeServiceResultCallback<PluginHost.CallbackOwner>
```

Custom plain-callback composition must forward the control:

```swift
callback: { owner, handle, method, argumentsJSON, control in
    callbacks.callback(owner, handle, method, argumentsJSON,
        shouldExecute: { control.allowsExecution })
}
```

Prefer the factory above. A four-argument callback closure no longer satisfies the
NativeServices API, preventing the former silent fallback to `shouldExecute = true`.
The provider's convenience initializer uses the factory. Its `publish` and `finish`
paths call `lease.send(...)`, which always constructs/binds/passes this control.
`PluginNativeServicesBridgeExtension.Callback` aliases the new five-argument type.

### Delivery entitlement versus native admission

`NativeServiceDeliveryEntitlement` is retained by the queued control independently
of the lease object. It captures the original owner/account/permission validity
closure. That closure is lock-only: dispatcher/Host owner lookup, permission store,
and `NativeServiceSnapshots.isCurrent(scope)`. It never synchronously enters MainActor
or Postbox and never executes Python.

| Transition | Further admission | Already-admitted body |
|---|---|---|
| Persistent lease active | allowed if current | worker checks current owner/grants/account |
| `close()` / cancellation of an open lease | closed | entitlement revoked; queued body skipped |
| Successful `send(terminal: true)` | closed | entitlement retained; normal terminal body runs |
| Repeated close after terminal completion | closed | does not itself cancel terminal delivery |
| Actual account epoch, permission or interpreter revocation | denied | worker validity check fails, terminal included |
| Admission failure | closed | entitlement revoked; release still follows normal cleanup |

The terminal guard does not test `lease.isOpen` or weak-capture the lease: both would
drop every normal terminal callback after native close/lease deallocation. Queued
callbacks retain the independent entitlement until their existing dispatcher work
finishes. `NativeServiceControllerSnapshots.deinit` explicitly retires account epochs,
because queued guards can retain its lock-protected value store longer than the UI
provider object.

Result/notification requests use the same entitlement predicate together with their
existing deadline/cancellation control and pending-result pins. Closing a live result
lease cancels the controls; no permission/account protection was removed from that
route. Plain sends use no new timeout timer; existing Host/dispatcher deadlines apply.

FIFO is unchanged: callback and release are admitted to the same captured-owner
dispatcher queue. A skipped callback is followed by its original release, exactly
once. Pool credit survives release backpressure until native FIFO admission.

## Files

- `NativeServiceCallback.swift`: mandatory controlled callback, independent delivery
  entitlement, immutable cleanup token on leases.
- `NativeServiceCleanup.swift`: cleanup identity and shared production route.
- `NativeServiceScheduler.swift`, `NativeServiceOperations.swift`,
  `NativeServiceOpenBarrier.swift`: atomic identity-match/removal overloads.
- `PluginServices/PluginNativeServicesBridgeExtension.swift`: real callback factory,
  cleanup routing, capture of `ownerWireToken`.
- `PluginServices/NativeServiceControllerSnapshots.swift`: account-epoch retirement
  when the native publisher is destroyed.
- Existing NativeService Swift fixtures use the mandatory callback argument; the
  result-only fixture now uses the production callback adapter too.

## Bounded fixtures and verification status

New `NativeServiceCleanupTests.swift` has four small Foundation tests:

1. Hidden active owner still permits its long-delay task cleanup; foreign plugin/
   token and replacement-generation cancellation fail; release is exactly once.
2. Subscription cancel revokes a queued body and preserves pool credit until release
   acknowledgement; duplicate cancellation cannot leak or double-release credit.
3. File-extension replacement cannot be removed by the old stored generation.
4. Cleanup cannot create resources and rejects an absent bound token.

New `NativeServiceRemediationTests.swift` has four Host/provider boundary fixtures:

1. Real Host maintenance reaches the fake engine's unload entry, with active owner
   hidden; from that worker it calls the real bridge and production cleanup route
   for task/native subscription/NotificationCenter subscription, then repeats each
   cancellation. Maintenance must return successfully and all resources retire once.
2. Block the actual owner worker via direct Host invocation (not merely the dispatcher
   queue), admit user/download/observe callbacks, revoke real Host permissions, release
   the worker: no corresponding engine callback body, exactly one release each.
3. Same blocked-worker sequence with native account epoch replacement.
4. A normal terminal callback survives native close and lease deallocation, executes
   once, and is followed by release in the actual dispatcher/Host trace.

These fixtures use `MaintenanceTestEngine` and real Host/dispatcher scheduling. They
do **not** execute CPython or `CallbackLeases.end`; the explicit unload bridge calls
are not evidence of a full SDK unload pass. The real-CPython fixture author must
combine the scenario below with the coordinator's native gate.

All own waits are bounded (2 s async waits, 4 s worker gates); run only these fixtures
after compilation with an **external 30 s process cap**:

```text
swift test --package-path swift/PluginHost --skip-build --filter 'NativeService(Remediation|Cleanup)Tests'
```

Local execution status: Swift/Swiftc unavailable in this Windows session. The new
Swift fixtures and iOS provider linkage are **not executed** here. Source/contract
checks are separate from runtime proof:

```text
python swift/PluginHost/NativeServiceRemediationSourceTests.py
4 passed / 0.019 s (external process cap: 30 s)
git diff --check: passed for changed tracked NativeService sources/fixtures
7 new/untracked remediation/provider/report files: no whitespace errors
```

The source checks cover the revoke-only route, immutable stored token matching,
mandatory controlled callback API and production adapter, plus the actual existing
Postbox import/access parser on changed UI files. They do not prove Swift compilation,
real SDK unload, native interpreter entry or a CPython handle sweep.

### Real-CPython join point for coordinator / native fixture author

Use own tiny fixture code, a native-bound random CallbackOwner token and unique
lease wrappers. Leave a long-delay owner task and persistent native subscription
alive, then enter Host maintenance. Let the real SDK `CallbackLeases.end()` issue
cleanup during `unload()`; expect no cleanup exception, one native cancellation/
release per lease, no remaining native resources, and no new callback admission
from the retiring owner. Repeat cleanup and try the old token against a replacement
lease. For callbacks, block the real worker before the accepted response, revoke the
grant or account epoch, then unblock: no user Python body. Also include the positive
terminal case. UI cleanup/side-effect quotas remain the UI-owner's HNS-02/HNS-05 work.
