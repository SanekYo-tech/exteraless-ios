# SDK → native wire contract (wave 2)

Owner: SDK agent. Baseline: `68bb1adf`. UI/TL/coordinator should use this file
when connecting their providers; TL model details are finalized in `tl-schema.md`.
All operations below use `op="call"`, `fqcn="exteraless.ios.Runtime"`, positional
`args`, empty `kwargs`, null `instance/value`. C supplies pluginId and immutable
ownerToken (see `native-owner-token.md`); Python does not author either field. Unknown native
operations must raise, not return a placeholder success.

## Existing services retained

`getSetting(key, default)`, `setSetting(key, value)`, `removeSetting(key)`,
`getFilesDir()`, `getCacheDir()`, `getPluginsDir()`, `getVersion()`,
`hasPermission(name)`, `isUnsafeMode()`, `log(text)`, `completeCallback(handle)`.
Settings values are typed JSON. The existing scheduled-runnable path remains
`AndroidUtilities.runOnUIThread(callable, delay_ms)` on the owner worker.

## Coordinator extension: settings, registrations, owner work

| Member | args | value / required effect |
|---|---|---|
| `getSettings` | `[]` | opaque JSON-object **string**, per coordinator contract |
| `setSettings` | `[json_string]` | null; atomic replace |
| `updateSettings` | `[json_string]` | null; atomic merge |
| `clearSettings` | `[]` | null; atomic reset |
| `uiRefreshSettings` | `[]` | null; UI provider refreshes actual open settings screens, called after successful mutation when reload=True |
| `logEvent` | `[{level,message,phase,traceback?}]` | null; bounded native plugin log, preserving severity |
| `menuRegister` | `[model, callback]` | `{id:String}`; persistent menu insertion, not immediate presentation |
| `menuRemove` | `[id]` | null; remove insertion and native callback reference |
| `postToOwner` | `[callback, delay_ms, queue]` | `{id:String}`; schedule on this interpreter's owner queue; callback method `run`, args `[]` |
| `cancelOwnerTask` | `[id]` | bool; cancel pending task and native reference |
| `getClientSetting` | `[key,default?]` | typed public value; strict Config mirrors use `[key]` and reject an absent native definition |
| `setClientSetting` | `[key,value]` | null; persist/apply real client behavior |
| `getProtectedPaths` | `[]` | `[absoluteString]`, maximum 64; implemented trusted native directory snapshot, headless `[]` |
| `fileRegister` | `[{extension,whitelist,blacklist,icon},callback]` | `{id:String}`; actual file-open interception |
| `fileRemove` | `[id]` | null |
| `intentRegister` | `[{before,priority,filters},callback]` | `{id:String}`; actual link interception; before result Bool controls cancellation |
| `intentRemove` | `[id]` | null |

Menu model uses original SDK keys: `menu_type`, `text`, `priority`, optional
`item_id`, `icon`, `subtext`, `condition`. Placements are original MenuItemType
strings. Native callback `__call__([context])` supplies the actual menu context.
Unsupported conditions/placements must fail at registration rather than remain inert.
File/intent callbacks receive the original SDK context dictionary (intent matching
uses `schemes/hosts/path_template/query_args/action/type/categories/flags`).
NativeServices' exact operations and validation are in `native-services-wire.schema.json`.
File callback success is void for every Python return type; context.file is a
portable File. Exceptions reach the native opener. Intent before callbacks retain
their actual Bool; after callbacks are void.

`postToOwner` is the only new transport entry allowed from an attached Python
background thread. It must capture the originating interpreter's CallbackOwner
token synchronously and never run Python inline/on main. **Do not resolve an old
request solely by a newer pluginId after reload.** Coordinator binds generation
identity; stale owner tasks are rejected/released in their original interpreter.
All other Python SDK/native mutations execute on the owner worker.
Task wrapper creation/ownership and publication share callbacks.lock; an early
terminal callback cannot be inserted again when its background admission returns.
All Runnable paths discard user return objects before codec serialization. The
native delay bound is 0...86400000 ms. Cancellation runs on the owner.

Native global client settings live at
`<context.sharedContext.basePath>/exteraless/client-settings.json`. Native returns
the specific **exteraless** directory from `getProtectedPaths`, not the app-group/
data/tmp root, and retains observed paths across logout. The adapter refreshes the
snapshot before every owner entry, including legacy plugins without async owner
binding, so an initially empty account context is not cached forever. Paths
come from the native dispatcher, never from a plugin configure argument. As in the
original Android sealed-storage audit, raw writes require `hooks` (and ordinary
filesystem access still applies); `settings` permission uses the redacted/guarded
`getClientSetting` / atomic `setClientSetting` API instead. `files` alone cannot
overwrite this JSON. This is separate from per-plugin PluginServiceStorage paths.

