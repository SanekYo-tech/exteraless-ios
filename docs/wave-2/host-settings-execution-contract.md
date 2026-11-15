# HNS-04 / HNS-F02: Host settings execution contract

Additive Host API (existing calls remain source-compatible):

```swift
public func updateSetting(
    id: String, key: String, valueJSON: String,
    expectedOwner: PluginHost.CallbackOwner? = nil,
    account: Int32? = nil,
    shouldExecute: @escaping @Sendable () -> Bool = { true }
) async throws

public func clickSetting(
    id: String, callbackId: String,
    expectedOwner: PluginHost.CallbackOwner? = nil,
    account: Int32? = nil,
    shouldExecute: @escaping @Sendable () -> Bool = { true }
) async throws
```

UI/Runtime must capture the page/action's `CallbackOwner`, **Int32 account index**
and revocable account/settings-revision token before any await (including before
`operationHost()`). `account` is the SDK account index, not AccountRecordId; the
record/account generation belongs in the execution token checked by the predicate.

Pass the captured owner/account through unchanged. Host rejects a foreign or
reloaded owner before enqueue, and checks that same generation again in the
actual interpreter mailbox. The predicate runs at admission and immediately
before `engine.runScript`; it must be thread-safe, lock-only/Foundation-only,
and must not synchronously hop to MainActor. False/stale -> `superseded`, with no
settings write or user callback. Task cancellation also revokes queued execution.

`expectedOwner: nil` / `account: nil` retain the old immediate/probe behavior.
Bound settings pages must supply both captured values; nil is not an account
scope guarantee.

## SDK insertion (SDK-owner, not edited by Host owner)

When `account` is present, Host emits the following numeric positional argument:

```python
setting_changed_json(key, value_json, account)
setting_click_json(callback_id, account)
```

Required backward-compatible Python signatures:

```python
def setting_changed_json(key, value_json, account=None): ...
def setting_click_json(callback_id, account=None): ...
```

Validate the supplied account as a nonnegative Int32 and use
`with _scope(platform, account):` around storage mutation and `on_change` /
`on_click`. Without a captured account Host preserves the old arity, so existing
strict probes remain valid. JSON value/key/callback-id quoting is unchanged.

Host mutation code and two bounded fixtures are supplied with this contract.
The read-only focused follow-up records the Runtime/SDK mutation wiring as
applied and the original setter/click counterexample as source-closed.

## HNS-F02: queued settings reads

The read route gets the same additive native-only execution arguments:

```swift
public func settingsJSON(
    id: String, account: Int32,
    expectedOwner: PluginHost.CallbackOwner? = nil,
    shouldExecute: @escaping @Sendable () -> Bool = { true }
) async throws -> String

public init( // CreateSettingsPayload
    pluginId: String, account: Int32,
    expectedOwner: PluginHost.CallbackOwner? = nil,
    shouldExecute: @escaping @Sendable () -> Bool = { true }
)

public func requestCreateSettings(
    _ payload: CreateSettingsPayload,
    expectedOwner: PluginHost.CallbackOwner? = nil,
    shouldExecute: @escaping @Sendable () -> Bool = { true }
) async throws -> String
```

Runtime/UI must capture owner + account/read-request/page validity before its
first await, then call `settingsJSON(..., expectedOwner: capturedOwner,
shouldExecute: { readToken.isCurrent })`. The predicate is lock-only/Foundation;
it must not read UIKit or synchronously wait for MainActor. Keep the existing
post-result checks as a second guard against displaying an expired response.
The read token must include the captured account generation and page/read
revision, not merely compare a reusable Int32 index. Invalidation must keep that
captured read revoked. Task cancellation also revokes the queue execution cap.

Host resolves and validates the target before entering the event queue, including
legacy calls omitting expectedOwner. The Host-bound EventBus also resolves/pins
direct `requestCreateSettings` calls. An explicitly supplied owner cannot replace
a different owner already carried by the payload. Payload and method predicates
are combined with AND; neither can reopen the other. Owner/guard travel in the
native in-memory envelope, are checked before fanout and again on the actual
worker, and are not serialized or selected from wire JSON. `CreateSettingsPayload`
remains non-Codable; its Hashable identity is a request identity, not closure data.

Expiry, replacement owner and cancellation reject the old read before arbitrary
Python `create_settings` / callback-registry mutation. A legacy nil owner is bound
to the current owner at Host admission, never re-resolved to a later generation
at fanout. Nil/default predicate does not assert account/page validity; real UI
reads must pass their captured guard.

The SDK invocation is unchanged: `dispatch_json("create_settings", accountPayload)`
with the existing **Int32 account** JSON field. No owner token, predicate or new
Python argument is added. UI/Runtime wiring is applied by its owner/coordinator.

### HNS-F02 fixtures and verification boundary

`swift/PluginHost/Tests/PluginHostTests/PluginSettingsReadExecutionTests.swift`
supplies five bounded tests:

- Another plugin holds the event queue; P1 read is actually enqueued, P reloads
  to P2, then the queue drains without any stale `create_settings` entry. Covers
  explicit owner, legacy Host and direct EventBus calls; a fresh P2 read succeeds.
- Account/read scope expires while the same interpreter remains loaded; stale
  Python entry is absent and a fresh-scope read succeeds.
- The owning worker is held by a prior callback. Every off-worker predicate stays
  open deliberately; actual `Thread` identity proves the worker rejects the read.
- A cancelled, queued UI read never enters Python or rebuilds its callback registry.
- Wire payload remains account-only with two SDK dispatch arguments; conflicting
  owners and either expired native predicate are rejected before Python entry.

The fixture gates have finite 5 s waits. Queue-admission barriers use `enqueued`
as well as retained/dispatched counts, rather than assuming a pre-actor credit
means the actor already accepted a request.

User-provided verified baseline: `7d04a35a`, CI `43708260304`, 545 Core / 169 Host /
30 Hooks green. That baseline predates these five new tests. Local Swift tests
have not been run: `swift`/`swiftc` are unavailable on PATH. The Runtime read-route
arguments above still require the UI-owner/coordinator patch and its verification.
