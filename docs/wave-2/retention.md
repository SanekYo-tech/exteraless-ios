# Retention / edit history / media lifetime — owner handoff

**Permitted native wiring is applied.** Remaining owner-locked bindings are delivered as exact
patch files below; parity stays `partial` until they and native checks land. No Swift/TelegramCore/UIKit/visual pass is claimed on Windows. No commit,
push, dispatch, real-account action or external plugin execution was performed.

The exact ownership set is `R-retention` in `docs/parity/remaining-ownership.json`: **27 setting
IDs**, plus the `module.backup / AyuDatabaseImport` family. The JSON fragment is
`docs/wave-2/retention-parity.json`. Do not replace the shared backup module's other-owner receipts.

## Native integration follow-up — actually applied

- **Postbox.swift:** before-upsert and before-update observers, queue-owned registration/removal,
  real stable-message-id reservation. Observer recursion into add/update is rejected; the retention
  observer writes only its cache rows. Covers offline refreshes as well as edit updates.
- **ProcessSecretChatIncomingDecryptedOperations / ManagedAutoremoveMessageOperations:** capture
  before remote secret deletion/clear and TTL removal/media expiry.
- **DeleteMessages.swift:** all four force-removal consumers consult actual retained ownership.
- **State/Fetch.swift:** the native fetch entry serves owned retained local resources.
- **MediaBox / TimeBasedCleanup / MediaBoxResourceKeepGate:** synchronous lease admission and
  size-worker unlink share one lock. A copied keep-ID set would leave a check/unlink race.
  Skipped inode groups are not counted as freed bytes; derived caches retain normal eviction.
- **RetentionOperationScope:** clear/dispose invalidates queued import/read/media work; Engine
  transactions check actual account/testing identity and cancellation inside Postbox and before
  delivery. Crypto checks cancellation between chunks. Explicit full reset finishes durable
  cleanup after the UI subscriber dismisses it.
- **Auxiliary Ayu import:** source rows are normalized, staged and merged into the real
  PrivacyObservations models; DeletedDialog gets an encrypted local descriptor with a working
  Engine reader/settings screen and scope-clear/expiry. Its privacy-owned storage capability is
  the small owner-locked API patch below, not a second privacy database.

### Owner-locked remainders (exact executable patch-tool format)

These files contain `*** Begin Patch` / exact source anchors, ready to pass as the patch tool's
`patchText`. Their target files were **not modified** by this follow-up. All hunks were dry-applied
in memory against current shared sources; no target writes were part of that check.

| Patch | Receiving owner / effect |
|---|---|
| `retention-state-hunks.patch` | TL owner: Account lifetime/cache-ready barrier and state replay delete/range hooks |
| `retention-enqueue-hunks.patch` | Chat lead: new-send deleted-reply quote transformation |
| `retention-ui-hunks.patch` | Coordinator/current UI owners: root, history projection, side-effect exclusions, read-only actions, 16 date/status readers and opacity |
| `retention-privacy-api-hunks.patch` | Coordinator: three thin privacy-owned snapshot/prepare-commit/epoch APIs in ExteralessPrivacyObservations.swift |

The two Postbox APIs previously missing from H1 now exist. The three thin privacy APIs remain
an explicit compile/wiring dependency until their owner applies that patch. Core Retention
sources/tests were left frozen during this native-integration follow-up.

## Delivered files and dependencies

- `swift/ExteralessCore/Sources/ExteralessCore/RetentionFeatures.swift`, `RetentionPolicy*.swift`;
  `Tests/ExteralessCoreTests/RetentionPolicyTests.swift`.