### Implemented originating-generation binding

Implemented host order: after registering CallbackOwner and **before** `load_json`,
bind `_exteraless_bridge.xt_set_owner_token(epoch)` then
`exteraless_runtime.bind_owner_json(json.dumps(epoch))` on that worker. SDK binding
repeats the C setter to validate exact agreement; its limit is 256 **UTF-8 bytes**.
Token identity is a random UUID unique per native interpreter generation.
New callback-producing operations refuse to run until bound. C injects the
top-level `ownerToken` for both xt_call_host and all seven BridgeBackend operations;
unbound caller-supplied tokens are removed. The dispatcher must
validate it against the captured CallbackOwner before admission. This closes the
case where a background thread of an abandoned old interpreter submits work after
the same pluginId has acquired a new owner. pluginId still comes only from C state;
the token is not a substitute for that identity check. Host-bound SDK loads always
bind the epoch; standalone legacy bridge tests retain their separate compatibility path.

`PluginHost.releaseCallbackHandles(handles, expectedOwner:)` now executes
`exteraless_runtime.release_handles_json(JSON_ARRAY_TEXT)` on that captured worker
instead of directly looping over C releases. This releases C refs **and** Python
lease/task/request bookkeeping when native account replacement suppresses reverse
callbacks. It is valid after `unload` (before interpreter destruction), is bounded
to 4096 positive handles per call, and does not call user code. Ordinary terminal
callbacks close their lease first; the subsequent native FIFO release is idempotent.

## UI extension

`uiPresent(kind, model, callbacks) -> {id:String}`;
`uiUpdate(id, model) -> null`; `uiDismiss(id) -> null`;
`uiState(id) -> {visible:Bool,...}`. Native owns the presentation and retains the
captured CallbackOwner. Models contain no Python/Java objects, only JSON data.

Current portable models (the NativeUI source validates the full field sets):

- `alert`: title, message, style (`message/loading/spinner`), cancelable,
  cancelOnTouchOutside, buttons `[{which:-1|-2|-3,text,destructive?}]`, optional
  items `[String]`, selectedIndex, progress, input/view (explicit widget DTO only),
  messageClickable, blurredBackground, blurBehind. Native link activation rechecks
  intents and UI scope. Native blur respects Reduce Transparency.
- Widget padding/margins use left/top/right/bottom native logical points. Layout
  supports fill/wrap/-1/-2 and numeric dimensions, weight and alignment. Font/image
  names are resolved by native; Bool is not accepted as a numeric dimension/style.
- `bulletin`/`toast`: text, optional title/subtitle, style (`info/error/success/undo`),
  durationMs, optional buttonText; no Android integer drawable emulation.
- `bottomSheet`/`menu`: title, items `[{id,text,icon?,destructive?,enabled?}]`.
- `share`: text and/or local file paths, optional mimeType/title.
- `settings`: title, SDK settings rows; change events have key/value.

Callback map values are **distinct Python wrapper callables for this lease**:
`positive`, `negative`, `neutral`, `item`, `change`, `action`, `undo`, `cancel`,
`back`, `dismiss`, `closed` as applicable. Callback wire is
`__call__([eventObject])`, with `{id,event,which?,key?,value?,context?}`.
The SDK maps to original Python arities: alert buttons/items `(builder, which)`,
dismiss/cancel/back `(builder)`, bulletin actions `()`, settings changes `(value)`.
`closed` is terminal and always required: include a reason, after any action/
dismiss callback. Python clears lease bookkeeping; native queues the C-handle
release after terminal delivery in FIFO order, even if the callback throws. Python
releases handles itself only on admission failure. Explicit uiDismiss waits for
the native closed/release sequence, rather than invalidating callbacks early.
Unload calls uiDismiss for outstanding presentations without reverse callbacks;
native `releaseInstances(pluginId)` independently invalidates old owners.
Builder listeners use stable per-event wrappers. `uiUpdate` carries models only,
including named item icons; callback targets change in Python without new handles.
Settings refresh uses stable generic change/action/longAction/refresh wrappers;
new row callback IDs remain plain DTO strings. See `sdk-ui-source-handoff.md`.

## TL/services extension

Reserved exact operation names from the contract:
`tlRequest(requestModel, callback) -> {requestId:String}`,
`tlCancel(requestId)`, `getPeer(peerModel, callback)`, `sendMedia(model, callback)`.
Models include account **index**, not account record ID. TL field/tag/bytes/Int64
rules and the request/response envelope will follow `docs/wave-2/tl-schema.md`.
Python request callbacks retain the resolved account; original callable/delegate
arity is `(response, error)`. Cancellation/unload release that request's unique
callback wrapper. Native must deliver a terminal result/error or cancellation.
RequestDelegate and UI action callback return values are void and do not allocate
unused C return handles. Before-intent/result-bearing explicit APIs keep their results.

