# TL native review remediation

Working against the independent findings in `reviews/tl-network.md`; that report
is retained read-only. This document records the native owner's changes, not a CI
or Apple execution receipt.

## TLN-F01/F02 — optional roles and post RPC vectors

Applied narrow validator/fixture changes following the read-only
`reviews/tl-network-source-closure.md`:

- **TLN-F01:** role-bearing objects containing explicit null are canonicalized by
  the shipping schema codec before peer-role validation. Declared flags determine
  absence: disabled/inferred-off optional null equals omission; required null,
  enabled-bit null and shared-bit disagreement still fail. `update` canonicalizes
  its candidate before snapshot-reference comparison. Native peer ranges and
  nonnull state-reference identity checks remain enforced.
- **TLN-F02:** counter-free RPC `Vector<User>` append/removal passes shipping
  `response`. Readonly reference projection applies to update/state contexts and
  counter-bearing results. Protocol subtree and continuity protection still run
  for every response; counter Updates retarget and ciphertext edits remain denied.
- Only the validator closure in `swift_sdk_tl_probe.swift` changed: all post-hook
  replacements now use shipping `ExteralessTLTransformCodec.response` with the
  original canonical value, declared method result type and actual metadata. The
  existing User/Int/Long vector and Boolean/shared-bit cases use that closure.
- `NativeFixtures.swift` and two added native XCTest methods cover optional null
  versus omission, inferred flags, enabled/required null, overflow/non-null retarget,
  User append/removal and primitive vector mutation. Native cases feed accepted
  bytes through the original generated method parsers. Existing encrypted/control
  negative fixtures are retained.

### Exact command / input delta for Build owner

Published **946-input / 8395 preflight** is the supplied baseline. The source-list
delta is explicit; existing source files are added as dependencies, not generated:

| Consumer | Added compile and fingerprint input |
| --- | --- |
| `tools/runtime/check_swift_plugin_embedding.py` (`codec_sources`, also included in existing `build-inputs.json`) | `telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLTransformCodec.swift` |
| Same Mac SDK probe command/inventory | `telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLUpdatePolicy.swift` |
| `tools/compat/tests/tl_bridge/run_native_fixtures.py` | `swift/PluginHooks/Sources/PluginHooks/PluginHookIngress.swift` |

The standalone fixture command retains the existing codec/schema/registry/commit
and Hook payload/transform/submission helpers. Ingress supplies the HNS06 payload
lifetime types; Router is not added. Compile now has a separate **120-second**
budget; fixture execution remains **28.5 seconds** plus bounded process cleanup
within 30 seconds. The Mac probe's existing compile/child budgets are unchanged.

Modified existing inputs: `TLTransformCodec.swift`, `swift_sdk_tl_probe.swift`,
`check_swift_plugin_embedding.py`, `run_native_fixtures.py`, `NativeFixtures.swift`,
and `TelegramCore/Tests/ExteralessTLReviewTests.swift`. SDK probe inventory was
updated after freeze for the two SDK-owned hashes and the two new native helper
dependencies. CodeMirror/Config manifest and receipt pins were not regenerated.

### Validation / frozen delta

At source freeze HEAD `8d607287f3e2617f5f45250f0448f680fa95ea5a`:

- 11 owned Python generator/role fixtures **PASS, 1.964 s**.
- Python syntax, compile-source closure, scoped diff whitespace and four changed
  Swift lexical checks passed. Probe edits outside the validator closure were
  checked byte-for-text against HEAD and are absent.
- Swiftc is unavailable locally; native fixtures and Mac TL probe remain **pending**.
  Supplied Core/Host/Hooks `622/180/30` is baseline evidence, not this delta's run.

Raw-file SHA-256 corpus: sorted `path + NUL + raw_sha256_hex + LF`, SHA-256
`8f000dfbb8da91a6c849e6a0f577594f3bd74474b6492a7f764bd53c8f49cad4`.
This includes the newly required shipping ingress source in the fingerprint.

```text
f0ab5063dc60f776b728ba471d9e6d82311bc1c4d0c87c601961bf205e6f917f python/runtime/smoke/swift_sdk_tl_probe.swift
df7a8e22d117fb5a865c5365ae073381b1b653584e557bf36446125f504ba80d swift/PluginHooks/Sources/PluginHooks/PluginHookIngress.swift
14c865c86cd58ee31128a861aaf119ef9cf12a8b057f771bfc3883f7973ef336 telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLTransformCodec.swift
ba6ad1462fc5d1dfce5ddc3fd619178ff1c4b0b5a8a5bd57650a0ec5166f3b2b telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLUpdatePolicy.swift
4661dbad81af66436b10b93e860f1d63c484a264a32accf957872f3cd8b716db telegram-ios/submodules/TelegramCore/Tests/ExteralessTLReviewTests.swift
3fd6893056238ac6d06dd75c99971211c1959da8ce30e7a80f4dc7cc60fc9801 tools/compat/tests/tl_bridge/NativeFixtures.swift
7fb85b7378fc2452f0a65f0f0f440f0920b85efb9cb1832759a0dbd8882a1f9f tools/compat/tests/tl_bridge/run_native_fixtures.py
76ec0ffb815560d4813e07b8ce7ecb42cd4c958c1722766428503f7df706129a tools/runtime/check_swift_plugin_embedding.py
```

