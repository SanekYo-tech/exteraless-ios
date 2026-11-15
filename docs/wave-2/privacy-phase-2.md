# Privacy phase 2 — boundary / store / transport follow-up

Source corrections and owner handoff supplied. Source checks are distinct from Swift compilation and device proof.
Retention and privacy-extras implementations have separate owners.

## Coordinator: central item-cache allocation (required before compilation)

Audited native definitions: TelegramCore named item-cache IDs occupy 0…62 with
historical gaps; application-specific item-cache IDs are `64 + Int8` and currently
occupy 64…71 and 74…79; the additional literal consumers use 100/101/102.
The initial privacy adapter used 63 for three disjoint prefixed keys. The new
`ExteralessPrivacyExtras/ExteralessFiltering.swift` now also uses 63, with a distinct
`exteraless.privacyExtras.blocked.v1` key. No same-entry collision was found, but
the collection must be an explicitly shared allocation, not independently chosen.

Apply only in coordinator-owned
`telegram-ios/submodules/TelegramCore/Sources/SyncCore/SyncCore_Namespaces.swift`:

```diff
         public static let cachedUniqueStarGifts: Int8 = 62
+        /// Exteraless account-local state. Each owner uses a unique key prefix;
+        /// domain clearing must never clear this entire shared collection.
+        public static let exteralessLocalState: Int8 = 63
     }
```

Privacy consumers now reference that public name. Keep their persisted keys exactly:
`exteraless.privacy.observations.v1`, `exteraless.privacy.readDates.v1`,
`exteraless.privacy.ownLastSeen.v1`. Ask extras/retention owners to use the same
central declaration only with coordinator-approved distinct prefixes, or allocate
a different ID centrally. Do not reuse historical gaps or application IDs.
The privacy clear operation removes its three rows only.

Final all-native Swift literal/definition re-audit: **59 named Core IDs** (0…62,
excluding historical gaps); app IDs **64–71, 74–79**; literal consumers **100**
(`CachedChannelAdmins`), **101/102** (`RecentPeers`), and extras' remaining **63**.
Privacy has no remaining numeric `collectionId: 63` use. Central declaration was
still pending at the final scan; its absence must be resolved before native build.

## Boundary correction

All five `ExteralessClient/Privacy/*.swift` files now avoid Postbox imports/access.
The two observation queries moved into the narrow Core functions in
`TelegramEngine/Privacy/ExteralessPrivacyObservationData.swift`. UI peer/message
types use existing `EnginePeer`, `EnginePeer.Id`, `EngineMessage.Id` wrappers and
typealiases. `AccountRecordId` is already a TelegramCore type, so its callback
signature does not require a Postbox import or a new alias. No allowlist was changed.

Initial official check after this correction:

```text
workdir: C:\exteraless-ios\telegram-ios
python build-system/Make/PostboxImportCheck.py .
```

Privacy problems: **0**. Whole tree: **2**, both in
`ExteralessClient/AI/ExteralessAINativeAdapter.swift` (import and `.postbox` access).
These were reported to coordinator, not edited by this role.

## Store corrections found while checking the boundary

- Real Postbox `MessageHistoryTable.fetch` requires equal peer+namespace in both
  bounds. Absolute bounds used in phase 1 violate that precondition. Observation
  queries now use peer/namespace-local bounds; explicit mark-read uses the native
  `getTopPeerMessageIndex(peerId:namespace:)` instead of an unnecessary range scan.
- The last scan page is `min(256, remaining)`, so a 50,000 bound cannot become
  50,176. Read batches enforce quota once, not one O(N) minimum lookup per message.
- Activity expiry/quota are applied on load and explicit maintenance, including
  reopening/reenabling the setting with no new activity. Pruning writes only the
  appropriate encrypted row; read dates keep their original no-time-expiry policy.
- Postbox may execute a queued transaction after its subscription is disposed.
  Observation work now checks a per-subscription cancellation token inside the
  actual transaction, plus the authorized peer and testing-environment identity.
- A per-Postbox epoch invalidates already-captured loaded-message batches when
  the user clears observations. Weak registry entries retain no account/user data.
  Distinct subscriptions and distinct Postboxes cannot cancel each other.

The public UI queries are now `exteralessPrivacyOwnLastSeen(engine:)` and
`exteralessPrivacyPeerObservationData(engine:peerId:)`; old raw transaction
accessors are internal. Maintenance is performed on attaching a context and on
settings invalidation. Its subscription is cancelled on `clearContext`, just like
the UI snapshot subscriptions. An already admitted transaction can finish; work
cancelled before transaction admission performs no observation mutation.

## TL producer / privacy consumer contract

The TL agent has supplied
`TelegramCore/Sources/ExteralessRuntime/TLRequestPrivacy.swift`. Privacy now consumes
its existing **native-only** hook, rather than creating a duplicate decoder:

