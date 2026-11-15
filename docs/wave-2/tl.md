# TL / native services — implementation handoff

## Phase 2 current handoff

Phase-1 descriptor factory, composition, ownerToken checks, exported method discovery,
deep observations and callback/release SDK seam were applied by coordinator. Phase-2
Network/Account/State/Host/edit shared insertions below have now been **applied by the
TL owner**. Their snippets are historical integration context, not pending edits.
Current applied-file inventory, additional Dialogs/native-services/Privacy Extras
state hooks, UI/SDK handoff, and the applied upload-origin integration are in
**`docs/tl-shared-integration.md`**. Swift compilation/execution is still pending.
The wire contract is `docs/wave-2/tl-schema.md`; tests make no account/server effects.

New source in this subwave:

- `PluginTLTransform.swift`, `PluginTLTransformRouter.swift`,
  `PluginTLSubmissionOrder.swift` under `swift/PluginHooks/Sources/PluginHooks`:
  actual result-bearing hooks, schema-validator closure, FIFO lanes, 5 s hook waits,
  cancellation, 256 operations / 32 MiB aggregate admission, and an ordered native
  submission gate that cannot submit after disposal.
- `TLNetworkRequest.swift`: cold Signal pre/post pipeline, final descriptor/privacy
  validation, actual NetworkEngineRequestService, original parser verification,
  preserved ACK/progress opt-in and retry/dependency policy. Post replacements are
  TL-validated then parsed by the **original** `data.2.parse`. The original parser
  also preflights engine responses to preserve engine TL_PARSING_ERROR/auth-init
  invalidation semantics. No cast/invented T. Prefix+privacy preparation has a
  6 s deadline; post hooks retain their independent 5 s deadline.
- `TLRequestPrivacy.swift`: checked Core-side factory extension using the existing
  TelegramApi descriptor factory. Final bytes produce weak Network+descriptor-bound
  privacy metadata. Global contents-read IDs resolve through the actual Postbox
  `messageIdsForGlobalIds`; every peer / unresolved ID participates in policy.
  Privacy2 already consumes this producer (`docs/wave-2/privacy-phase-2.md`).
- `TLTransformCodec.swift`, `TLNativeSnapshots.swift`, `TLUpdatePolicy.swift`,
  `TLUpdateBarrier.swift`: real accepted-update and difference mutation. Global
  continuity is preserved, channel continuity is preflighted, state versions are
  checked before continuation, and existing replay verification remains mandatory.
  Channel cancellation uses Core's existing empty-deletion counter carrier with
  original pts/pts_count; the carrier never re-enters plugin hooks. Actual native
  field descriptors preserve synthesized short-message fromId/optional presence.
- `PluginTLTransformIntegration.swift`: UI→awaiting Host event adapter, explicit
  cancellation gate and captured host/account mapping. Requires Host payload/event
  additions below. Existing PluginHookRouter.swift was not edited.
- Media adds albums, spoiler, TTL, native encrypted-chat sending and `editMedia`.
  Edit uses stock upload/reference-revalidation/Updates application, with the small
  upload-attribute/required-upload seam below. Advertised Runtime methods are now
  `tlRequest`, `tlCancel`, `getPeer`, `sendMedia`, `editMedia`.

### Phase 2 exact policies / current limitations

- Pre CANCEL: terminal `EXTERALESS_PRE_REQUEST_CANCELLED`, no add or willSubmit.
  Post CANCEL: terminal `EXTERALESS_POST_REQUEST_CANCELLED` for non-counter results.
  Counter-bearing RPC response cancellation is declined; semantic cancellation is
  performed at the accepted state barrier instead.
- Invalid replacements, native-parser rejection, detach and hook timeout: preserve
  original data with named diagnostics. Pre queue/prefix overflow/timeout: terminal
  named error. FIFO submission spans both hook wait and asynchronous privacy lookup.
- Read-only update references/constructor/counters cannot be retargeted. Container
  filtering is an ordered, unambiguous subsequence. Incoming short-message container
  rewriting supports text/entities and preserves actual synthesized native fields.
  Partially accepted/hole containers use observational fallback.
- Encrypted/control updates cannot be dropped: qts alone cannot replace secret-chat
  sequencing/key exchange. Secret **sending** uses existing encryption, not raw TL.
- Media constraints and secret negotiated-layer constraints are specified in the
  wire contract. No secret edit protocol is invented. Paid/rich-message edit remains
  a named unsupported case, and cloud TTL albums are refused.
- `PluginCallbackDispatcher.release` now returns Bool. TL retains completion/cancel
  quota until control release is admitted. Coor composition's release closure should
  return that Bool; no conversion to Void. One bounded retry timer services releases.

### Phase 2 verification status