## HNS-F01 — TL provider execution revocation

The TL provider now captures `PluginNativeExecutionContext.captureGuard()` in
`admit` on the originating owner worker and stores it in the immutable ticket.
Capturing on MainActor is not used. Parent execution, the published account-context
epoch and permission remain live checks. `nativeCancellation(ticket)` additionally
checks registry membership and the exact current owner; this is the predicate
passed to **all six** native request/query/text/media/album/edit routes and all
three deferred media-preparation paths.

The existing TLN05 `allowsContinuation`/`beginCommit` calls now receive that same
predicate through `exteralessTLSendText`/media enqueue. Thus completed hook A cannot
write when blocked B later times out or the parent send is cancelled, even when
A's interpreter is still loaded. Already-admitted enqueue commits retain their
native tracking ownership; parent revocation does not pretend to roll them back.

Raw RPC and direct-edit/upload descriptors retain a separate execution predicate
alongside ancestry. Descriptor lookup copies the predicate under lock and evaluates
it outside the lock. Retired-account bindings become denied tombstones while the
descriptor survives. Query continuations and edit initial/retry/upload continuations
also check the supplied predicate. Native response/state processing after actual
RPC admission remains on its existing path.

**Coordinator integration applied — postimage verified:** all four hunks from
`tl-execution-guard-integration.patch` are present exactly once in Runtime, Network
and TLNetworkRequest. Runtime forwards the fifth TL callback predicate to worker
`shouldExecute`; both cold fast paths check execution before PR02 privacy admission;
ordered final add checks the original and final descriptors before the body-aware
privacy guard. The callback signature edge is connected in source.
PR02/C5/CA04/TLN04 and RuntimeSDK05's typed `PluginConfigAuthority` entry points
remain present. The packet is an applied-source record, not a pending insertion.

Revocation is deliberately separate from resource ownership: `contains`, completion,
cancellation and release accounting never evaluate the execution predicate. Invalid
deferred work enters normal ownership cleanup, skips the user callback and retains
its completion slot until control release admission. Already-queued callback guards
remain independent of registry membership after completion/release; Host retains its
expected-owner/worker gate. Successful parent batches keep valid guards. No predicate
is invoked while a TL registry/descriptor-association lock is held.

Provider implementation checks were made at working-tree HEAD
`9c409eb88541ba948ad593f9096b8f4a3485de74`; coordinator postimage verification was
completed at `93a1badcb0ef414ca5218cf938e3b8e2be47a828`:

- 11 Python generator/role fixtures **PASS**, 1.847 s; no schema drift.
- 11 changed Swift sources passed lexical checks and scoped `git diff --check`.
- Local postimage check: **4/4** unique applied hunks; final-execution-before-PR02
  ordering and PR02/C5/CA04/TLN04 markers verified. Runtime's SDK05 typed authority
  signatures were inspected. The original 12 frozen file hashes still match; the
  integrated corpus below adds the three coordinator-owned postimages.
- Four `PluginTLExecutionGuardTests` fixtures use the **real provider dispatch**,
  real Host batch revocation with an owned canned engine, a manual main drain,
  and the exact production cancellation predicate with `ExteralessTLEnqueueCommit`.
  Cases: A→blocked B→timeout; cancelled parent send; successful batch; callback
  admitted before timeout but rejected at its later worker check. They verify zero
  native writes, no revoked callbacks, retained cleanup quota and valid success.
- The Foundation fixture additionally checks reentrant predicates outside registry
  locks and cleanup/release after revocation.
- Swiftc is unavailable locally: these new Swift fixtures were **not executed**.
  Supplied baseline CI `43708260304` / `7d04a35a…` / `169/30` is not an F01 receipt.
  Native compilation/tests remain **pending** after the applied integration.

Source fixture: `telegram-ios/submodules/TelegramUI/Tests/PluginTLExecutionGuardTests.swift`;
it needs the TelegramUI/TelegramCore/PluginHost test dependencies. No Enqueue CMC02,
Host, SDK, C bridge or build/dependency file was edited in this F01 change.

## Shared integration status