```swift
exteralessTLPrivacyMetadata(network:description:) -> ExteralessTLPrivacyMetadata?
// peerIds: [PeerId], allPeersResolved: Bool,
// incrementViews: Bool?, requestsOnline: Bool?
```

The producer must bind metadata to the **exact Network and final descriptor** after
validating the final wire bytes. A changed request must not retain the identity of
an explicit-read-exempt descriptor. An absent/unknown peer is not an exemption.
Every resolved peer in a vector contents-read must allow it; if any ID is unresolved,
the global policy must allow it too. The same metadata supplies the outgoing peer
to the read-after-send/offline follow-ups. A resolved-empty/multi-peer result never
falls back to an old pre-mutation descriptor's peer.

The public, TelegramApi-free boundary available to a native producer/reviewer is:

```swift
public func exteralessPrivacyRequestIsAllowed(
    accountId: Int64, method: String, peerIds: [EnginePeer.Id],
    allPeersResolved: Bool, incrementViews: Bool?, requestsOnline: Bool?
) -> Bool
```

`accountId` is the pinned `Network.accountRecordId`, not a plugin account slot.
This only queries the current policy; it neither registers a bypass nor weakens
Network's final guard. No access hash, token, message text, full parameter object,
or request bytes are accepted by this public hook or logged by the consumer.
`FunctionDescription` stays internal to the Core/API integration. Raw requests
without trusted metadata still get terminal `403 EXTERALESS_PRIVACY_SUPPRESSED`
when the global mode forbids them. No affectedMessages/PTS are fabricated.

## Proxy: loss / restore and lifetimes

Re-read `ProxyUtil.kt:71–117`: Android only changes the auto-disable decision in
`onAvailable`; there is no `onLost` branch. Keeping the last usable conditions
through `.unsatisfied`/`.requiresConnection` is therefore intentional. The native
policy now models this explicitly in `PrivacyProxyPathState`, including a separate
availability field. The next satisfied Wi-Fi/cellular/other route **replaces** the
old conditions; it never unions stale Wi-Fi/cellular bits into the new route.
Resetting the user mask to zero immediately removes suspension. The persisted
`ProxySettings.enabled` flag still decides whether a server can be used, so a
manual off cannot become an automatic on after airplane mode.

The route monitor is process-wide, matching Android's one registered callback;
it captures no account/context and performs no polling. Its teardown clears the
handler and cancels NWPathMonitor. Each account's settings/path subscription is
separately disposed by Account's existing disposable set. Settings observations
subscribe before initial emission, react to empty storage-invalidations as well
as privacy keys, and unregister on disposal.

## Checks and prepared tests

Executed from repository root, with a 20-second external timeout:

```text
python docs/wave-2/tests/privacy_source_fixtures.py
Ran 8 tests in 0.014s — OK
```

The fixtures use the actual `PostboxImportCheck` scanner and actual checked-in
source: all five privacy UI files, the real Postbox range preconditions, local
range bounds, final-page quota, batched store writes, cancellation/identity/epoch
admission, disjoint persisted keys, native metadata/global-policy boundary and
proxy/settings disposal. The namespace fixture checks the proposed hunk when the
coordinator declaration is not installed; it is **not** a compilation claim.

Prepared Swift tests (not executed here):

- `PrivacyObservationLifecycleTests`: persisted expiry without a new event,
  unchanged read-date lifetime, actual 50,003-record batch reduced to 50,000,
  deterministic over-quota repair, first-date replay preservation, clear vs late
  subscription and per-account/per-subscription cancellation.
- `PrivacyProxyPathTests`: Wi-Fi → airplane → cellular restoration; other-route
  replacement, zero-mask reset and rejection of unavailable-path transport flags.
- `PrivacyPolicyTests.testValidatedMultiPeerReadRequiresEveryExceptionAndCompleteResolution`:
  a mixed-peer vector, unresolved IDs and another account cannot borrow one exception.

Required native check after the namespace hunk and TL phase-2 integration:
`swift test --package-path swift/ExteralessCore --filter Privacy`, plus the existing
TelegramCore native tests/full application build. The coordinator-reported
15 CoreSettings and 95 NativeHost tests are baseline evidence, not execution of
these new privacy tests. No commit/push/CI dispatch or account effects were performed.

Final checks repeated after the code changes: 8 source fixtures passed; the official
whole-tree Postbox checker still reported exactly the two AI-adapter issues above
and no privacy issue; `git diff --check` for this slice passed. The real parity
merger accepted 34 feature IDs + 4 modules with current nonempty source anchors:
14 implemented-source, 13 partial, 9 unsupported, 2 platform-prerequisite;
**0 verified/ported claims**. Observation records stay partial until the central
namespace integration; unrelated retention/extras evidence is untouched.