Prepared **8 new PluginHooks tests** for FIFO, queued cancellation, timeout/late
reply, duplicate reply admission, invalid replacement fallback, registration
replacement, submission-after-disposal and async privacy ordering. NativeFixtures
now also checks same-method mutation, readonly metadata/pts, channel cancellation
counter carriers, container subsequences, native short-message presence repair,
MODIFY_FINAL and retained control-release quota. Both suites are pure and have no
account/server effects. Swift execution remains a coordinator gate; baseline green
Core/Host/Hooks runs are not reported as execution of these new tests.

Executed phase-2 static checks covered 22 owned Swift files, paired delimiters,
whitespace, scoped diff and preservation of coordinator's ownerToken/null-value/
exported-method gates. This is source evidence, not Swift compilation. Run the
Foundation fixture driver (30 s total budget) and `swift test --package-path
swift/PluginHooks --filter PluginTLTransformTests` under a 30 s external limit on
the Swift host after applying the shared insertions.

## Phase 2 original insertion proposal — historical, now integrated

### 1. Network.swift: inside each cold Signal, after weak-self guard, BEFORE privacy

In `requestWithAdditionalInfo`, insert after the existing `guard let self` block:

```swift
if let transformed = exteralessTransformedRequestWithAdditionalInfo(network: self,
    data: data, info: info, tag: tag, automaticFloodWait: automaticFloodWait,
    onFloodWaitError: onFloodWaitError) {
    return transformed.start(next: { subscriber.putNext($0) },
        error: { subscriber.putError($0) }, completed: { subscriber.putCompletion() })
}
```

In `request`, at the same location:

```swift
if let transformed = exteralessTransformedRequest(network: self, data: data, tag: tag,
    automaticFloodWait: automaticFloodWait, onFloodWaitError: onFloodWaitError) {
    return transformed.start(next: { subscriber.putNext($0) },
        error: { subscriber.putError($0) }, completed: { subscriber.putCompletion() })
}
```

**Inside the generator**, not at Signal construction: subscriptions can change
between construction and subscription. The original privacy/observe/request body
stays the fallback. The transformed branch owns observations and runs current
privacy against final checked metadata; it calls willSubmit only after a real add
was accepted, and didComplete with the final descriptor. Thus no double hooks and
no pre-CANCEL mark-read. No existing privacy call is moved above this branch.

In `Account.swift`, directly after the current managed-operations privacy lease:

```swift
self.managedOperationsDisposable.add(exteralessInstallPrivacyAccount(account: self))
self.managedOperationsDisposable.add(exteralessInstallTLAccount(account: self))
```

This supplies real self/global-message-ID resolution and detects retired accounts.
Privacy2 already has the required side-metadata consumer; **do not overwrite it**.
No further TelegramApi constructor changes are needed: the checked factory extension
is on the Core side and never copies hashes/text/body into log parameters.

### 2. UpdateGroup / UpdateMessageService: retain real incoming provenance

In `UpdateGroup.swift`, add the case:

```swift
case pluginContainer(ExteralessTLUpdateContainer)
```

Append `.pluginContainer` to the existing empty-array cases in all three computed
properties `updates`, `users`, `chats`. Other current group switches have default/
wildcard branches and preserve existing counter processing. Add a getter:

```swift
var pluginContainer: ExteralessTLUpdateContainer? {
    if case let .pluginContainer(value) = self { return value }
    return nil
}
```

At the beginning of `UpdateMessageService.addUpdates(_:)`, insert:

```swift
let captureContainer = exteralessTLWantsContainerTransforms()
func publish(_ groups: [UpdateGroup]) {
    var result = groups
    if captureContainer {
        result.append(.pluginContainer(ExteralessTLUpdateContainer(original: updates,
            normalizedUpdates: groups.flatMap { $0.updates })))
    }
    self.putNext(result)
}
```

Add `!captureContainer` to the existing initial observational `.updates` condition.
Within **this function only**, replace its `self.putNext(groups)` calls with
`publish(groups)`, `.updatesTooLong`'s `self.pipe.putNext([.reset])` with
`publish([.reset])`, and `.updateShortSentMessage`'s pipe call with
`publish([.updatePts(pts: pts, ptsCount: ptsCount)])`. Do not alter the public
`putNext`/session-reset methods. The marker survives AccountStateManager's group
concatenation but contributes no duplicate updates/users/chats.

### 3. AccountStateManagementUtils.swift: accepted barriers, preserve replay checks

At the tail of `finalStateWithUpdateGroups`, add the last argument to the existing
`finalStateWithUpdates(...)` call:

```swift
containers: groups.compactMap { $0.pluginContainer }
```

Add `containers: [ExteralessTLUpdateContainer] = []` as the last parameter of the
private `finalStateWithUpdates`. Replace its current observer-loop + time Signal
body with:

```swift
return exteralessTLAcceptedUpdateBarrier(accountPeerId: accountPeerId, postbox: postbox,
    network: network, state: state, updates: sortedUpdates(updates), containers: containers)
|> mapToSignal { effectiveUpdates -> Signal<AccountFinalState, NoError> in
    return network.currentGlobalTime |> take(1)
    |> mapToSignal { serverTime -> Signal<AccountFinalState, NoError> in
        return finalStateWithUpdatesAndServerTime(accountPeerId: accountPeerId,
            postbox: postbox, network: network, state: state, updates: effectiveUpdates,
            shouldPoll: shouldPoll, missingUpdates: missingUpdates,
            shouldResetChannels: shouldResetChannels, updatesDate: updatesDate,
            serverTime: Int32(serverTime), asyncResetChannels: asyncResetChannels)
    }
}
```

The helper now owns single-update observations/transformations. Global counters
were advanced in the unchanged preceding logic. Channel preflight follows the same
sorted ledger as the interpreter; stale/hole updates retain their original path.
`verifyTransaction` / `replayFinalState(skipVerification:false)` MUST remain intact.
The existing state-manager operation FIFO waits for this Signal; no core queue waits.

For difference containers, rename the current implementation to
`private func finalStateWithDifferenceImpl(..., observePlugins: Bool)` and change
its initial observer condition to `observePlugins && PluginHookRouter.hasSubscribers(.updates)`.
Keep its entire state/messages/encrypted-message application body. Add this wrapper
with the current public/internal function signature:

```swift
func finalStateWithDifference(accountPeerId: PeerId, postbox: Postbox, network: Network,
    state: AccountMutableState, difference: Api.updates.Difference,
    asyncResetChannels: (([(peer: Peer, pts: Int32?)]) -> Void)?) -> Signal<AccountFinalState, NoError> {
    guard exteralessTLWantsContainerTransforms() else {
        return finalStateWithDifferenceImpl(accountPeerId: accountPeerId, postbox: postbox,
            network: network, state: state, difference: difference,
            asyncResetChannels: asyncResetChannels, observePlugins: true)
    }
    return exteralessTLDifferenceBarrier(postbox: postbox, network: network, state: state, difference: difference)
    |> mapToSignal { effective -> Signal<AccountFinalState, NoError> in
        return finalStateWithDifferenceImpl(accountPeerId: accountPeerId, postbox: postbox,
            network: network, state: state, difference: effective,
            asyncResetChannels: asyncResetChannels, observePlugins: false)
    }
}
```

This is called after the existing authorizedState/initialState equality check in
AccountStateManager. Difference state/users/chats/encrypted payloads are immutable;
deleted channel semantic entries retain their original channel counter carriers.

### 4. Host/ExtensionPoints: awaiting value channel, not observational dispatch

Add these Foundation-only declarations (no PluginHooks dependency is required):

```swift
public struct PluginTLHookDecision: Equatable, Sendable {
    public var strategy: HookStrategy
    public var valueJSON: String?
    public init(strategy: HookStrategy = .default, valueJSON: String? = nil) {
        self.strategy = strategy; self.valueJSON = valueJSON
    }
}

public struct PluginTLHostPayload: Equatable, Sendable {
    private let identity = UUID()
    public let kind: ExtensionPointKind
    public let account: Int32
    public let name: String
    public let canonicalName: String
    public var valueJSON: String
    public let metadataJSON: String
    public let errorJSON: String?
    public let canCancel: Bool
    public let normalize: @Sendable (String) throws -> String
    public let shouldExecute: @Sendable () -> Bool
    public init(kind: ExtensionPointKind, account: Int32, name: String, canonicalName: String,
        valueJSON: String, metadataJSON: String, errorJSON: String?, canCancel: Bool,
        normalize: @escaping @Sendable (String) throws -> String,
        shouldExecute: @escaping @Sendable () -> Bool) {
        self.kind = kind; self.account = account; self.name = name; self.canonicalName = canonicalName
        self.valueJSON = valueJSON; self.metadataJSON = metadataJSON; self.errorJSON = errorJSON
        self.canCancel = canCancel; self.normalize = normalize; self.shouldExecute = shouldExecute
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    public var valueField: String {
        switch kind { case .preRequest: return "request"; case .postRequest: return "response"
        case .update: return "update"; case .updates: return "updates"; default: return "value" }
    }
    public var phase: String {
        switch kind { case .preRequest: return "preRequest"; case .postRequest: return "postRequest"
        case .update: return "update"; case .updates: return "updates"; default: return "invalid" }
    }
}
```

