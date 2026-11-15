# Chat phase 2 — source handoff

**Source implementation and exact-ID receipts; native integration/verification pending.**
Patch only: no commits, push, CI dispatch, account sends/deletes, or external-plugin execution.

## Ownership and receipt coverage

`chat-parity.json` covers **137 original feature IDs + 4 modules**, including every
assigned ID from `docs/parity/remaining-ownership.json`:

| Package | Exact IDs | Receipt |
|---|---:|---|
| P-message-actions | 46 | Native actions/visibility and linked native moderation defaults |
| P-composer-policy | 19 | Native input/send/default/preview/formatting paths |
| P-message-presentation | 10 | Bubble/reply/unread/share/spoiler/time and header hunks |
| Reconciliation media/browser/aliases | 13 | Native consumers or individual source/platform dispositions |
| Restored baseline playback | 6 | Current gallery, SharedMediaPlayer and proximity consumers |

The named package lists are reproduced in `chat-phase2-receipts.json`; the read-only
auditor `tests/chat_receipts.py` asserts the exact package union is **75**, the additional
**13 + 6** reconciliation lists and **137** unique total records, checks source
anchors, and merges through the real `merge_parity` without writing the main inventory.
There are **zero ported/verified claims**. A native source callsite is not a build or frame pass.
Live source references are recorded in `ios.implementation_callsites`; unbound shared
hunks carry separate source evidence.

The three sticker presentation IDs (`chats.stickerShape`, `chats.stickerTimeSide`,
`neko.hideTimeForSticker`) and `nagram.silentMessageByDefault` remain Chat-owned.
Sticker packs/emoji/recents/size belong to Stickers; dialog sorting, including both
`sortByUnread` IDs, belongs to Dialogs. Feed/Player/Pills own their new implementations
and receipts for explicitly transferred IDs. The six original playback IDs were
never transferred; their current consumers and source-test evidence are restored.
See `chat-media-ledger.md` for every reconciliation ID and its disposition.

**Existing definitions were retained/restored in `ChatFeatures.swift`.** Domain files
add only missing preferences. All **16** baseline Feed/Player/Pill keys remain registered:
`wideFeedPosts`, four account-object Feed fields, seven playback fields and four base
Pill fields. Original defaults/types/options are preserved. The new regression test
performs real registration, atomic writes and reload of these values.

## Required coordinator hunks

Exact code is in **`chat-phase2-common.md`**. The current source requires its shared
changes before a native compile:

`chat-phase2-shared.patch` is the ready OpenCode patch envelope for these shared
files, with narrow contextual hunks. It preserves the latest Privacy-extras share
barrier and avoids Dialogs' next-channel/topic/story sections.

1. `ChatControllerInteraction.sendCurrentMessage` becomes `Bool?`; send parameters
   gain `notificationOverride`; `ChatController.transformEnqueueMessages` and inline
   result dispatch preserve nil/default versus explicit false. Owned callers already
   pass these values. Existing Stars/send-as/scheduling guards stay in the native path.
2. Canonical **`chats.showTextTranslate`** is now connected: AI reads the canonical
   policy, its duplicate definition is removed, and Main/Share preparation calls
   `ChatFeatures.migrateSettings`. Include the AI follow-up with the frozen Core slice.
3. AI's visible-text projection now has internal access in the live tree. Chat reuses
   that owner's summary/translation/rich/transcription projection for double-tap LLM.
4. Apply chat-origin expanded-header call/search gates, universal call confirmation,
   and the existing native favorite/copy-link/reaction/report menu gates.
5. Apply AppDelegate and share-extension URL-import hunks with the existing native
   proxy/login/Ton/document-routing checks and the shared settings/filter path.
6. `chat-media-shared.patch` supplies the AI message-menu sheet entry and Cloud's
   source-defined alias projection/import rules. These remain owner-applied hunks.

The aggregate `nagram.showTextTranslate` record includes both Chat and AI consumers.
Apply the AI receipt-exclusion section of `chat-media-shared.patch` before merging:
`merge_parity` rejects conflicting duplicates. The Chat aggregate retains both domains.

**Already applied by coordinator:** the first-wave `exteralessMessageContextActions`
and tapped `exteralessConfirmBotCommand` hunks. Their live callsites are now in the
fragment. Do not add a second insertion. AI native/render and NativeService barriers
were preserved during owned source edits.

