# Native SDK services — implementation and coordinator handoff

2026-11-15. Baselines supplied by coordinator: IPA `68bb1adf` / `43635233046`,
Foundation `496d426` / `43645893132`. This work is source/WIP, not a new IPA or
native execution pass. All changes are in the assigned new-file areas.

**Phase 2 update:** coordinator accepted Phase 1 and applied its URL/app/document
openers plus the lifetime-aware builtin Browser barrier; UI-owner composes the
provider. The remaining work described in **Phase 2** below is additive notification
publishers/ready caches, with new Core insertion hunks. Coordinator reported
`4b3f7064` green for 89 Host / 122 Core tests; the 15 Phase-1 NativeService fixtures
and new Phase-2 fixtures were not part of that result. No CI was launched here.

## Delivered interface

`TelegramUI/Sources/ExteralessClient/PluginServices/PluginNativeServicesBridgeExtension.swift`:

```swift
public final class PluginNativeServicesBridgeExtension: PluginBridgeExtension, @unchecked Sendable {
    public convenience init(services: TelegramPluginServices,
        callbacks: PluginCallbackDispatcher,
        interceptionSites: Set<NativeServiceInterceptionSite> = [])
    @MainActor public func update(context: AccountContext)
    @MainActor public func clearContext()
    public func dispatch(requestJSON: String, pluginId: String) throws -> String?
    public func releaseInstances(pluginId: String)
    public let exportedMethods: [String: Set<String>]
}
```

The full closure-injected initializer is also public. Its `platformSnapshot`
closure is thread-safe; `resolveAccount` is `@MainActor` and resolves the captured
**record id**, through `services.context(recordId:)`. It never substitutes the
currently selected account. Every admitted callback compares the request token
with a freshly captured owner's **random `wireToken`**, in addition to the C and
BridgeServices checks. Full JSON success/failure envelopes; unknown members return
nil. `exportedMethods` is immutable and excludes file/intent routes unless concrete
interception sites were supplied. BridgeServices discovery uses this table.

Wire/model fragment: **`docs/wave-2/native-services-wire.schema.json`**. `x-operations`
lists every dispatch name, argument order, result, callback arity and permission.
Its generic envelope/model definitions are a fragment; the Swift per-member reader
enforces exact allowed fields/arity and UTF-8 bounds.

### Runtime operations

| Operation | Native implementation |
|---|---|
| `postToOwner(callback, delayMs, queue)` | One real serial DispatchQueue/timer for each of the eight SDK queue names plus `UI`; never Python on main. Returns `{id}`. |
| `cancelOwnerTask(id)` | Cancels a pending scheduler entry and releases its wrapper through the original owner FIFO. Bool says whether it removed an entry; already handed-off work returns false. |
| `logEvent(model)` | Appends a structured event to **the existing** `services.serviceLogs` / `PluginServiceLogBuffer`; returns null as in sdk-wire.md. |
| `fileRegister(model, callback)` / `fileRemove(id)` | One global literal-extension owner; same-plugin replacement retires its old lease, foreign removal cannot take it. Requires a patched document site and result dispatcher. |
| `intentRegister(model, callback)` / `intentRemove(id)` | Stable priority-desc order, native filter matching, sequential asynchronous before barrier, one-shot after delivery following the original opener. |