- **TLN04 / post CANCEL policy — applied by coordinator:** all 11 hunks from
  `tl-review-network.patch` are present in current TLNetworkRequest source, on top
  of PR02/C5 and CA04 classification. Atomic lane admission and `canCancelResponse`
  are connected. Private identity requests may queue without TL decoding/plugin
  events; nonprivate ordered requests retain descriptor/privacy preparation.
  Final PR02 body-aware privacy admission and CA04 log context remain present.
- **TLN05 commit boundary — applied by coordinator:** all five source hunks are
  present, with Chat's newer CMC02 typed outcome wrapper. A supplied-permit recheck
  immediately after bot authorization, and another at the actual transaction's
  first-write boundary. Existing bot authorization, privacy/reply
  rewrite, native message slots and committed-message publication are retained.

`TLRequestOrigin.swift` calls the applied `tlCommit:` argument. No direct edits were made to
EnqueueMessage.swift, Network.swift or TLNetworkRequest.swift by this remediation.

## Native implementation

- **TLN01:** post validator protects exact encrypted/protocol subtrees before
  returning replacement bytes to the original native parser. It rejects insertion,
  deletion, vector reordering and ciphertext/control edits. `canCancelResponse`
  also excludes protocol-bearing results. Accepted-state member matching applies
  the same rule; difference semantic CANCEL checks its messages as well as updates.
- **TLN03:** explicit constructor/field roles include scalar and vector PeerIds
  (inviter/actor/promoter/bot/community IDs, MessageAction users, giveaway IDs,
  requesters/viewers and native peer objects). Peer ranges use Postbox's actual
  asymmetric positive-56/negative-55-bit limits without `abs(Int64.min)`. Reference
  projections retain roles across optional subtrees and vectors. Opaque document,
  file, random and transport IDs are not promoted to PeerIds.
  The current table contains **248 constructor/field roles**. Its schema audit
  explicitly distinguishes `users` counts and duration `prev_value/new_value`
  fields from similarly named peer references.
- **TLN04:** `PluginTLSubmissionOrder.reserveIfNeeded` checks pending-lane state
  and reserves under the same lock. The submitting head remains visible until
  native add returns. Dedicated tests cover held A → gates off → B, cancellation
  of A, unrelated-account bypass and the add-return race.
- **TLN05:** `TLEnqueueCommit.swift` transfers ownership at the native write
  boundary. Provisional cancellation releases existing-registry correlations and
  cancels authorization/preparation; a claimed commit retains its native result
  subscription until actual IDs have installed message-view tracking. Client
  disposal suppresses delivery, not tracking. This is shared by media, new text
  and the coordinator's TLN02 legacy-text route through `exteralessTLSendText`.
  `allowsContinuation()` and `beginCommit()` both consult the same supplied
  `isCancelled`/permit predicate, covering permission, logout and same-record
  AccountContext replacement without requiring an immediate dispose. Cancellation
  after the write boundary is not represented as rollback.
- **TLN09:** fast photo/document and revalidated-document builders derive spoiler
  on/off from attributes; photo retry revalidates the actual message reference.
  Edit passes that reference through and checks the final input-media spoiler
  against the requested attributes before RPC. Cached media TTL, document query
  and video timestamp are carried through the reference/revalidation path.
  Existing-reference live-photo/video-cover edits fail by name when that native
  fast path cannot preserve the extra media. Required-upload guards remain.
- **TLN10:** edit DTOs preserve caption presence. Entities with omitted caption
  receive schema/native-range checks first, and cached-text UTF-16 checks in the
  native continuation. Explicit empty caption is still validated as empty.
- **Chat explicit silent:** TL sends always append the resolved notification
  attribute, including empty flags for explicit `silent:false`.

## Verification status

- **11 Python fixtures PASS, 2.097 s** (seven generator checks + four role/schema
  audits). The generated codec/schema have no drift.
- Before coordinator integration, **11 Network hunks + 5 Enqueue hunks** matched
  in-memory checks. Current Network source was subsequently inspected after the
  coordinator's application; the Enqueue packet is now applied too, including the
  post-authorization predicate check and Chat's later typed outcome continuation.
- Final scoped `git diff --check`, Python syntax and lexical checks for **15 Swift
  files** passed. Current Network source was checked for the applied lane/post
  policy plus C5, PR02 and CA04 guards. The updated **5-hunk Enqueue packet** matched
  in memory with both supplied-permit checks. These are not Swift typecheck results.
- The bounded native/Hook runners report **SKIP: Swift/Swiftc unavailable** on this
  Windows host. The prior green Host/Hooks run does not cover this remediation.

Prepared owned regression sources:

- `tools/compat/tests/tl_bridge/NativeFixtures.swift`: encrypted difference and
  nested update rejection, protocol CANCEL, inviter/vector retargets and ranges,
  opaque Int64 preservation, deferred caption checks and commit ownership.
- `swift/PluginHooks/Tests/PluginHooksTests/PluginTLSubmissionOrderTests.swift`:
  three gate-off/admission tests; the hooks runner includes this class.
- `telegram-ios/submodules/TelegramCore/Tests/ExteralessTLReviewTests.swift`:
  eight native canned tests. They use real Api parsing/serialization,
  AccountMutableState secret-operation/counter ledger, native media/reference
  builders and temporary in-memory Postbox views. Ciphertext is never decrypted
  and no authenticated Account/Network is constructed.
  Authorization fixtures cover permit revocation while held, revocation between
  authorization and transaction, and a live control with exactly one write.
- `telegram-ios/submodules/TelegramUI/Tests/PluginTLEditModelTests.swift`:
  three real DTO presence/range regressions.

Build-owner integration for the native tests: add `Tests/ExteralessTLReviewTests.swift`
to the existing TelegramCore `ExteralessNativeCoreTestsLib.srcs` (its current deps
already cover this fixture); include the UI model test in a TelegramUI test target
with TelegramUI/TelegramCore dependencies. No BUILD file was edited. Run only these
owned fixtures under a 30-second execution limit after native compilation.

Existing bounded Foundation commands:

```sh
python -B tools/compat/tests/tl_bridge/run_native_fixtures.py
python -B tools/compat/tests/tl_bridge/run_shared_fixtures.py hooks
```

TLN04 is applied source; native execution remains unverified locally.
TLN05 is wired in source, including the coordinator's CMC02 continuation. Host, SDK,
privacy guard and Rust owner files were not edited. No account/server test, external
plugin, CI dispatch or commit was used.

## Historical HNS-F01 integrated postimage pins

Raw-file SHA-256 for 15 files, including the applied coordinator packet and its
three source postimages, checked at `93a1badcb0ef414ca5218cf938e3b8e2be47a828`.
Corpus hash is SHA-256 of
sorted `repo-relative path + NUL + raw_sha256_hex + LF` records:
`73979ca60816a04f7c34c20ca46ed6f1b74171d709bd37ac7c4754ee061af4c4`.

```text
0c4a4426579727f8d1bd0dffc30443c58bbfe033ca805812035bb2e91ca75e3c docs/wave-2/tl-execution-guard-integration.patch
32081bed061ef977da64aea4f6b5d25830c2b07fe7f956dc53166b22620ac8be telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLMediaEditServices.swift
b5f6e204fd839267b36181479a22daacb0df8ef55c8473c67a33c1240e4eac3c telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLMediaServices.swift
ad4e1a8154581e9de89ef413af4dee16a10c9a0a06db47f6943e59f07aba3823 telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLNativeServices.swift
468aebbb567a665ce93d54f24e4e816c88519a48f3b1f228ad7e625597c5c9ab telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLNetworkRequest.swift
413ae07748fc228dc2a0b271768f2812e8d4ece0061d0c88c22a3bb1f7ff0182 telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLRequestOrigin.swift
a7ba8101615f8ac6753fe683c115321fb61ebb4c478e88a11fcd3eaa699c93f0 telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLRequestRegistry.swift
d77c9983d248b7fa97d95645bff61e9db5d4ff8f2f8f3c9a8cbe7065c1741d8a telegram-ios/submodules/TelegramCore/Sources/Network/Network.swift
2b0f4bda3a578dd4d546379cbd97dc3f14a70f0b5a3038799a228700a1d89eb0 telegram-ios/submodules/TelegramCore/Sources/PendingMessages/PendingMessageUploadedContent.swift
69bcbd2d49d81a2e30f570f19c42cb339b67d953bcb8538e61c671f883969a05 telegram-ios/submodules/TelegramCore/Sources/PendingMessages/RequestEditMessage.swift
6ed178c0fa45272c8a59aeaf019c74a00821416de32216a65aa71153bfe21a85 telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift
60b9129f9424ada9d4a626336e01e69af2ce2044e04652b43fb07546de3a613c telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLBridgeExtension.swift
987db9218fd79bbaa7cca7cfc67d94a96bd2ed00d53635e03ff614488e126da7 telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLMediaPreparation.swift
1bc7522f378645a117298f286907e959f2a6d100fad0f61ae5c32e61b372da6d telegram-ios/submodules/TelegramUI/Tests/PluginTLExecutionGuardTests.swift
3e651c4df3fac24e0c6c488fe4180affddaa08626ad6d4a29cc72f1af5665805 tools/compat/tests/tl_bridge/NativeFixtures.swift
```
