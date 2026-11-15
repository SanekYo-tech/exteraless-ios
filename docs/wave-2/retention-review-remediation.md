# Retention review remediation — FROZEN

2026-11-15. Source slice for **PR06 (retention), PR07–PR11 and the PR05/PR14 native
process contract** from `reviews/privacy-retention.md`. The independent review and
earlier reports remain unchanged. H1–H9 were already applied; their old patches were
not replayed during this remediation.

**FROZEN means source/handoff freeze, not native acceptance.** Swift/XCTest, device
frames, power-loss and cross-process execution were not run on this Windows host.
The user-reported Core CI blocker (missing Chat dependency) is outside this slice.
Core `RetentionFeatures.swift`, `RetentionPolicy*` and Core policy tests were not changed.
The 23-file owned source freeze is recorded in `retention-review-freeze.sha256`
(UTF-8, BOM removed and line endings normalized to LF); structured receipts are in
`retention-review-facts.json`.

## Applied fixes

All implementation paths below are under
`telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/` unless stated otherwise.

| Finding | Actual source effect |
|---|---|
| **PR06** | `ExteralessRetentionStore.isEligible` accepts secret **Local=1 and SecretIncoming=2**, keeping distinct message keys. The range hook scans each namespace with its own peer/namespace upper/lower bounds and one shared scan/capture budget. The remote clear call in `State/ProcessSecretChatIncomingDecryptedOperations.swift` passes both namespaces. Individual deletion and TTL use the same now-covered capture adapter. Filtering-summary changes belong to the Extras owner. |
| **PR07** | `RetentionDisplayScope.swift` composes the existing native `exteralessFilteringMessage`, `FilteringPolicy.decision` and `exteralessFilterReactions` over retained snapshots before the UI merge. Raw live messages supply full-album text context; their already projected counts are not projected again. Retained reaction projection always starts from the frozen source. Account/environment, sender, reply-sender, regex and full album scopes are retained. Snapshot **v4** preserves a known reply author, with v1–v3 readers; it creates no reply/server row. Filtering-generation changes also refresh the overlay. |
| **PR08** | Full `ExteralessRetentionAlbumKey` contains peer, message namespace, thread and grouping key. The UI checks the complete key, including every member of an existing group. A bounded encrypted album registry allocates IDs through the actual `Transaction.reserveMessageStableId` counter. Retained-only albums do not use raw grouping keys; existing native group IDs are retained when joining their full scope. |
| **PR09** | `RetentionMediaOwnership.retentionAdmitMedia` verifies authorized account, a live unexpired version owner, resource membership, epoch/token and optional exact message/version. Both the engine route and native `State/Fetch` adapter reach this admission. `materialize` repeats it after file restoration and before publishing; an unpruned index alone is insufficient. The owner clock is injectable. Expired/missing resources terminal-fail without cloud fallback. |
| **PR10** | Independent encrypted `exteraless.retention.mediaOwnership.v1` stores exact token/native-ID ownership until deletion completes. `Store.finish`, media retirement and full reset preserve credits before index removal. GC unions them with proven ciphertext orphans, rechecks the current Postbox under the file lock, removes complete files, extension aliases and derived representations even when `.bin` is missing, syncs directories, then acknowledges credits. The existing durable reset marker remains until fixed-slot cleanup and file cleanup finish; interrupted cleanup is replayable. Reservations exclude pending native IDs. |
| **PR11** | `RetentionFileSystem` syncs the leaf directory and its ancestor links through the supplied trusted account/container root. Store synchronizes the file before rename. Existing-file recovery authenticates the whole file, then repeats file and directory barriers before acknowledgement. Failed parent fsync leaves a retryable file, not a `.stored` receipt. |
| **PR05 / PR14 contract** | `RetentionProcessScope.swift` supplies a validated immutable `ExteralessRetentionProcessConfiguration`, explicit process roles and `updateConfiguration`. Complete registered, successfully loaded and type-valid retention values are required. A compatibility constructor without configuration is inert and cannot prune or publish ready. Queued maintenance is checked against its configuration epoch inside Postbox. Only main-application owners automatically prune/GC; extension captures may retire entries under their loaded limits and leave durable cleanup credits. |

UI composition is applied in
`TelegramUI/Sources/ExteralessClient/Retention/ExteralessRetentionHistoryAdapter.swift`
and the narrow `ChatHistoryListNode.swift` merge call. `originalView: view` and the
existing server read/PTS/SEQ, AI/identity and native count projections remain their original owners.

## Process and file ordering

The exact App-facing contract is [retention-process-scope-contract.md](retention-process-scope-contract.md).
App-owned `Account.swift` now supplies `ExteralessAccountRetentionEnvironment`, an
ordinary Account owner and a separate standalone writer lease. Root, NotificationService,
Share, NotificationContent and Siri call its configuration API. These files were inspected,
not edited by this remediation.

