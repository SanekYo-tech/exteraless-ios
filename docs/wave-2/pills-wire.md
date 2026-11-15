# Plugin Pill wire v1

Stable callable surface for the SDK adapter. Native implementation:
`ExteralessClient/Pills/PluginPillBridgeExtension.swift`. Install it in the existing
`CompositePluginBridgeExtension` **before `host.start()`**, so exported-method
discovery sees these five static `exteraless.ios.Runtime` methods:

| Method | Arguments | Result | Permission |
|---|---|---|---|
| `pillRegister` | `descriptor, callbacks` | registration object below | `ui` |
| `pillUpdate` | `id, model` | `null` | `ui` |
| `pillUnregister` | `id` | `bool` (removed) | `ui` |
| `pillGetLayout` | none | layout snapshot below | `ui`, `settings` |
| `pillSaveLayout` | layout object below | `null` | `ui`, `settings` |

All calls use the normal static bridge envelope (`op:call`, positional `args`, no
instance/kwargs). C supplies immutable `pluginId` / `ownerToken`; the native bridge
captures `PluginCallbackDispatcher.captureOwner(pluginId)` and requires **exact**
token equality. Tokens are random per-interpreter UUIDs; SDK-supplied identity is
not authoritative. `member_kind` is side-effect-free discovery and returns
`"method"`. Unknown members are left to the composite.

## Source provenance and permissions

The checked-in Java **and** Kotlin snapshots contain no class/symbol named
`PluginPillServices`. The actual original surface is Java
`app.exteraless.pillstack.PillRegistry` (`PillInfo` / `PillCreator`),
`pills.BasePill`, `PillStackEvents`, and Kotlin `PillStackConfig`; Java
`com.exteragram.messenger.pillstack.*` provides compatibility wrappers.
`python/sdk/extera_utils/class_aliases.py` maps these same classes.

