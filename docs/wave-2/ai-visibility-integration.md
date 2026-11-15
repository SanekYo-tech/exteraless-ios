# AI visibility — applied source receipt

Scope: the three original `appearance.hideAiEditor`, `appearance.hideIvSummary`,
`appearance.hideMessageSummary` controls. All three defaults are **false**; their
registered Bool rows use native settings Reset → `ClientSettings.reset`, restoring
the original availability predicate independently of stock provider replacement.

## Applied consumers and module edges

- Chat and attachment-caption stock button: `ChatTextInputPanelNode.swift:3661,3685,4039`.
  `ExteralessAIHooks` is declared in **AccountContext**. The file already imports
  AccountContext at line 12; its BUILD already depends on `//submodules/AccountContext`.
  Only the AI button/pill predicates and stale action guard were changed. The
  existing rich-input expansion/readiness/formatting/silent/retention paths are retained.
- Legacy caption and rich editor toolbar gates are applied in
  `LegacyMessageInputPanel.swift:461,677` and `RichTextAttachmentScreen.swift:2187`.
- The message bubble gates its actual `needsSummarizeButton` before construction
  (`ChatMessageBubbleItemNode.swift:2037`) and prevents a stale hidden button from
  starting a summary (`:7824`). Existing open summary can still be closed.
- Shared Instant View layout: `InstantPageLayout.swift:1167–1175`.
  `ExteralessAIVisibility` is declared in **TelegramCore**, in
  `Sources/ExteralessAI/ExteralessAIVisibility.swift`. The layout file already imports
  TelegramCore at line 3 and its BUILD already depends on
  `//submodules/TelegramCore:TelegramCore`.

**No new production BUILD edge is needed.** The new layout fixture is included by
the existing `//submodules/InstantPageUI:InstantPageUITestsLib` `Tests/**/*.swift`
glob and uses its existing InstantPageUI/TelegramCore/UIKit dependencies.
The test entry is `//submodules/InstantPageUI:InstantPageUITests`.

## IV index/anchor contract and authorized correction

The initial pre-layout `continue` needed refinement for structured summary blocks:

- `InstantPageLayout.swift:874–885,991–1019` assigns embed/details indices, and
  nested blockquotes pass the same counters through their children (`:567`).
- `BrowserInstantPageContent.swift:533–549,650–719` and
  `InstantPageControllerNode.swift:492–509` enumerate concrete embed/details items
  to restore state and route callbacks. Dropping those slots can rebind indices.
- The applied implementation executes the real block layout to advance its counters,
  then projects summary output to **zero-height placeholders** for embeds/details.
  Embed placeholders carry no URL/HTML or media. Details preserve index, expansion
  state and nested placeholder structure, with no title/content height. Other
  summary text/media drawing is omitted. Native details nodes clip to their bounds
  (`InstantPageDetailsNode.swift:72`).
- Named anchors are retained at the hidden summary boundary. Surviving content's
  anchors still use the native name lookup (`BrowserInstantPageContent.swift:1843`).
  Media selection uses media IDs/indices from the current layout (`:1518–1598`),
  permitting the preserved sparse media slots.
- The backing page is neither filtered nor saved: `pageBlocks = instantPage.blocks`
  and its original iteration indices remain. V2 rich-quote node paths
  (`InstantPageV2Layout.swift:782–789`) and the translation backing graph are not edited.

`ai-visibility-shared-hunks.patch` records the final applied two-file change,
including this coordinator-authorized contract correction.

## Receipts and verification status

`ai-visibility-parity.json` contains the three real inventory IDs with original
definition/consumer evidence and applied native callsites. Status is **implemented,
ported=false**, with native execution/frames pending. The separate
`nagram.showTextTranslate` receipt uses canonical `chats.showTextTranslate`; its App
migration-root status remains pending the App owner's return.

Visibility fixtures cover default/reset versus replacement, exact native caption
matching, and actual V1 placeholder objects/ordinals/anchors. No account, web view,
remote request or plugin is created by these fixtures. They are **not executed here**;
native typecheck, XCTest and timestamped frames remain pending. SDKConfig manifests,
the earlier 88 source hunks, CI and commits are outside this finalization pass.

## Final source checks and Core cohort — 2026-11-15

- All **5/5 hunks** in the two-file visibility artifact match exact applied spans.
  Artifact SHA-256: `e84037d335390adbabb0fe5c1eeaef6625bfa245a9a4c9d7954f05c342acd3b1`.
- The local syntax pass included the applied InstantPage/composer source and the
  real placeholder fixture: zero syntax error/missing nodes. PostboxImportCheck
  also exited 0. These are source checks; native typecheck/execution/frames are pending.
- Current default/reset fixture: `AINativePolicyTests.swift:22`; native caption
  fixture: `TelegramCore/Tests/ExteralessAINativeTests.swift:147`; actual placeholder
  fixture: `InstantPageUI/Tests/InstantPageAIVisibilityTests.swift:9`.
- All three original IDs remain **implemented / ported=false** in the receipt.
  The canonical `nagram.showTextTranslate` secondary evidence remains in `ai-parity.json`.
- The subsequently authorized AF follow-up adds a shared target resolver and a
  policy regression. The new frozen **3-file native Core cohort** is
  `c17e6a68591e3e23fd3052cfcefc4a8dc0eba697b78178f4a88398b795769cfa`;
  individual raw-byte pins are in [`ai-followup-core.sha256`](ai-followup-core.sha256).
  Use this cohort for the next native-policy test run; the reported AI75 pass belongs
  to the earlier AICF-owner cohort. Membership, hashing algorithm, native fixtures
  and pre-recording visual expectations are in
  [`ai-followup-remediation.md`](ai-followup-remediation.md).