- `.exteraless-retention.lock` is outside the resettable vault and is never removed by reset.
  Independent OS file handles use `flock(LOCK_EX)` for file publication/restoration/deletion.
- **No Postbox transaction waits for that file lock.** A file worker acquires it first,
  then performs bounded Postbox admission/acknowledgement. Native removal waits for the
  `Signal<Float, NoError>` completion, not a progress value.
- GC plans against a fresh transaction, not another process's copied keep set.
  `Postbox.afterBegin` compares the shared transaction version and clears table caches on
  external commits (`Postbox/Sources/Postbox.swift:2646–2660`). This is the actual storage
  mechanism used by the ownership recheck.
- A retired token cannot be allocated again while its credit exists. A second collector
  observes the first collector's acknowledgement after acquiring the same OS lock.
  The new lock fixture uses independent file handles; it is **not** a claim that separate
  iOS processes were executed.
- The ownership journal and album-ID registry each have a separate **4 MiB / 20,000-entry**
  cap. Retained filtering has a 100-entry page, up to 1,000 live context messages and the
  existing one-million-operation regex budget. Message/version/media limits still apply.

## Prepared native regressions

`telegram-ios/submodules/TelegramCore/Tests/RetentionReviewRemediationTests.swift`
contains **11 actual-adapter cases**:

1. Independent main/Share settings caches: unregistered snapshot rejection, inert unknown
   owner, preservation of a 60-day row under loaded 90-day policy, explicit main 30-day prune.
2. Accountless standalone owner: real pre-upsert and deletion capture with PTS/QTS/SEQ unchanged.
3. Local/SecretIncoming keys, individual delete/TTL and two-namespace remote-clear scan budget.
4. Retained sender/reply-sender/regex/album filtering, reaction idempotence, account rejection
   and unchanged backing reaction counts/state.
5. Real Postbox album-ID reservation: namespace/thread/peer collisions and stable repeated lookup.
6. Native fetch and exact-version materialization reject expiry with no prune event.
7. Controlled clock advances at the actual restore-file sync seam; publication is denied.
8. Message clear removes owned native complete/alias/derived files with missing ciphertext.
9. Interrupted full reset resumes the ownership journal with missing ciphertext, preserving a
   foreign cache file.
10. Fail-once parent fsync followed by authenticated recovery resync; tampered recovery never
    reaches the directory sync recorder.
11. Independent file handles serialize writer and collector critical sections.

Media is four bytes. Tests construct disposable encrypted Postboxes and synthetic peers,
never `Account`, `Network`, APNs or real Share/account actions. Waits share a 25-second
per-case deadline; the native runner must retain an outer **30-second** process bound.
Existing native retention fixtures were adapted to the explicit configuration contract.

## Checks actually completed

- `python -B build-system/Make/PostboxImportCheck.py .` from `telegram-ios`: **exit 0**.
- Scoped `git -c core.autocrlf=false diff --check`: **exit 0**.
- Existing Swift comment/string parser: **31 source/test files** with balanced delimiters;
  owned UI remains free of Postbox imports/access, and retention has no collection-wide clear.
- Source parameter check: **16/16 date/status calls** and **6 owner constructor sites** match
  current labels, order and defaults. Feed's native MessageCell and offline smoke still reach
  the same item/renderers; no new required harness parameter was introduced.
- **11** regression methods and their accountless/bounded construction were inspected.
  These are prepared tests, not executed test passes.

## Exact remaining handoff

**hdo:** apply only [retention-review-tests-hdo.patch](retention-review-tests-hdo.patch):
one source-list line in `telegram-ios/submodules/TelegramCore/BUILD`, adding
`Tests/RetentionReviewRemediationTests.swift` to `ExteralessNativeCoreTestsLib`.
No production H1–H9 hunk remains in this retention slice. App/extension readiness integration
and its acceptance stay with the App owner; no replacement Account/Root/extension patch is supplied.

Native typecheck/link, the bounded adapter regressions and labelled UI frames remain unverified.
Run them after the external Core dependency/build gate is repaired; no CI, commit or push was invoked.

## Focused follow-up — PFR01 / PFR04 / PFR05 — FROZEN owner slice

2026-11-15. Follow-up authority: `reviews/privacy-retention-followup.md` (readonly).
This appended slice supersedes the previous owner API/readiness and native-reference details;
the PR06–11 namespace, filtering, journal and file/Postbox ordering fixes remain in place.
Its separate receipts are `retention-followup-facts.json` and
`retention-followup-freeze.sha256` (normalized UTF-8/LF).

### Owner fixes applied

- **PFR01:** `ExteralessRetentionConfigurationState` carries an increasing version for both
  available and unavailable states. `RetentionOwnerState` changes configuration, operation
  epoch and readiness atomically. Unavailable immediately makes `loadedPolicy == nil` and
  `performsMaintenance == false`; only role/root identity is retained. Stale/equal versions
  cannot restore policy or revoke a later recovery. A wrong new role/root becomes unavailable.
  Work capture includes the policy and epoch under the same lock, closing the capture race
  between reading old policy and obtaining a new work token.