Scheduling bounds: 128 wrappers/owner, 1024 total across this provider; scheduler
also bounds its map independently. Delay is **0...86,400,000 ms** (24h adaptation
inside the SDK's nonnegative Int32 source bound). Unknown queue names and negative
delays fail explicitly. Cancelling long delays removes entries from timer maps;
it does not retain thousands of cancelled `asyncAfter` closures until their dates.
There is one timer per queue. Callback method `run`, arguments `[]`.

`NativeServiceCallbackTransport.result(using:)` uses the coordinator's now-real
`PluginCallbackDispatcher.result(owner,handle,method,argsJSON) async throws -> String`.
It decodes the **Python result**, never the Bool from `.callback`. The lease pins
result invocations across the interval before their Task reaches dispatcher enqueue:
a concurrent unregister cannot enqueue release first. Cancellation cancels that
Task; coordinator skips result callbacks still waiting in its FIFO. An executing
callback remains under Host/watchdog policy, and its late result cannot change an
already completed opening. No Host/Dispatcher/C source was edited here.

File/intent barriers: 300 ms/handler, 2 s total; 64 concurrent openings, 1 MiB
arguments/opening and 8 MiB outstanding argument budget. Failure, timeout or pressure
falls through to native opening. Explicit caller/account cancellation suppresses
opening. Removing a registration advances past that handler immediately; it never
waits on Python. Callback leases are released on remove/unload, not on each event.

Once the Host has retired an interpreter, its C teardown owns the remaining handle
sweep. A release is never redirected to the replacement owner with the same plugin
id. Until retirement, admission/release share the captured owner's FIFO.

### Original file semantics, including the SDK/source discrepancy

Read: original Python `file_utils.py:403–410,419–432,468–567`, Java
`PluginServices.java:149–175`, `files/FilesControllerJava.java:82–113,142–204,258–277`.

- Python names its lists `whitelist_places` / `blacklist_places`, but the actual
  Java implementation tests **case-insensitive substrings of the filename**. The
  native port follows that executable behavior; it does not reinterpret strings
  like `ChatActivity` as a location filter. Extensions are literal final suffixes,
  normalized for case/leading dots; paths/globs/compound suffixes fail admission.
- `handler.onClick.callAttr("__call__", args); return true;` ignores the returned
  value. A successful dict/bool/null therefore handles the file; an exception falls
  back to the stock opener. The fixture pins a dict containing `handled:false`.
- Context contains real `file_name`, `path`, `file` (wire path string), `mime`,
  account slot, `place`, and optional partial message identity. Activity/fragment
  are null, not fabricated JVM objects. SDK should project `file` to its real
  portable `File` class (hunk below). Android custom icon factories remain false.
- The concrete document adapter reads MediaBox asynchronously without starting a
  fetch. Missing/incomplete cache returns to the original native preview/download
  path. Native protected/secret media are excluded by the callsite's export rule.

### Intent matching and opening semantics

Read: `intents.py:28–61,91–122,164–210`,
`intents/IntentsDispatcher.java:89–134,177–221,227–305,315–435`,
`browser/Browser.java:295–313`, `LaunchActivity.java:1600–1621`.

Schemes/hosts and template literals compare case-insensitively; `{name}` captures
whole path/host segments. Required query names, action, MIME, categories and flag
masks are parsed and checked, including SDK `whitelist_flags`/`blacklist_flags`
(the original Java only consumed `flags`, silently ignoring those SDK spellings).
Template captures have independent per-handler maps, with both `path_vars` and
`path_args`; reserved context fields retain native identity. `query` and
`query_args` are both supplied. First duplicate query wins, literal `+` is space,
`%2B` stays plus. Opaque **tg:** is normalized to a hierarchical Telegram URL;
other schemes retain NSURL/URLComponents parsing.

The enabled iOS sites carry ACTION_VIEW, flags 0, no Android MIME/categories.
Impossible action/MIME/category/nonzero-whitelist-flag registrations fail by name;
they are neither silently ignored nor retained as inactive handlers. This is not
an Android Activity/Intent executor. SDK ACTION_SEND/native share stays with UI-agent.

Actual before `true` suppresses later before handlers, original opening and all
after callbacks. A successful file callback has different semantics, above.
After callbacks run after the original native opener **returns**, as the Android
wrapper's `finally` does; this is not a browser page-load completion event.

## Portable controller/cache/media APIs

All below are real asynchronous native reads/fetches, with `{id}` admission and
`__call__(value, error)` delivery; error is `{kind,message}` or null. SDK uses one
unique lease per request/subscription and captures the account for query callbacks.
One-shot timeout defaults to 30 s, download to 300 s, bounded to 100...600,000 ms.
No account/network/plugin corpus was exercised during this implementation.

| Dispatch member | Model fields (all require `account`) | Actual source/effect |
|---|---|---|
| `nativeGetUser` | `id, timeoutMs?` | Cache-only Postbox peer view, then reuse TL-agent `exteralessTLGetPeer`; first value, null if peer absent. **id 0 reads this actual account's current user**, as MessagesController.java:6772–6776. |
| `nativeGetChat` | `id` **or** `peer:{type:group|channel,id}`, `timeoutMs?` | Bare positive id reads both real cache namespaces; one hit is used, no hits returns null, two hits require typed peer. No guessed namespace or invented controller. |
| `nativeObservePeer` | `peer:{type,id}` | Continuous real Postbox peer view with duplicate-value suppression; no server refresh. |
| `nativePeerInfo` | `peer, timeoutMs?` | Actual `getPeerCachedData`: about, pinned id; cached user blocked/common chats/call availability; cached channel participant/admin/banned counts. Null/unknown stays null, `partial:true`. |
| `nativeGetContacts` | `offset?, limit?, timeoutMs?` | `EngineData.Item.Contacts.List`; stable id ordering, real total, 1...500 identities/page and `nextOffset`. No iOS address-book permission/fetch is pretended. |
| `nativeMessageMedia` | `peer, messageId, timeoutMs?` | Actual message `effectiveMedia`, including rich-message documents; up to 64 file manifests with real total/export availability. |
| `nativeResourceStatus` | `peer, messageId, fileId, timeoutMs?` | Async MediaBox remote/fetching/paused/local state and real progress; first value. |
| `nativeObserveResource` | `peer, messageId, fileId` | Continuous MediaBox status; `fileId` must resolve from that actual message. |
| `nativeDownload` | `peer, messageId, fileId, timeoutMs?` | Actual `fetchedMediaResource` with message reference; owns one refcounted fetch. Success only on complete MediaBox data, returns actual path/size. |
| `nativeNotificationSettings` | `peer, timeoutMs?` | Stored peer notification overrides, explicitly inherit/unmuted/muted; missing cache/preview inheritance stays null. |

Reads require `messages.read`; download additionally `network` and `files` because
it exports an actual client cache path. Rechecks occur at native start, before the
post-transaction download fetch, and before callback admission. Cancelling an
operation disposes its own Signal/fetch reference, not other consumers' downloads.
`clearContext`/account removal cancels resources for their captured native record.

The peer projection deliberately reuses TL-agent code instead of reconstructing
Api.User/Chat or duplicating its codec. `nativeGetUser/nativeGetChat` responses use
the documented partial `getPeer` projection, with actual fields under `cached`.
Missing users/chats do not become all-zero objects. The **synchronous** Java-shaped
controller cache facades still need SDK adaptation: expose async access or warm a
`nativeObservePeer` lease and use `nativeServiceState(id)` to read its last snapshot.
Do not wait on a semaphore from a Python owner to main/Postbox to imitate getUser.

Synchronous methods:

- `nativeServiceState(id) -> {ready,kind,value}` reads a lock-published native
  subscription value; `ready:false` means no value has arrived, `ready:true,value:null`
  means the actual cache reports no peer. Same owner and current grants required.
  Retained native subscription snapshots have a combined **16 MiB** byte budget.
- `nativeConnectionState(account)` reads real `Account.networkState` publication:
  waitingForNetwork/connecting/updating/online. Before publication: ServiceUnavailable.
- `nativeServiceCancel(id)` and `notificationUnsubscribe(id)` return whether they
  removed that owner's operation; admitted leases always receive FIFO release.

### NotificationCenter — three live mappings, not an empty registry

`notificationSubscribe({account,event}, callback) -> {id}`;
callback `__call__(sourceId, actualAccountSlot, [])` maps to
`delegate.didReceivedNotification(id,account,args)`. SDK must use a distinct wrapper
for each subscription. `notificationSupported(account)` fails if publishers are
not attached and otherwise returns **only**:

| Android source id/name | Native publisher |
|---|---|
| **25 contactsDidLoad** | Actual `engine.data.subscribe(Contacts.List)` first publication/peer-list change. |
| **46 mainUserInfoChanged** | `engine.data.subscribe(Peer.Peer(id: account.peerId))`, subsequent actual peer changes. |
| **137 didUpdateConnectionState** | Actual `account.networkState`, subsequent state changes. |

Source ids were computed from checked-in `NotificationCenter.java`'s `totalEvents++`.
Original `ContactsController`, `MessagesController`, `ConnectionsManager` callsites
for these events pass no payload arguments. Read both Java and Kotlin trees; these
services/controllers are Java here. No Foundation NotificationCenter name is used
as a fictitious Android publisher. In particular `didReceiveNewMessages`,
`onDownloadingFilesChanged`, `fileLoaded`, playback, contactsImported and dialogs
reload are **not** advertised without matching native events/payloads. Native
per-file status/download APIs above provide the portable implemented path.

## Coordinator insertion hunks (assigned common files; not applied here)

### 1. Composition before `host.start()`

`Sources/Exteraless/ExteralessPluginRuntime.swift`:

```diff
@@
     private var tlServices: PluginTLBridgeExtension?
+    private var nativeServices: PluginNativeServicesBridgeExtension?
@@ public func update(context: AccountContext)
         tlServices?.update(context: context)
+        nativeServices?.update(context: context)
@@ public func clearContext()
         tlServices?.clearContext()
+        nativeServices?.clearContext()
@@
                 let services = self.services
+                let native = PluginNativeServicesBridgeExtension(
+                    services: services, callbacks: callbacks,
+                    interceptionSites: [.chatDocument, .externalURL, .applicationURL])
+                NativeServiceOpenHooks.shared.install(provider: native)
+                if let context = self.currentContext { native.update(context: context) }
+                self.nativeServices = native
@@
                 host.bridge.extensionProvider = CompositePluginBridgeExtension([
-                    ui, ClientSettingsBridgeExtension(permits: { callbacks.hasPermission($0, $1) }), tl,
+                    ui, ClientSettingsBridgeExtension(permits: { callbacks.hasPermission($0, $1) }), tl, native,
@@ public func terminate() async
         tlServices?.clearContext()
+        nativeServices?.clearContext()
```

Include a site in `interceptionSites` only with its hunks below. Empty sites leave
task/log/account services usable and file/intent admission explicitly unavailable.
The composition already imports PluginHost; all provider sources are TelegramUI.

### 2. Actual external browser barrier

In `Sources/OpenUrl.swift`, replace the opening of `openExternalUrlImpl` with this
wrapper; the existing body starting with the login-part comment becomes the new
`openExternalUrlAfterNativeServices`. Its three `openCheckedExternalUrl` calls stay
inside that body. The original stock URL/confirmation implementation is retained.

```diff
@@
 func openExternalUrlImpl(context: AccountContext, urlContext: OpenURLContext, url: String, forceExternal: Bool, presentationData: PresentationData, navigationController: NavigationController?, dismissInput: @escaping () -> Void) {
     let url = ClientSettings.shared.bool("chats.stripTrackingOnOpen", default: true) ? ChatLinkPolicy.removingTracking(from: url) : url
+    let original = {
+        openExternalUrlAfterNativeServices(context: context, urlContext: urlContext, url: url, forceExternal: forceExternal, presentationData: presentationData, navigationController: navigationController, dismissInput: dismissInput)
+    }
+    if let parsed = canonicalExternalUrl(from: url), MainActor.assumeIsolated({
+        NativeServiceOpenHooks.shared.interceptURL(context: context, url: parsed, original: original)
+    }) { return }
+    original()
+}
+
+private func openExternalUrlAfterNativeServices(context: AccountContext, urlContext: OpenURLContext, url: String, forceExternal: Bool, presentationData: PresentationData, navigationController: NavigationController?, dismissInput: @escaping () -> Void) {
     // A login part hides the host a link opens (see `externalUrlWithLoginPart`). Every external link leaves through
```

The captured continuation calls the unwrapped body, preventing recursion. MainActor
assumption is at the already-main native opening site; the Python C callback never
uses it or waits on main.

### 3. Actual document-opening barrier

In `Sources/OpenChatMessage.swift`, within `.document(file, immediateShare)`, after
the `let proceed = { ... }` block at present lines 240–280:

```diff
@@
                     }
+                    let proceedWithNativeServices = {
+                        let handled = MainActor.assumeIsolated {
+                            NativeServiceOpenHooks.shared.interceptFile(
+                                context: params.context, file: file, messageId: params.message.id,
+                                place: params.navigationController?.topViewController is ChatController ? "ChatActivity" : "UNKNOWN",
+                                exportAllowed: !params.message.isCopyProtected() && !params.copyProtected && params.message.secretMediaDuration == nil,
+                                original: proceed)
+                        }
+                        if !handled { proceed() }
+                    }
                     if file.mimeType.contains("image/svg") {
```

In that SVG alert's default action replace **`proceed()`** with
**`proceedWithNativeServices()`**, and make the same replacement in its following
`else`. Thus native confirmation precedes plugin file export; the continuation
still constructs the existing BrowserScreen/QuickLook. Immediate share is its own
operation, not a claimed document-open interception. Other callers of this common
document path report UNKNOWN unless an actual ChatController is on top.

### 4. Incoming app URLs, with `from_intent:true`

`Sources/AppDelegate.swift`, `openUrl(url:)`'s authorized branch: wrap its existing
wallet/ordinary-open block in a continuation and use the bridge before that block.

```diff
@@
             } else if let context = context {
+                let nativeOpen = {
                 if (WalletContext.isTonConnectUrl(url.absoluteString) || url.scheme?.lowercased() == "ton"), !WalletConfiguration.with(appConfiguration: context.context.currentAppConfiguration.with { $0 }).isAvailable {
@@
                 } else {
                     context.openUrl(url, external: true)
                 }
+                }
+                let intercepted = MainActor.assumeIsolated {
+                    NativeServiceOpenHooks.shared.interceptURL(context: context.context, url: url, fromIntent: true, original: nativeOpen)
+                }
+                if !intercepted { nativeOpen() }
             } else if let authContext = authContext {
```

`openUrlWhenReady`'s `.start(next:)` (present 3023–3038):

```diff
@@
         |> deliverOnMainQueue).start(next: { [weak self] context in
+            let nativeOpen = {
             if (WalletContext.isTonConnectUrl(url.absoluteString) || url.scheme?.lowercased() == "ton"), !WalletConfiguration.with(appConfiguration: context.context.currentAppConfiguration.with { $0 }).isAvailable {
@@
             } else {
                 context.openUrl(url, external: external)
             }
+            }
+            let intercepted = MainActor.assumeIsolated {
+                NativeServiceOpenHooks.shared.interceptURL(context: context.context, url: url, fromIntent: true, original: nativeOpen)
+            }
+            if !intercepted { nativeOpen() }
@@
             Queue.mainQueue().after(1.0, {
```

The captured account has already been selected/resolved here. Logged-out auth
flows do not claim active plugin accounts. SDK/Host maintenance owns wallet freeze
and permission scope gates; this provider does not create a second executor.

### 5. SDK/builtin direct URL openers also need the barrier

`Sources/Exteraless/TelegramPluginServices.swift`, replace `openURL` with:

```swift
public func openURL(_ url: URL, pluginId: String) throws {
    let snapshot = self.platformSnapshot
    let account = try snapshot.account(at: snapshot.selectedAccount())
    let logs = self.serviceLogs
    DispatchQueue.main.async { [weak self] in
        guard let self, let context = self.context(recordId: account.recordId) else { return }
        let original = {
            UIApplication.shared.open(url, options: [:], completionHandler: { opened in
                if !opened { logs.append(pluginId: pluginId, level: .error, message: "Browser.openUrl: iOS could not open the URL") }
            })
        }
        let intercepted = MainActor.assumeIsolated {
            NativeServiceOpenHooks.shared.interceptURL(context: context, url: url, original: original)
        }
        if !intercepted { original() }
    }
}
```

Native UI-agent-owned `PluginUIBridgeExtension.swift:252–254`, exact local hunk for
that agent (its existing owner/scope/permission checks surround this):

```diff
@@
                 if let url {
                     guard self.hasPermission(pluginId, .intents) else { return }
-                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
+                    guard let context = self.accountContext else { return }
+                    let original = { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
+                    if !NativeServiceOpenHooks.shared.interceptURL(context: context, url: url, original: original) { original() }
```

Native UI owns its existing presentation generation; apply this inside its current
main callback, not by routing Python onto UIKit. Both native/browser and incoming
TG handling may fire distinct false/true `from_intent` events, as the original
Browser -> LaunchActivity chain does.

## SDK-side handoff (SDK/coordinator owns Python)

1. **Background post publication race:** `_scheduling.Scheduler.post` currently
   writes `lease.id`, `native_owned`, `tasks`, `on_close` after host admission. A
   zero-delay owner callback may finish before a background posting thread reaches
   those writes. Do not rely on a small artificial native delay. Serialize lease
   publication/terminal bookkeeping with `platform.callbacks.lock` (including
   task dictionary mutations/removal), and ensure an already-closed lease is never
   inserted afterward. Cancellation is allowed only on the owner, as already gated.
   Its `run` wrapper must call the user function and **return None**, like the
   original Java Runnable, rather than exporting an ignored arbitrary Python result
   through `_codec.dumps` (which can otherwise create unused C return handles).
2. **File result must really be ignored:** in `_registrations.register_file`, wrap
   the passed SDK `_FileOpenCallback` before `registry.add`:

   ```python
   if not callable(callback):
       raise TypeError("file registration requires a callable on_click")
   def native_click(context):
       from ._java_types import File
       context = dict(context)
       if isinstance(context.get("file"), str):
           context["file"] = File(context["file"])
       callback(context)  # exceptions propagate through the lease/Host result
       return None        # original Java ignores even non-JSON callback returns
   # Pass native_click, rather than callback, to registry.add("file", model, ...).
   ```

   The supplied native fixture covers a returned JSON dictionary already. This
   wrapper additionally prevents serialization of an arbitrary ignored Python
   return value from being mistaken for a user callback exception or exporting
   unused C return handles.
3. Wire the added controller/subscription facades to the **exact x-operations**.
   Terminal requests need a terminal SDK lease wrapper; native owns admitted C
   handles and releases them through the coordinator's `release_handles_json`.
   `nativeObservePeer/nativeObserveResource/notificationSubscribe` retain their
   wrapper until cancellation/unload. For delegate notifications wrap
   `didReceivedNotification(id,account,args)` as a callable (method `__call__`),
   with the original no-implicit-hook-account behavior.
4. File/intent native removal and all account teardown releases already invalidate
   native leases; the SDK should also retire its original FileController/IntentsManager
   Python registration dictionaries on silent native retirement if reuse is supported.

## New files / dependencies

- `swift/PluginHost/Sources/PluginHost/NativeService{Wire,Callback,Scheduler,InterceptionModels,OpenBarrier,Operations,LogEvent}.swift`:
  Foundation-only models, queues, lease/result lifetime, bounded registry and log projection.
- `swift/PluginHost/Tests/PluginHostTests/NativeServiceTests.swift`,
  `NativeServiceDispatcherTests.swift`; `swift/PluginHost/NativeServiceSourceTests.py`.
- `TelegramUI/Sources/ExteralessClient/PluginServices/{PluginNativeServicesBridgeExtension,NativeServiceAccountModel,NativeServiceOpenHooks}.swift`.
- `TelegramCore/Sources/ExteralessRuntime/NativeServiceAccounts.swift`,
  `NativeServiceMedia.swift`: direct Postbox access stays in Core. No Postbox or
  TelegramApi import/access in the new UI files; no UIKit in the Core helpers.

Existing Source globs should include these; build-agent owns BUILD/Package changes.
No new package/binary dependency. Core helpers use existing Foundation/Postbox/
SwiftSignalKit and reuse existing TL-agent peer/value APIs. UI uses existing
AccountContext/TelegramCore/PluginHost/SwiftSignalKit. No umbrella Postbox alias.

## Checks and remaining constraints

- Executed own source checks: **5 passed**, command
  `python swift/PluginHost/NativeServiceSourceTests.py`, external 30 s cap. It checks
  original event IDs + real source publishers, SDK queue constants, schema/export
  route consistency, original file return/filter behavior, and the actual existing
  `PostboxImportCheck` parser against the three new UI files.
- Authored **15** bounded XCTest cases for actual named scheduler independence, delay/
  cancel/FIFO cleanup, budgets/stale generation, async-result lease pinning, source
  file dict semantics, URL parsing/filtering, actual-result vs admission, priority/
  after delivery, timeout/late return, account cancellation, byte-bounded structured
  log redaction, and snapshot/late-disposable races. A FakeEngine-only Host fixture
  drives **the actual dispatcher.result** path and checks invocation-before-release.
- **Not executed locally:** Swift/Swiftc and WSL are unavailable on this Windows
  host. XCTest/typechecking/iOS linkage, integrated native effects and visual frames
  remain coordinator gates. Run only these tests after compilation with an external
  30 s process cap, e.g. `swift test --package-path swift/PluginHost --skip-build
  --filter NativeService`; no real account or network is needed by the fixtures.
- Hunk application and Python facade changes above are integration dependencies,
  not claimed as applied. No commit/push/CI dispatch was performed.
- Logs retain structured canonical JSON in the existing 4096-byte default record,
  with error/warning native severity preserved; debug is an info bucket with
  explicit structured `level:"debug"`. Native error text/phase survives bounded
  redaction of labelled credentials and URL userinfo. Custom buffers smaller than
  the default may truncate their message as for any existing log entry.
- Android raw SQLite/JVM objects (`MessagesStorage.getDatabase/executeFast`,
  arbitrary controller private fields, Xposed/Dex), Android activity MIME/categories/
  flags and custom file drawables have named platform constraints. Location/secret-
  chat controllers, global playback controller mutation, complete synchronous Java
  cache/controller APIs (including username getter overloads), non-cloud/local or
  scheduled message resource ids, arbitrary media mutations and unmapped NotificationCenter
  ids are not implemented/advertised by this provider. TL requests/media send stay
  with TL-agent; native widgets/presentation stay with UI-agent.

## Phase 2 — real notification payloads and synchronous ready caches

### Static source/corpus evidence

Read the actual Android emitters and delegate consumption, without importing or
executing a corpus plugin. `third_party/corpus/all` currently contains **20 source
files** (variants are counted separately). Lexical references, not a compatibility
percentage:

| Member | References / files |
|---|---|
| `getUser` | 12 / 7 |
| `getChat` | 10 / 7 |
| `getClientUserId` | 4 / 3 |
| `getCurrentUser` | 5 / 4 |
| `didReceiveNewMessages` | 3 / 1 (`auto_forwarder.plugin`) |
| `getNotificationCenter` | 2 / 1 |
| targeted file/download/playback notification names, `getContacts`, `getUserFull`, `getChatFull` | 0 in this collected subset |

`auto_forwarder.plugin:274–305` reads `args[1]` as a MessageObject list, then
`messageOwner.out/message/peer_id`; `:792,1541–1559` reads current user and user/chat
caches. Therefore a fake empty argument list or all-default Message is unusable.
Reproduce the read-only report with:
`python swift/PluginHost/NativeServicePhase2SourceTests.py --corpus`.

Original payload/frequency evidence:

- `MessagesController.java:22511`: `(dialogId, messages, scheduled, mode)`;
  `:20312–20314` ephemeral messages use the same four arguments; `:21508–21510`
  welcome messages carry a different mode. Native scope here is ordinary cloud-peer
  messages, including local/scheduled namespaces, not welcome/quick-reply/secret encodings.
- `ImageLoader.java:2258–2299`: loaded `(location, finalFile)`, failure
  `(location, canceledReason)`. `FileLoadOperation.java:2158–2204` distinguishes
  generic **0**, cancellation **1**, retry limit **2**. Native generic fetch errors
  map to 0; disposing one refcounted subscriber does not fabricate reason 1.
- `DownloadController.java:1527–1742` / `FileLoader.java:624,646,1904` emit
  `onDownloadingFilesChanged` with no arguments, on actual list changes.
- `MediaController.java:1767,1775` emits `(messageId, progressFraction)` from its
  17 ms visible progress timer (hidden audio throttles to 1 s); `:2757` seek uses
  the same two fields; `:3630,4210` start uses `(newMessageObject, oldMessageObject)`;
  pause/play state uses `(messageId)`. The native adapter subscribes to real
  `MediaPlayerStatus`; it adds **no progress timer**.
- `dialogsNeedReload` has both zero-argument and optional-true callsites in
  `MessagesController`; the native chat-list view invalidation maps to its valid
  zero-argument variant. The actual native window is root 64 / archive 16.

### Advertised events and exact callback args

`notificationSubscribe({account,event}, callable)` still delivers
`callable(sourceId, actualAccountSlot, args)`. All numeric ids below are pinned by
the Phase-2 test to the checked-in `NotificationCenter.java`, not upstream guesses.
`notificationSupported(account)` returns only the installed subset.

| ID / event | `args` | Native publisher / availability |
|---|---|---|
| 1 `didReceiveNewMessages` | `[dialogId, [MessageObjectDTO], scheduled, 0]` | **Core hunks A/B below**, after original transaction commit. All applied ids are read before the notification mute/read filter. |
| 3 `dialogsNeedReload` | `[]` | Changed non-loading `engine.messages.chatList` root/archive windows. Initial snapshot is suppressed. |
| 25 `contactsDidLoad` | `[]` | Actual `contactPeerIdsView` publication/change; no full contact-user materialization. |
| 46 `mainUserInfoChanged` | `[]` | Actual self `EngineData.Item.Peer.Peer` changes. |
| 137 `didUpdateConnectionState` | `[]` | Actual Account.networkState changes. |
| 142 `fileLoaded` | `[resourceKey, absoluteFilePath]` | **Core hunk C**: successful native fetch completion, then one MediaBox read confirming complete data. |
| 143 `fileLoadFailed` | `[resourceKey, 0]` | **Core hunk C**: the actual native fetch error, not a guessed remote/paused transition. |
| 148 `messagePlayingProgressDidChanged` | `[messageId, fraction]` | Actual finite timestamp/duration publication; no fabricated tick. |
| 150 `messagePlayingPlayStateChanged` | `[messageId]` | Actual message-backed native player state changes. |
| 151 `messagePlayingDidStart` | `[newMessageDTO, previousMessageDTOOrNull]` | Actual native track change, after its real cached Message was read. |
| 152 `messagePlayingDidSeek` | `[messageId, fraction]` | A change of native `MediaPlayerStatus.seekId`, not an inferred timestamp jump. |
| 306 `onDownloadingFilesChanged` | `[]` | **Actual** `FetchManagerImpl.entriesSummary`; advertised only if that concrete native publisher is present. |

File events require `messages.read` **and** `files`; other listed events require
`messages.read`. File keys use actual `MediaResource.id.stringRepresentation`.
SDK's native FileLoader facade must use that same opaque key; it is not an invented
Android `dc_id_documentId.ext` filename. Convert the loaded path to the existing
portable SDK `File` object at the delegate boundary.

No entry is exposed for Android reset **149** (its `stopService` flag has no native
Android Service equivalent), global playback speed **288**, or VideoPlayer-object
start **286**. The latter carries a JVM player object, not a message DTO. Native
playback snapshots do expose the real rate. Non-message playlists have no invented
MessageObject id: their snapshot remains not ready. Arbitrary HTTP ImageLoader
tasks, upload events, welcome/quick-reply modes, community/secret-dialog encodings
and other unmapped ids remain explicit scope/platform obstructions.

#### MessageObjectDTO

`NativeServiceMessageValue.swift` reads actual `Postbox.Message` fields:

```text
{
  nativeType: "MessageObject", partial: true,
  currentAccount: actualSlot, dialogId: AndroidCompatibleCloudDialogId,
  namespace: actualNativeMessageNamespace,
  isForwarded: Bool, source: "Postbox.Message/native-message-v1",
  messageOwner: {
    id, date, message, out, peer_id, from_id?, grouped_id,
    unread? (only with actual cached read-state), reply_to?, entities, media
  }
}
```

Peer and entity TL values reuse existing Core Api conversion/snapshot functions.
Media is explicitly **partial native data**, not a synthetic TL constructor:
file/image ids, MIME/name/size, native resource keys, real cloud access hash/file
reference when stored, image dimensions. Unrepresented native media has a named
`nativeType` and `unsupportedFields:true`, not a fabricated empty media. No pts,
flags or missing access hash are initialized to zero.

SDK-agent must project the outer list to its ArrayList port and each DTO to a
NativeMessageObject facade (`getId/getDialogId/isOut/isForwarded` from these actual
fields; `messageOwner` from the data). Native file/photo descriptors must remain
partial and reject unavailable members; they must not pass through a TL decoder
which invents defaults. Delegate returns are void/ignored. The owner worker wrapper
should return None to avoid exporting unused arbitrary Python return handles.

### Bounded ordered delivery and disposal

`NativeServiceEventDelivery` is a provider buffer above the existing dispatcher:
**256 outstanding events per owner, 32 MiB JSON total, executing event included**.
One result-bearing dispatcher call per owner is outstanding. Coalescible status
updates replace only the trailing status segment; they never cross message,
file-terminal, playback-start or seek events. Committed ids retain their producer
order; no NativeService code requests/updates/reorders transport pts.

The producer budgets before a main-queue hop. Core batches at most 16 adjacent
same-dialog/schedule messages / 512 KiB, with a 256 KiB individual DTO bound.
Unrepresentable/oversized critical data and exhausted delivery budgets retire the
subscription with a named native diagnostic, rather than leaving a silently gapped
active registration. The 30 s invocation deadline cancels queued owner work;
execution still goes through the existing Host watchdog. These are deadline/control
timers, not client-status polling.

Wakeups are bounded too: one pending event-pump wakeup per owner and one coalesced
main binding drain for referenced-peer views. Repeated coalesced status events or
thousands of cache misses cannot accumulate uncounted GCD work items.

Every callback lease now also captures its **native account epoch**, independent
of CallbackOwner's interpreter epoch. `shouldExecute` on the existing dispatcher
checks the live lease/account/permissions immediately before entry. Cancel, account
replacement and unload remove queued events and dispose source subscriptions
idempotently. The new `NativeServiceAcknowledgedRelease` keeps pool admission credit
until the dispatcher's **Bool release admission** succeeds (or that interpreter is
retired). A bounded release retry queue merges closed handles, so rapid post/cancel
cannot make an unbounded control backlog or silently lose refused releases.

