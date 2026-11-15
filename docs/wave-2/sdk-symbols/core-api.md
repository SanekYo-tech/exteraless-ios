# Core SDK — exact individual source routes

**249 / 249 original IDs**, one JSON row each, with **0 missing, duplicate or unknown IDs**.
Scope: `android_utils`, `base_plugin`, `client_utils`, `hook_utils`, `intents`.
Primary map: [`core-api.json`](core-api.json).

Source revision: **`e16f380836c10de3fb1d08f468f1242788eb245d`**;
inventory revision: **`9bfce05f708fba472ca942bcfe355914847a347d`**.
All code line anchors resolve against that requested snapshot. During final checking,
parallel archive/proxy work changed four shared worktree files; the captured versions
were checked against Git instead of silently shifting the audit's source revision.

The original declarations, parameter names/kinds/defaults and return annotations
remain those addressed by each exact ID in `docs/parity/sdk-surface.json`, as required
by this directory's schema. They are not replaced with the sometimes narrower runtime
override signatures. All five original Android SDK files are byte-identical to their
current `python/sdk` copies and match the inventory's original hashes. The property
`BasePlugin.client` retains the inventory's one ID/line 806; its getter, setter and
deleter bodies are all accounted for in that row.

## Counts

| Module | pure-sdk | native-adapter | plugin-contract | metadata | unsupported | partial | IDs |
|---|---:|---:|---:|---:|---:|---:|---:|
| android_utils | 2 | 5 | 0 | 2 | 0 | 5 | 14 |
| base_plugin | 34 | 9 | 11 | 54 | 9 | 5 | 122 |
| client_utils | 6 | 11 | 2 | 12 | 8 | 45 | 84 |
| hook_utils | 0 | 0 | 0 | 2 | 0 | 7 | 9 |
| intents | 4 | 5 | 0 | 11 | 0 | 0 | 20 |
| **Total** | **46** | **30** | **13** | **81** | **17** | **62** | **249** |

These are source-disposition counts. Every row has `ported=false`, `verified=false`
and `native_execution_claimed=false`. A pure descriptor or exported typing name is
classified for its own body/declaration; it contributes no native-hook coverage.
All partial/unsupported rows name a concrete `missing_operation`.

### Fingerprints

- Sorted exact ID list (UTF-8, one ID per line, terminal LF):
  `5e675b499c67fdeed16df140f4aa6266d44334fc073d990b4d3cdf537d5bde95`.
- Original signature projection:
  `5ccc3e8c2bc5e0c5cf2e6995f011815cf2d3d70e13ab3f341e4ecf8c7876b605`.
  This covers present `id`, `kind`, `parameters`, `return_annotation`, `origin` keys
  for owned rows sorted by ID, compact sorted-key UTF-8 JSON plus LF.
- `source_sha256` pins **65 inputs**: 60 code/test/original-source Git blobs at
  `e16f3808`, the inventory blob at `9bfce05f`, the supplied read-only README schema
  bytes and three completed-Mac report files. All **61 applicable Git blobs** matched.
  The two output documents are excluded to avoid a self-reference cycle.
- Final JSON file SHA-256: `27d04bd9b7d39fff971842592982445f2d39e3cf5bda4996eca9ba0b6ee6c783`.

## Concrete routes and callback boundaries

The map follows original body → installed override/registry → terminal consumer.
Its shared transport references are explicit: `Platform.call` or C-backed proxy →
`_exteraless_bridge.c:native_request_context/py_xt_call_host` →
`NativeBridgeBinding.nativeBridgeDispatch` → `BridgeServices.dispatchJSON` → the
named provider. Native identity and epoch come from C. The composition at
`ExteralessPluginRuntime.swift:167–237` actually installs TL, NativeServices, UI and
settings providers, plus the URL/document and notification sites.

