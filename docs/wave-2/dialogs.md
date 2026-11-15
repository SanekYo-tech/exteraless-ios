# P-dialog-navigation — source handoff

**Review follow-up:** [dialogs-remediation.md](dialogs-remediation.md) records the
IDS-03/04/05 generation/reattach/badge-eligibility fixes and pending native fixtures.

Owner scope: **16 package IDs + `nagram.sortByUnread` / `neko.sortByUnread`**.
All 18 receipts are in `dialogs-parity.json`. The integration continuation has
applied **23 hunks in eight shared files**; see [current integration receipt](../dialogs-integration.md)
for exact applied/remaining slices. Native/visual verification is pending.

## Integration required from coordinator

1. Register `DialogFeatures.definitions` with the other client definitions before
   consumers start. There are **13 live global definitions**, all with original
   defaults (11 false booleans, two page selectors defaulting to 0).
2. Retain `ExteralessDialogIntegration`, construct after shared settings configure,
   call `update(context:)` on main, and `clearContext()` on account teardown/switch.
   It supplies the per-forum native settings action and the native archive-position
   preference lease. It does not register duplicate global definitions itself.
3. `dialogs-native-hunks.patch` is now an **audit receipt** of applied shared
   slices, including both back-badge bindings. Per-file status is in
   `dialogs-parity.json`; the source fixture checks actual postimages.
   The separate `dialogs-state-hunk.patch` pin-echo call is now observed applied
   in TL-owned source; this owner did not edit the state file.
4. Compose Privacy Extras initialization **before** dialog presentation. The list
   calls its public `canSelect(identity)` and `exteralessFilterChatList` policies;
   the badge uses its public filtered account/peer counts. Settings/filter/hidden
   invalidations are combined directly. There is no global callback chain or
   cycle back into the dialog provider. Keep the extras owner's default exclusion
   hook at this boundary, rather than installing a second transform around it.
5. Supersede only the two old sort receipts in `chat-parity.json` when merging this
   fragment. Do not alias the Neko key to the Nagram key.

Shared hunks cover `ChatListController.swift`, `ChatListItem.swift`,
`NavigateToChatController.swift`, `ChatController.swift`,
`Chat/ChatControllerLoadDisplayNode.swift`, `ChatHistoryListNode.swift`,
`AvatarNode.swift` and two PeerInfo story-entry guards. The pin-echo guard for
`AccountStateManagementUtils.swift` was delegated separately and is now observed
in TL-owned source. Avatar/header geometry,
main-menu construction, message menus/composer, feed rendering and receipts remain
with their existing owners. The existing Appearance main-menu Archive action is
the entry when the archive row is completely hidden; no second menu was added.

## Exact original fields and behavior

Android paths below are relative to `third_party/exteraless-android/TMessagesProj/src/main/`.
The inventory hash still matches the ownership snapshot:
`17cf1a8efad7469c8696045904105694347e26a2dbe70040d0f64658464ed99c`.