Use the convenience provider initializer, which installs that acknowledged path.
For custom composition pass `acknowledgedRelease:
NativeServiceReleaseTransport.acknowledged(callbacks)` and use the same transport
for the legacy `release` closure; a Void closure that discards a refused release is
not a reliable cleanup transport.

### Synchronous ready-cache API (no owner-to-main wait)

New Runtime methods use the same response envelope and a value with
`{ready,kind,value,source?,generation?,revision?}`. **Only `ready:true` is usable.**
All require a current owner token plus `messages.read`.

| Method | Positional args | Actual ready data |
|---|---|---|
| `nativeCachedUser` | `[account,id]` | Native peer header; id 0 is the actual account user. |
| `nativeCachedChat` | `[account,idOrTypedPeer]` | Both group/channel caches are observed for a bare id; ambiguous hits require typed peer. |
| `nativeCachedClientUser` | `[account]` | Same actual self header. |
| `nativeCachedClientUserId` | `[account]` | Real platform account peer id, not a placeholder account 0. |
| `nativeCachedUserFull` | `[account,id]` | Actual cached full-info fields including **id/user_id**, about, blocked/call/common-chat/pinned data. |
| `nativeCachedChatFull` | `[account,idOrTypedPeer]` | Native CachedGroup/ChannelData fields; cached group admin identities/count/version, explicitly bounded; channel admin count with unknown identities null. |
| `nativeCachedContacts` | `[account]` or `[account,offset,limit]` | Real cached contact ids. Whole-list form is not ready if the 512 retained ids are only a prefix; paged form serves only retained, actually known ranges. |
| `nativeCachedConnection` | `[account]` | Last actual Account.networkState. |
| `nativeCachedPlayback` | `[account]` | Actual active/message/state/position/duration/rate/progress, or actual inactive state. |
| `nativeCachedDownloads` | `[account]` | Actual native download-list entries, total and explicit truncation. |