## Native implementation

### Presentation and gestures

- Sticker radii and side-time layout cover static/animated/video-sticker paths.
  Time and share move together only when the row fits; overlapping name/reply geometry
  forces a native-layout fallback. Hidden time hides timestamp content, **not reactions**.
- Reply colors/emoji/background have independent native gates. Transparent-background
  changes now invalidate the inline-block cache. Tail preference participates in the
  bubble graphics cache key and fill/mask/outline/shadow generation, plus mosaic corners.
- Unread capsule changes real separator geometry. Channel share hiding preserves native
  discussion/ad controls. Text/rich spoiler display and hit-testing share the setting.
- Time hints use native message-tooltip dispatch, preserving imported-message and effect
  actions. The owned chat node observes presentation/input settings and requests refresh.
- All double-tap values **0…12** are mapped. 1 retains native quick reaction, 2 native
  reaction/menu, 4 permission-checked reply; others go through the existing chat-node
  reference to a native action host. 6 forwards, 7 hides sender names; they are distinct.
  Edit/delete/forward use native capability calculations; delete keeps confirmation/Undo.

### Actions

- Selection toolbar More and configurable left action use the original six left-button
  values. Copy preserves rich private fragments; edit/reply/forward/select-between are
  native. Forward-as-copy initializes the **actual** destination picker state, so user
  changes there override the initial choice.
- Native message extras: repeat-as-copy, forward without sender, reminder in Saved Messages,
  private reply, reference-only account-local bookmarks, media copy/sticker creation,
  cache removal, native author moderation/permissions and chat actions.
- Gallery footer invokes an account/message-bound native bridge: copy photo/current frame,
  QR scan, profile photo and forward/forward-copy draft. Media decode is bounded to 1920px;
  existing media fetching/export and profile upload UI are reused. Secret/protected/paid
  media are excluded. Original Share/Save remains reachable.
- Chat actions expose native members/admins/permissions/recent-actions/statistics/boost/
  linked-chat/navigation/title operations. They are reached from the composer and message
  menus, without editing Appearance's title/avatar nodes.
- Deletion defaults are **active through an indirect original call**:
  `NekoChatSettingsActivity.getDeleteMenuChecks` → `AlertsCreator:7961,8089` →
  `DeleteMessagesBottomSheet.toggleDefaultChecks:529`. `ConfigItemKeyLinked:38–53`
  persists one parent integer. Native `chats.defaultDeleteMenu` preserves that bitmask;
  its four logical IDs are aliases for bits 8/4/2/1, edited by a native four-checkbox
  screen. The moderation sheet seeds only allowed actions once, preserves later user
  choices, and has a common-groups checkbox. Confirmed common-group ban/restrict/history
  work uses existing native contexts/APIs, permission checks and the original 100-group bound.

### Composer and enqueue

- Mention creation uses the native peer picker and kernel `setLink`/mention codec;
  legacy applies an undoable attribute splice. Date now invokes native date editing.
- The actual Neko ordered Markdown grammar is separate from Telegram's grammar. Disable
  leaves authored formatting/rich structures intact. URLs/code/mentions/emoji are protected.
- Pangu uses attributed group splices and thin spaces, remapping entity ranges before
  interception. Structural rich payloads, code/URLs and encrypted text are not rewritten.
- Original 30 schedule-delay steps and minute-ceiling rule retain explicit dates.
  AV confirmation routes recording Send to native Preview before eventual paid send.
- Money hides the real Wallet `.money` attachment tab. Bot button/quick replies, attachment
  versus More, native recording-type menu, chat/sender placeholder and preview default
  all have consumers. The single-line native placeholder shows sender inline.
- Preview-only alternate hosts use the original ten built-in rules, preserving signed
  URLs and original sent text. Per-draft explicit enable and per-URL dismissal share one
  policy between the preview panel and outgoing attributes.
- Forward comment order operates on complete native message values. The multi-source
  forward branch now preserves every album member **and the comment**, and enqueues
  contiguous batches serially; the old branch dropped both in some cases.
