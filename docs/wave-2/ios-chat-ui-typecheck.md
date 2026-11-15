# Chat UI compiler follow-up — f05473ea

2026-11-16. **Source-only fixes in 11 authorized files.** The bounded source
checks passed; Swift/UIKit compilation and frames remain pending the coordinator's
next coherent full-iOS build.

## Input and diagnostic causes

- Full-iOS run: **43761767575**; failed snapshot
  `f05473ea63ffd568fff92dfa1fd7414fd53c2c12`.
- Local source base: `4bcf80a0d7160264accbb6b415facde82cf87928`.
- Log: `C:\Users\sasha\AppData\Local\Temp\opencode\ipa-f05473ea-failed.log`.
- Log SHA-256:
  `44bbe728503d02f3103b75119344ad0ad4a710722195c63e88e752c6532ee749`.

The owned files contain **44 diagnostic rows: 42 errors and 2 warnings** in this
log. Counts below exclude repeated excerpts and notes.

| Cause | Diagnostics | Original locations |
|---|---:|---|
| Missing context/String alert overload import | 32 errors | Bookmarks:20; CallConfirmation:60; SendAdmission:192; GalleryChatActions:25; MessageMediaActions:79/87/103/121; SelectionActions:183 |
| Raw search messages treated as EngineMessage wrappers | 3 errors | ChatActions:83 |
| Pre/post-transform `messages` redeclaration | 1 error | ChatControllerNode:5518 |
| Associated-value enum case used as an equality value | 1 error | ChatHistoryListNode:2073 |
| Never-assigned local weak variable | 1 error | ChatExportAccess:375 |
| Nested weak capture beneath implicit strong captures | 1 error | SelectionActionSession:39 |
| Nonisolated local menu helpers calling MainActor APIs | 3 errors | GalleryChatActions:47/59; SelectionActions:34 |
| Main-delivered UI callbacks missing static actor context | 2 warnings | ChatControllerNode:860; GalleryChatActions:51 |

## Narrow source corrections