`NativeServiceControllerSnapshots` pins self plus root 64/archive 16 active peers;
lazy referenced peer views use an LRU capped at **256/account**, **32 MiB combined
ready data**. It never scans all Postbox peers or materializes 20k contact users at
startup. Contact observation uses ids only. A first uncached getter enqueues one
native view subscription and returns not ready immediately; there is no semaphore,
main.sync, implicit RPC or polling. Existing async operations remain the explicit
fallback for unloaded peers/full info or larger contact pages.

Postbox's absent `remoteContactCount` reads as zero; it is not a contacts-loaded
flag. Consequently an initially empty contact-id cache stays not ready (including
a genuinely empty account after restart) until there is real populated data or an
explicit async read. A later observed clear of a populated cache is a real empty
snapshot. This conservative empty-cache limitation avoids advertising a fabricated
zero-contact controller; no contact-sync RPC is started to resolve it.

Snapshot headers are marked partial; `source` pins the actual native field source.
Unknown cache/full-info remains not ready, distinct from an existing deleted User.
Every account replacement gets a new generation, and every LRU eviction/re-reference
gets a new publisher token, so late values cannot resurrect an old account/peer.
Committed-message sender/dialog headers are seeded before notification admission.
The cache is account-owned native data and contains no Python handles; each getter
still rechecks the calling interpreter and grants.

