# Native channel feed — implementer handoff

Latest source slice: [FPP-02–05 remediation and FROZEN Core](../feed-remediation.md).
That handoff supersedes the per-channel lookahead, shallow projection, overlay-visibility,
metadata/header-lifecycle and unapplied-composition notes below.

Status: **partial, source implementation**. Native compile, the new XCTest suites and
recorded-frame verification remain pending. The coordinator's reported 122 green
baseline tests are not evidence that these new feed tests or UIKit sources ran.

## Delivered subsystem

The settings entry in the existing `ExteralessChatIntegration` now resolves the
`ExteralessFeedController` in `ExteralessClient/Feed/ExteralessFeedScreen.swift`.
Its post rows host **`ChatMessageItemImpl` and the native message item nodes**:
full text/entities/rich-message content, inline image/album/file/video/poll content,
native reactions, forwarded headers and associated reply previews. The old excerpt
row loop is removed. Cells use real peer/namespace/message IDs and peer/namespace
scoped album keys; neither stored nor outgoing message IDs are rewritten.

| Original source / effect | Native implementation |
|---|---|
| `FeedConfig.includeArchived=false`, `addNewChannels=true`, exclusions/known sets | Original keys stay in `ChatFeatures`; account-keyed settings read/write and searchable included/excluded lists in `Chats/ExteralessFeedController.swift`. No 2,000-ID prefix truncation. Disable auto-add / include-all / exclude-all waits for complete enumeration. Include-all clears stale exclusions, matching Android. |
| `FeedTimelineLoader`, `FeedBackfillCoordinator` | `ExteralessFeedHistory.swift`, `ExteralessFeedTimeline`: native hole-filling history views, 20-message pages / 40 around an older cursor, up to nine album-tail entries, four concurrent history requests, ten-second retryable rounds. Service entries advance the real cursor. |
| `(date, uid, mid)` sort; `FeedMessageIdentityMap` / normalizer | `ChatFeedPosition.orderingPeerId` uses Android's **negative channel uid** for ties while retaining native composite identity. Native media/message references remove the synthetic-ID/normalizer requirement. |
| `FeedStore`, window/cache/merge/deletion | 500-message display windows plus at most 29 lookahead messages per included source (whole albums). Eviction rewinds only affected source cursors; advancing consumes displayed IDs, not an album-shuffled timestamp. Native `Messages` observation applies edits/deletes/reactions to the retained window. Native database/media cache remain the persistent store. |
| `FeedChannelRegistry` | Paginated root **and** archive traversal via native `AccountViewTracker`, 100 chat entries per page, 200 around an older cursor. Cursor includes non-channel rows. No 1,000-chat completion limit. Gap/stalled cursor/timeout remains explicitly partial with Retry. Account synchronization and chat-list changes trigger 500ms coalesced scans. |
| `FeedUnreadTracker` | `FeedUnreadTracker.swift` + `ExteralessFeedReadState`: one-second coalesced, peer-scoped receipt frontiers; exact native unread counters; separator outside the entire oldest unread album; native mark-all. Only laid-out, fully visible posts or viewport-filling tall posts count, after initial positioning, in active foreground without overlays. |
| Read / mark-all privacy boundary | **`engine.messages.applyMaxReadIndexInteractively`** and **`togglePeersUnreadMarkInteractively`**. They update local state through existing native helpers; the Privacy owner's existing synchronization/network policy determines outgoing receipts. Feed introduces no read RPC or exemption. |
| `FeedActivity` / `FeedChatIntegration` lifecycle | Background/exit cancels page views, metadata timers and queued renders; already seen receipts drain against their immutable original engine. Account invalidation rejects stale callbacks and clears presentation data. Foreground re-observes the window and probes heads. Newer bursts beyond an overlapping head page show an explicit gap/refresh affordance, preserving the reading anchor. |
| `FeedChannelAvatarMenu` | Actual avatar context menu: open channel, native mute/unmute, select channel posts, exclude + Undo. Post actions: native gallery, formatted/rich copy, native share/forward, native discussion/source navigation and poll voting. |
| `FeedChannelsActivity` | Search, alphabetic included/excluded sections, complete native pagination and account-scoped bulk/individual membership changes. |
| Copy protection / secret content | Only joined broadcast cloud posts enter the feed. Secret media, service rows and ads are excluded. Native bubble and gallery receive copy-protection state; export rechecks current messages and platform restrictions. Entities and rich-message clipboard structure are retained. |

The read tracker, layout leases, counters and page/observation generations are
account-local. `ExteralessFeedIntegration` allocates a **new badge promise** on account
replacement: old subscribers never start receiving the replacement account's count.

