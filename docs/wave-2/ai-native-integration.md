# Native AI — applied shared-source integration

2026-11-15. Coordinator-authorized application of
`ai-native-remediation.patch` after the Core remediation/SC remove-intent correction.

**Applied through the patch tool: 88 source hunks in 29 Swift files.** The original
artifact has 89 hunks in 30 files; its one BUILD hunk is assigned to **hdo** in
[`ai-native-build-hdo.patch`](ai-native-build-hdo.patch). This report supersedes the
earlier handoff's “common source not applied” status.

## Actual shared paths closed

Paths below are relative to `telegram-ios/`.

| Applied files | Actual call-graph effect |
|---|---|
| `submodules/AccountContext/Sources/ExteralessAIHooks.swift`; `submodules/TelegramUI/Sources/ChatController.swift` | Selection Speak passes message/copy provenance into direct native speech. Copy/Share revalidate. Protected stock translation carries its capability to the screen; `compose` cannot re-admit it to the external adapter. AI-01/02 shared callsites are applied. |
| `submodules/TelegramUI/Components/TextProcessingScreen/Sources/{TextProcessingScreen,TextProcessingTranslateContentComponent,TextProcessingTextAreaComponent}.swift` | Capability passes through root → sheet → content → request and selection controls. Both explicit Copy and selection Copy/Share use the engine permission check. Missing `copyResult` is not used to grant external processing. |
| `submodules/AccountContext/Sources/AccountContext.swift`; `submodules/TelegramUI/Sources/SharedAccountContext.swift`; `Tests/ComposerHarness/AppContext/HarnessSharedAccountContext+Generated.swift` | Shared factory and generated conformance publish the required capability parameter; the implementation forwards it to the native screen. |
| `submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift`; `.../ChatMessageRichDataBubbleContentNode/Sources/ChatMessageRichDataBubbleContentNode.swift`; `.../ChatMessagePollBubbleContentNode/Sources/ChatMessagePollBubbleContentNode.swift`; `submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift` | Native display and actions consume the same effective language/origin/text/entities/page resolver. Open summary remains a summary; quiz explanation uses the translated solution with original media. Copy/AI/Speak see the displayed manual translation and UTF-16 prefix offsets. |
| `submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift` | Summary toggle owns per-message generation/disposal. Off cancels A; stale callbacks cannot retire B. Summary request uses the effective display language. |
| `submodules/TelegramUI/Components/Chat/ChatMessageInteractiveFileNode/Sources/ChatMessageInteractiveFileNode.swift`; `submodules/TelegramCore/Sources/TelegramEngine/Messages/Transcription.swift`; `submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIChatPolicyObserver.swift` | Stock inline availability/execution uses selected-provider/Premium policy. Native Telegram response/trial-state transaction receives the lease. Experimental-local partial/final writes await guarded storage. Cancel and generation checks reach actual callbacks; provider changes refresh the chat. |
| `submodules/TelegramCore/Sources/State/ServerMessageMerge.swift` | Real merge invokes the rich-aware source comparison and invalidates stale translations/summaries on source edits. |
| `submodules/AttachmentUI/Sources/AttachmentController.swift`; `submodules/TelegramUI/Components/LegacyMessageInputPanel/Sources/LegacyMessageInputPanel.swift`; `.../RichTextAttachmentScreen/Sources/RichTextAttachmentScreen.swift`; `submodules/TelegramUI/Sources/ChatControllerNode.swift`; `.../Chat/ChatControllerLoadDisplayNode.swift` | Specific existing composer/attachment factory calls carry user-input/chat provenance. Their mode, draft replacement, send callbacks and entry selection are retained by the exact incremental diff. |
| `submodules/GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift`; `.../Items/ChatImageGalleryItem.swift`; `submodules/InstantPageUI/Sources/InstantPageControllerNode.swift`; `submodules/TelegramUI/Sources/OpenResolvedUrl.swift`; `submodules/TelegramUI/Components/Wallet/WalletTransactionScreen/Sources/WalletTransactionScreen.swift`; `.../Gifts/GiftViewScreen/Sources/GiftViewScreen.swift`; `.../Stories/StoryContainerScreen/Sources/StoryItemSetContainerViewSendMessage.swift` | Gallery message/OCR and gift-message factory routes carry source capability. Other listed callers carry their explicit user-input or story restriction state. |