### Phase-2 coordinator/Core hunks — C applied, A/B assigned separately

Per coordinator's additional authorization, **C is now applied** in the existing
`Network/FetchedMediaResource.swift`, only in its `ranges:` overload. A is assigned
to TL-owner, B to Chat-owner; UI-owner enables `publisherSites` after all three
sites are connected.

UI-owner adds the parameter when composing the provider **after applying A/B/C**:

```swift
PluginNativeServicesBridgeExtension(services: services, callbacks: callbacks,
    interceptionSites: existingSites,
    publisherSites: [.committedMessages, .mediaFetch])
```

Until then, the implemented direct chat-list/download-list/playback/ready-cache
services operate, and message/file-terminal registration fails by name. No changes
to Host, CallbackDispatcher, C, Runtime or BUILD were made for this slice.

**A — `TelegramCore/Sources/State/AccountStateManager.swift`, processEvents:**

```diff
@@
                 let signal = self.postbox.transaction { transaction -> [([Message], PeerGroupId, Bool, MessageHistoryThreadData?)] in
+                    nativeServicePublishCommittedMessages(postbox: self.postbox, transaction: transaction,
+                        messageIds: events.addedIncomingMessageIds)
                     var messageList: [([Message], PeerGroupId, Bool, MessageHistoryThreadData?)] = []
```