| Dynamic surface | Actual invocation route |
|---|---|
| BasePlugin.on_plugin_load | Host.loadPlugin binds owner → runtime.load_json → SDK.load_plugin:2744–2747 → subclass override |
| BasePlugin.on_plugin_unload | Host retirement → runtime.unload → SDK._unload_record:2824–2843 → override and finally cleanup; quiet failed-load paths may skip override |
| BasePlugin.on_app_event | Host appEvent dispatch → runtime.dispatch_json → SDK.call_app_event:2935 → AppEvent conversion → instance.on_app_event |
| BasePlugin.create_settings | Captured-owner/account Host settings read → runtime create_settings → SDK.get_settings_json:3420 → instance.create_settings and row/callback serialization |
| BasePlugin.pre/post_request_hook, on_update(s)_hook | PluginTLTransformIntegration's installed ingress → Host priority/normalization chain → runtime schema decoding → exact SDK call_* method → user override |
| BasePlugin.on_send_message_hook | ExteralessPluginRuntime.installHooks → Host send chain → runtime registration flag → SDK.call_send_message_hook; priority gap F02 applies |
| MenuItemData.on_click | Native PluginUIMenus.invokeMenu → captured-owner FIFO → Lease.wrap → _registrations.native_click → account-scoped user callable with partial native context |
| RequestCallback / bare send_request callback | Native TL completion ticket → owner FIFO → runtime.invoke_handle_json → Requests.completed → user fn/delegate.run; F04 applies |
| NotificationCenterDelegate.didReceivedNotification | Installed native account publishers → provider.emit → owner FIFO → Center.received validates event/account → typed argument projection → delegate method |
| Intents before/after callable | Real OpenUrl/AppDelegate site → NativeServiceOpenHooks → ordered native opening barrier → owner callback → SDK._IntentCallback/_invoke; after runs when original continuation resumes |
| R / queued function | Python Runnable carrier → admitted scheduler/legacy callback route → captured interpreter worker; Python never runs on UIKit main |
| View/SeekBar listener factories | Wrapper methods exist, but corresponding native view listener attachment/event APIs are missing; five partial rows explicitly identify them |
| MethodHook/MethodReplacement callbacks | Default protocol bodies exist; native BasePlugin hook installation is explicitly unsupported, so no iOS method-hook producer invokes them |

Notification callbacks retain their original **explicit account argument without
implicit hook scope**. Ordinary module-level account helpers default to native UI
selection; `AccountClient(None)` resolves hook scope first. The original
`AccountClient.run_on_queue` body does not forward its account pin: it captures the
current hook scope through the installed queue helper.

## Gap list

### Missing operations and restricted original shapes

- **9 base-plugin unsupported rows:** four Xposed installation/removal entry points,
  MethodHook plus before/after callbacks, MethodReplacement plus replacement callback.
  HookFilter construction/serialization, metadata constants and HookParam wrapping
  remain separate pure data operations.
- **8 client unsupported rows:** `get_location_controller`, `get_messages_storage`,
  `get_secret_chat_helper`, global `get_media_controller`, and their four AccountClient
  forwarders. The first three fail because the installed Account lacks the getter;
  MediaController.getInstance has no native bridge provider.
- **5 listener factory partials:** View click/long-click/touch/key and SeekBar progress/
  start/stop wrappers have no matching native widget listener subscription and event
  DTO. Native dialog/settings callback signatures are separate consumers.
- **12 controller getter pairs:** callbacks/partial DTOs are actually wired, while
  synchronous Android caches/full types and mutations remain absent. Concrete gaps
  include MessagesController.getUser/getChat/getUserFull/getChatFull synchronous joins,
  ContactsController list fields, MediaDataController.getStickerSets,
  FileLoader.getPathToAttach/original attachment overloads,
  DownloadController.canDownloadMedia, NotificationsController writes,
  UserConfig.getClientUser, ConnectionsManager.getCurrentTime/nonzero request flags,
  and arbitrary NotificationCenter event codecs/postNotificationName.
  Existing `nativeCached*` exports do not automatically add these SDK methods.
- **Send/edit input projection:** native operations exist, but signed Android dialog
  IDs and complete MessageObject reply/edit-target shapes are not automatically
  converted. `send_message` covers a closed text subset, not original photo/document/
  caption-only/arbitrary SendMessageParams forms. File/peer/native enqueue restrictions
  remain explicit; synchronous admission is not delivery.
- **Reflection partials:** registered Python ports use their real ClassInfo/Field
  bodies; generic native Class/getDeclaredFields/private writes are not provided.
  `get_field`/`set_field` are genuine aliases of those same limited helpers.
- **Other partial rows:** full MVEL menu conditions, cross-plugin PluginsController
  enumeration/lifecycle operations, arbitrary DispatchQueue creation, unhook-owner
  forwarding to the unavailable native Xposed operation, and the five defects below.
- **Native adaptations with explicit limits:** UI context/fragment are portable
  facades; clipboard override does not request the original best-effort copied
  bulletin; bulletin fragment arguments are currently ignored. Intent registrations
  are for installed ACTION_VIEW URL sites, with unsupported MIME/activity-category/
  nonzero required task-flag filters rejected rather than silently retained.

### CORE-API-F01 — AccountClient edit default loses omission

**Sources:** `python/sdk/client_utils.py:882–886`;
`python/exteraless_runtime/_tl.py:573–591`;
`TLMediaEditServices.swift:101–108`.

The retained AccountClient wrapper always forwards `with_spoiler=False`. The runtime
module override uses `_OMITTED` to distinguish absence from an intentional clear.
The selected bodies were executed with a data-only `native_media` recorder:

```text
target = {peer:{type:user,id:7}, id:9, namespace:0}
edit_message(target, text="replacement", account=2)       -> no spoiler key
AccountClient(2).edit_message(target, text="replacement") -> spoiler:false
```

