# Dialogs remediation — IDS-03 / IDS-04 / IDS-05

**Source fixes applied; native transaction fixtures written but not executed on
this Windows host.** This is an implementer receipt, not independent review or
native/visual acceptance. The original read-only review is preserved:
[`reviews/identity-dialogs-stickers.md`](reviews/identity-dialogs-stickers.md).

## IDS-03 — sent generation, local intent and reconciliation ownership

The current-prefix echo heuristic was removed. The account's Postbox now stores
`exteraless.dialog.pins.reconciliation.v1` in the existing local-state collection.
It carries:

- The **actually encoded outgoing order**, its local snapshot, request ID,
  local-intent generation and reconciliation revision.
- Pending local order/removals. Native local pin/unpin/reorder already increment
  `SynchronizePinnedChats`' operation-log index. The adapter reads that native
  watermark; its own reconciliation/replay enqueues record their watermark as
  owned work. This also detects committed ABA order changes without modifying the
  frozen local pin APIs or introducing a new pts/seq counter.
- Locally owned extra pins, a pending verification/disable state, and the native
  operation index claimed by the in-flight read/request.

`AccountStateManagementUtils.swift:5194` delegates only the managed root pin
operation to `exteralessReplayDialogPinUpdate`. Other groups/native-only roots use
the existing replay switch. An unpin affecting sent/local intent is **provisional**:
it preserves the current local entry and coalesces a real native reconciliation.
A fresh `getPinnedDialogs` result removes an ordinary remote-unpinned peer when
neither pending local intent nor local-only ownership retains it. This is not an
unconditional ignore rule. Explicit local Unpin is retained, including a later
old `.pin` echo; unrelated remote additions survive the merge.

Shared sync insertions are limited to:

- `ManagedSynchronizePinnedChatsOperations.swift:85,119`: pass the existing
  operation index and capture a read owner/generation.
- `:238`: reject stale local intent/revision/order before applying the pin result.
- `:305`: persist the **encoded** peer list before starting the existing
  `messages.reorderPinnedDialogs` request.
- `:315`: acknowledge only `.boolTrue` with that encoded order. A failed/frozen
  read or false RPC leaves intent dirty. A matching authoritative read can finish
  without another RPC; the ledger records that it was a read confirmation.

Acknowledgement stores request ID, generation, revision, source (read/RPC) and
server order. An older/retired response cannot clear a newer intent. The claimed
operation index survives response completion until the next claim: native log
cleanup occurs in a **following transaction**, and an echo in that window must
not mistake the completed operation for queued work.

Production logic is in
`TelegramCore/Sources/ExteralessDialogs/ExteralessDialogPinReconciliation.swift`:
`exteralessBeginDialogPinSync`, `exteralessResolveDialogPinSync`,
`exteralessRecordDialogPinRequest`, `exteralessCompleteDialogPinSync`, and
`exteralessReplayDialogPinUpdate`.

The native request/retry path, actual `Api.Bool`, operation-log cleanup, parsed
peer/message data and surrounding state barriers/post-commit invalidations remain
the native owners' paths. The new replay helper does not read/write `AuthorizedAccountState`,
pts/seq, message read state, media or drafts. It changes only native pin order and
its account-local reconciliation record/log entry.

## IDS-04 — initial false after account reattach

`ExteralessDialogIntegration.swift:50` now observes the pin flag independently with
`distinctUntilChanged`, including its initial emission. It calls
`exteralessUpdateDialogPinPolicy(account:)`; the latest global flag is read **inside
the selected account's transaction**, so an already queued retired UI callback
cannot reinstall an old true value.

On A→B→off→A, A's persisted local-only/overflow state causes initial false to queue
the necessary native reconciliation. A matching active generation or already
queued native operation covers repeated attaches; unrelated preference changes
do not enter this path. Successful authoritative reconciliation clears the pending
state. Failure leaves it retryable on a later attach, without an enqueue/RPC loop
on every settings callback. B has its own Postbox record and remains independent.

No App/Root file was changed. The existing Root lifecycle still calls the same
`ExteralessDialogIntegration.init/update/clearContext` API.

## IDS-05 — subtract the same eligible contribution

`ExteralessDialogBadgeContribution.swift:8` uses the real
`telegramPostboxSeedConfiguration.peerSummaryCounterTags` and
`resolvedIsRemovedFromTotalUnreadCount`, including global mute defaults and
secret-chat associated contact identity. It checks native group inclusion too:
the stock total is root-only, while the existing Privacy Extras total explicitly
covers root + archive.