This is the existing post-replay read transaction. Do not use
`stateManager.notificationMessages`: `messagesForNotification(...alwaysReturnMessage:
false)` omits muted/read/unjoined cases. Do not use `pollStateUpdateCompletion`:
its implementation actually sends `help.test`.

**B — `TelegramCore/Sources/PendingMessages/EnqueueMessage.swift`, ONLY the
post-transaction map in `enqueueMessagesWithPrivacyAuthorization`:**

```diff
@@
-        |> map { resultIds, ephemeralMessageIds -> [MessageId?] in
+        |> mapToSignal { resultIds, ephemeralMessageIds -> Signal<[MessageId?], NoError> in
             for messageId in ephemeralMessageIds {
                 let _ = _internal_sendEphemeralOutgoingMessage(account: account, messageId: messageId).startStandalone()
             }
-            return resultIds
+            return nativeServicePublishEnqueuedMessages(account: account, messageIds: resultIds)
         }
```

The original enqueue/authorization commits first. The helper is a cold local read
of those returned ids; it preserves their order and the caller's result, excludes
unsupported welcome/ephemeral modes, derives scheduled from the actual namespace.
This closes the corpus's outgoing `messageOwner.out` notification path too.

**C — APPLIED — `TelegramCore/Sources/Network/FetchedMediaResource.swift`:** wrap only the
**ranges:** overload, using its unique body/return anchors below. Indent its
existing body once inside the local function; no duplicate fetch implementation.
The short range overload already calls this overload, so it needs no second hook.