Permission evidence is `app/exteraless/plugins/PluginServices.java:87–122`
(ordinary UI proxy construction uses UI) and `PluginPermissions.java:36–49`
(`ui`, and `settings` for reading/writing application settings outside one's own).
Registration does not implicitly activate a pill or mutate global layout. The
native settings screen can activate it; a plugin needs `settings` to do so.

## Registration

```json
{
  "androidId": 910,
  "title": "My status",
  "symbol": "chart.line.uptrend.xyaxis",
  "refreshIntervalMs": 30000
}
```

- `androidId`: exact signed Int32, excluding built-in IDs 1–15 and −1 (the empty
  selection sentinel). It is scoped to the **C-authenticated plugin ID**.
- `title`: nonempty, at most 128 characters / 512 UTF-8 bytes.
- `symbol`: optional SF Symbol name, defaults to `circle`, at most 128 bytes.
  Android resource IDs are translated by the SDK's explicit icon/class mapping.
- `refreshIntervalMs`: integer 0…3600000, default 300000. 0 disables automatic
  provider update callbacks; positive intervals below 5000 are adapted to 5000.

Callbacks is an object with only `start`, `update`, `tap`, `longPress`, `stop`.
`update` is required; the others are optional. Each supplied value is a **fresh,
unique wrapper** marshalled as `{"__handle__":positiveInt64,"__fqcn__":null}`.
Never reuse a wrapper handle across callbacks/registrations. Failure before
admission leaves handles owned by the SDK/C call transaction. Successful admission
transfers all supplied wrappers to the native registration until retirement.
Registering the same `(pluginId, androidId)` twice while it is live is rejected;
the SDK facade unregisters its previous lease before replacing it. The persisted
native integer ID remains the same. Closing leases remain budgeted until their
FIFO release is admitted, preventing a release-backpressure leak.

```json
{"id":"registration-uuid","nativeId":10000,"androidId":910,
 "refreshIntervalMs":30000,"mappingVersion":1}
```

`id` is a lifecycle token, **not** the persistent/native integer ID. Every reload or
new registration gets a new `id`. Native integer identity is persisted under
`<existing shared base>/exteraless/pills/plugin-identities.json`, keyed by
`(pluginId, androidId)`. Allocation is transactional, collision-checked, monotonic
and never recycled on unload. It does not hash IDs or add an overflow-prone offset.
Existing mappings survive restart and reversed plugin load order. Built-ins,
dynamic rate IDs, registered native IDs and dormant layout IDs are not overwritten.
An existing mapping that conflicts with a newly imported rate ID fails explicitly;
it is never silently reassigned to a different pill.

At most 64 live/pending registrations and 4096 retained identities. The archive
holds only identity metadata, not callbacks, credentials, readings or accounts.
Corruption/version/capacity failures preserve it. No new visible setting is needed.

## Native callback → original BasePill mapping

Every callback is invoked as `__call__` on the captured Python owner worker. The
first argument is native routing context, consumed by the SDK wrapper:

```json
{"id":"registration-uuid","nativeId":10000,"androidId":910,
 "selection":"visible-subscription-uuid","account":0,
 "accountRecordId":"1234567890123456789","generation":"account-generation-uuid"}
```

`account` is the existing stable SDK account slot. `accountRecordId` is a decimal
string, not an Android account index. `selection` changes on every visible
subscription; retain it in asynchronous updates from that subscription.

| Wire callback | Wire argument array | Original method(s), without routing context |
|---|---|---|
| `start` | `[context]` | `onPillSelected()`, `onStackVisibilityChanged(true)` |
| `update` | `[context, force]` | `onUpdateData(boolean force)` |
| `tap` | `[context]` | `onPillClicked()` |
| `longPress` | `[context]` | `onPillLongClicked() -> boolean` |
| `stop` | `[context]` | `onStackVisibilityChanged(false)`, `onPillUnselected()` |

Start is followed by one `update(..., false)`. Timer refresh is false; the native
Refresh control is true. `PluginPillBridgeActions` preserves that distinction at
the existing `ExteralessPillSubscription.refresh(force:)` callsite without changing
the frozen Core enum. Multiple timers cannot duplicate one selection's automatic
update within its interval. `getPillId` and
`getRefreshInterval` are descriptor properties in the SDK adapter, not render-time
Python calls. Loading/text/progress setters publish a DTO through `pillUpdate`.
Theme changes are native rendering; arbitrary Android Views must be adapted to
the portable DTO, never executed on the main render queue.

All callbacks except `longPress` are **void**: wrappers discard the source return
and explicitly return `None`. `stop` performs local cleanup; its return/cleanup
failure must not become a deferred native UI failure. Long-press's Boolean is
obtained through the dispatcher's asynchronous result route, with cancellation and
selection validation and a two-second deadline. A still-visible header opens its
native pill settings when the handler returns false, is absent or times out.
UIKit does not synchronously wait for Python. The current Core action contract
identifies an account/pill, not a view: if several surfaces share that exact scope,
tap/explicit refresh/long-press target the most recently attached selection once,
not multiple side effects. Automatic refresh still services each visible selection.

Normal disappearance cancels the native provider subscription and sends guarded
`stop`; a synchronous foreground gate also blocks queued data/action callbacks
before asynchronous Core cancellation completes. Backgrounding sends only guarded
stop cleanup, and resume gets new selection tokens. Account retirement, host unload or permission loss suppress callbacks to
the retired scope. Registration wrappers remain alive across ordinary selection
changes and account switches, until explicit unregister/unload. Native callback
admission and handle release share owner FIFO. Pending result callbacks pin their
handles until cancellation/completion, and release is batched per registration.

During `unload()`, Host's live `captureOwner` may already be nil. `pillUnregister`
then validates the request token against the registration's **previously captured**
owner, while the enclosing BridgeServices validator authenticates the retiring C
epoch. This cleanup-only path creates no callbacks/effects and cannot remove a
new generation's UUID. Other operations still require a live captured owner.
Registry changes renew the header's plugin subscription even when a replacement
keeps identical title/interval/native ID; queued old-subscription paints are
cancelled before the coalesced rebuild. Long-press completion has another
registration/selection check on main immediately before the native fallback.

## Publishing a reading

```json
{
  "selection":"visible-subscription-uuid",
  "value":"12 MB",
  "title":"My status",
  "detail":"Measured by the plugin",
  "source":"My provider",
  "phase":"ready",
  "updatedAtMs":1700000000123,
  "progress":0.25,
  "isHighlighted":false
}
```

Call `pillUpdate(registration.id, model)`. `selection` and `value` are required.
SDK view builders keep pre-selection setter values locally and publish them only
after receiving a valid selection context; constructing a view is not permission
to publish an account-agnostic reading.
`title` defaults to descriptor title; `detail` to empty, `source` to the plugin
name, `phase` to ready, `isHighlighted` to false. Timestamp/progress may be omitted
or null. Native injects the integer `PillModel.id`; callers cannot replace it.

PillModel bounds apply: title 128, value 256, detail 2048, source 256 characters;
finite progress 0…1; positive Unix milliseconds when a timestamp is supplied.
Phase is idle/loading/ready/stale/failed/unavailable. An unavailable measurement
must not be converted to zero. Request envelope is at most 64 KiB for these calls.
Updates are coalesced latest-value at a maximum of 4Hz per visible subscription.
Owner, registration, account generation and selection are rechecked before
delivery. Updates from stopped selections fail `InvalidHandle`, even when the
same native integer ID has since been re-registered.

## Global layout snapshots

`pillGetLayout()` returns native integer IDs, including unknown/dormant IDs:

```json
{"revision":"owner-and-scope-snapshot-uuid","idSpace":"native",
 "active":[5,6,10000],"hidden":[],"selected":10000,"infiniteScrolling":true,
 "mappings":[{"androidId":910,"nativeId":10000}],"mappingVersion":1}
```

`mappings` contains this plugin's retained mappings; other plugins' identity
metadata is not returned. SDK live-list adapters translate their own Android IDs
using it, and preserve all opaque native IDs. `pillSaveLayout` accepts
`{revision,idSpace,active,hidden,selected,infiniteScrolling}`. Both lists are
duplicate-free/disjoint; selected is −1 or present in active. Unknown/dormant IDs
omitted by a sanitized caller are merged back at their prior slots, not deleted.
Layout is saved in one `ClientSettings.applyPublic` CAS batch. A changed snapshot
returns `SettingsConflict`; fetch again and reapply the intended edit. Revisions
expire after five minutes and are scoped to the interpreter and active account
generation. No partial layout or callback identity is persisted.
Snapshots retain only the five layout/rate-instance fields needed by CAS (at most
64 total / 32 per owner), not complete settings or credentials. Legacy unknown
Android integers are not automatically reinterpreted as another plugin's IDs;
the SDK translates its own explicit list edits using the retained mapping and
preserves opaque IDs on read/save.

## Composition and verification

Exact convenience constructor (throws on invalid native configuration; archive I/O
is performed off main by admitted register/layout calls):

```swift
let pills = try PluginPillBridgeExtension(
    services: services, callbacks: callbacks,
    identityURL: URL(fileURLWithPath: context.sharedContext.basePath, isDirectory: true)
        .appendingPathComponent("exteraless/pills/plugin-identities.json")
)
pills.update(context: context)
```

The designated constructor also takes an injected registry/settings store and
`platformSnapshot: @Sendable () -> PluginPlatformSnapshot`. It uses the existing
`PluginCallbackDispatcher` for captured owner, permission checks, `callback`,
`result(shouldExecute:)` and `release`. No new host framework or public setting is
created. TelegramUI already imports PluginHost/ExteralessCore; Foundation/Darwin
provide bounded archive I/O. All five new `PluginPill*.swift` files are picked up by
the TelegramUI source glob. The archive is inside TelegramPluginServices' existing
protected `exteraless` directory.

Runtime/UI-agent hunks in `Sources/Exteraless/ExteralessPluginRuntime.swift`:

```diff
@@ properties near nativeServices
     private var nativeServices: PluginNativeServicesBridgeExtension?
+    private var pillServices: PluginPillBridgeExtension?
@@ update(context:), after services.update and nativeServices.update
+    pillServices?.update(context: context)
@@ clearContext(), before services.clearContext()
+    pillServices?.clearContext()
@@ startup, after self.nativeServices = native and before the composite/host.start()
+    guard let pillContext = self.currentContext else { throw PluginHostError.notRunning }
+    let pills = try PluginPillBridgeExtension(services: services, callbacks: callbacks,
+        identityURL: URL(fileURLWithPath: pillContext.sharedContext.basePath, isDirectory: true)
+            .appendingPathComponent("exteraless/pills/plugin-identities.json"))
+    pills.update(context: pillContext)
+    self.pillServices = pills
@@ installed composite
-    ui, ClientSettingsBridgeExtension(permits: { callbacks.hasPermission($0, $1) }), tl, native,
+    ui, ClientSettingsBridgeExtension(permits: { callbacks.hasPermission($0, $1) }), tl, native, pills,
@@ terminate(), alongside nativeServices.clearContext()
+    pillServices?.clearContext()
```

Call `ExteralessClientRuntime`'s Pill integration update before the plugin bridge's
update, so both share the same native account-generation lease. Host teardown calls
the existing composite `releaseInstances(pluginId:)`; this unregisters native view
leases and releases wrappers while preserving identity metadata. Ordinary account
clear only retires selection/read-snapshot state, allowing live plugin registrations
to attach to the next account generation.

New fixtures: `Tests/Exteraless/PluginPillContractsTests.swift` (seven local
archive/DTO/layout cases). Build-agent can compile it with `PluginPillWire.swift`
and `PluginPillIdentityArchive.swift`, depending on PluginHost and ExteralessCore;
no live interpreter, networking or permission prompt is used. Core Pill source/tests
remain frozen. These new native tests and the full bridge are not claimed compiled
or executed on this Windows host. Run only with a 30-second outer bound.
`Tests/Exteraless/PillPassivePingContractsTests.swift` adds one separate positive/
finite/freshness sample fixture, depending on TelegramCore. Network-owner fake-event
and wrapper-switch tests are still required for the pending Rust forwarding hooks.

Passive RTT evidence/new projection and exact Network-owner forwarding instructions
are in [pills-ping.md](pills-ping.md). The existing Rust pong RTT is currently
discarded at its Swift consumer; it is not replaced by RPC-duration statistics.

Local verification: bounded source/manifest and whitespace checks passed for the
ten follow-up Swift files, five Runtime methods, eight native fixture methods,
owner/selection/foreground/CAS/FIFO routes and the existing Rust RTT emitter.
This is source verification only; native typechecking/XCTest and visual frames
remain pending. No CI, commit/push, real provider, location or external plugin was run.
