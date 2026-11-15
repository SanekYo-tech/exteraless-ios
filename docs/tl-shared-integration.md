# TL shared integration — source handoff

## Applied in the working tree

The TL owner applied the authorized phase-2 insertions from `docs/wave-2/tl.md`:

- `TelegramCore/Sources/Network/Network.swift`: both cold Signal generators enter
  the transforming path after weak-self validation and before privacy/willSubmit.
- `Account/Account.swift`: managed TL account lease beside the privacy lease.
- `State/{UpdateGroup,UpdateMessageService,AccountStateManagementUtils}.swift`:
  container provenance and accepted live/difference barriers. The interpreter uses
  the exact order previewed by the channel ledger (`updatesAreSorted: true`).
- `PendingMessages/RequestEditMessage.swift` (the actual path): upload attributes,
  mandatory-upload checks, retry forwarding and descriptor-bound request origin.
- `PendingMessages/PendingMessageUploadedContent.swift` and the edit uploader:
  all 11 `docs/tl-upload-origin.patch` hunks are applied, including both upload RPC
  wrappers, five photo/file forwards and explicit edit-upload ancestry.
- `swift/PluginHost/Sources/PluginHost/{PluginHost,ExtensionPoints,PluginEventQueue}.swift`
  and new `PluginTLHostPayload.swift`, `PluginTLInvocationOrigin.swift`: awaiting
  events, per-plugin normalization/priority, captured handles, worker-time permission,
  cancellation and owner checks. Maintenance's private queue barrier, HostActivity,
  state admission, native-effect gates and lifecycle implementation are retained.

Additional authorized integrations are also applied:

- Dialogs: remote-unpin echo guard in `AccountStateManagementUtils.swift`, only in
  `.UpdatePinnedItemIds/.unpin/.peer`. Uses the existing server-prefix helper.
- Native services A: `nativeServicePublishCommittedMessages` in
  `AccountStateManager.swift`'s post-replay `processEvents` read transaction, before
  `messagesForNotification` filters the incoming ids.
- Privacy Extras: six replay transaction callers in `AccountStateManager.swift`
  now invalidate presentations in `afterNext`, only for nonnil replay results
  (`value.finalStatte` in the two difference tuples). Original returned values,
  replay verification arguments and operation FIFO are retained.
- Network/Maps: resolver TCP factory is installed before the base-factory capture
  and WEB override; backup discovery uses `ExteralessNetworkBackupDNS.backupSignal`.
  Both exact `network-maps-network-hunk.patch` insertions are applied in Network.swift.

## Coordinator callback-origin handoff

Inspection now finds the property, adapter installation, `refreshSubscriptions`,
`clearContext`, termination detach and Bool release closure already applied in
`TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift`. Do not reapply those
older tl.md hunks. Transform and observation subscriptions must stay coupled to
the same live Host flags/account. Empty gates retain the native original path.

**Remaining callback-origin hunk** in that file, before its main-actor hop:

```diff
@@
 guard let self, let host, let owner = host.callbackOwner(id: pluginId), owner.wireToken == ownerToken else { return false }
+let tlOrigin: PluginTLInvocationOrigin?
+do { tlOrigin = try PluginTLNativeOrigin.capture(owner: owner) }
+catch { return false }
 Task { @MainActor in
     self.enqueueCallback(host: host, owner: owner, handle: handle,
-                         method: method, json: json, delayMs: delayMs)
+                         method: method, json: json, delayMs: delayMs, tlOrigin: tlOrigin)
 }
@@
 private func enqueueCallback(host: PluginHost, owner: PluginHost.CallbackOwner, handle: Int64,
-                             method: String, json: String, delayMs: Int) {
+                             method: String, json: String, delayMs: Int, tlOrigin: PluginTLInvocationOrigin?) {
@@
 try await host.invokeCallback(id: owner.pluginId, handle: handle, method: method,
-                              argumentsJSON: json, expectedOwner: owner)
+                              argumentsJSON: json, expectedOwner: owner, tlOrigin: tlOrigin)
```

This uses the implemented optional `tlOrigin:` parameter on Host's expected-owner
callback APIs. The value is native, immutable and per invocation; it requires no
new C field, Python ambient flag, extra callback handle or release operation.
Scheduled callbacks keep their existing completion/refcount behavior. TL service
callbacks instead bind ancestry to their existing unique `(CallbackOwner, handle)`
lease and retire it after `release_handles_json` or interpreter retirement.

## SDK-owner exact contract

Current SDK source already contains `hook_priority_json`, `Schema.hook_names`,
`_matching_priorities`, transforming `snapshot.tl` decoding and readonly context.
Host calls on the **captured owner worker**:

```python
hook_priority_json("pre_request_hook", "TL_messages_sendMessage", "messages.sendMessage")
# JSON Int32 priority (maximum matching registration), or JSON null.
```

The other protocol names are `post_request_hook`, `on_update_hook`,
`on_updates_hook`. Native dispatch now explicitly includes `canonical_name` as
well as `request_name` / `update_name` / `container_name`. For post-request matching,
the canonical name is always the RPC method, never its response constructor.
Match the generated `hookNames` aliases plus canonical/short names, preserving
Android's exact request/update/container partition and shared substring matching.
Host sorts priority descending, then plugin id. A priority query/decoder failure
is diagnostic-only; it does not unload a current or replacement generation.

The selected value field contains:

```json
{"schemaVersion":1,"observational":false,"phase":"preRequest",
 "metadata":{"requestName":"messages.sendMessage","accountRecordId":123},
 "tl":{"_":"messages.sendMessage"},"canCancel":true}
```