- Enqueue applies default silence only to an **absent** notification attribute. Explicit
  false is stored as an empty-flags attribute and survives plugin MODIFY. CANCEL retains
  one nil slot per original input. `enqueueMessagesFromPlugin` still bypasses interception.

### Privacy boundary map

`EnqueueMessage.swift` now calls `ExteralessBotSendAuthorization.check` **after plugin
decisions, before media transforms or DB effects**; decline returns one nil per input.
The transaction calls `exteralessPrivacyOutgoingMessages` before any enqueue effects.
Then it invokes Retention's `exteralessRewriteDeletedReplies`; failure is reported
and returns one nil per input before inserts. The native rich/album/reply payload
continues through the successful rewrite.
Its post-commit `mapToSignal` now calls `nativeServicePublishEnqueuedMessages`, retaining
the ephemeral loop and original result order. This is the NativeServices owner's cold
local event read; it does not re-enter send interception or start a new network request.
No Network, SDK/TL, read/presence/account-state implementation was changed by Chat.

Privacy's scheduled-send helper excludes explicit schedules, bots/unknown private peers,
Saved Messages, encrypted chats, monoforums, paid/suggested/quick-reply/ephemeral/story/
game/invoice sends. Resend stays on its native transaction path. Share-extension
`sentShareItems` uses a separate standalone-send path: the URL hunk does not claim to
add these enqueue hooks there. Read receipts/retention/filtering remain with their owners.

### Kotlin-only links / real rich kernel

The existing AdGuard parser/store/updater remains the single filter. New ingress hooks
reach the real `ChatRichTextEditorComposer → RichTextEngineEditor →
TGIDObservingBlockTextView` path, plus legacy input:

- Private fragments rewrite only link/button-URL destinations through the `Document`
  tree, retaining labels, tables, folds, media, formulas and opaque non-URL payloads.
- Native RTF import rewrites href attributes before storage insertion.
- Final `insertText`/non-marked replacements are transformed **before** the native edit;
  provisional IME candidates are untouched. Code destinations remain literal; undo and
  selection are owned by the kernel. No post-change nested correction is issued.
- Plain `unmarkText` without a final text delivery is not retroactively rewritten.
  AppDelegate/share-extension ingress awaits the supplied coordinator hunks.

Full filter pin retained: `https://filters.adtidy.org/extension/ublock/filters/17.txt`,
version `2.0.14.84`, 184303 bytes, SHA-256
`06098fad1d9ee93ce294223206d9cb4b4c180df7a356eb563fa64e775e36cdfc`.
Runtime override: `<telegram-data>/exteraless/adguard_url_tracking.txt`;
bundle lookup: `adguard_url_tracking.txt`. Resource packaging belongs to Build.
The native updater validates before atomic replacement, bounds size/time, and supports
cancel/reset. No full-corpus or bundled-runtime pass is asserted here.

## Source-backed differences / remaining proof

- The earlier storage-only classification of the five `defaultDeleteMenu*` IDs was
  incorrect: the named helper supplies the real delete sheet. It has been corrected in
  code and receipts; all five remain original IDs sharing the original linked bitmask.
- Combine creates an editable, entity-preserving draft; it does not automatically send
  and delete the originals. Delete-my-messages reviews up to 100 recent matches per
  invocation through native deletion, not an unlimited purge. These are explicit partial
  adaptations. Grouped icon rows become a native nested menu.
- Header and common-menu/AI/call/share hunks remain pending as listed above. Some time-hint
  variants outside the wired text/rich/sticker/round nodes still require native review.
- Basic geometry, UIKit APIs, callback lifetime, generated header linkage and visual
  behavior need the native compiler and simulator/device. No compilation or frames were
  available in this Windows session; Swift/Swiftc are absent.

## Verification and build handoff

- **Core Chat FROZEN:** `chat-core-frozen.md` lists the complete 16-source/6-test-file
  cohort (51 XCTest methods), including the `ChatDoubleTapAction` dependency.
- FPP-01 is remediated in the native integration with a leased, identity-checked lazy
  factory scope. See `reviews/chat-FPP01-remediation.md`; saved actions cannot reactivate
  A or invalidate B, including after clear/re-activation of the same identity.
