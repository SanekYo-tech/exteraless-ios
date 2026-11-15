# CMC-03 — final destination-draft admission

2026-11-15. Scoped source remediation of the remaining P1 in
[`reviews/chat-source-closure.md`](reviews/chat-source-closure.md). The old report
is read-only. **Actual-Postbox fixtures are authored; Swift/XCTest execution is
not available on this Windows host.**

## Applied chain and exact shared sections

1. [`ChatControllerForwardMessages.swift`](../../telegram-ios/submodules/TelegramUI/Sources/ChatControllerForwardMessages.swift),
   the persistent `ChatInterfaceState.update` call and its completion adapter:
   forwards the original access/permit/IDs/account into a
   `ChatInterfaceStateWriteAdmission`. The native destination `peerId`, `threadId`,
   forward IDs and all forward options are preserved. This snapshot has **one
   common persistent call** for the peer and thread destinations; the two physical
   setters are in the Core writer below. Navigation consumes only `isWritten`.
2. [`ChatInterfaceState.swift`](../../telegram-ios/submodules/ChatInterfaceState/Sources/ChatInterfaceState.swift),
   `update(engine:peerId:threadId:_:)`: legacy `Signal<Never, NoError>` adapter to
   the same implementation as the new typed overload. Implementation/API lives in
   [`ChatInterfaceStateUpdate.swift`](../../telegram-ios/submodules/ChatInterfaceState/Sources/ChatInterfaceStateUpdate.swift).
3. [`TelegramEnginePeers.swift`](../../telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Peers/TelegramEnginePeers.swift),
   interface-state write API: old `setOpaqueChatInterfaceState` delegates to
   `setOpaqueChatInterfaceStateWithResult`; additive write-snapshot acquisition
   provides the full CAS operand. The existing unversioned getter is preserved.
4. [`ChatInterfaceStateWriteAdmission.swift`](../../telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Peers/ChatInterfaceStateWriteAdmission.swift):
   `_internal_setOpaqueChatInterfaceState` queues the **actual Postbox transaction**;
   `_internal_writeChatInterfaceState` is the **one native writer** for guarded and
   legacy callers. It checks destination identity/CAS and the current source in
   that transaction, then calls admission around both the synchronization operation
   and `setPeerChatInterfaceState` / `setPeerChatThreadInterfaceState`.
5. [`ExteralessChatExportAccess.swift`](../../telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatExportAccess.swift),
   additive `draftWriteAdmission` method, and
   [`ExteralessForwardDraftWrite.swift`](../../telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessForwardDraftWrite.swift):
   capture the original immutable source baseline and lease; create the native
   executor outside the MainActor implementation. This is the same original
   `ExteralessContentExportPermit`, not a new independent grant.

The old transform-level `permit.perform` is gone from this persistent path.
Disposing an already queued Postbox subscriber is still insufficient by itself;
the queued body now sees cancellation/admission and returns a rejection **before
any native draft or synchronization write**.

## API / semantics

```swift
// Existing adapters keep their signatures and normal native behavior:
ChatInterfaceState.update(engine:peerId:threadId:_:) // Signal<Never, NoError>
engine.peers.setOpaqueChatInterfaceState(peerId:threadId:state:)

// Additive guarded update. Non-nil admission automatically captures read CAS:
ChatInterfaceState.update(engine:peerId:threadId:admission:expectedState:_:)
    // Signal<ChatInterfaceStateWriteResult, NoError>

engine.peers.getOpaqueChatInterfaceStateSnapshot(peerId:threadId:)
engine.peers.setOpaqueChatInterfaceStateWithResult(
    peerId:threadId:state:expectedState:admission:)
```

- `OpaqueChatInterfaceStateSnapshot` binds account ID, the full peer namespace/ID
  and optional thread ID to the exact stored bytes **and** timestamp/scroll/reply
  metadata. Absent state is an explicit snapshot, not “skip comparison”.
- The final transaction compares the full `StoredPeerChatInterfaceState` with that
  snapshot. It rejects a newer destination draft even when the UI/model equality
  would consider parts of the state equal. It does not retry an old transform over
  a new user's draft.
- The final transaction also rereads each source message, checks stable ID/version,
  thread/native content (including rich pages), and uses the existing Core
  effective-peer predicate for **both private cached protection flags**. Missing,
  edited or newly protected source is rejected independently of UI-observer timing.