`tl` above is schematic; real fields come from the generated schema. Decode only
`tl` into the SDK TL class/vector. Keep metadata, `canCancel`, phase and optional
`tlError` in readonly `_exteraless_tl_context`, outside TL `_values`. HookResult
returns `strategy` and `request` / `response` / `update` / `updates` (or unambiguous
`params`). DEFAULT and CANCEL may retain the input value. MODIFY values are
normalized between plugins and again at the Core boundary.

Post metadata includes actual response timestamp/duration/networkType. RPC errors
carry `response = null` and schema `error`; error-to-success fabrication is refused.
The Host observer builder unwraps its historical one-element container envelope
and passes `tlError` as the error object, so observational fallbacks use the same
real SDK values. Observational results remain nonmutating.

## Recursion and applied media seam

Android's `ConnectionsManager.sendRequest` runs the pre/post chain for plugin calls;
there is no general request-hook bypass in the inspected SDK/engine/controller.
The existing iOS `enqueueMessagesFromPlugin` send-hook bypass is a separate native
entry-point policy. No account-wide or process-wide request ignore flag was added.

Request-hook descendants carry a native root id and ancestor plugin ids. Normal
plugin requests outside hooks have no excluded plugins. The invoking hook's plugin
is appended for its native effects and callbacks; descendants skip only ancestors,
and other plugins/source callbacks still execute. New effects at ancestry depth 32
fail explicitly. Owner tokens are still checked independently of ancestry.
Core's descriptor/enqueue bookkeeping is in `ExteralessRuntime/TLRequestOrigin.swift`;
Host's mailbox/callback bookkeeping is in `PluginTLInvocationOrigin.swift`.

`tlRequest` and the final edit RPC bind origin to the exact weak Network + native
FunctionDescription identity. A pre replacement receives a new descriptor; origin
is deliberately copied, descriptor-identity privacy exemptions are not. Native
enqueue uses real stored `OutgoingMessageInfoAttribute.correlationId` and the actual
RPC `random_id`/PendingMessageRequestDependencyTag. Each album member has its own
lease. Local Postbox message views retire completed/deleted leases even if request
hooks were disabled in the meantime; failed messages retain ancestry for retries.

**Applied under the additional authorization:** both `messages.uploadMedia` call
sites in `PendingMessages/PendingMessageUploadedContent.swift` now use the origin
helper, and `RequestEditMessage.swift` forwards its optional native origin to the
uploader. `docs/tl-upload-origin.patch` records the applied changes. Helper signature:

```swift
func exteralessTLRequestForMessage<T>(network: Network, postbox: Postbox,
    messageId: MessageId?,
    data: (FunctionDescription, Buffer, DeserializeFunctionResponse<T>),
    origin: ExteralessTLRequestOrigin? = nil) -> Signal<T, MTRpcError>
```

This connects the local photo/file paths supported by the TL preparer. Multipart parts
use Download's request service directly and do not enter these Network hooks.
Reference-revalidation/embedded video-cover uploads need explicit ancestry before
extending hook-origin edits to existing referenced media. Spoiler-only edits of
existing referenced media from a hook currently return the named
`EDIT_HOOK_REFERENCE_UPLOAD_UNSUPPORTED` error. Do not infer origin from
an account-wide active request or another edit of the same MessageId.

## Verification / handback

Windows currently has Python but no `swift` or `swiftc`. New native/Host/Hook source
has **not** been compiled or executed here. The prior baseline green counts are not
evidence for these changes. No live account, server action, commit or CI was used.

Executed locally:

- Seven generator fixtures: **PASS**, 2.212 seconds; generator `--check`: no drift
  (1720 constructors, 849 supported RPCs, 2402 Android aliases).
- All 11 upload-origin hunks applied and verified against captured pre-patch hashes.
  Reversing just those hunks in memory reproduces both original files exactly;
  all `uploadMedia` RPC arguments match byte-for-byte. Both changed Swift files
  passed lexical checks, including initial/retry origin forwarding and required-upload guards.
- Scoped `git diff --check`: clean; final lexical checks passed for 36 Swift files.
  These are source-only checks, not a compiler receipt. Native `verifyTransaction` and the six original replay
  verification arguments were compared with HEAD and retained.
- Native, Host and Hooks runners explicitly reported **SKIP: Swift unavailable**.

Existing recursive source globs in TelegramCore, `swift/PluginHost/BUILD.bazel`
and `swift/PluginHooks/BUILD.bazel` include the new helpers; SwiftPM discovers their
new test files. The Foundation TL contract filegroup still has no new dependency.

Owned fixtures: eight `PluginTLHostTests.swift` cases (FakeEngine), eight `PluginTLTransformTests.swift` cases,
and `tools/compat/tests/tl_bridge/NativeFixtures.swift` (coded byte fixtures). Run each
with a total wall-clock bound of 30 seconds on the Swift host; compilation counts
toward the bound. The native driver already enforces it:

```sh
python tools/compat/tests/tl_bridge/run_native_fixtures.py
python tools/compat/tests/tl_bridge/run_shared_fixtures.py host
python tools/compat/tests/tl_bridge/run_shared_fixtures.py hooks
```

After the coordinator's callback-origin hunk, the independent Network review should
check final-parameter privacy and CANCEL/no-willSubmit, original parser/terminal and
ACK/progress paths, asynchronous ordering, descriptor ownership, accepted channel
counter carriers, callback ancestry and failed-upload/no-caption-only-success.

The 6-second prefix deadline includes its FIFO admission wait. Prefix preparation
(decoding, origin/Postbox resolution, hooks and final privacy preparation) begins
in subscription order per account; later native adds cannot overtake it. Other
accounts continue independently. Host also keeps its own 256-event/32-MiB TL
reservation budget, including envelopes whose upstream router deadline expired.
