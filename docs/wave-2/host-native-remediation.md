# Host/native remediation — HNS-04/06/07/08/09

Independent `reviews/host-native-services.md` is read-only. The owned source
remediation below is supplied; no new CI/native result is claimed here.

## Cross-owner insertions needed for end-to-end closure

### Runtime observation handoff (HNS-06)

`PluginHookObservation.reserveDeliveryBytes(_ bytes: Int) -> Bool` is added by the
Host/Hooks owner. It upgrades the router's shared reservation before an encoded
payload is retained by a MainActor Task. The observation carries the reservation
through value copies until the handoff finishes. In Runtime's existing observe
closure, after encoding and **before** Task creation:

```swift
let json = try PluginTLObservationCodec.jsonString(event)
guard event.reserveDeliveryBytes(json.utf8.count) else { return }
Task { @MainActor [weak self] in self?.forward(event, json: json) }
```

Host ingress reserves synchronously before its own pre-actor hop. Thus the
upstream reservation overlaps the downstream one during transfer; returning from
the synchronous observation handler is not completion of retained MainActor work.

### Runtime native-send cancellation (HNS-07)

Capture the originating send predicate **inside the synchronous router handler**,
before creating the MainActor Task:

```swift
let shouldExecute = PluginHookRouter.currentSendExecutionPredicate()
let task = Task { @MainActor [weak self] in
    // Existing host/account checks, plus shouldExecute().
    let decision = try await host.events.preSendMessageResult(
        SendMessagePayload(account: account, paramsJSON: payload.jsonString()),
        shouldExecute: shouldExecute)
    // Existing result conversion/completion.
}
```

The predicate becomes false synchronously when the native send times out,
cancels or detaches; it does not wait for delivery of `task.cancel()` on another
queue. Host rechecks it at ingress, fanout, actual worker and deferred effects.

### Native-effect lease capture (HNS-07; common lease owner)