AI-03's owned engine-backed source/context resolver and per-export/per-commit checks
are now connected to the applied shared routes. Source-level closure of these paths
is not a native runtime or visual acceptance claim.

## Anchor and coexistence audit

- All current source anchors were unique and ordered before editing; no rebasing or
  extra source changes were needed.
- Before application, normalized before/expected-after SHA-256 values and exact
  post-hunk spans were captured for all 30 listed files. The expected output is the
  current tree plus only the approved hunks (BUILD held at its before state).
- Post-edit comparison confirmed **88/88 exact source spans**. The patch tool
  initially removed one existing final empty line in `TextProcessingTextAreaComponent`;
  it was restored through an EOF patch. Its focused full-source digest then matched.
  All 29 source files therefore match the approved result, including surrounding
  coordinator/Chat-lead code, with line endings normalized for the comparison.
- Baseline manifest:
  `C:\Users\sasha\AppData\Local\Temp\opencode\ai-native-integration-646cf147185c44ad9fd98747d548390c.json`.
- This comparison includes the coordinator's existing menu/identity/Zalgo work and
  the Chat lead's current source. No whole-file replacement was used. The new
  `ExteralessPluginMenuEntry.updating` chat action menu and the appended
  `exteralessMessageContextActions` / `exteralessProtectedCopyAction` paths are outside
  the changed hunks. Other adapters and FPP/SC/Tools ownership were not edited.

## BUILD handoff — hdo

Apply **only** `ai-native-build-hdo.patch` for this integration's deferred BUILD work.
It is the exact extracted BUILD segment, with these new labels:

- `//submodules/TelegramUI:ExteralessAINativeTestsLib`
- `//submodules/TelegramUI:ExteralessAINativeTests`

Dependencies in that segment are `:TelegramUI`,
`//submodules/TelegramCore:TelegramCore`, and
`//third-party/exteraless:ExteralessCore`; runner:
`//Tests/Exteraless:Runner`.

The existing `//submodules/TelegramCore:TelegramCoreTests` glob contains the native
Postbox fixtures. Core's `AINativePolicyTests` is in the SPM test glob. Production
AI/Speech and TelegramCore AI helpers are already in their recursive source globs.
No BUILD file was edited in this integration pass.

## Harness seams and verification

- Required `makeTextProcessingScreen(... capability: ...)` is published in the shared
  protocol, forwarding implementation and checked-in generated harness conformance.
  Both current generators were executed with stdout captured in memory:
  `Tests/ComposerHarness/Tools/generate_harness_stubs.py` and
  `Tests/ExteralessHarness/Tools/generate_context_stubs.py`. Each emitted the required
  parameter and matched the applied conformance signature exactly. No generated
  source files were rewritten by that check; native Swift conformance checking is
  still required.
- The installed route was inspected at
  `submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift:109–110,128,175`:
  context update installs the adapter, teardown removes it, and the native adapter
  has the AccountContext protocol conformance. The applied stock component invokes
  `ExteralessAIHooks.compose` with `component.capability`.
- Existing fixtures: 23 declared native-remediation XCTest methods (5 pure policy,
  10 real in-memory Postbox, 8 native component/transport). They use bounded synthetic
  data and injected transports/recognition; this pass adds no fixture behavior.
- Native full typecheck/link, the stock hook/inline UI matrices, and recorded frames
  remain native harness checks. None was run in this Windows integration pass.
- Post-edit `python build-system/Make/PostboxImportCheck.py .`, from `telegram-ios`,
  was executed once: **exit 0, no diagnostics**.
- The full post-edit exact-hunk/digest audit was executed once: **29 source files,
  88 exact applied source hunks**, plus the EOF-only correction/focused digest check
  described above. The original approved artifact's digest also matched. The
  **one BUILD hunk remains deferred**, its file's before-state digest matched, and
  `ai-native-build-hdo.patch` was verified against the exact original segment.
- Generator publication check: **2/2 signatures matched**, with the capability
  required in each. These are source/artifact checks, not Swift or XCTest passes.
- CI, commit and push were not invoked.