`_controllers.py` consumes the ready nativeGetUser/Chat/Contacts/PeerInfo, peer and
resource subscriptions, media/status/download and notification-settings operations.
One-shot callbacks close; subscriptions retain their lease. State snapshots preserve
`ready:false` versus `ready:true,value:null`. `supported()` queries current exports.
NotificationCenter gets only the native notificationSupported result (IDs 25/46/137),
with `(id,actualAccount,args)` and no implicit hook-account scope.

## Source-pinned Config mirrors

All 308 overload receipts live in `sdk-config-parity.json`. Each supported method
resolves its canonical actual ClientSettings key and performs a guarded native read
or write. Bool/Int/String accessors, inversions, percentages and enum/geometry
overloads have explicit mappings. No generic unknown-field fallback exists.
Credentials are denied and the native setPublic check remains authoritative.

The native global compatibility-storage namespace and runtime-manager metadata
remain contract dependencies. Needed metadata includes actual safe/engine/developer/
compatibility/compact state and pinned-plugin identities; getters and mutation
operations must reflect the Host/manager, carry current owner provenance and enforce
settings. Until their provider exports exact methods/fields, those named ExteraConfig
overloads fail explicitly. The NativeUI owner handles its 16 manager IDs.

No JVM/Dex/Xposed executor is proposed. Reflection support is limited to registered
Python port classes and native operations genuinely implemented by the providers.

## Plugin pills — implemented SDK binding

Transport uses the Pill owner's `pills-wire.md` contract:
pillRegister/pillUpdate/pillUnregister/pillGetLayout/pillSaveLayout.
The native bridge owns persistent original↔native ID mapping, including restart and
dynamic-rate collisions. SDK `_pill_types.py` supplies actual data classes and
mutable layout ADTs; `_pills.py` supplies the exact five Runtime bindings and
selection/account-scoped callback leases. Details and v1 boundaries: `sdk-pills.md`.

Original source: `app/exteraless/pillstack/PillRegistry.java` and `pills/BasePill.java`
plus the `com/exteragram/messenger/pillstack/core/PillRegistry.java` facade.
`PillInfo(id,name,iconRes,iconColorTop,iconColorBottom,creator)` exposes fields and
same-named accessors. `creator.create(context, resourcesProvider)` returns a pill.
Registration batches defer layout invalidation; default native pills are not
fabricated by Python. Reserved built-in IDs are those of the actual PillType enum.

The current native `PillModel` has id/title/value/detail/source/phase,
optional updatedAtMs/progress and isHighlighted. Phases are
idle/loading/ready/stale/failed/unavailable. Absent time/progress are omitted;
timestamps are positive Unix milliseconds. SDK data validation follows this model.

Callbacks use unique existing SDK leases and the C-bound owner epoch, with
account/scope fields exactly as supplied by the Pill bridge. Long click requires
the actual result API. The bridge owns timers, presentation, native ID allocation
and layout persistence. `getActivePills/getHiddenPills` expose stable mutable
ArrayList drafts; `savePillsLayout` commits through the native atomic layout API.
Native-only stock creators report that they cannot produce an Android View.
The earlier pillRemove/pillSetActive/pillSnapshot/pillTransaction names are retired
proposals and are not used by the SDK.

## TL transform assembly

The public SDK entrypoint is `hook_priority_json(hook,name,canonical_name)`. Protocol
names are pre_request_hook/post_request_hook/on_update_hook/on_updates_hook, matching
ExtensionPointKind.protocolName. It reads the one real BasePlugin registration ledger,
routes exact request/update/container names appropriately and shares substring hooks;
max matching priority is returned, or JSON null when there is no registration.

Schema.hook_names reads the generated hookNames table. Dispatch unwraps snapshot.tl
regardless of observational true/false, with deep immutable `_exteraless_tl_context`
outside TL `_values`. Post errors are actual decoded error DTOs. The Host/native
normalizer remains authoritative between plugins and at final application.

Host now forwards `canonical_name` in dispatch_json arguments. This removes
the two generated short-name ambiguities (`reorderUsernames`, `toggleUsername`)
when requestName is absent from post metadata; the SDK accepts it. Ordinary
pre/update/container paths derive canonical identity from the real TL discriminator.

The native SDK driver now runs a second fresh child with two actual local SDK TL
plugins and Host.transformTL. It verifies ordering/name matching, MODIFY_FINAL,
CANCEL, schema normalization between plugins, invalid edits preserving the prior
valid value, update/container registrations, RPC errors and cleanup.