- **31 new bounded XCTest methods** across Core policy (10), factory lifetime (3), deletion defaults/rights (3), media/aliases (5), rich tree (2), real engine
  ingress (2), TelegramCore outgoing transforms (3), and TextFormat grammar (3).
  Tests use local fixtures only, with no account/network/plugin sends or deletions.
- The older 30 Chat tests remain. Coordinator-reported `4b3f7064` Core122/Host89/Hooks16
  green is baseline evidence, **not a pass of this newer UI/source WIP**.
- `PostboxImportCheck.py telegram-ios` passed. Existing allowlisted imports/accesses were
  preserved; new UI helpers use Engine APIs.
- UTF-8/NUL/whitespace/delimiter sanity passed for 39 chat helper/test Swift files.
  This is lexical source sanity, not Swift compilation.
- Earlier declaration audit covered 17 files/19 imports. The final media cohort audit
  covers 9 files/9 Core imports and identifies four required target edges:
  `BrowserUI`, `LegacyMediaPickerUI`, `ChatMessageInteractiveMediaNode` and
  `AdminUserActionsSheet` → `ExteralessCore`. No unresolved source owners. This is
  declaration analysis, not a Bazel build.
- New Swift files are in the normal source globs; ensure new native tests are included.
  TelegramCore test target needs Core + PluginHooks, TextFormat tests need Core.
  The shared share-import hunk additionally needs a direct `TextFormat` dependency
  on `ShareExtensionContext`; its existing BUILD does not yet declare that edge.
  `AdminUserActionsSheet` additionally imports `ExteralessCore` for the linked defaults.
  The ObjC host header/property changes must compile in the real native graph.
- Bounded Core command with the frozen cohort and AI follow-up:
  `swift test --package-path swift/ExteralessCore --jobs 1 --filter Chat`.
  Also run `--filter CloudLegacyImportTests` for the committed-slice dependency.
  Native build remains coordinator-owned full Make.py build. Every simulator XCTest
  invocation must use **`-parallel-testing-enabled NO`**, without overlapping processes.
- Read-only receipt check: `python docs/wave-2/tests/chat_receipts.py --check`.
  Merge only the current `chat-parity.json` alongside the other owners' fragments.
- Final receipt check passed: 137 unique Chat records, exact 75 + 13 + 6 lists,
  four modules and all 567 inventory features retained. The strict AI+Chat merge
  was also checked after applying the ready AI receipt-exclusion hunk **in memory**.
- Remaining packets dry-applied in memory: `chat-phase2-shared.patch` has 10 files /
  28 hunks; `chat-media-shared.patch` has 4 files / 10 hunks. This checks applicability,
  not compilation. TL owner still needs the explicit-false notification-attribute
  fix in `TLMediaServices.swift:321`, supplied in `chat-phase2-common.md`.
- Identity's requested ChatController section is applied: custom-wallpaper projection
  and date/time-format invalidation. Retention's enqueue section is applied after
  outgoing privacy and before result allocation. The final source contract also
  checks all five lazy Settings factories and the FPP-01 identity/epoch gate.

## Frames to record before visual acceptance

1. Static/animated/video stickers, incoming/outgoing, names/replies/share/reactions:
   side time and share move together or both retain native position; hidden time retains
   reactions; 0/original, 1/6pt, 2/message radii clip only the sticker. Narrow width/RTL.
2. Reply switches and tail toggle in text/media albums: one native layout update, no stale
   cached mask/outline, preserved corners and reply content. Light/dark and wallpaper.
3. Unread capsule centers its label, no full-width backdrop after toggle; spoiler reveal
   and hit testing agree; timestamp hint preserves imported/effect taps.
4. Double-tap every enum on an eligible/ineligible message, account switch while an
   action is open, repeat cancellation, Stars, send-as and protected/secret content.
5. Mention/date/Markdown/Pangu/preview defaults across both input backends; rich table/
   folded quote/media paste and IME commit preserve structure and one native undo step.
6. Selection More/left actions, forward-copy picker toggles, mixed-peer albums with a
   comment before/after; Send with sound versus default silent across text/media/inline.
7. Gallery current-frame/QR/profile actions, close/account switch during fetch; native
   preview/save controls retain original geometry and secret-media exclusions.

Record real-time transitions and evaluate labelled frame sheets as required by AGENTS.md.
No visual status should be promoted until those recordings have been reviewed.