```diff
@@
 ) -> Signal<FetchResourceSourceType, FetchResourceError> {
+    func nativeServiceOriginalFetch() -> Signal<FetchResourceSourceType, FetchResourceError> {
     var isRandomAccessAllowed = true
@@
         ), implNext: reportResultStatus)
     }
+    }
+    return nativeServiceTrackMediaFetch(mediaBox: mediaBox, reference: reference,
+        signal: nativeServiceOriginalFetch())
 }
```

The wrapper subscribes to the original Signal exactly once, passes its completion/
error through, and captures the original native account source. A range completion
is not called fileLoaded until actual MediaBox data is complete. Completed-file
lookups are bounded to 128/account, two seconds, and disposed with that account.
Native generic error maps to original reason 0; no Android cancellation is inferred.

**Applied-C routine source check — PASS** (local process capped at 30 s):

```text
PASS original ranges-overload fetch body equals its pre-patch body after dedenting
PASS complete source outside that overload equals the pre-patch source
PASS two public overloads; one nativeServiceTrackMediaFetch wrapper/factory call
PASS original signal stays cold; exactly one of the helper's subscription branches runs
PASS fileLoaded requires actual MediaBox data.complete; errors/disposal pass through
PASS no retry wrapper and no partial-range/cancel success fabrication
PASS git diff --check for FetchedMediaResource.swift and this handoff
```