- `ChatInterfaceStateWriteResult` carries exact destination peer/thread and a typed
  rejection (`destinationChanged`, `sourceChanged`, `copyProtected`, identity,
  decoding/encoding, cancellation/admission or duplicate-claim failures).
- Guarded updates refuse undecodable old data and encoding failure instead of
  constructing/storing an empty fallback draft. Supplying neither admission nor
  expected state keeps the legacy unconditional behavior through the same writer.
- An admission without a CAS operand is rejected at the lower API. Reusing a
  successful admission cannot write again, even with a freshly matching operand.

### Native execution / lock order

The executor is explicitly **`@Sendable`**, created by a non-actor helper, and
captures only value identifiers plus the thread-safe original permit/operation
lease. It contains no controller, AccountContext, UI read, MainActor hop or
`DispatchQueue.main.sync`.

Order: **original permit → original operation lease (`withActive`) → short native
claim lock**. The claim lock is released before native setters and never invokes
external code. Cancellation takes that claim lock alone. Permit revocation and
lease cancellation cannot interleave the admitted write: a previously revoked
permit or cancelled lease makes zero writes; once the actual transaction wins the
claim, that synchronous native write owns completion. The transaction itself
serializes the source-policy and destination-CAS reads with the writes.

## Actual Postbox regression fixtures

[`ChatForwardFinalAdmissionTests.swift`](../../telegram-ios/submodules/TelegramUI/Tests/ChatMedia/ChatForwardFinalAdmissionTests.swift)
adds **8 native XCTest methods** using the existing tiny in-memory
`ChatMediaNativeFixture`:

1. Actual read/transform → held queued native transaction → original permit revoke
   plus subscriber disposal → release: the disposed body is observed running,
   zero setter receipts, byte-identical rich/media/reply/forward destination, and
   zero navigation. Both peer and thread.
2. Operation cancellation with an otherwise still-valid inherited permit also
   refuses the queued native write.
3. A separate native transaction writes a new destination draft between transform
   and write. CAS preserves its exact bytes for peer and thread.
4. Both private flags independently, source edit, deletion and changed source
   thread are rejected in the final transaction without relying on a UI observer.
5. Positive peer/thread controls write once and retain native rich media/reply/
   forward options. A second execution with current CAS still writes zero times.
6. Wrong account, peer namespace and thread in admission **or CAS** reject; invalid
   opaque draft data never reaches the transform or a setter.
7. An absent-state read cannot overwrite a newly inserted peer/thread draft.
8. Nil admission/expected-state retains the existing unconditional legacy contract.

These go through `ChatInterfaceState.update(source:…)`, the real Postbox read, the
real formatter/transform, and **the exact production `_internal_set…` transaction
factory/writer**. The internal write-body receipt records execution even after
disposal, after the native setter callsite. A following queued read observes the
finished transaction's bytes; this is not a formatter-only spy.
The fixtures assert that this body runs off the main thread. No Account, Network,
external plugin, pasteboard/Photos/profile or RPC is constructed.

Waits are bounded at 1 s, the controlled queue barrier at 2 s. Run the one class
serially with the native runner's **30 s logic budget** and
`-parallel-testing-enabled NO`.

## Build / checks

Production sources use the existing Core, ChatInterfaceState and TelegramUI source
globs. The native fixture is covered by `Tests/ChatMedia/*.swift` in
`//submodules/TelegramUI:ExteralessChatMediaTests`.

Build owner: apply
[`chat-forward-final-admission-build.patch`](chat-forward-final-admission-build.patch)
for the test target's direct ChatInterfaceState dependency and the required-source
entry in `Tests/Exteraless/native-tests.json`. No new test target, CI dispatch or
simulator fleet is needed. Existing Postbox test visibility already admits
TelegramUI.

- `PostboxImportCheck.py` from `telegram-ios/`: PASS.
- Scoped `git diff --check`: PASS; Git only reports its LF/CRLF conversion notice.
- Build handoff `git apply --check --whitespace=error`: PASS. Local source checks
  confirm one native peer/thread writer, data-only executor and valid handoff links.
- Swift / swiftc / Xcode: unavailable here; no native typecheck, XCTest or UI/device
  execution is claimed. Source admission/CAS closure and executable native proof
  remain distinct until the class is run.

No commit or CI was started. Gallery/Share ownership stays with Feed; their terminal
export flow is outside these destination-draft changes.