Host supplies `PluginNativeExecutionContext.captureGuard() -> @Sendable () -> Bool`.
It captures only the current revocation state, independently of TL ancestry. In
`PluginNativeCallLease.init(isCurrent:)` (outside this owner's files), compose it
when the lease is created on the native callback worker:

```swift
let execution = PluginNativeExecutionContext.captureGuard()
self.current = { execution() && isCurrent() }
```

This is necessary for an effect issued by completed fanout A but still waiting
on main when B times out: poisoning B alone cannot revoke A's old effect, and
poisoning unrelated/healthy callbacks is not an acceptable replacement. Existing
owner/account/permission validators remain required. Outside a batch the captured
guard permits normal work; successful batches do not cancel their valid effects.

## HNS-04 settings seam

Exact Swift and SDK signatures are in `host-settings-execution-contract.md`.
Host owner validates/pins the expected interpreter and passes the lock-only
predicate to the actual mailbox. UI owner captures page/account/revision tokens;
SDK owner enters the explicit account scope. Those two insertions are separate.

## Closure and test evidence

| Finding | Owned source closure | Supplied executable fixtures | Remaining integration |
|---|---|---|---|
| HNS-04 P1 | `PluginHost.updateSetting/clickSetting` pin expected host/interpreter/wire token before enqueue; supplied predicate reaches actual mailbox; captured nonnegative Int32 is a numeric SDK argument. Nil account preserves old arity. | `PluginSettingsExecutionTests` (2): queued revoked click/change do not enter SDK; reload cannot retarget; account and legacy arities. | UI/Runtime captured page/account/revision token and SDK `_scope(platform, account)` per settings contract. |
| HNS-06 P1 | One synchronous `PluginEventIngress` budget for all Host routes, including awaited/TL, request observations, all coalesced keys/items, and `submitAsync` before Task creation. Credits follow retained handler/native work. Hooks uses a shared registration-independent credit carried in payload value copies. | `PluginEventIngressTests` (4); `PluginHookIngressTests` (3). Limits 2, distinct keys, request bytes, awaiting overflow, terminal retention, restart with old retained work, MainActor-like retained copies and native fallback. | Runtime must claim encoded observation bytes before its MainActor Task (hunk above). |
| HNS-07 P2 | Queue creates an exact execution capability; timeout/cancel revokes it before completing the waiter. Host checks each fanout step and actual worker. Only that cap's currently running native invocations are timeout victims; queued and unrelated work are not victims. Ancestry remains unchanged/separate. | `PluginBatchOwnershipTests` (2): C callback survives A/B timeout, D does not run late, fresh batch still invokes D; B's running native payload retains credit; cancellation and completed-A deferred-effect guard. | Runtime native-send predicate and common `PluginNativeCallLease` captured guard (hunks above). |
| HNS-08 P2 | `PluginWatchdog.RiskyOperation` tracks each load entry/exit. Cancelled sleeps return. Actor-side clear checks marker and generation before touching timer/file; overlapping loads keep the latest still-active attribution. Host finishes its exact risky token. | `PluginWatchdogMarkerTests` (2), manual clock: A cancel wake/stale actor hop cannot delete B; A exit while B runs cannot start an idle clear. | Native gate execution. |
| HNS-09 P2 | `Configuration.stopTimeout` (default 5 s) bounds total terminal Python unload/destruction waits. `destroyAll(timeout:)` starts independent destruction then bounds waits, retaining timed-out `.destroying`/mailbox evidence. Provider retirement/no-finalize decision is reached. Late completion matches its original handle/completion. | `PluginBoundedStopTests` (1): finite held old destructor, maintenance timeout, bounded stop, healthy owner cleanup, zero finalize, old real exit later. | Native gate execution with real CPython teardown. |

### Admission details

- Host defaults: 1024 retained leaf events, 32 MiB charged payload/metadata bytes;
  TL transforms retain the additional 256-transform sublimit. `maxQueueBytes` is
  additive in `PluginEventQueue.Limits`. UTF-8 strings plus bounded envelope/array
  metadata are charged without JSON serialization. Explicit coalesced input charges
  its leaf items, not just one bucket. Credits are not reset by stop/restart.
- Observation policy is **drop newest before enqueue**, returning false from the
  discardable `emit*` / `submit*` APIs. Awaiting overflow throws
  `PluginHostError.eventQueueFull`. Supersession still replaces queued settings
  when admission has capacity; it does not temporarily overcommit the hard limit.
- `PluginEventBus.queueStatistics()` reports retained count/bytes as well as drops.
  These counts include executing work and work outliving a timeout/cancelled waiter.
- Router defaults: shared 256 retained factories/deliveries/sends, 32 MiB total;
  `PluginHookIngressLimits` can lower those limits. Raw event bytes are charged
  before handler delivery, and encoded bytes must be reserved before retaining
  the encoded MainActor payload. Send JSON reserves a conservative encoding bound
  before allocating it. Wire Codable fields/equality do not include runtime credits.
- `currentSendExecutionPredicate()` captures a small revocation state; successful
  completion does not revoke it, while cancellation/timeout/detach revoke it
  synchronously before fallback, including finish-before-host-cancellation binding.

### Lifetime / compatibility

`PluginEventQueue.start(handler:onTimeout:limits:)` remains available for existing
one-argument handlers. Host uses `startControlled` with the exact execution cap.
`SubinterpreterManager` invokes completion cleanup on the actual owner after
`engine.runScript` and releases the job closure before waiting for the next job.
This preserves outstanding credit/inflight evidence for native calls whose awaiter
was already released by abandon. Existing TL origin capture, per-ancestor filtering
and readonly transform validation are preserved; no whole-pipeline bypass was added.

The previous ownership regression now asserts explicit batch membership alongside
the existing per-interpreter overlap/replacement assertions. No assertion was
disabled to obtain a pass.

### Verification boundary

There are **14 new bounded tests** across the six fixture files above (11 Host,
3 Hooks). Native waits use manual finite gates (maximum 5 s) and small queue
limits; no actual hung CPython, external plugins, account or network action occurs.
Local Swift/compiler execution remains unavailable. Static checks are source
hygiene/API checks, not runtime proof. Coordinator should run the existing Host/
Hooks suites plus these tests with a 30 s test-process limit after compilation.

Cross-owner insertions above require their owners' application and the real native
gate. In particular HNS-06/07 end-to-end closure must not be inferred from passing
Host-only fixtures while the Runtime/lease constructor is still unpatched.
