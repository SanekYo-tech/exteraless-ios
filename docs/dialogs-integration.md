# Dialogs — shared integration receipt

**Review follow-up:** [IDS-03/04/05 remediation](wave-2/dialogs-remediation.md)
supersedes the initial current-prefix pin-echo heuristic, selected-context-only
disable handling and unqualified badge subtraction described in this first
integration receipt. The new native fixtures are not yet executed.

**Applied: 23 hunks in eight shared files.** Owner permission was extended for
these slices after the 18-ID source handoff. Native build, XCTest and frame
verification are still **not executed**.

## Applied source

Paths in this table are relative to `telegram-ios/submodules/`.

| File / native boundary | Applied effect |
|---|---|
| `ChatListUI/Sources/ChatListController.swift:1419,1452` | Per-account forum layout resolves before list/chat routing; native monoforum branch remains first. |
| Same file `:2143,2189,2251` | Real native preload, story and archived-story provider factories are switched by dialog policy; existing native result/layout/ready handlers consume the results. |
| Same file `:2980,4347,4411` | Story camera, notification-open and peer-story entry guards. |
| `ChatListUI/Sources/Node/ChatListItem.swift:4057,5720` | Archived peer-row reveal arrays and action-dispatch recheck use the original swipe-disable rule. Native explicit menu unarchive/delete/undo paths remain their own operations. |
| `TelegramUI/Sources/NavigateToChatController.swift:55–57` | Local forum layout plus native cached view mode chooses the existing router branch. No server forum-setting write. |
| `TelegramUI/Sources/ChatController.swift:9838` | Ordinary public-channel hashtag taps honor the original configured page, including default 0. Explicit existing-search scope still has precedence. |
| Same file `openResolved` | Forum URLs use the shared forum-aware router with native peer/subject/peek data. |
| Same file `:11210–11216` | Native next-chat visibility and long-press history controls are connected to policy. Existing selection and native offer checks are retained. |
| `TelegramUI/Sources/ChatHistoryListNode.swift:781,1357` | Disabling an offer disarms expansion/releases its native hold; release rechecks the current chat/thread's flag before the real handoff at `:1393`. The current thread, rather than an optional next candidate, selects the topic policy. |
| `AvatarNode/Sources/AvatarNode.swift:1206,1266,1400` | Retain the latest unfiltered native story stats; apply live story policy on main, update the existing indicator, and dispose observation with the node. |
| `TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift:3624,4884` | Only the two requested story-entry guards: archive and post story. |
| `TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift:604` | Initial native Back badge goes through `exteralessDialogInitialBackBadge`, retaining the native entry-point flag and privacy/filter gate. |
| Same file `:4985–4988` | `chatUnreadCountDisposable` subscribes to `exteralessDialogBackBadge`, retains disposal/main-thread delivery and writes the existing `navigationItem.badge`. |

`docs/wave-2/dialogs-native-hunks.patch` records the exact **already-applied**
dialog UI/shared edits. `pending_shared_files` is empty. The separate state hunk
is also observed applied; Root composition remains delegated below.

Coordinator seams observed in the current source after application:

- Pill visibility remains at `ChatListController.swift:2385,2868`.
- Feed entry remains at `ChatListController.swift:6377`.
- Appearance main-menu factory remains at `ChatListController.swift:7273`.
- AI selected-text/speech and settings observation remain in
  `ChatController.swift:4453,4456,7887`.
- Native bot routing and age-verification gates precede forum routing in
  `NavigateToChatController.swift:25–34`.

Application used narrow patch contexts. This continuation added no composer,
bot-command, web/call-coordinate, Root, account/passcode, BUILD or namespace
allowlist changes. These are source-scope observations, not runtime tests of the
other owners' implementations.

## Integration status and Root handoff

### TL/shared-state owner — pin echo observed applied