Add `.tlTransform(PluginTLHostPayload)` to PluginEvent and
`.tlTransform(PluginTLHookDecision)` to PluginEventResult. In PluginEvent.kind return
payload.kind; in priority return `.request` for this case. Its coalesceKey is nil
(the existing default handles it). Add to PluginEventBus:

```swift
public func transformTL(_ payload: PluginTLHostPayload) async throws -> PluginTLHookDecision {
    guard [.preRequest, .postRequest, .update, .updates].contains(payload.kind) else {
        throw PluginHostError.runtimeFailure("Unsupported TL transform kind")
    }
    guard subscribers.hasSubscribers(payload.kind), payload.shouldExecute() else { return .init() }
    switch try await queue.submitAwaiting(.tlTransform(payload)) {
    case let .tlTransform(value): return value
    default: return .init()
    }
}
```

Add this case to PluginScriptBuilder.dispatch, using its existing `call` helper:

```swift
case let .tlTransform(payload):
    var snapshot: [String: Any] = ["schemaVersion": 1, "observational": false,
        "phase": payload.phase, "metadata": try PluginRuntimeScript.jsonValue(payload.metadataJSON),
        "tl": try PluginRuntimeScript.jsonValue(payload.valueJSON), "canCancel": payload.canCancel]
    if let error = payload.errorJSON { snapshot["tlError"] = try PluginRuntimeScript.jsonValue(error) }
    var arguments: [String: Any] = ["account": payload.account, payload.valueField: snapshot]
    switch payload.kind {
    case .preRequest, .postRequest: arguments["request_name"] = payload.name
    case .update: arguments["update_name"] = payload.name
    case .updates: arguments["container_name"] = payload.name
    default: throw PluginHostError.runtimeFailure("Unsupported TL transform kind")
    }
    if payload.kind == .postRequest {
        arguments["error"] = try payload.errorJSON.map(PluginRuntimeScript.jsonValue) ?? NSNull()
    }
    return try call(payload.kind.protocolName, arguments)
```

In PluginHost.handleEvent, add `.tlTransform` as its own case before the current
observational group. It must remain inside that method's lifecycle/batch ownership:

```swift
case let .tlTransform(payload):
    guard payload.shouldExecute() else { return .tlTransform(.init()) }
    // Query actual current registration priorities on captured workers. Android
    // takes max priority of matching registrations, descending, then plugin id.
    var ordered: [(plugin: Plugin, handle: InterpreterHandle, priority: Int32)] = []
    for target in subscribers {
        guard payload.shouldExecute() else { return .tlTransform(.init()) }
        do {
            let source = PluginRuntimeScript.call("hook_priority_json",
                [payload.kind.protocolName, payload.name, payload.canonicalName])
            let output = try await invokePlugin(target.plugin, source, expectedHandle: target.handle,
                shouldExecute: payload.shouldExecute)
            let raw = try PluginRuntimeScript.jsonValue(output)
            if raw is NSNull { continue }
            let number = try PluginServiceArgument.integer(raw, name: "TL hook priority")
            guard let priority = Int32(exactly: number) else { continue }
            ordered.append((target.plugin, target.handle, priority))
        } catch {
            if payload.shouldExecute() {
                await recordExecutionFailure(target.plugin, expectedHandle: target.handle, message: String(describing: error))
            }
        }
    }
    ordered.sort { $0.priority == $1.priority ? $0.plugin.id < $1.plugin.id : $0.priority > $1.priority }
    var current = payload.valueJSON
    var result = PluginTLHookDecision()
    for target in ordered {
        guard payload.shouldExecute() else { return .tlTransform(.init()) }
        var next = payload; next.valueJSON = current
        let output: String
        do {
            output = try await invokePlugin(target.plugin,
                try PluginScriptBuilder.dispatch(for: .tlTransform(next)), expectedHandle: target.handle,
                shouldExecute: payload.shouldExecute)
        } catch {
            if payload.shouldExecute() {
                await recordExecutionFailure(target.plugin, expectedHandle: target.handle, message: String(describing: error))
            }
            continue
        }
        do {
            guard let raw = try PluginRuntimeScript.jsonValue(output) as? [String: Any],
                  let name = raw["strategy"] as? String, let strategy = HookStrategy(rawValue: name),
                  Set(raw.keys).isSubset(of: ["strategy", payload.valueField, "params"]) else {
                throw PluginHostError.runtimeFailure("Malformed TL hook result")
            }
            switch strategy {
            case .default: break
            case .cancel:
                if payload.canCancel { return .tlTransform(.init(strategy: .cancel)) }
                log?("TL_HOOK_CANCEL_UNSUPPORTED: \(payload.canonicalName)")
            case .modify, .modifyFinal:
                guard let replacement = raw[payload.valueField] ?? raw["params"] else {
                    throw PluginHostError.runtimeFailure("TL modification has no value")
                }
                let candidate = try PluginRuntimeScript.encodeJSON(replacement)
                if let other = raw["params"], raw[payload.valueField] != nil,
                   try PluginRuntimeScript.encodeJSON(other) != candidate {
                    throw PluginHostError.runtimeFailure("Ambiguous TL modification")
                }
                current = try payload.normalize(candidate) // validate BETWEEN plugins
                result = .init(strategy: strategy, valueJSON: current)
                if strategy == .modifyFinal { return .tlTransform(result) }
            }
        } catch {
            // Invalid edits fail open for this plugin, with the previous valid value.
            log?("TL_HOOK_INVALID_REPLACEMENT: \(payload.canonicalName)")
        }
    }
    return .tlTransform(result)
```