## R-feed2: exact entry gaps and coordinator hunks

**`docs/wave-2/feed-native-hunks.patch` is an unapplied `functions.patch` payload.**
It contains the complete AccountContext entry definition and insertion hunks for:

1. `AccountContext/Sources/ExteralessFeedEntry.swift`: controller factory, badge
   signal and tab-visibility getter. Dependency direction stays
   `ChatListUI -> AccountContext <- TelegramUI`.
2. `ExteralessClient/ExteralessClientRuntime.swift`: register
   `FeedFeatures.definitions`; construct/retain/update/clear the optional
   `ExteralessFeedIntegration`; install the entry factories. Feed must receive the
   new context **before root tab construction / appearance re-composition**.
3. `ChatListUI/Sources/ChatListController.swift`: **Channel feed** in the native
   Chats-tab context menu. The existing settings feed action remains a working entry.
4. `TelegramRootController.swift`: retain a feed controller, replace the Contacts
   slot while enabled, subscribe its badge, refresh on preference change and dispose
   observers. Native Calls/News inputs and current-controller identity are retained.
5. `Appearance/ExteralessTabNavigation.swift`: apply the same replacement during
   appearance phase-2 re-composition, preventing Contacts being inserted alongside
   the feed. This is for the coordinator/Appearance owner to apply together.

Only these missing definitions are added in `FeedFeatures`:

| Original ID = default | Actual key / current gap |
|---|---|
| `appearance.showFeedTab=false` | Same key. Getter/factory/tab-replacement implementation exists; **actual root-tab insertion still requires the supplied hunks**. Do not mark this verified/ported. |
| `appearance.showFeedUnreadCounter=true` | Same key. Native feed header/tab badge and account-scoped badge signal consume it; the **closed native tab badge subscription** still requires the root hunk. Disabled removes partial indicators as well as counts. |

Feed visibility controls the replacement slot independently of the Contacts-only
appearance filter. The retained Contacts controller and native contact entry points
remain usable. A partial count is displayed as `N+`, or `…` while unknown.

The four `chats.includeArchived/addNewChannels/excludedChannels/knownChannels`
definitions and `chats.wideFeedPosts` already belong to `ChatFeatures` and are not
registered again. No additional cached-item namespace/state row is needed.

## Changed source groups / build handoff

- Core: `ChatFeedPolicy.swift`; new `FeedFeatures.swift`, `FeedUnreadTracker.swift`,
  `FeedPresentationPolicy.swift`; `Tests/ExteralessCoreTests/FeedTests.swift`.
- TelegramCore: existing `TelegramEngine/Messages/ExteralessFeedHistory.swift`;
  new `ExteralessFeedChannels.swift`, debug-only `ExteralessFeedOfflineFixture.swift`.
- TelegramUI: existing `Chats/ExteralessFeedController.swift` (membership screen/settings);
  all nine new `ExteralessClient/Feed/*.swift` files.
- Native fixture tests: `TelegramUI/Tests/FeedTests/FeedNativeFixtures.swift` and
  `FeedNativeOrchestrationTests.swift`. Add to a dedicated iOS unit-test target with
  testable TelegramUI, TelegramCore, SwiftSignalKit and ExteralessCore dependencies.

The existing TelegramUI graph already uses the native message-item modules. Ensure
the new source glob sees Feed and these direct imports: `ChatMessageItemImpl`,
`ChatMessageItem`, `ChatMessageItemView`, `ChatHistoryEntry`, `ChatControllerInteraction`,
`ChatInterfaceState`, `AvatarNode`, `WallpaperBackgroundNode`, `Pasteboard`,
`ChatRichTextEditorComposer`, `TextSelectionNode`, `OpenUserGeneratedUrl`,
`LocalizedPeerData`, `ExteralessCore`. Debug smoke also imports SwiftUI.
TelegramCore needs its existing ExteralessCore/Postbox/SwiftSignalKit graph. BUILD
and application composition edits are supplied to their owners, not applied here.

## Offline verification prepared

**16 Foundation XCTest cases** in `FeedTests.swift`: original signed-uid tie order,
frontier inside an album, peer/namespace collisions, independent receipt frontiers,
counter acknowledgements without guessed numeric countDiff, account replacement,
exclusion, failed receipt retry with a newer seen frontier, whole-album unread boundary,
foreground/overlay/layout gates, bounded retention and cursor rewind, pagination gaps,
four-request timeout/cancel, stale media leases, membership snapshots/coalescing,
include-all semantics and definition disjointness.