`ExteralessDialogBackBadge.swift:44` obtains that eligibility with the **same
`totalUnreadCountIncludeTags`** used for the selected total. Only an included peer
contributes the current-chat subtraction. Known exclusions contribute zero even
when their filtered count is unknown; an unknown included contribution/total
suppresses the number. Messages/chats and manual unread marks are handled by the
production `exteralessDialogBackBadgeText` function.

The UI adapter still has one Privacy Extras total projection and at most one
current-peer summary, not a second chat-list filtering pass. Excluded peers do not
need that summary. Peer/contact/global-notification updates invalidate the input.

The initial native badge is an already-subtracted **string without peer/tag/mute
provenance** (`ChatControllerContentData.swift:2068–2083`). The existing initial
adapter now treats it as unknown and waits for the checked live stream, preventing
an incorrect initial flash. No frozen/shared chat input or ContentData code was
changed for this.

## Actual native fixtures — pending execution

`telegram-ios/submodules/TelegramCore/Tests/ExteralessDialogReviewTests.swift`
contains **9 XCTest cases** using real `SqliteValueBox(inMemory: true)` + `Postbox`
and separate committed transactions. The fixture uses production replay/sync/
badge adapters and the existing native local reorder/Unpin APIs. It never creates
an Account, AccountManager or Network, and media fetching fails the fixture.

| Fixture | Contract |
|---|---|
| Committed reorder → late unpin | limit 5, `[1…6]` → sent `[1…5]` → committed `[6,1…5]` → late unpin(6); 6 remains and newer intent survives the old ack. |
| Reverse order + explicit Unpin + false RPC | unpin echo before reorder; native explicit Unpin and a later old pin echo; false result does not acknowledge/clear intent. |
| Real remote removal | Provisional unpin(2) is actually removed by the next authoritative snapshot; local-only 6 remains. |
| Native ABA | Two committed reorders return to the old array; the native operation watermark still rejects the old read/ack. |
| Completion → cleanup window | An echo after the successful response but before native cleanup obtains a fresh operation, surviving cleanup of the old index. |
| Unrelated remote addition | New peer 7 survives pending local order, but its later explicit native Unpin is not resurrected by a stale snapshot. |
| A→B→off→A | Two disposable stores with overlapping peer numbers; one necessary enqueue for A, none for unaffected B; repeated/in-flight false calls deduplicate, actual read reconciliation clears A's overflow. |
| Badge matrix | Real native total: private 5 + channel 3, Include Channels off/on × messages/chats × peer/global mute and explicit unmute; unknown counts/totals and entry suppression; read state/pts/seq unchanged. |
| Unknown peer/group scope | Unknown eligibility suppresses the number; a moved archive peer contributes only to the total that includes archive. |

The fixtures share a **20-second absolute suite deadline**, and any signal wait is
at most 2 seconds within that budget. No wall clock/device/account state is changed.
RPC results and valid native pin replay operations are injected into the production
transaction boundaries; this is not a claim that real RPCs were executed.

Build owner: `dialogs-remediation-build-hunk.patch` adds the new file to the
explicit `ExteralessNativeCoreTestsLib` source list. No BUILD was edited here. The
ordinary TelegramCore tests glob also sees the file, but that is not a native-run
receipt. Run the selected native target with the project Make.py workflow on Mac,
with a 30-second fixture-process budget; no CI was launched by this owner.

## Checks actually run

- `python docs/wave-2/tests/dialogs_remediation_source_fixtures.py` — **5 passed**.
- `python docs/wave-2/tests/dialogs_source_fixtures.py` — **8 passed**.
- `python telegram-ios/build-system/Make/PostboxImportCheck.py telegram-ios` —
  **passed, exit 0**; no allowlist additions.
- Scoped `git -c core.autocrlf=false diff --check` — **passed**.
- Frozen Core Dialog source/test paths have no working-tree changes. The old
  independent review was read only.

These are bounded **desktop source checks**, not Swift/Postbox/UIKit execution.
The 9 new native fixtures, native typecheck/build, and recorded frames remain
**unexecuted**. No commit, push, CI, real RPC, external plugin or real-account test
was performed. IDS-03/04/05 are source-remediated here; independent acceptance
requires the native fixtures and reviewer follow-up.