The actual native branch treats any non-null spoiler as a media-reference edit.
A cached text-only message consequently reaches `EDIT_SPOILER_REQUIRES_MEDIA`;
a media message can have its spoiler cleared. This Swift consequence is a source
counterexample, not a new native execution result.

**Fix needed:** preserve omission through the AccountClient adapter while keeping an
explicit False distinguishable and the existing native target/permission validation.

### CORE-API-F02 — send-hook priority is discarded

**Sources:** original `PluginsController.java:1698–1709,1962–1987`;
`python/sdk/base_plugin.py:720–726`; `_platform.py:183–184`;
`PluginHost.swift:1397–1427`.

Android stores the priority and calls send hooks in `byPriority` order. The retained
Python registration stores only a Boolean, its installed bridge method only checks
the owner, and the Host send chain performs no priority query. The selected original
and adapter bodies produced identical state for priority 100 and -100:

```json
{"_exteraless_send_message_registered": true}
```

Thus priority cannot influence current ordering; an earlier subscriber can
CANCEL/MODIFY_FINAL before the intended higher-priority callback.

**Fix needed:** retain/query the send priority and order native send subscribers by it
under the existing owner and permission guards. TL hook priority already has a
separate implemented query and is not evidence for this missing send path.

### CORE-API-F03 — missing class produces a positive proxy

**Sources:** `python/sdk/hook_utils.py:34–71`;
`python/virtualjava/finder.py:111–118`; `proxy.py:204–219`;
`BridgeServices.swift:772–807`.

For an allowed name, the exact find_class body and actual virtualjava resolver were
executed with a backend whose class_exists would return false:

```text
find_class("org.telegram.messenger.CoreApiMissingClass")
-> <JavaClass org.telegram.messenger.CoreApiMissingClass>
native class_exists calls -> 0
```

The promised fail-soft None is replaced by a proxy; later native operations still
fail. Registered Python ports are a separate valid fast path.

**Fix needed:** check actual native existence before accepting an unregistered class,
retaining aliases, registered ports, fail-soft None and permission enforcement.

### CORE-API-F04 — request-callback exception containment changed

**Sources:** `python/sdk/client_utils.py:247–250,309–312`;
`python/exteraless_runtime/_tl.py:332–339,413–414`;
`python/exteraless_runtime/_callbacks.py:33–38`.

Both original bare/delegate callback paths use safe_call. The installed completion
and RequestCallback.run call user code directly; the lease reports and rethrows.
An isolated execution of the exact run body with a callback raising
`ValueError("source-counter-only")` propagated that exception, whereas the original
safe_call body logs it and returns None.

**Fix needed:** restore containment around user callbacks while retaining strict
schema/native failures and the current account scope, terminal lease and C-owned
FIFO release behavior. No further Host-disable consequence is inferred here.

### CORE-API-F05 — cancellation crosses named queues

**Sources:** original `DispatchQueue.java:62–68`;
`python/exteraless_runtime/_scheduling.py:13,64–78`;
`NativeServiceScheduler.swift:60–75`.

The original queue removes a runnable from its own Handler. OwnerQueue drops
`self.name` when forwarding cancellation, and Scheduler selects the callback across
its whole task table. Executing the exact Python class bodies with two recorded
pending entries and positive native-Bool recorders produced:

```text
STAGE_QUEUE.cancelRunnable(shared_callback)
-> cancelOwnerTask("stage-task")
-> cancelOwnerTask("global-task")
```

The native scheduler correctly cancels each supplied id; the overbroad selection is
in Python. The returned queue also exposes a task-id return from postRunnable where
Android returns Boolean, recorded as a type limitation in its row.

**Fix needed:** preserve the originating queue when selecting callback-based
cancellations, retaining the existing positive-native-Bool winner and FIFO lease
release rules. This counterexample did not run native timers or schedule callbacks.

## Verification and evidence limits

- Read-only structural checks: exact set of 249 IDs, one row each, matching original
  path/line/symbol at the pinned revision, unchanged five original SDK copies/signature inputs, nonempty
  routes/contracts/evidence, concrete missing operations, and all claim flags false.
- Five isolated-AST body counterexamples ran under a **30-second process bound**.
  Boundary recorders only captured arguments/state; no plugins, live RPC, C/Host
  lifecycle or native UI were executed by these counterexamples.
- Existing named unit cases are cited as source definitions with their actual scope,
  not relabeled as new passes. Historical completed Mac 43738810843/136 reports were
  read locally: all three SDK children are green and explicitly scope their evidence
  to Host/C/SDK/Foundation DTO behavior. UIKit and production network remain outside
  those reports. Their source/prototype counts are not 249 individual runtime passes.
- This work writes only the two new `core-api` documents. Findings are for the
  implementation owners; source routes and limitations are recorded without changing
  production, scanner classifications, existing receipts or CI state.