| Original ID | Default / original evidence | Native disposition / consumer |
|---|---|---|
| `dialog.customForumTabsEnable` | Getter false, but **absence inherits**; `DialogConfig.java:10–23`, `ChatObject.java:2638–2642`, `CustomForumTabsPopupWrapper.java:37–66` | Per-account encrypted native item-cache entry per namespace-packed peer ID; absent / Tabs / List are distinct. `ExteralessDialogForumController` provides the three choices. `ChatControllerContentData` updates actual native topic panels. Shared list/router hunks resolve layout before choosing list versus chat. No server `toggleForum` or `updateForumViewAsMessages` write. |
| `nagram.disableGlobalSearch` | false; `DialogsSearchAdapter.java:1104–1109`, `SearchAdapterHelper.java:184–258` | Live `GlobalPeerSearchContext.searchRemotePeers` → `exteralessDialogRemotePeerResults`. The original still calls `contacts.search`: it filters global results to contacts/joined chats while retaining `my_results`. Native message/hashtag search is independent. Preference changes reproject live results; account/test-environment cache keys are distinct. |
| `nagram.disableStories` | false; `NaConfig.kt:316–320`, `StoriesController.java:256–291,1081`, `SharedMediaLayout.java:3878,5042` | Native subscription refresh/load cancellation, peer/search story-list presentation gates, hashtag story-query cancellation, chat/list story stats and shared story-opening guards. Header/preload/avatar/PeerInfo guards are in the shared patch. Cached stories, upload state and server visibility are retained. |
| `nagram.doNotUnarchiveBySwipe` | false; `DialogsActivity.java:2519–2521` disables the archived peer row swipe | Shared `ChatListItem` hunks remove both reveal arrays **and recheck at action dispatch**. Explicit native menu unarchive remains its normal operation. Forced entry refresh on policy changes also updates already-visible rows. |
| `nagram.hideArchive` | false; `MessagesController.java:10093–10101,12650–12667` removes the folder reference, not its chats | `ChatListNodeEntries` omits `.archive` references and suppresses the story-only synthetic archive row. Archive membership, previews in selected folders and native data remain intact. Off rebuilds from the current native list. Key retains the inventory's `appearance.hideArchive`. |
| `nagram.searchHashtagDefaultPageChannel` | 0 = This chat; `NaConfig.kt:479`, `ChatActivity.java:38011–38017` | `HashtagSearchControllerNode` selects native page 0/1/2. The shared chat hunk removes the stock automatic public-channel → Public posts override, which otherwise defeats default 0. An explicit scope inherited from an existing search stays explicit. |
| `nagram.searchHashtagDefaultPageChat` | 0 = This chat; `NaConfig.kt:485`, `ChatActivity.java:38016` | Same native selector, separate key. Native `currentController`, `myChatContents`, `globalChatContents` keep their real engine providers. No-peer searches fall back to My messages; addressed/chat-only searches retain their explicit scope. Defaults apply on entering a search, preserving a tab the user already chose. |
| `neko.disableSwipeToNext` | false; `NekoConfig.java:167`, `ChatsHelper.java:505–506` | Shared visibility **and release-time** guards. `ContentData` observes preference changes in place; native `getNextUnreadChannel` / native peer reference remain the source. |
| `neko.disableSwipeToNextTopic` | false; `NekoConfig.java:168`, same helper | Separate thread flag, same native gesture path. Native `getNextUnreadForumTopic` / `ThreadData.id` are retained. Clearing a disabled expansion does not arm the next gesture. |
| `neko.openArchiveOnPull` | false; `NekoConfig.java:114`, `DialogsActivity.java:2340–2350` | The native reveal gesture arms one open, consumed at scrolling end. Root/unfiltered/non-search/non-editing only; Hide archive wins. Integration calls real `updateChatArchiveSettings` to make the native row pullable, atomically retaining its prior position for rollback. |
| `neko.rememberAllBackMessages` | false; `ChatActivity.java:11729–11732,18564–18566,52048–52051` | `ChatHistoryNavigationStack` keeps only the latest return point when off, the chat/thread-owned path when on. Native `EngineMessage.Index` values are retained. Scrolling does not prune all-replies mode. Owned long-press helper clears the path then calls the normal down action; shared visibility hunk installs it. |
| `neko.sortByContacts` | true; `NekoConfig.java:123`, `sort_by_contacts` | Evidence-backed **original storage-only** declaration. No Java/Kotlin consumer found; no fabricated live sort control, migration or alias. |
| `neko.sortByUnmuted` | true; `NekoConfig.java:121`, `sort_by_unmuted` | Same declaration-only disposition, independent key. |
| `neko.sortByUser` | true; `NekoConfig.java:122`, `sort_by_user` | Same declaration-only disposition, independent key. |
| `neko.unlimitedPinnedDialogs` | false; `DialogsActivity.java:9622–9641`, `MessagesController.java:17848–17882` | Actual native pin operation uses the account's archive pin limit for the root list; native pinned indices/persistence are retained. Sync preserves local extras, sends at most the **actual root server limit**, and discards/requeues a stale response when local order changed. Filters, archive and topics keep native limits. The existing `.done` still means the local native operation, not server acknowledgement. |
| `neko.unreadBadgeOnBackButton` | false; `ActionBar.java:2614–2617` | Shared badge hunks call `ExteralessDialogBackBadge`: native notification-category preferences/counts, current-chat subtraction and entry-point suppression. Privacy Extras filtered projections participate; an unknown numeric projection hides the number. Initial stale unfiltered badges are suppressed when filters apply. |
| `nagram.sortByUnread` | false; `NaConfig.kt:1398–1402`, `MessagesController.java:1436–1515`, `ChatsHelper.java:375–413` | **Live key `chats.sortByUnread`, only Nagram.** Actual native list ordering prioritizes mentions/reactions and positive unmuted unread counts after pins, preserving draft/date ties. Manual unread dots alone are not priority. Monoforum mentions are ignored as in the source. |
| `neko.sortByUnread` | false; `NekoConfig.java:120`, `sort_by_unread`; settings row actually uses NaConfig at `NekoGeneralSettingsActivity.java:171,353` | Original storage-only declaration; distinct from Nagram. No native key/row or migration into `chats.sortByUnread`. This fragment does not claim an Android preference-import implementation. |