**`docs/wave-2/dialogs-state-hunk.patch`** contains only
`AccountStateManagementUtils.swift → UpdatePinnedItemIds → .unpin`.
It calls the existing `exteralessDialogKeepsOverflowPinOnRemoteUnpin` adapter before
removing a native local overflow pin omitted from the server-limited prefix.
The call is now present at `AccountStateManagementUtils.swift:5208`, before native
unpin mutation. It appeared during the back-badge verification; the state file
was not edited by this owner. The separate patch is now an applied-source receipt.

### Back badge — applied after explicit permission

Both `neko.unreadBadgeOnBackButton` bindings are applied at the source sites above;
their pending entries are cleared. Before patching, the complete current file was
transformed **in memory using exactly the two approved hunks**. Its expected
LF-normalized SHA-256 matched the actual file immediately after the patch:

`3890aed1b66a9853a29ec89be08d2ca09545d9bca7dfc54b45fa55c099116075`

This step-local comparison confirms that input/sendBotCommand, AI and native
privacy guards elsewhere in that working-tree file were preserved exactly. It is
an application receipt, not a permanent hash pin against other owners' later edits.

### AppExtras integrator — exact Root contract

Register **`DialogFeatures.definitions` once (13 definitions)** after configuring
the shared ClientSettings store and before dialog consumers begin.

| Exact key | Default |
|---|---|
| `chats.sortByUnread` | false |
| `chats.disableGlobalSearch` | false |
| `chats.disableStories` | false |
| `appearance.hideArchive` | false |
| `chats.openArchiveOnPull` | false |
| `chats.doNotUnarchiveBySwipe` | false |
| `chats.searchHashtagDefaultPageChat` | 0 |
| `chats.searchHashtagDefaultPageChannel` | 0 |
| `chats.disableSwipeToNext` | false |
| `chats.disableSwipeToNextTopic` | false |
| `chats.rememberAllBackMessages` | false |
| `chats.unreadBadgeOnBackButton` | false |
| `chats.unlimitedPinnedDialogs` | false |

Page values are 0 This chat / 1 My messages / 2 Public posts. Per-forum layout is
native account-local tri-state data, not a fourteenth global definition. The four
legacy `NekoConfig.sort_by_*` fields are not live definitions or Nagram aliases.

Root's main-thread lifetime contract:

```swift
private var dialogs: ExteralessDialogIntegration?

// Add DialogFeatures.definitions to the existing one-time registration batch.
// After shared settings configure AND Profile/Privacy Extras initialization/update:
if dialogs == nil { dialogs = ExteralessDialogIntegration() }
dialogs?.update(context: context)

// Account teardown/switch:
dialogs?.clearContext()
```

**Profile/Privacy Extras update must precede Dialogs Root update.** The integration
uses the current account and native archive preferences; it provides the
`dialogs.forumLayout` settings action. It does not discover a global AccountContext.

The existing `ChatListNodeLocation` wrapper already composes
`exteralessDialogProjectList → exteralessFilterChatList` with native group/filter
identity and public hidden-account policy. AppExtras owns that file now and must
keep this one composition rather than adding filters to each native branch.

## DirectSourceChecks

- `python docs/wave-2/tests/dialogs_source_fixtures.py` — updated to **8 bounded,
  offline desktop source checks**. It verifies the applied UI/state postimages,
  actual provider calls, native release/reference ordering, original
  sort collision evidence, no read/draft mutations in pure adapters, and 18 IDs.
  **Back-badge continuation run: 8 passed in 0.105 s.**
- `python telegram-ios/build-system/Make/PostboxImportCheck.py telegram-ios`:
  **passed, exit 0**, with zero allowlist additions.
- Scoped `git -c core.autocrlf=false diff --check`: **passed, exit 0** for the
  approved back-badge file; the earlier seven-file slice also passed.

These desktop checks read source files; they do **not execute Swift, UIKit, an
account/database/network action, a plugin or a native test target**. Previously
written 8 Core XCTest + 2 native preference fixtures remain unexecuted here. The
native test target was already wired by the build owner; this slice edits no BUILD.

No commit, push or CI dispatch. Visual expectations remain in
`docs/wave-2/dialogs.md#expected-frames--written-before-recording`; only a real
Mac/iOS build and timestamped recorded frames can supply native/visual acceptance.