The pre-patch file had no working-tree diff; comparison used its Git version and
also checked the helper's existing complete-data guard. This is source verification,
not an executed account/download or Swift/framework runtime test.

### Phase-2 files and checks

New pure files: `NativeServiceSnapshots.swift`, `NativeServiceEventDelivery.swift`,
`NativeServicePlayback.swift`, `NativeServiceReleaseQueue.swift`; owned callback/
operation helpers updated. New Core files: `NativeServicePeerHeader.swift`,
`NativeServiceMessageValue.swift`, `NativeServiceAccountEvents.swift`; owned
`NativeServiceAccounts.swift` gains id-only contacts/live cached-data observations.
New UI files: `NativeServiceControllerSnapshots.swift`, `NativeServiceLivePublishers.swift`;
owned provider integrates them. Existing dependencies already include FetchManagerImpl
and UniversalMediaPlayer. Core imports no UIKit; new UI has no Postbox import/access.

Executed **only the new Phase-2 source suite**: **5 passed / 0.040 s**, hard 30 s tool
cap (`python swift/PluginHost/NativeServicePhase2SourceTests.py`). It pins original
ids/payload callers, installed-source filtering, wire names, non-polling/id-only
contacts, and runs the real PostboxImportCheck parser on changed/new UI files.
Authored **8 additional bounded Swift fixtures** in `NativeServicePhase2Tests.swift`:
cache miss/epochs/LRU/byte bounds, coalescing across critical-message boundaries,
executing-event quota/cancellation, execution-time validity, acknowledged release
credit, real playback seek/payload shapes. These were not executed here; Swift is
unavailable. No account, network/HTTP test, corpus execution, commit or CI dispatch.