All abbreviated Chat helper names below refer to
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/`.

### Alerts and the real return type

Added `import PresentationDataUtils` to `ExteralessBookmarks.swift`,
`ExteralessChatCallConfirmation.swift`, `ExteralessChatSendAdmission.swift`,
`ExteralessGalleryChatActions.swift`, `ExteralessMessageMediaActions.swift`,
`ExteralessSelectionActions.swift` and `ExteralessChatActions.swift` (which also
contains a context/String alert after the failed search expression).

The actual overload is `PresentationDataUtils/Sources/AlertTheme.swift:9–23`:
`AccountContext`, optional String title, String text, native actions →
**ViewController**. Its implementation at lines 70–84 constructs `AlertScreen`.
The prior lookup found Display's theme/NSAttributedString overload instead.
TelegramUI already directly declares PresentationDataUtils and AlertComponent in
its BUILD dependencies.

Call confirmation also adapts to that real return type: it requires the returned
`AlertScreen` to bind `dismissed` to the existing cancel callback, and disposes
through its native `dismiss()` override. A failed cast returns nil/cancels through
the existing flow. `AlertComponent.swift:828–845` owns animation and dismissal
notification. Initial/replacement prompt identities and their consumed callbacks
continue to be owned by `ExteralessChatCallFlow`.

### Send batch, pinned history and capped search

- **`TelegramUI/Sources/ChatControllerNode.swift`:** the post-ordering/options batch
  is named `preparedMessages`. The mutable pre-transform batch still receives thread
  and correlation changes; final send uses the prepared batch/count with the same
  silent intent, schedule time, repeat period, postpone flag and captured operation.
- **`TelegramUI/Sources/ChatHistoryListNode.swift`:** `if case .pinnedMessages = subject`
  excludes the whole pinned-history case from retained-history injection. This covers
  both nil and non-nil `id` payloads; equality against `.pinnedMessages(id: nil)` would
  exclude only one payload. Default-source, scheduled/tag and bubble-mode conditions
  retain their previous roles.
- **`ExteralessChatActions.swift`:** `SearchMessagesResult.messages` is `[Message]`,
  and `EngineRawMessage` aliases that type. The native deletion callback takes
  `[EngineRawMessage]`. The producer now uses an explicitly typed
  `Array(result.messages.prefix(100))`, without calling `_asMessage()` on raw values.
  Author/thread search scope, native review confirmation and the 100-message cap
  are retained.

### MainActor and capture lifetime

- Gallery's local `notice`, `add`, `imageAction` and the gallery action callback
  are MainActor-bound. Selection's local `add`, its selection-load callback and
  `ExteralessSelectionActionSession.read`'s body carry the same main-only contract.
- The session invokes its MainActor body synchronously through `assumeIsolated`
  **inside the existing terminal permit callback**. Its eligibility read already
  uses `deliverOnMainQueue`; `ExteralessChatExportAccess.perform` also delivers the
  final validation on main before `permit.perform`. The permit calls its body
  synchronously under its lock (`AccountContext/Sources/ExteralessContentExportPermit.swift:49–58`).
- The render-settings callback's actor assertion is inside its existing
  `Queue.mainQueue().async` block. Call-prompt setup runs after CallFlow's
  `readPeers` main delivery, and prompt disposal keeps its existing main-queue block.
  SwiftSignalKit's main queue is backed by `DispatchQueue.main` and executes inline
  when already current. No additional queue/Task hop is introduced.
- **`ExteralessChatExportAccess.swift`:** the original optional window is mapped to
  the existing `SwiftSignalKit.Weak` box and captured as a `let`. Only `Weak.value`
  is read for source-window and presentation identity. The box stores a weak
  reference, its initializer receives only a present window, and missing/deallocated
  windows still fail the existing presentation predicate.
- **`ExteralessSelectionActionSession.swift`:** both finite outer read/validation
  closures explicitly capture `[self]`, matching their prior strong captures.
  The continuing eligibility observer still captures `[weak self]`. Single-choice,
  source/lease retirement, copy protection and revalidation remain in their existing
  order. This does not introduce the nonescaping weak-plus-mutable-local closure
  shape documented in `telegram-ios/CLAUDE.md:640–656`.

## Checks / coordinator boundary

- Eleven-file `git diff --check` passed.
- A bounded read-only source comparison against the pinned base matched **only**
  the reviewed import, type/capture/actor, variable-name and enum-pattern replacements:
  11 source files, 42 inserted / 24 removed lines.
- Actual alert return/dismissal types, raw search/deletion types, enum payload,
  Weak storage/initializer, main-queue delivery and existing BUILD edges were checked
  against their declarations. UTF-8/NUL checks passed.
- Existing queue/Task-hop counts match the base. The same send operation and
  optional sound/schedule arguments reach final send; source/CAS/FU admission bodies
  and their retained ownership are covered by the exact-diff boundary.
- No runtime-mirroring tests were added. Swift is unavailable locally; none of these
  source checks is a successful compiler, XCTest, IPA or frame result.

This slice is ready for coordinator composition with the other diagnostic groups,
then a new full native compiler pass. No CI dispatch, commit, push, account/UI use,
network request or external-plugin execution was performed here.

## Modified-source pins

SHA-256 of UTF-8 with CRLF normalized to LF, after this follow-up:

```text
c8a6bc0261a3681d1c5da9119b09dc952938f6fe52770b6c9e4d43c7441aa424  telegram-ios/submodules/TelegramUI/Sources/ChatControllerNode.swift
7936e34b321c2fb9c064ae1bb285aee145136c2a7e974900524eac6c4b69712b  telegram-ios/submodules/TelegramUI/Sources/ChatHistoryListNode.swift
ede20ffe8c77c41b5f6d9282fc166299a7de2aab803ef53e2f329bb1efe6ad66  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessBookmarks.swift
923cbe2fbbc5bfc6fd70ba9c7f26550496892680b2c405fb2b309c1c5730ce1f  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatActions.swift
81f351b5ac9dce8aa125d0f50ec1d8b020e103bb340532fbdb04c2cbed10af69  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatCallConfirmation.swift
b370d8b492c466108281ba22040835462e396288f30e41d57f9d67073a25ed4d  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatExportAccess.swift
09d525825b3091f1fe5399036bb81d8bb35f20898f9ff744d034c0144b9b87e2  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatSendAdmission.swift
0ad448318a7387356c481f24410b493f22dbea53bed32bbe6da01fbaf2e86389  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessGalleryChatActions.swift
d12a2f20c523b531c1f838833a3b41c4bccb1c2ba117ba94344953431ead0c50  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessMessageMediaActions.swift
ebe29000893fc3c50cbf0c5544a9e8b56324b925c0dd94971840e19feb8823a7  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessSelectionActions.swift
22a6947373ea744bd7952c80ada966d6ab89cca2ba0748b1f20dfdbcd58f7c83  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessSelectionActionSession.swift
```

### Read-only contract pins

```text
cebcd6133513aa6ebb1e499315e2db73cbd925d171c2ebc69427c45dfc4f7dbe  telegram-ios/submodules/PresentationDataUtils/Sources/AlertTheme.swift
ad6c4ad34be6d394a1c67bd0030ae65c4f227e43ebfdc6431790373c5be0a6fa  telegram-ios/submodules/TelegramUI/Components/AlertComponent/Sources/AlertComponent.swift
17049e387398755f79224f58b49ac1b72e1983315ff0c5a836b1c86222202a66  telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Messages/SearchMessages.swift
85fe70dd6ee4acd5f41c94c7e2d22ed761fa71625547db8e60175938cc6678a7  telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Utils/EnginePostboxCoding.swift
982d269332020819aa3e3b56e65ad9ec6b69f57b5a4a993caf77308c7ab5bde4  telegram-ios/submodules/ChatPresentationInterfaceState/Sources/ChatPanelInterfaceInteraction.swift
dcfcb93673830bad49467b294d8aedfa56e851cd36ed9639a6c21d51e484715a  telegram-ios/submodules/AccountContext/Sources/ChatController.swift
01675a040b4653a9d3f4235f7b6d7a7dbfde05b1004a9b087b7a6d39da56e495  telegram-ios/submodules/SSignalKit/SwiftSignalKit/Source/Bag.swift
ac7db4cdf6b9728f0936bf35998cee3f6b8d7824abbc07e71e679e068315b31b  telegram-ios/submodules/SSignalKit/SwiftSignalKit/Source/Queue.swift
3397655c88c43fce4e2643e5a421f0a8ea13e4e2ee83b9d6286654a22c5ac46e  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Chats/ExteralessChatCallFlow.swift
```