`InterpreterHandle` is the existing captured batch-handle type. Keep `shouldExecute`
through invokePlugin's worker-time check, not just an outer Task check. The existing
event queue supplies lifetime admission, priority lane and batch watchdog behavior.

SDK-agent addition required in `python/exteraless_runtime/__init__.py` (the function
uses real registration data, not a default priority invented by Host):

```python
def hook_priority_json(hook, name, canonical_name):
    platform = _runtime(loaded=True)
    instance = platform.loader.plugins[platform.plugin_id].instance
    candidates = {name, canonical_name}
    schema = getattr(getattr(platform, "tl", None), "schema", None)
    if schema is not None:
        candidates.update(schema.hook_names(canonical_name))  # actual generated hookNames table
    matches = [int(priority) for pattern, substring, priority
               in instance.__dict__.get("_exteraless_request_hooks", ())
               if any((pattern in candidate if substring else pattern == candidate)
                      for candidate in candidates)]
    return _codec.dumps(max(matches) if matches else None)
```

Expose `Schema.hook_names(name)` from `tl-schema.json["hookNames"]` (return an empty
tuple for unknown names), and apply the same candidate-name matching in `_registered`.
Runtime dispatch must unwrap both observational and transforming `snapshot.tl` to
the real TL data class while keeping readonly metadata outside `_values`. This is
required before enabling the transform registration. Core repeats validation even
if Host/plugin bypasses the per-plugin normalizer.

### 5. UI composition: install the implemented transform adapter

In `ExteralessPluginRuntime`, retain:

```swift
private var tlTransforms: PluginTLTransformIntegration?
```

At the end of `installHooks` (after current registration is installed):

```swift
if let host {
    let services = self.services
    tlTransforms = PluginTLTransformIntegration(host: host,
        accountIndex: { services.accountIndex(recordId: $0) },
        diagnostic: { logs.append(pluginId: "host", level: .warning, message: $0) })
}
```

At the START of `refreshSubscriptions`:

```swift
tlTransforms?.updateSubscriptions(active: hasAccount)
```

In `clearContext`, disable its subscriptions; in terminate, call `detach()` and nil
the property before stopping Host. Preserve the coordinator's current TL service,
ownerToken, callback result/release and exported-method wiring.

### 6. RequestEditMessage.swift: stock upload seam (no alternate sender)

Append to `_internal_requestEditMessage` and `requestEditMessage` signatures:

```swift
mediaAttributes: [MessageAttribute] = [], requireMediaUpload: Bool = false
```

Append nondefault versions of those two parameters to `requestEditMessageInternal`.
Forward them in `_internal_requestEditMessage`'s call, and in both initial/retry
`requestEditMessageInternal` calls. In `generateUploadSignal`, initialize:

```swift
var attributes: [MessageAttribute] = mediaAttributes
```

Keep the existing webpage/invert attributes appended afterwards. After extracting
pendingMediaContent (the progress branch has already returned), before the Postbox
transaction, add:

```swift
if requireMediaUpload, case .update = media, pendingMediaContent == nil {
    return .fail(.error(.generic))
}
```

After extracting `inputMedia` and before constructing the edit RPC, add:

```swift
if requireMediaUpload, case .update = media, inputMedia == nil {
    return .fail(.error(.generic))
}
```

This preserves stock revalidation, schedule/group checks, local updates and final
AccountStateManager application. It stops a failed file upload becoming a successful
caption-only edit. Existing callers retain defaults; TL edit explicitly requires
its requested media. New edit code rejects paid/rich/secret edit cases by name.

---

## Phase 1 source inventory / history

## Phase 1 applied: TelegramApi public descriptor factory

`FunctionDescription`'s existing initializers and `Network.request` are internal.
The latter is correctly called from the new TelegramCore helper. Do **not** expose
TelegramApi to TelegramUI. Add this function to
`telegram-ios/submodules/TelegramApi/Sources/TLObjectSupport.swift`, after
`tlFunctionParts` (its existing `import TelegramApiObjC` is sufficient):