- `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/**`: actual per-account
  Postbox rows, native message/attribute snapshots, mutation helpers, AES-GCM media vault,
  MediaBox ownership, Engine facade, reply rewrite and original Ayu SQLite import adapter.
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Retention/**`: lifecycle,
  archive/versions/exceptions/import screens, local media opening/export/clear, inline projection,
  native session-hide and sender-search adapters.
- `telegram-ios/submodules/TelegramCore/Tests/ExteralessRetentionTests.swift`: synthetic encrypted
  Postbox, messages, SQLite exports and media fixtures. No `Account` or `Network` is constructed.
- Native follow-up fixtures: `TelegramCore/Tests/RetentionNativeIntegrationTests.swift` and
  `Postbox/Tests/MediaBoxRetentionKeepTests.swift` — actual before-image storage, queued-cancel
  denial, original auxiliary SQLite conversion, first-read/last-seen semantics, no server rows,
  native hard-link lease ownership and normal derived-cache eviction.

Build-owner dependencies: TelegramCore and its tests need **ExteralessCore, Postbox,
SwiftSignalKit, CryptoKit, sqlcipher**; import uses the already internal TelegramApi module.
TelegramUI needs **QuickLook, UniformTypeIdentifiers**, existing AccountContext/Display/
ChatHistoryEntry/ChatPresentationInterfaceState/LocalizedPeerData, and the chat owner's
`ExteralessChatTableController`. Existing source globs should include the new directories.
This owner did not edit BUILD/MODULE/C/Python or owner-locked files. The seven explicitly
permitted existing native files listed above were patched in place.

## Original symbol map (reviewed Java **and** Kotlin)

Paths below are relative to `third_party/exteraless-android/TMessagesProj/src/main`.

| Inventory ID(s) | Actual original/default | Native behavior |
|---|---|---|
| `nagram.enableSaveDeletedMessages` | `NaConfig.kt:558`, false; `MessagesController.java:20221-20264`, `AyuMessagesController.onMessageDeletedInner:210` | Capture the actual old received row before explicit remote deletion; retain it outside server history |
| `nagram.enableSaveEditsHistory` | `NaConfig.kt:564`, false; `MessagesStorage.java:16482-16498`; `AyuMessagesController.onMessageEditedInner:127` | Frozen old native versions at the before-upsert boundary, including offline history refreshes; no fabricated missed intermediate versions |
| `nagram.saveDeletedExceptionsMode`, `nagram.saveEditedExceptionsMode` | 0 / 0; `AyuSavePreferences.java:165-185`: 0 excludes marked dialog **or sender**, 1 includes only marked | Independent per-account packed-peer marks in encrypted Postbox; separate modes |
| `nagram.saveDeletedInPrivateChats`, `...saveDeletedInGroups`, `...saveDeletedInChannels` | true; `NaConfig.kt:1464-1480`, `AyuSavePreferences:127-137` | Deleted-message kind gates; unknown chat follows original fallback |
| `nagram.saveInArchivedChats` | true, `NaConfig.kt:1482`; `AyuSavePreferences:140`, `AyuMessagesController:131` | Archive-folder gate for **both** deleted and edited capture |
| `nagram.saveDeletedMessageForBot`, `...saveDeletedMessageForBotUser` | false / false; `AyuSavePreferences:93-124` | A resolved sender wins: known bot uses bot-user flag, known human returns true; bot-dialog flag is the unresolved/non-user sender fallback |
| `nagram.messageSavingSaveMedia` | true; `AyuMessageUtils.java:444,665,690` | Media policy controls real archive ownership/copying, not a UI cache flag |
| `nagram.saveMediaInPrivateChats`, `...PublicChannels`, `...PrivateChannels`, `...PublicGroups`, `...PrivateGroups` | all true, `NaConfig.kt:600-628`; `AyuMessageUtils:665-712` | Public/private channel/group selection from actual native peer metadata |
| `nagram.customDeletedMark`, `...deletedMarkColor`, `...useDeletedIcon` | empty / 0 / true; `TimeStringHelper.java:75-117,219-227` | Default/custom deleted label, signed or unsigned Android ARGB (0 follows theme), icon |
| `nagram.translucentDeletedMessages` | true; `ChatMessageCell.java:17154,17243,22744,30505` | 0.75 opacity; whole album only when every message is deleted |
| `nagram.customEditedMessage`, `...useEditedIcon` | empty / true; `NaConfig.kt:216,936`; `TimeStringHelper:36,76,128` | Default/custom edited text or pencil in history and native date/status |
| `nagram.chatMenuItemViewDeleted`, `...chatMenuItemClearDeleted` | true / true; `ChatActivity.java:5190-5191,48268` | Actual archive viewing and account/peer/version clearing; chat menu gated by save-deleted like original |
| `nagram.replyToDeletedAsQuote` | true; `DeletedReplyQuote.java:97-149` | UTF-16-safe collapsed quote + bold author, body entities shifted, one prefix per enqueue album, thread routing retained, deleted server reply ID removed |
| `neko.showMessageHide` | false; `ChatActivity:48257,48588,41609`; `MessageHelper:165` | **Session-local hide**, using the current history node's actual ignore-ID set; not deleting a server/archive row |
| `neko.showViewHistory` | false; `ChatActivity:48549-48572,50982` | **Search messages by this sender in a group**, not edit history. Native `activateSearch(.member(...))` |

`LegacyDefaults.java:16-53` pins `showViewHistory=true` only for eligible Android upgrades with
no existing preference. New iOS installation default remains the declaration's false.
Deleted reply lookup/prefix removal (`DeletedReplyQuote.findOriginal/canRemove/remove`) are
additional original helpers, not independent settings; their cross-chat navigation/edit-server
UI is not claimed as verified by this patch.

Edit retention deliberately does **not** inherit deleted kind/bot gates: Android only checks
the edit exception list and archived folder. Entities/rich text are frozen as native attributes;
the iOS adapter also captures entity-only content changes. Poll result/live-location/web-preview
refreshes of the same media kind are not treated as content edits.

## Storage / lifecycle invariants

- Approved namespace: `Namespaces.CachedItemCollection.exteralessLocalState == 63`.
  Every owned key starts with `exteraless.retention.`. **No collection-wide clear.** Privacy's
  and privacy-extras' keys are untouched. ItemCache has no implicit per-collection quota here.
- Native index format 1; per-message journal format 2 (v1 migration); native snapshot format 3
  (v1/v2 readers). Unknown JSON fields/versions and invalid ranges fail explicitly.
- Rows occupy a bounded 0..<20,000 slot range. This permits an explicit reset of an unreadable
  index without relying on its contents. Reset writes a durable marker, removes index/key,
  clears rows in 256-key transactions, removes owned media, then releases the marker. Relaunch
  resumes an interrupted reset. Per-message/version/peer clear uses exact rows and reference sets.
- Defaults added for iOS: 30 days (1...365), 5,000 messages (100...20,000), 32 versions/message,
  **32 MiB total index + row bytes**, 512 MiB media budget (16...2048), 128 MiB/file,
  4,096 resources, 64 resources/version. Unknown resource size reserves the per-file bound.
  Media reservations include encrypted chunks and the native full-file copy (4 KiB rounding);
  derived thumbnails follow the ordinary Telegram cache budget.
  User-facing media materialization/import signals have a 25 s terminal-failure deadline;
  timeout cancels the underlying reader/crypto work rather than emitting a success placeholder.
  Source capture times survive replay/import; reads do not renew retention.
- Message text/entities/replies/forwards/reactions/native media metadata are in the account's
  existing SQLCipher Postbox. No message content or exception list is stored in ClientSettings
  or UserDefaults. Settings contain ordinary flags/bounds/labels only.
- Vault directory is `<Postbox parent of media>/exteraless-retention-media`. Its random 256-bit
  key is in that encrypted index. Files use authenticated 256 KiB chunks, with account/epoch/
  resource/token/length/chunk position as AAD. File and directory are synchronized before ack.
  Tamper, truncation, reordered chunks, wrong account/key and partial writes are rejected.
- Native source resources are pinned while the copy is pending. A **separate, collision-checked
  `LocalFileMediaResource`** is reserved for the retained copy; completed copies retain its real
  MediaBox lease. A missing archive file cannot fall through to cloud fetching. The fetch adapter
  restores authenticated bytes into MediaBox; it never recovers media that was not locally received.
- UI previews use MediaBox's real extension aliases. GC removes retired archive native ids,
  their hard-link aliases and derived cache representations before removing their durable
  ciphertext filenames. Shared resources remain until the last retained version releases them.
- Account owns the service across background/active-context changes. `dispose()` cancels crypto,
  observation and pins even if a queued task temporarily retains the service. UI `clearContext`
  invalidates screens/requests; removal of the account's Postbox directory removes its vault.
- Maintenance runs at startup, foreground/settings changes and a 60 s timer while the account
  lives. iOS suspension does not execute cleanup; expiry is enforced on every read and on resume.
- Server state is advanced by the stock code. No fake message namespace, PTS, sequence response,
  unread count, history hole or cloud row is generated. Missing ids never create archive content.

## AyuDatabaseImport boundary

Reviewed `java/app/exteraless/backup/AyuDatabaseImport.java:130-317`, `AyuData.java:192-317`,
`AyuDatabase.java:28-39`, all message/reaction entities. `merge` is schema-driven and differs
from `AyuData.importDatabase`'s whole-Room-db replacement/version gate.

The native picker calls `TelegramEngine.Messages.importAyuDatabase`: read-only **sqlcipher**
SQLite connection, `query_only`, `trusted_schema=OFF`, integrity check, named-column whitelist,
64 MiB input, 16 MiB staged rows, 20,000 message rows / 40,000 reaction rows. The shipped
SQLCipher omits progress callbacks, so the reader uses real `sqlite3_interrupt` at 20 seconds.
Source files are never replaced, upgraded or followed through their Android attachment paths.

- `DeletedMessage` and `EditedMessage` merge into native retained rows, with Ayu dedup identities,
  dates, received text/entities, reply/forward metadata and `DeletedMessageReaction` counts.
- The source `userId` must equal this account's actual Telegram user id. Other-account rows
  are counted and excluded. Negative dialog ids require an unambiguous locally known native
  group/channel or a user-selected matching peer; no negative-id-to-channel guess is made.
- Android secret-chat session ids are reported unresolved. They cannot become iOS secret-chat
  session ids. Source-only media paths are reported as metadata without bytes.
- Supported media TL conversion is explicit (photo/document); unknown constructors fail before
  archive commit. Full validated Ayu source fields remain in the encrypted snapshot receipt,
  including legacy metadata without a direct native rendering equivalent.
- `SpyMessageRead`/`SpyMessageContentsRead`: source `userId` is the owning account, `dialogId`
  resolves to an actual known peer, and positive message IDs use the native **Cloud** namespace.
  Thread messages keep that same per-peer namespace. Existing incoming-message contradictions
  are rejected. `date` is preferred; `entityCreateDate` is the fallback only when date is absent.
  Null/zero remains unset. First stored dates win, matching DAO `CONFLICT_IGNORE`.
- `LastSeenEntity`: `userId` is the observed user, not the account. The original global table
  is applied only to known cloud users in the selected account. Self rows are explicitly skipped,
  not reclassified as authoritative own presence. `SpyLastSeen.lastSeenDate` is the original
  fallback when LastSeenEntity is absent. No seconds/milliseconds heuristics are used.
- All these timestamps are **Unix seconds**, with no timezone conversion. Evidence:
  `AyuSpyController.java:51-52,117-121,138-142,188-197`; `LastSeenHelper.java:32,55,97-100`;
  `AyuDeletedDialogs.java:59-65`. Zero is unset; negative, future, overflow/millisecond values
  fail. Activity has the existing seven-day window; read/activity maps retain their 50k bounds.
  Quota selection occurs once, avoiding repeated whole-map sorts on a full store.
- `DeletedDialog`: encrypted peer descriptors preserve folder (0/1), top id, last date and
  capture date. No Telegram chat-list/message/peer row is inserted. Unknown native peers and
  Android secret-session identities are reported unresolved. The Imported chat records screen
  reads descriptors through TelegramEngine and opens only the local archive. Descriptors have
  a separate 5,000-record / 1 MiB bound and the configured retention expiry.
- SQL schema is closed for every auxiliary table; `table_xinfo` rejects generated/hidden columns.
  The **16 MiB staging budget is shared across messages, reactions and auxiliary rows**;
  auxiliary rows have a combined 50k cap. The importer reports actual imported counts, duplicates,
  expiry, unset/self/unresolved rows and quota exclusions.
- Privacy storage is accessed only through the privacy-owned API patch. Admission uses the same
  epoch as Clear privacy observations, so an earlier import cannot repopulate cleared observations.
  Privacy encodings and descriptors are prepared before archive commit; cancellation/schema
  failures leave their target rows untouched.
- Export is explicit bounded text/entities/rich-text JSON plus native media sharing. It is not
  a byte-compatible Android Room database export/import. The original Android export at
  `AyuData:192` copies the SQLite DB only; attachment files are separate there too.

## Mandatory coordinator hunks

The following is the original H1–H9 review map. H1, the permitted secret/TTL/resource pieces
of H3, H4 and H5 are now **applied**. Use the exact `.patch` files above for remaining bindings;
their anchors supersede this earlier prose, including the evolving application root.

### H1 — Postbox transaction observer and real display-id reservation

`telegram-ios/submodules/Postbox/Sources/Postbox.swift`:

```diff
@@ public final class Transaction {
+    public func reserveMessageStableId() -> UInt32? {
+        assert(!self.disposed)
+        return self.postbox?.messageHistoryMetadataTable.getNextStableMessageIndexId()
+    }
@@     let messageHistoryMetadataTable: MessageHistoryMetadataTable
+    let messageHistoryObservers = Bag<(Transaction, Message, StoreMessage) -> Void>()
@@ fileprivate func addMessages(transaction: Transaction, messages: [StoreMessage], location: AddMessagesLocation) -> [Int64: MessageId] {
+        if !self.messageHistoryObservers.isEmpty {
+            for value in messages {
+                if case let .Id(id) = value.id, let previous = self.getMessage(id) {
+                    for observer in self.messageHistoryObservers.copyItems() {
+                        observer(transaction, previous, value)
+                    }
+                }
+            }
+        }
         var addedMessagesByPeerId: [PeerId: [StoreMessage]] = [:]
@@             if case let .update(updatedMessage) = update(message) {
+                for observer in self.messageHistoryObservers.copyItems() {
+                    observer(transaction, message, updatedMessage)
+                }
                 self.messageHistoryTable.updateMessage(id, message: updatedMessage,
@@ public class Postbox {
+    public func installMessageHistoryObserver(_ observer: @escaping (Transaction, Message, StoreMessage) -> Void) -> Disposable {
+        let disposable = MetaDisposable()
+        self.impl.with { impl in
+            let index = impl.messageHistoryObservers.add(observer)
+            disposable.set(ActionDisposable { [weak self] in
+                self?.impl.with { impl in impl.messageHistoryObservers.remove(index) }
+            })
+        }
+        return disposable
+    }
```

`Bag.isEmpty` is already used by the native code. Callbacks are before storage mutation, run on
the existing transaction queue and write only retention cache entries. No new Postbox→Core
dependency. The reservation touches only the native stable-id counter, not message/cloud state.

### H2 — Account ownership, startup and cache-ready barrier

`TelegramCore/Sources/Account/Account.swift`, authorized `Account` (not UnauthorizedAccount):

```diff
@@     private var automaticCacheEvictionContext: AutomaticCacheEvictionContext?
+    private let exteralessRetentionAccount: ExteralessRetentionAccount
@@         self.peerId = peerId
+        self.exteralessRetentionAccount = ExteralessRetentionAccount(postbox: postbox, accountPeerId: peerId)
@@             let mediaBox = postbox.mediaBox
-            let _ = (accountManager.sharedData(keys: [SharedDataKeys.cacheStorageSettings])
-            |> take(1)).start(next: { [weak mediaBox] sharedData in
+            self.managedOperationsDisposable.add((combineLatest(self.exteralessRetentionAccount.ready,
+                accountManager.sharedData(keys: [SharedDataKeys.cacheStorageSettings]))
+            |> take(1)).start(next: { [weak mediaBox] _, sharedData in
                 guard let mediaBox = mediaBox else { return }
                 // existing settings read and setMaxStoreTimes
-            })
+            }))
@@
-        self.automaticCacheEvictionContext = AutomaticCacheEvictionContext(postbox: postbox, accountManager: accountManager)
+        self.managedOperationsDisposable.add((self.exteralessRetentionAccount.ready
+        |> deliverOnMainQueue).start(next: { [weak self] _ in
+            self?.automaticCacheEvictionContext = AutomaticCacheEvictionContext(postbox: postbox, accountManager: accountManager)
+        }))
@@     deinit {
+        self.exteralessRetentionAccount.dispose()
```

Apply the deinit hunk to authorized Account. ClientSettings must be configured/loaded at the
existing application startup **before** accounts start replay; `update(context:)` alone is too late.

### H3 — Explicit deletion/expiry capture and force-resource ownership

`TelegramCore/Sources/State/AccountStateManagementUtils.swift`, replay switch:

```diff
@@             case let .DeleteMessagesWithGlobalIds(ids):
+                exteralessRetainBeforeDelete(transaction: transaction, mediaBox: mediaBox, ids: transaction.messageIdsForGlobalIds(ids))
                 var resourceIds: [MediaResourceId] = []
@@             case let .DeleteMessages(ids):
+                exteralessRetainBeforeDelete(transaction: transaction, mediaBox: mediaBox, ids: ids)
                 _internal_deleteMessages(transaction: transaction, mediaBox: mediaBox, ids: ids,
@@             case let .UpdateMinAvailableMessage(id):
+                exteralessRetainBeforeRangeDeletion(transaction: transaction, mediaBox: mediaBox, peerId: id.peerId, namespace: id.namespace, maxId: id.id)
```

The range helper uses real peer/namespace index bounds and an authoritative ID predicate;
20,000 examined rows / configured retained-message cap is exposed as `bounded` in its result.
Do not infer deletion from an arbitrary history cache miss or synthesize a new row.

`State/ProcessSecretChatIncomingDecryptedOperations.swift`:

```diff
@@
-                                        _internal_deleteMessages(transaction: transaction, mediaBox: mediaBox, ids: filteredMessageIds)
+                                        exteralessRetainBeforeDelete(transaction: transaction, mediaBox: mediaBox, ids: filteredMessageIds)
+                                        _internal_deleteMessages(transaction: transaction, mediaBox: mediaBox, ids: filteredMessageIds)
@@
-                                    _internal_clearHistory(transaction: transaction, mediaBox: mediaBox, peerId: peerId, threadId: nil, namespaces: .all)
+                                    exteralessRetainBeforeRangeDeletion(transaction: transaction, mediaBox: mediaBox, peerId: peerId, namespace: Namespaces.Message.Local, maxId: Int32.max)
+                                    _internal_clearHistory(transaction: transaction, mediaBox: mediaBox, peerId: peerId, threadId: nil, namespaces: .all)
```

`State/ManagedAutoremoveMessageOperations.swift:84-88`:

```diff
                 if let message = transaction.getMessage(entry.messageId) {
                     if message.id.peerId.namespace == Namespaces.Peer.SecretChat || isRemove {
+                        exteralessRetainBeforeDelete(transaction: transaction, mediaBox: postbox.mediaBox, ids: [entry.messageId])
                         _internal_deleteMessages(transaction: transaction, mediaBox: postbox.mediaBox, ids: [entry.messageId])
                     } else {
+                        exteralessRetainBeforeMediaExpiry(transaction: transaction, mediaBox: postbox.mediaBox, previous: message)
                         transaction.updateMessage(message.id, update: { currentMessage in
```

All existing `mediaBox.removeCachedResources(Array(Set(resourceIds)), force: true)` in
`State/AccountStateManagementUtils.swift` and `TelegramEngine/Messages/DeleteMessages.swift`
must pass the **filtered** ids:

```swift
mediaBox.removeCachedResources(
    exteralessRetentionUnownedResources(transaction: transaction, mediaBox: mediaBox, ids: Array(Set(resourceIds))),
    force: true
)
```

This also protects a file owned by another retained version during a local delete/clear. Capture
itself remains on the explicit remote/expiry sites, not every user-initiated delete helper.

### H4 — Actual native archive fetch

`TelegramCore/Sources/State/Fetch.swift`, beginning of the overload with `postbox` at line 78:

```diff
 ) -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError>? {
+    if let retained = exteralessFetchRetainedLocalResource(postbox: postbox, resource: resource) {
+        return retained
+    }
     if let _ = resource as? EmptyMediaResource {
```

The helper owns only reserved stock LocalFileMediaResource ids. Unknown ordinary resources
return nil; owned-but-unavailable files terminate with `.generic`. No cloud fallback or `.never`.

### H5 — MediaBox size eviction (applied)

`MediaBoxResourceKeepGate.keep` synchronously acquires a ref-counted lease. Its `evictIfUnkept`
checks native primary/partial/extension aliases and executes the inode unlink group under the
same lock. `MediaBox.keepResource` now owns this lease as well as its existing data-queue context.
`TimeBasedCleanup.evictResourceFiles` invokes the gate before accounting freed bytes. A snapshot
of a keep-set was replaced with this actual check/unlink admission boundary. Tests are in
`Postbox/Tests/MediaBoxRetentionKeepTests.swift` (prepared, not executed here).

### H6 — Root composition

`TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift`:

```diff
@@     private var privacy: ExteralessPrivacyIntegration?
+    private var retention: ExteralessRetentionIntegration?
@@
-                    + PrivacyFeatures.definitions + AIFeatures.definitions + ToolsFeatures.definitions)
+                    + PrivacyFeatures.definitions + AIFeatures.definitions + ToolsFeatures.definitions + RetentionFeatures.definitions)
@@         if privacy == nil { privacy = ExteralessPrivacyIntegration() }
+        if retention == nil { retention = ExteralessRetentionIntegration() }
@@         privacy?.update(context: context)
+        retention?.update(context: context)
@@         privacy?.clearContext()
+        retention?.clearContext()
```

### H7 — Inline display projection; raw server view stays raw

`TelegramUI/Sources/ChatHistoryListNode.swift`, after the stopHistoryViewUpdates wrapper,
before the transition combineLatest:

```swift
let includeRetained: Bool
if case .default = self.source {
    includeRetained = !isScheduledMessages && tag == nil && subject != .pinnedMessages && mode == .bubbles
} else { includeRetained = false }
let retentionHistoryUpdate = exteralessRetentionHistoryUpdates(
    context: context, location: chatLocation, source: historyViewUpdate, enabled: includeRetained)
```

Replace only the combineLatest input `historyViewUpdate |> debug_measure...` with
`retentionHistoryUpdate |> debug_measure...`. Its first five tuple fields are unchanged.
Rename the `chatHistoryEntriesForView` return binding to `baseFilteredEntries`, then add:

```swift
let filteredEntries = exteralessRetentionMergeDisplayEntries(
    baseFilteredEntries, retained: update.5, presentationData: chatPresentationData,
    groupMessages: mode == .bubbles, reverse: reverse, reverseGroups: reverseGroups,
    historyAppearsCleared: historyAppearsCleared, pendingRemovedMessages: pendingRemovedMessages)
```

Keep `ChatHistoryView(originalView: view, ...)` pointed at **view**. The existing
`maxMessageIndexForEntries` calculates read maxima from `originalView.entries`, not the overlay.

In the **visible-item side-effect loops only** (translation at ~3150/3168; visible resource/
view/mention/fact-check at ~3215/3343; possible reactions at ~3417/3443), insert after each
message binding:

```swift
if EngineMessage(message).exteralessRetention != nil { continue }
```

For the group author-story refresh at ~3339, use the first message with no retention attribute;
likewise for its ad anchor at ~3403. In `addMediaToPrefetch` return true immediately for a retained
message (no append). Do not apply these guards to the drawing/lookup loops: context/media actions
must still find a retained display item.

### H8 — Menus, native actions and deleted reply rewrite

`Chat/ChatControllerOpenMessageContextMenu.swift`, first lines of `openMessageContextMenu`:

```swift
if MainActor.assumeIsolated({ self.exteralessOpenRetainedContextMenu(message: message) }) { return }
```

For a live clicked item, filter the returned album group to non-retained entries before the
stock menu builders receive `updatedMessages`. Add `self.exteralessRetentionContextItems(message:
message)` to the existing combineLatest and append its returned items with a separator to the
normal list. The helper returns real edit-history entries only, plus the original session-hide/
sender-search actions. It does not conflate Neko showViewHistory with Ayu edit revisions.

`ChatController.swift` avatar menu: append
`MainActor.assumeIsolated { strongSelf.exteralessRetentionChatItems() }` before `return items`
in the `.peer` branch at ~6143 and before the equivalent return in `.replyThread`.

At the beginning of the actual `openMessage` closure, after resolving its `message` from the
history node (~885), route a retained item to
`ExteralessRetentionIntegration.open(context: self.context, parent: self, scope: .message(message.id))`
and return true. This opens the real local-media/version screen instead of a live poll/story/
wallet/bot action. In `updateMessageReaction`, `requestSelectMessagePollOptions`, todo mutation,
and `openMessageReplies`, return immediately when the current history item is retained. This is
a read-only local archive, not an actionable cloud message. `canSetupReply` may allow the normal
reply path only when `RetentionPolicy.current.replyToDeletedAsQuote` is enabled; that setting's
explicit archive menu already calls native `setupReplyMessage`.

`TelegramCore/Sources/PendingMessages/EnqueueMessage.swift`, new-send transaction in
`enqueueMessagesWithPrivacyAuthorization`, immediately after privacy transformation:

```swift
let rewrite = exteralessRewriteDeletedReplies(transaction: transaction,
    accountPeerId: account.peerId, messages: messages)
guard case let .success(messages) = rewrite else {
    if case let .failure(error) = rewrite {
        ExteralessRetentionAccount.get(mediaBox: account.postbox.mediaBox)?.report(error)
    }
    return (Array<MessageId?>(repeating: nil, count: messages.count), [])
}
```

Keep the existing reply/voice-discard/draft lifecycle. Quote-overflow is explicit failure, not
body truncation or a successful fake send. Native checks must include preservation of the draft
on that cancellation. Resends bypass this new-send wrapper, retaining the already rewritten text.

### H9 — Date/status marks and translucency

`ChatMessageDateAndStatusNode.Arguments`, in its existing component source:

```diff
@@         var animationRenderer: MultiAnimationRenderer
+        var retention: ExteralessRetentionMessageAttribute?
@@
-            animationRenderer: MultiAnimationRenderer
+            animationRenderer: MultiAnimationRenderer,
+            retention: ExteralessRetentionMessageAttribute? = nil
@@             self.animationRenderer = animationRenderer
+            self.retention = retention
```

Replace the complete `var updatedDateText = arguments.dateText` through `let (date, dateApply)
= dateLayout(...)` block with this native TextNode-compatible implementation. **TextNode's
attachment is UIImage**, not UIKit NSTextAttachment (see `Display/Source/TextNode.swift:1685`).
The top-level UIKit helper is deliberately not a component dependency.

```swift
let policy = RetentionPolicy.current
let dateFont = Font.regular(floor(arguments.presentationData.fontSize.baseDisplaySize * 11.0 / 17.0))
let dateString = NSMutableAttributedString(string: "")
func appendText(_ text: String, color: UIColor) {
    dateString.append(NSAttributedString(string: text, font: dateFont, textColor: color))
}
func appendMark(text: String, symbol: String?, color: UIColor) {
    if let symbol, let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: dateFont.pointSize)) {
        let mark = NSMutableAttributedString(string: "\u{2003}", font: dateFont, textColor: color)
        mark.addAttribute(.attachment, value: image.withTintColor(color, renderingMode: .alwaysOriginal), range: NSRange(location: 0, length: mark.length))
        dateString.append(mark)
    } else { appendText(text, color: color) }
    appendText(" ", color: dateColor)
}
if let impressionCount = arguments.impressionCount {
    appendText(compactNumericCountString(impressionCount, decimalSeparator: arguments.presentationData.dateTimeFormat.decimalSeparator) + " ", color: dateColor)
}
if arguments.retention?.isDeleted == true {
    let markColor: UIColor
    if let argb = policy.deletedColorARGB {
        markColor = UIColor(red: CGFloat((argb >> 16) & 255) / 255.0,
            green: CGFloat((argb >> 8) & 255) / 255.0,
            blue: CGFloat(argb & 255) / 255.0, alpha: CGFloat((argb >> 24) & 255) / 255.0)
    } else { markColor = dateColor }
    appendMark(text: policy.deletedMark.isEmpty ? "deleted" : policy.deletedMark,
        symbol: policy.useDeletedIcon ? "trash" : nil, color: markColor)
}
if arguments.edited && (arguments.context.getAppConfigValue("message_primary_edited_date") as? Bool) != true {
    appendMark(text: policy.editedMark.isEmpty ? arguments.presentationData.strings.Conversation_MessageEditedLabel : policy.editedMark,
        symbol: policy.useEditedIcon ? "pencil" : nil, color: dateColor)
}
appendText(arguments.dateText, color: dateColor)
let (date, dateApply) = dateLayout(TextNodeLayoutArguments(attributedString: dateString,
    backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .middle,
    constrainedSize: arguments.constrainedSize, alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
```

In the apply block directly after `let _ = dateApply()` set:

```swift
strongSelf.timestampContentNode.accessibilityLabel = arguments.retention?.isDeleted == true
    ? "Deleted message. " + arguments.dateText : nil
```

Append `, retention: EngineMessage(<value>).exteralessRetention` after the existing
`animationRenderer:` argument (and before the closing `))`) at these 16 actual sites:

| Component `.../Sources/<same name>.swift` | `<value>` |
|---|---|
| ChatMessageBubbleItemNode (mosaic) | `item.message` |
| ChatMessageAnimatedStickerItemNode | `item.message` |
| ChatMessageStickerItemNode | `item.message` |
| ChatMessageTextBubbleContentNode | `item.message` |
| ChatMessageFactCheckBubbleContentNode | `item.message` |
| ChatMessageContactBubbleContentNode | `item.message` |
| ChatMessageMapBubbleContentNode | `item.message` |
| ChatMessageGiveawayBubbleContentNode | `item.message` |
| ChatMessagePollBubbleContentNode | `item.message` |
| ChatMessageRestrictedBubbleContentNode | `item.message` |
| ChatMessageRichDataBubbleContentNode | `item.message` |
| ChatMessageTodoBubbleContentNode | `item.message` |
| ChatMessageAttachedContentNode | `message` |
| ChatMessageInteractiveMediaNode | `message` |
| ChatMessageInteractiveFileNode | `arguments.message` |
| ChatMessageInteractiveInstantVideoNode | `item.message` |

`ChatMessageBubbleItemNode`, apply after `strongSelf.currentApplyParams = applyInfo`:

```swift
let allDeleted = item.content.allSatisfy { EngineMessage($0.0).exteralessRetention?.isDeleted == true }
strongSelf.mainContainerNode.alpha = RetentionPolicy.current.translucent && allDeleted ? 0.75 : 1.0
```

Apply equivalent alpha reset to the sticker/animated-sticker/instant-video main content
containers. Mixed live/deleted albums keep the full bubble opacity; per-item deleted mark still
identifies the retained item. Do not compound 0.75 on parent and child. These frame-sensitive
insertions are supplied for coordinator/native review, not claimed as a visual pass.

## Checks and remaining verification

- Read original effect callsites/defaults and actual native Postbox/MediaBox APIs; central
  namespace approval received and consumed.
- First delivery validated **27 exact ownership IDs** through the real inventory `merge_parity`
  function. Native follow-up rechecked the exact ownership/inventory IDs and receipt anchors,
  seven retention UI files without Postbox imports, fourteen native helper boundaries, all four
  force-removal readers and both actual Postbox before-mutation sites. `git diff --check` on
  permitted/owned paths passed. **70 exact patch-tool hunks** dry-applied in memory to **28
  owner-locked files** without writing them. These are source checks, not native execution evidence.
- Swift/Swiftc were absent in the environment. Prepared Core/native fixtures are **not executed**.
- Required coordinator checks: frozen Core RetentionPolicyTests; native ExteralessRetentionTests,
  RetentionNativeIntegrationTests and MediaBoxRetentionKeepTests after the owner patches;
  full supported Telegram build; PostboxImportCheck; quote/send cancellation and all 16
  status callsites; independent review of import schema/peer mapping and retention/media races.
- Native fixtures cover actual encrypted-row round trip/delete/server-state invariance, dedup,
  expiry/account/peer namespaces, ciphertext authentication, offline recovery, shared media owners,
  native extension-alias cleanup, missing-media terminal callback, interrupted reset, real Ayu
  SQLite import and rejection of unknown columns. Each normal wait is 3 s; full-reset recovery
  has a 20 s wait (fixture total <30 s). Run fixtures with an outer 30 s runtime bound.
- Byte-compatible Android Room export, deleted-quote original-lookup/
  remove-prefix UI, large unsupported TL media schemas remain explicit module-level gaps.

### Expected frames (not recorded)

Use synthetic peers/messages only. Deleted text/photo/file/sticker/round-video show the mark
and 0.75 opacity in light/dark themes, RTL and large type. A recycled live cell returns to full
opacity. Mixed albums retain full bubble opacity. A delete+archive update is delivered as one
paired display update (no one-frame disappearance); no unread counter or server hole changes.
Edit icon/custom labels fit the date row; ARGB 0 tracks the theme. Open history, export, local
media and clear from chat/settings; account switch dismisses old previews and clears old rows.
Record and inspect labelled frames under AGENTS.md before any visual verification claim.