- Existing media leases, crypto callbacks/acknowledgements, materialization, queued prune,
  GC and reset carry their originating work epoch. Fast valid recovery cannot re-admit old
  work. The readiness publisher drains outside its mutex; waiters reread current state and
  retain an unavailable epoch so a coalesced invalid→valid publication cannot silently revive
  an earlier readiness wait.
- **PFR04:** `awaitReadiness` returns one typed success/failure with a default five-second
  deadline (maximum 25). Corrupt/unsupported index with no reset marker produces
  `.archive(.invalidArchive/.unsupportedFormat)` without setting ready or erasing data.
  Read generations prevent an older successful read from superseding a newer failed read.
  The token is owner/configuration/attempt scoped and checked by `isReadinessCurrent`.
  `retryReadiness` starts a distinct attempt; `resetArchiveForRecovery` exposes the existing
  explicit main-role journaled reset. `ready` is only a success-only compatibility accessor.
- **PFR05:** native archive rendering returns `ExteralessRetainedLocalFileMediaResource`,
  a `LocalFileMediaResource` subclass with bounded immutable account/epoch/token/source
  provenance. The existing native fetch adapter recognizes this reference after reconciliation,
  deletion-journal acknowledgement or owner disposal and returns terminal `.generic`.
  Provenance is routing information only: the live version/expiry/epoch/token admission still
  runs before and after restoration. Ordinary unowned LocalFile resources still return nil
  to the stock caller. No unbounded retired-ID table or blanket local-file classification is used.
- Retained reference coding has a **startup-only** registration helper. The stock Postbox
  coding dictionary is unsynchronized, so registration is handed to its existing once-only
  declaration block rather than performed on a rendering/file queue.

### Six additional native adapter fixtures (17 total, prepared)

`RetentionReviewRemediationTests.swift` now also covers:

1. A real 60-day archived row: valid 90 → held 30-day prune → committed 90-day settings plus
   an injected post-commit error receipt → versioned unavailable → queue release. The row
   survives; a pending readiness wait fails once; stale states are ignored; newer 90 recovers.
   This injects the error snapshot at the owner boundary. App's settings/environment fault and
   publication ordering regression belongs to its owner.
2. Unavailable followed immediately by valid recovery at the actual four-byte restore-file
   synchronization seam: the old materialization epoch still fails cancelled.
3. Corrupt index/no marker: typed finite failure, bytes preserved, explicit repair and one
   retry continuation; native PTS/QTS/SEQ remain unchanged.
4. Unsupported index/no marker: explicit reset, then typed retry success; no automatic erase.
5. Held startup: finite timeout; disposal cannot later become readiness success.
6. A resource obtained from the real snapshot renderer, native coding round-trip, four-byte
   materialization, clear/reconcile/GC, then only the old reference supplied to native fetch:
   one generic failure. Repeated after owner disposal; an ordinary local-file control retains
   the stock routing result.

Tests share the existing 25-second wait budget and require an outer native process timeout
<=30 seconds. They create disposable Postboxes, never real Account/Network/APNs objects.
**No Swift/XCTest/native/visual execution is claimed.**

### Checks and current receiving-owner work

- PostboxImportCheck and scoped `diff --check`: exit 0.
- Source/parser audit: 21 native retention sources plus the regression file; clean code
  delimiters/storage boundaries, four typed readiness/recovery methods and versioned update.
- Parameter audit: seven owner constructor sites match four published overloads.
- `RetentionReviewRemediationTests.swift` is already in the native test source list; the old
  test-list hdo is no longer a remaining gate.
- App's ordinary and standalone construction/update bindings now pass the versioned state
  in the inspected source. Its ordered environment states, actual startup subscription disposal,
  typed factory failure handling and pre-Account recovery UI remain **App-owned acceptance**.

**Exact common hunk:** `retention-followup-coding-hunk.patch` adds
`registerExteralessRetentionResourceCoding()` immediately after the stock LocalFile declaration
in `TelegramCore/Sources/Account/AccountManager.swift`. Apply before native coding fixtures.

**App consumer requirement:** replace factory/standalone Bool-only waits with `awaitReadiness`
and handle failure before constructing/transferring an Account writer; revalidate success tokens
at the final boundary. The inspected `exteralessRetentionReady` forwarding property and
`retentionScope.account.ready` standalone wait still used the compatibility route at this audit.
Internal cache-eviction success barriers may retain it after typed factory admission. The full
API contract is in `retention-process-scope-contract.md`; those App files were not edited here.

This is an owner-source freeze, not a claim that PFR01–05 or the whole application has passed
native review. Previous review reports and frozen receipts remain historical and unchanged.