```swift
/// A schema-checked descriptor for the native plugin TL codec. Arguments stay
/// out of log metadata; only the real function name is exposed.
public func tlBridgeFunctionDescription(name: String, expectedSchemaHash: UInt64) -> FunctionDescription? {
    guard TLApiSchemaHash == expectedSchemaHash else { return nil }
    for index in 0 ..< TLApiFunctionCount {
        let info = TLApiFunctionAt(index)
        if String(cString: info.pointee.constructor.name) == name {
            return FunctionDescription(name: name, parameters: [])
        }
    }
    return nil
}
```

This is an additive descriptor-only seam. Serialization, TLObject storage,
layout, C engine and the existing builders remain the native implementation.
The hash uses the exact FNV-1a `SwiftTL-Storage/1` calculation from `SwiftTL/main.swift`.
Regeneration drift refuses submission rather than sending a mismatched layer.

## Current source findings

- Native input `TelegramApi/swift_scheme.tl`: 1720 constructors and 859 methods;
  SwiftTL adds `help.test`, producing 860 records, 849 nongeneric supported methods.
- Java `TLRPC.java` + all 18 `tgnet/tl/*.java` files: 3135 constructor declarations;
  2402 aliases match current native IDs, 733 known constructors are absent or generic.
- Original SDK: `client_utils.send_request` (291), `RequestCallback` (256),
  `get_connections_manager` (384), `get_messages_controller` (372), six public
  text/media send helpers (488–675), `edit_message` (723). `AccountClient` forwards these with
  account scope. `PluginServices.sendRequest` (242) delegates to the real
  `ConnectionsManager.sendRequest`; callback args are response/error.
- `ConnectionsManager.java` has seven `sendRequest` overloads and one
  `sendRequestSync` overload, stage-queue dispatch,
  pre hooks (441), post hooks (524), and `cancelRequest` (670). iOS wrapper ownership
  is explicit; Android connection flags/quick acknowledgements are not silently ignored.
- Native cached `TelegramUser` does not store `bot_info_version`, and native peer
  models do not preserve a complete server User/Chat. `getPeer.cached` is therefore
  an explicit read-only partial snapshot; InputPeer/InputUser/InputChannel values
  come from the existing Core conversion functions and real TL serialization.

## Implemented native paths

Under `telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/`:

- `TLCodec.swift`: deep Sendable values; strict JSON types; schema-driven boxed and
  bare constructors/vectors, Int32/Int64/double, true flags, Bool, strings, bytes,
  int128/int256; inferred or authoritative flags with shared-bit validation;
  complete-buffer consumption, signatures, UTF-8, canonical length/padding, depth,
  byte/vector/total-value limits (including zero-byte `?true` expansion). Native requests can only be constructed by this
  validator. Hash is layout validation, never a replacement for response data.
- `TLSchemaGenerated.swift`: immutable native metadata from the actual build input;
  1719 ordinary constructors plus the typed-vector primitive, 849 nongeneric RPCs,
  current Android short hook names. Unknown/generic methods fail by name.
- `TLNativeServices.swift`: real `(FunctionDescription, Buffer,
  DeserializeFunctionResponse<TLBridgeParsedResponse>)` → `account.network.request`.
  Explicit `(error: MTRpcError)` avoids the ObjC-IUO inference regression. RPC error
  code/text are preserved. The optional `applyUpdates` parses the intact native
  `Api.Updates` and calls `account.stateManager.addUpdates`; no pts writer or
  fabricated response fields. Response logging supplies constructor names only,
  avoiding reflection of sensitive generic enum associated values.
  `exteralessTLGetPeer` is a real Postbox transaction and uses existing
  `apiInputPeerOrSelf` / `apiInputUser` / `apiInputChannel` conversions.
- `TLMediaServices.swift`: photo/document/audio/video **and text** use
  `enqueueMessagesFromPlugin`. Files become real LocalFileMediaResource data;
  MediaBox storage is checked before enqueue. File I/O runs on a private utility
  queue. Native MessageEntity conversion checks ranges, UTF-16 boundaries and
  receive-only/lossy variants first. Caption/entities/silent/reply/forum thread,
  scheduled-send and text link-preview flags are real message attributes. Message
  IDs are actual local enqueue results. Native restrictions, cached reply/topic,
  mention access hashes and effective paid-message requirements are checked.
- `TLRequestRegistry.swift`: generation-owned UUID tickets, unique C-wrapper
  leases, 64 per plugin / 256 global (including pending callback admission), media
  preparation limits 2 / 4, native deadline timers, finish-before-disposable-install
  handling, and one terminal winner. Completion disposes native work, then retains
  its quota slot until callback admission; unload retires all owner tickets.

Under `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/`:

- `PluginTLBridgeExtension.swift`: the four Runtime operations, strict reflection
  kinds/arity/kwargs/permissions, synchronous owner/account capture, main-thread
  record resolution, native Signal subscriptions, per-owner completion FIFO and
  one shared bounded-backpressure retry timer. Account clear yields terminal
  account errors; unload/cancel suppress callbacks. No Python runs inline or on
  main. Request IDs are bridge leases, not MTProto message IDs.
- `PluginTLModels.swift`: exact v1 admission validation, including the additive
  `sendMedia(kind:"text")`, `applyUpdates`, schedule/link-preview controls.
- `PluginTLMediaPreparation.swift`: bounded local FileHandle reads, native ImageIO
  JPEG conversion and AVFoundation metadata over an owned temporary copy. Native
  cancellation invokes `cancelLoading`; temporary inspection files are removed.
- `PluginTLObservationCodec.swift`: real deep TL data + actual RPC errors added to
  existing observations, with named decode failures and Android hook-name mapping.

Generator/SDK artifact:
`tools/compat/generate_tl_bridge.py`, `python/runtime/tl-schema.json`. Alias IDs
come from TLRPC.java **and** all namespace files, never a guessed class prefix.
There are 281 data sum-type aliases and two `_long → long` field aliases.
`hookNames`/`hookAliases` preserve all actual `Class.getSimpleName()` spellings;
`preferredHookNames` chooses only an existing id-matched name. Android's original
implementation is `PluginsController.hookName`, lines 1946–1953.

## Phase 1 applied: account resolver and composition

Add inside `TelegramPluginServices` (its accountContexts dictionary already belongs
to main):

```swift
@MainActor public func accountContext(recordId: Int64) -> AccountContext? {
    return self.accountContexts[recordId]
}
```

Construct/retain the provider **before `host.start()`**, so on_plugin_load can use
native services. Its initializer matches the current `PluginCallbackDispatcher`:

```swift
let callbacks = PluginCallbackDispatcher(host: host, log: { message in
    logs.append(pluginId: "host", message: message)
})
let tl = PluginTLBridgeExtension(
    storage: services.serviceStorage,
    hasPermission: { callbacks.hasPermission($0, $1) },
    captureOwner: { callbacks.captureOwner($0) },
    callback: { callbacks.callback($0, $1, $2, $3) },
    release: { callbacks.release($0, $1) },
    accountLookup: { index in try services.platformSnapshot.account(at: index).recordId },
    resolveAccount: { recordId in services.accountContext(recordId: recordId) },
    diagnostic: { logs.append(pluginId: "host", level: .warning, message: $0) }
)
tl.update(context: context) // real current context, on main
```

Include `tl` in the coordinator's `CompositePluginBridgeExtension`. Forward later
`update(context:)` and `clearContext()` on main. `releaseInstances(pluginId:)` is
already the PluginHost extension teardown seam. The account lookup closure reads
the existing Int32-slot → Int64-record snapshot; the resolver reads that exact
record, never whichever account is currently selected.

### Callback byte budget and overload

`PluginCallbackDispatcher.callback` currently accepts only 1 MiB per callback and
8 MiB queued. To admit the documented TL bridge response size, replace its guard
with:

```swift
guard bytes <= 16_777_216, queuedCallbacks < 1024, queuedBytes + bytes <= 33_554_432 else {
```

The provider sends a compact `EXTERALESS_CALLBACK_BACKPRESSURE` error if a large
response cannot be admitted, and retries that small control result in owner FIFO
order until the original deadline + 1 second. A permanently refusing dispatcher
produces a named diagnostic and releases the native/C lease. It cannot promise a
Python callback from an expired/stuck interpreter. See the SDK release hook below
for logical lease cleanup even when the dispatcher cannot admit an error.

## Phase 1 applied: deep observations / Android hook names

In `ExteralessPluginRuntime.installHooks`'s existing `observe` closure replace:

```swift
let json = try event.jsonString()
```

with:

```swift
let json = try PluginTLObservationCodec.jsonString(event)
```

Keep this **before** the main-actor hop: it runs on PluginHooks' serial observation
queue. In `forward`, replace the four callback-name arguments with:

```swift
// preRequest and postRequest:
requestName: PluginTLObservationCodec.hookName(value.metadata.requestName)
// update:
name: PluginTLObservationCodec.hookName(value.name)
// updates:
container: PluginTLObservationCodec.hookName(value.name)
```

The JSON metadata retains canonical native names and `observational:true`.
Request errors also carry `tlError` with original code/text, avoiding the older
host's string-only error argument. SDK decoding should take it from that snapshot.

## SDK integration notes (SDK/coordinator own these files)