Suggested bounded command: `swift test --package-path swift/ExteralessCore --jobs 1
--filter FeedTests` (30-second fixture/process budget; build separately if needed).

**Four native orchestration fixtures** use injected finite page/window signals:
1,250 channels plus an empty non-channel page, root/archive completion, gap timeout /
retry, native message edit/delete and same-ID albums, and cancellation of a missing
source. They construct **no Account, Network or TelegramEngine** and send no reads,
votes, reactions, messages or external plugin calls. Their total expectation budgets
are eleven seconds; the gap timeout is injected as 10ms, production remains 10s.

**Prepared SwiftUI render smoke:** `ExteralessFeedSmoke(context:edited:)`. It accepts
only a supplementary account under a UUID-named temporary fixture/harness directory,
with SOCKS `127.0.0.1:1` configured **before account construction**. The permit expires
after 30 seconds. It creates six synthetic posts with local-only PNG media, same-ID
albums in two peers, a protected channel, formatted/spoiler text, a forward, associated
reply and reaction counts. Rendering uses the production feed cell/item builder.
The smoke cell does not dispatch interactive Telegram actions. No real account was
used to prepare or run tests. A renderer-capable offline AccountContext host and native
linking are still required; ComposerHarness's unprovided context members trap rather
than silently substitute behavior.

### Expected recorded frames (not yet captured)

- Initial status rows settle into actual bubbles; photo/album tiles, full formatted
  text, forwarded source, reply preview and reaction counts are visible in the feed
  itself. Editing the fixture changes only the correct composite post; a reused cell
  never flashes another peer's media. No clipped header, doubled album or empty media gap.
- Read separator stays outside the oldest unread album. Native-height resolution and
  the initial unread jump finish before receipts become eligible. Background, inactive
  app, native overlay and avatar menu produce no new visible receipts.
- Insertions/edits/count updates preserve the first visible composite ID and offset.
  Newer-page gaps show Refresh; failure/cancel shows Retry with retained posts, never
  a fabricated beginning-of-history state. Repeated scrolling uses bounded windows.
- Account switch, light/dark, increased text size, RTL, rotation, phone/tablet/Duo
  band insets and Reduce Motion: source/channel actions and media belong to the displayed
  account; the native tab slot and badge update without duplicate Contacts/feed entries.

Use `AGENTS.md`'s `simctl io recordVideo` and timestamped frame-sheet procedure on a
dedicated fixture simulator; each prepared fixture run is capped at 30 seconds.

## Evidence / remaining work

Local Windows checks: Postbox import/access guard, owned-path diff whitespace check,
and native interaction initializer label comparison passed during implementation.
The initializer supplies all 131 required arguments (two optional native edit hooks
use their defaults). Final source/hunk/parity checks are recorded below after they run.
Swift/Xcode are absent here; no native compile, XCTest execution or frame pass is claimed.

Specialized native actions (advanced/paid reaction UI, callback/web-app actions,
sticker/poll-result tools and advanced selected-text actions) navigate to the original
native post where needed. Initial unread positioning is bounded to the loaded window;
older windows remain explicitly loadable. `wideFeedPosts` controls edge-to-edge row
placement; per-media native sizing limits remain. These are not claims of full Android
gesture/menu/style equivalence.

`feed-parity.json` has seven original feature IDs plus `module.feed`, all **partial**.
When merging latest evidence, replace the old chat fragment's five feed-related feature
records and `module.feed`, rather than passing conflicting independent entries verbatim.
Its old `Chats/ExteralessFeedController.swift:228/304` references are superseded by this
fragment. The Pill owner should use the new `Feed/ExteralessFeedScreen.swift` header
callsite for its own latest fragment; pill definitions/views remain separately owned.

### Final local checks

- `PostboxImportCheck.py`: **passed** after the final Core/UI/test additions.
- **20 Swift files / 20 XCTest methods** passed UTF-8, NUL, trailing-whitespace and
  delimiter sanity. This is source validation, not execution/typechecking.
- Native interaction initializer: **131 required labels supplied**, no unknown
  labels; the two optional native rich-edit hooks retain their defaults.
- Real parity merger: **7 features + module.feed accepted**, **35 path/line
  references checked**, all partial, **zero verified/ported claims**.
- Coordinator payload: **17 unique-context hunks + one new AccountContext file**
  across five shared paths simulated successfully **in memory**. No shared path was
  written by that check.
- Owned-path `git diff --check`: **passed**. No commit, push or CI dispatch.

Native compilation, these new tests and the prepared render smoke still need the
coordinator's build/fixture runner and independent review before status promotion.