The four legacy dispositions were checked across **both Java and Kotlin**, not
inferred only from the inventory's `unresolved` label. Generic preservation of
unknown JSON values by ClientSettings is not represented as a working legacy sort.

## Ordering, persistence and read boundaries

- `ExteralessDialogLocalList` observes **actual locally known native entries** with
  the native group/filter predicate. It does not fetch the network. The ordinary
  AccountViewTracker view remains the loader. This avoids sorting only whichever
  50/80 rows happen to be on screen while an older unread chat stays below them.
- Promotion and windowing retain native item/message/thread identities. The
  displayed window is selected around the native peer identity, not a synthetic
  timestamp. Shared list transitions prefer exact peer identity for scroll anchors.
  Pins retain native positions; draft/date order breaks priority ties; names/locale
  do not participate. Folder IDs are never replaced with array positions.
- Unknown server dialogs/holes are **not** fake cached rows. Known rows on either
  side of a local hole can be shown, with a continuation; the native loader still
  controls acquisition. A global order including dialogs the server has not sent
  cannot be promised by a local comparator. Metadata work is proportional to the
  native locally known list; device memory/frame-time profiling remains pending.
- Privacy Extras projects preview/counter/mention/reaction data before promotion.
  Hidden-account selection also gates the final entries, including contact and
  Saved Messages suggestions. No hidden-account result is made visible by sorting.
- Lookup/filter/search/history-stack adapters contain no mark-read/draft mutation.
  Next navigation continues through native references and the existing read/privacy
  pipeline **only after the user's navigation action**. No synthetic thread IDs.
- `ChatArchiveSettings.withExteralessArchivePull` stores the prior native row
  position in the same account preference, preserves `hiddenPsaPeerId`, survives
  recreation, and lets a subsequent explicit native Unhide win. Clearing/switching
  the UI context cancels observers; it does not erase the account's lease or drafts.
- Extra pins use native persistence, not a success-shaped external cache. The
  local limit is 100/other server-provided archive limit, not infinity. Server RPC
  failures/retries keep the existing native operation behavior. A preference
  generation is pinned across sync so turning the flag off mid-request cannot
  upload overflow pins. The outbound root limit also applies if the preference
  changes before sync begins; the shared remote-unpin echo guard retains a local
  overflow pin omitted from that server-limited prefix. Explicit local Unpin
  removes it before its echo. Existing delete/unarchive confirmations/permissions are
  not routed through custom operations.
- The forum override affects native panel/navigation presentation. Changing it
  in an open chat updates that panel in place; the next entry uses list/tabs routing.
  It does not discard a current draft or replace a native thread history owner.

## Files and build wiring

Core: `CoreDialogFeatures.swift`, `DialogPolicy.swift`, `DialogOrderingPolicy.swift`,
`DialogHistoryPolicy.swift`, and `DialogPolicyTests.swift`.