1. `sendMedia(kind:"text")` is the native rich/plain enqueue path. Map
   message→caption, entities, notify→!silent, searchLinks→!disableLinkPreviews,
   scheduleDate→scheduleTime, replyToMsg→replyTo, replyToTopMsg→threadId. Unsupported
   reply markup/quotes/rich article fields must fail rather than disappear. Do not
   route rich-text helpers through a raw messages.sendMessage RPC: it lacks local
   pending-message state. Raw edit helpers can opt into `tlRequest.applyUpdates`.
2. In `Requests.cancel`, leave the pending lease intact if native returns
   `cancelled:false`: native completion may already own a queued callback. Popping
   and closing it unconditionally makes that valid callback enter a closed SDK
   lease. True cancellation closes/removes it normally.
3. Native owner-side handle release should retire matching SDK leases/pending
   request mappings even without callback delivery. The current host
   `releaseCallbackHandles` invokes raw `xt_release_handle` only. A pure-Python
   `_exteraless_runtime.release_handles_json(handles)` helper can first clean the
   SDK lease table, then release C handles; coordinator can invoke it on the same
   captured-owner worker. CPython/C BridgeBackend remain the actual backend.
4. Canonical decoded constructors and their explicit FQCN aliases must share class
   identity/field aliases (`isinstance(response, TLRPC.TL_user)`, `_long` on decoded
   GeoPoint). A class cache keyed separately by alias and canonical name breaks
   those operations. Use the generated registry for both.
5. For observational hooks, unwrap `snapshot.tl` into a deep data object and retain
   observational/readonly metadata outside its TL field dictionary. Match both
   canonical and actual Android hook names through the generated tables.
6. Build-agent now stages the schema at `resources/python/tl-schema.json`; the SDK
   source now checks that location and the repo's `runtime/tl-schema.json` fallback.
7. Root `Vector<T>` responses (e.g. users.getUsers) are Java `org.telegram.tgnet.Vector`
   with `.objects`, not bare ArrayList. `tgnet/Vector.java:7–44` is the actual class;
   primitive `.Int/.Long` wrappers/conversions are in the same file. Adapt root
   callbacks using the request's declared result type; keep nested vector fields
   as arrays. The native wire array is intentional and lossless.
8. Java serializers recompute `flags.n?true` bits from Boolean members. Python
   data-object mutation should keep those flag bits coherent before crossing the
   strict native codec; e.g. changing `.silent` on a decoded object must also update
   its bit. Value-optionals still require their presence flags/shared-bit companions.

## Checks and remaining boundaries

- **Passed:** seven owned Python generator/registry fixtures; latest run 1.794 s;
  generator `--check` reports no drift.
  They cover native-input IDs/layout hash, generation drift, actual Android names,
  legacy/generic exclusions, field order/shared flags, and non-code Java scanning.
- **Prepared, not run on Windows:** `NativeFixtures.swift` +
  `run_native_fixtures.py`. Nine pre-engine TelegramApi goldens, every truncation
  of those bodies, primitive/vector/bytes/UTF-8/flags/type/read-only/bounds rejection,
  request/response roundtrips (including pts and full-width Int64), plus owner,
  cancel/complete/unload/deadline/disposable-install/quota races. Run:

  ```sh
  python tools/compat/tests/tl_bridge/run_native_fixtures.py
  ```

  It compiles only the three Foundation production codec/metadata/registry files,
  with a 30-second total budget, and never opens an Account/network. `swiftc` was
  unavailable locally; the skip is **not** a native test pass.
- **Static checks:** owned Swift delimiter/whitespace checks, scoped diff check;
  source signatures checked against MTRpcError.h, TelegramApi Buffer/parser,
  Postbox/MediaBox, AccountStateManager, native entities and enqueue/resource types.
  Full Swift/iOS compilation is still required after coordinator applies the seam.
- Media returns local enqueue acceptance; delivery/upload failure follows native
  pending-message state. Cancellation cannot recall an already-started enqueue.
  Paid messages, monoforums, uncached/closed topics, uncached replies/mention users,
  unsupported/lossy entities, animated photo input and unsupported AV metadata fail
  by name. Phase 2 adds secret native sends, albums, TTL, spoilers and edit-media as
  specified above; cross-peer quotes and rich/paid/secret edits remain unsupported.
- Phase 2 implements the transforming helpers and adapter. The shared insertions
  at the top of this document are required to make those production callsites live;
  the prior observational-only limitation is superseded by that integration.
- BUILD/MODULE/dependency locks/common Network/composition-root edits remain in
  their assigned ownership. Existing recursive Core/UI globs cover the new Swift
  files. Imports: Core Foundation/Postbox/SwiftSignalKit/MtProtoKit/internal
  TelegramApi; UI AccountContext/PluginHost/PluginHooks/TelegramCore and Apple
  AVFoundation/ImageIO/UniformTypeIdentifiers. No new external native dependency.