Native helpers: `TelegramCore/Sources/ExteralessDialogs/**` and
`TelegramUI/Sources/ExteralessClient/Dialogs/**`. Unique native consumers changed:
`ChatListNode{,Entries,Location}.swift`, `ChatListViewTransition.swift`,
`ChatListSearchListPaneNode.swift`, `HashtagSearchControllerNode.swift`,
`ChatControllerContentData.swift`, `ChatHistoryNavigationStack.swift`,
`ChatArchiveSettings.swift`, `TogglePeerChatPinned.swift`,
`ManagedSynchronizePinnedChatsOperations.swift`, `StoryListContext.swift`,
and `StoryContainerScreen/Sources/OpenStories.swift`.

Existing recursive source globs in TelegramCore, TelegramUI and ChatListUI pick up
new sources. Their existing ExteralessCore dependencies are present. No BUILD file
was edited. HashtagSearchUI consumes the public TelegramCore functions with its
existing TelegramCore dependency, without a direct Core import.

**Build owner wired the target concurrently:** `Tests/Exteraless/BUILD:69–87`
now contains `DialogNativePreferenceTestsLib` / `DialogNativePreferenceTests`,
the existing `Runner`, TelegramCore/TelegramUIPreferences deps, and a short test
timeout; the integration suite includes it. The already-applied BUILD hunk was
removed from the pending patch. This is target wiring, not a test-run receipt.

## Verification

- **Not executed:** `swift test --package-path swift/ExteralessCore --filter DialogPolicyTests`
  (8 bounded fixtures: comparator, scope/pins, windows, capacity, tri-state forum,
  navigation defaults, thread-owned history, real durable-store rollback/CAS).
- **Not executed:** native `DialogNativePreferenceTests` (2 tests; no Account,
  network, live database, plugin or user-account operation). Target is wired above.
- Offline source fixture: `python docs/wave-2/tests/dialogs_source_fixtures.py`.
  **8 tests passed** in the integration continuation (offline). This checks native
  provider/read boundaries, exact 18-ID receipts, native preference usage and
  declared applied/pending shared slices.
- Required checker: `python telegram-ios/build-system/Make/PostboxImportCheck.py telegram-ios`.
  **Passed, exit 0**. No allowlist entries added.
- Scoped `git diff --check`: **passed**.
- **Not executed:** native Bazel app build, CI, simulator, physical-device or
  recorded-frame checks. Host is Windows; Swift and WSL are unavailable. No
  commit/push/CI dispatch or external plugin/account test was performed.

## Expected frames — written before recording

Await a coordinator-built Mac/simulator build; **no visual pass is claimed**.

1. Sort on: priority rows travel upward behind the stationary native pinned rows;
   folder/tab identity, selected rows and draft preview survive. Off restores
   native draft/date order. Test >80 rows with an old unread item, two accounts,
   archive and two custom folders; no duplicate/disappearing peer during paging.
2. Archive: hide removes the entire row, including a story-only archive. Pull mode
   uses the native reveal motion and opens **once after release/settling**. A short
   or cancelled pull, editing/search/folder list or Hide archive must not open it.
   Native row position returns on disabling pull mode. No orphan gap/second haptic.
3. Forum: existing native tab/header/side-panel geometry is used. Default tracks
   native forum settings; explicit List beats server Tabs. Change the preference
   while a draft is present: the draft/caret/native thread stay, panel updates;
   next entry routes correctly. Check a topic whose ID equals one in another chat.
4. Next channel/topic: disabling during expansion collapses the control through
   the native path and clears the armed release. A later unrelated release must
   not navigate. Re-enable and use the real native candidate and thread reference.
5. Stories/badge: story header, avatar ring and entry affordances disappear with
   their native layout updates; no initial unfiltered badge flash, no ghost story
   archive. Back badge respects chats/messages category and Feed suppression.

Record light/dark, LTR/RTL, large text and both enable/disable paths with native
`simctl io recordVideo`; evaluate labelled ffprobe-timestamped frame sheets per
AGENTS.md. Compare motion with the stock native spring: one coordinated settle,
no extra oscillation, clipping, stale hit target or title/row teleport. Attach
actual frame indices/times before upgrading these expectations to verification.
