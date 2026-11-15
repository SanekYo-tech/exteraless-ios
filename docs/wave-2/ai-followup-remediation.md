# Native AI follow-up remediation — AF-01…06

2026-11-15. **AF fixes and the handed-off Chat menu/sheet integration are applied
to source.** The exact History renderer hunk and two BUILD dependency hunks are
ready in [`ai-followup-shared.patch`](ai-followup-shared.patch). Native typecheck,
XCTest execution and recorded-frame acceptance remain pending.

The findings are from the read-only [`reviews/ai-final-followup.md`](reviews/ai-final-followup.md).
Coordinator-reported **75 AI tests PASS, run `43700711108`, commit `f99909b5`**
remains evidence for the AICF-owner cohort. This follow-up has a new native Core
cohort below; that previous pass is not attributed to the changed files.

## Applied routes

| Finding | Source correction |
|---|---|
| **AF-01 P1** | `TelegramCore/Sources/ExteralessAI/ExteralessAIScope.swift:136–150` uses the Chat UI's effective cached-user **copyProtectionEnabled OR myCopyProtectionEnabled** predicate. Acquisition, validation, the live cached-peer observer and queued AI writes all reach this predicate. No message-version bump is needed to revoke external processing/Copy. |
| **AF-02 P2** | `TelegramCore/Sources/State/ServerMessageMerge.swift:22–34` calls `exteralessAIInvalidateDerivedAttributes`: incoming `SummarizationMessageAttribute(fromLang:)` survives source edits, with summary/translated payloads removed; stale translation attributes are dropped. |
| **AF-03 P2** | `ExteralessAIRichSource.swift` owns preview/full selection and the actual native full-content completion transaction. `requestFullRichText` delegates to that implementation; it captures source version before `getRichMessage`, rejects a changed source, invalidates prior derived output and advances only the committing scope's actual version. Scoped whole-message operations load missing full content and revalidate after the await. Summary/translation use complete `fullInstantPage`; the real rich translator rejects an incomplete whole-message source. |
| **AF-03 display/Copy** | The rich node exposes its actually applied page only for the matching message ID/version. `ExteralessAIChatActions` and native context-menu Copy use that page. The shared display resolver preserves collapsed preview versus expanded source, and refuses an incomplete cached translation when complete source exists. Show More admission depends on displayed completeness, including translated previews. The translation action uses the same cache-usability check. |
| **AF-04 P2** | The round-video node's actual component/action now calls `ExteralessAIHooks.transcribe`. Availability and trial-lock display respect selected-provider policy. Its disposable is the Cancel authority even after a cooldown relayout; account/message/resource identity and generation guard callbacks. The adapter's shared `exteralessAINativeRequest` carries the lease through Task/Signal cancellation, and `ExteralessAINativeTranscriptionRequest` executes the provider/Premium branch. Native Telegram response/trial and external transcript writes retain their real guarded Postbox paths. |
| **AF-05 P2** | `AINativeTranslationTarget.resolve` is the single enabled/availability/peer-auto/default-language/normalization calculation. It applies `toLanguage ?? appLanguage`, native base-language normalization and `nb → no`. Chat actions, Copy/AI/Speak and the new sheet use it. The renderer's exact call to this resolver is the first handoff hunk. Incoming auto translation prevents a manual Hide action from claiming to hide it. |
| **AF-06 P2** | Only a confirmed engine commit can produce `ExteralessAIScope.committedRetryCapability`, using the version actually read back from Postbox. `ExteralessAIResultAccess.begin()` cancels/linearizes with the previous operation, carries that receipt into Retry, then reacquires and validates. External edits still fail equality. Scope renewal snapshots source/version atomically; resolve/observer callbacks are generation-bound. Result completion is once-only and cannot mint a version. |

Paths in this table beginning with module names are relative to `telegram-ios/submodules/`.
Owned UI implementations are under `TelegramUI/Sources/ExteralessClient/AI/`.

### Chat-owner integration

- `ExteralessAIIntegration.presentMessageTranslation` invokes
  `exteralessPresentMessageTranslationSheet` before constructing the fallback result
  screen. The helper carries the captured message capability, effective language
  and account lease, loads full rich source when needed, and validates before and
  after the asynchronous stock-screen factory. The resulting capability retains
  the effective external/Copy restrictions; stock Copy still uses its engine guard.
- The four `ChatMenuPolicy` gates are applied at
  `ChatInterfaceStateContextMenus.swift:1000,1344,1784,1934`; reaction-panel admission
  is gated at `Chat/ChatControllerOpenMessageContextMenu.swift:148`. Each file has
  one `ExteralessCore` import. Existing native eligibility and Chat/plugin action
  paths coexist with the AI display/Copy hooks.
- `ai-parity.json` retains original ID **`nagram.showTextTranslate`** and its honest
  secondary consumer evidence for canonical **`chats.showTextTranslate`**. Final
  owner/aggregator reconciliation and App migration publication remain their join.

### Authorized shared boundaries

`TelegramEngineMessages.swift` changes from this owner are confined to the body
of `requestFullRichText`. The round-video changes are confined to transcription
availability/component binding and transcription action/cancellation sections.
Reversing only those two round-video sections in memory reproduces the review's
exact pre-follow-up file SHA-256:
`e62cc8bec071fe498b202a69ba823f3b354cbc89470674f7b2cbb7463e589b1e`.
This checks preservation of the surrounding video/retention/time-hint source.

## Meaningful native fixtures

**Ten new declared methods:** 1 pure policy, 4 TelegramCore, 5 UIKit/engine-boundary.
All use bounded synthetic content and injected I/O. None was executed here.

| Fixture | Exercised boundary |
|---|---|
| `AINativePolicyTests.testAF05DefaultAutoTargetUsesTheSameAvailabilityAndNormalization` | Nil target/app `en-raw`, `nb-NO`, disabled and Premium/channel availability, manual Hide with incoming auto. |
| `ExteralessAINativeTests.testAF01MyCopyProtectionRevokesScopeWithoutMessageVersionChange` | Real cached-user mutation; stableVersion unchanged; existing scope invalid, fresh external/Copy denied, queued summary write refused. |
| `testAF02SourceEditKeepsFreshSummaryEligibilityOnly` | Actual server merge in Postbox, both plain and rich-only edits, new `fromLang`, no old summary/translation payload. |
| `testAF03FullRichCompletionInvalidatesPreviewResultsAndUsesActualVersion` | Actual full-source completion helper, small preview/full pages, actual commit receipt, stale-version and cancelled responses refused, replacement full page invalidates derived cache. |
| `testAF05NilAutoTargetUsesEnglishForNativeDisplayAndCannotHideAuto` | Native incoming message/attributes and real translation commits; English default auto display, French manual override, no false Hide, auto-disabled original. |
| `ExteralessAIFollowupNativeTests.testAF01ActualResultAccessObserverRevokesCopyAndFurtherExports` | Real `ExteralessAIResultAccess` observing real Postbox cached-peer changes; actual result text-view Copy revoked; scoped injected transport admits no further body-bearing request. |
| `testAF06RealResultAccessSuccessRetryAndExternalEdit` | Real ResultAccess begin/resolve/validate/finish, actual translation commit → Retry succeeds at V′; external edit → Retry rejects; repeated/failed completion cannot advance capability. |
| `testAF03FullRichSourceFeedsCopySummaryAndRealTranslationClient` | Preview `A`, complete `A + SENTINEL_B`; native Show More's completion helper, displayed-page Copy projection, actual summary source builder and rich translation client. Captured provider queries include B, stored page stays complete, and Retry keeps the confirmed full-source/translation commits. |
| `testAF04ActualRoundButtonRoutesSelectedProviderWithoutPremiumGate` | Creates the **round-video node and its real button component**, sends `.touchUpInside`, and runs the adapter's shared executable route for 5 providers × Premium/non-Premium. Uses real Speech-service decode/response plumbing with tiny injected PCM/recognizer/HTTP data and real Postbox commits; counts native gates and actual selected-provider callbacks. |
| `testAF04RoundButtonCancelReachesQueuedRealPostboxCommit` | Presses that same button to start and cancel, after response transaction admission behind a queue barrier. Both external and native Telegram/trial bodies run and refuse mutation after lease revocation. A forced cooldown display state cannot swallow Cancel; source version, transcript and trial state remain unchanged. |

Current native-owner set: **35 methods** (7 policy + 15 TelegramCore + 13 UIKit),
plus **1** separately targeted InstantPage visibility fixture. Tests inject account
data/provider boundaries; full AccountContext/root navigation and rendered frames
still require native harness acceptance.

## Patch handoff and test targets

[`ai-followup-shared.patch`](ai-followup-shared.patch) has **3 hunks in 2 files**:

1. Coordinator: `ChatHistoryListNode.swift` effective auto-target block.
2. BUILD owner/hdo: `TelegramUI/BUILD` production dependency on
   `ChatMessageRichDataBubbleContentNode` for the displayed-page reader.
3. BUILD owner/hdo: six direct dependencies on the existing
   `ExteralessAINativeTestsLib`: AccountContext, ComponentFlow, Postbox,
   SwiftSignalKit, AudioTranscriptionButtonComponent, ChatMessageInteractiveInstantVideoNode.

The native test target already exists. Apply these incremental dependencies before
native compilation. Intended native runs after handoff:

- Core: `swift test --package-path swift/ExteralessCore --filter AINativePolicyTests`.
- `//submodules/TelegramCore:ExteralessNativeCoreTests` (the general TelegramCore test
  glob also includes the file).
- `//submodules/TelegramUI:ExteralessAINativeTests`.
- `//submodules/InstantPageUI:InstantPageUITests` for the visibility projection.

## Performed checks and source cohorts

- Cached local Swift parser: **35 files, zero syntax error/missing nodes**; the final
  three edited files were reparsed successfully. This is not Swift typechecking.
- `python -B build-system/Make/PostboxImportCheck.py .`: **exit 0**.
- Scoped `git diff --check`: **exit 0**.
- Follow-up handoff: **3/3 unique before spans**, applied only in memory for checking.
  Import/dependency declaration audit: **23 files / 94 imports**, seven missing
  direct edges in the current tree, **zero after the handoff**. Relative BUILD labels
  are resolved in this audit; it is not Bazel analysis.
- Visibility artifact: **5/5 exact applied spans** in its two authorized source files.
  Three injected provider response literals also passed JSON decoding.
- AICF's four-file manifest still matches the review:
  `38b943fb548e3f3c83d89d1b1988ae1fd5201353d99581ad5a8b1d4feb7796dc`.
  Both older review-file hashes match their recorded pins; the final review is
  `ca5e10041632661c2c95288f5c06f22587272a818004ae935463ee6bc300c550`.

Snapshot HEAD during hashing: `7d04a35a3612a2dc32dba6fb54744e38c07cabe9`.
These hashes describe **working source bytes**, including untracked additions.
Manifest algorithm is SHA-256 of sorted unique entries
`relative POSIX path + NUL + SHA256(raw bytes) + LF`, UTF-8 encoded.

| Cohort | Files | Manifest SHA-256 |
|---|---:|---|
| **New frozen native Core**: `AINativePolicy*.swift` sources + `AINativePolicyTests.swift`; individual pins in [`ai-followup-core.sha256`](ai-followup-core.sha256) | 3 | `c17e6a68591e3e23fd3052cfcefc4a8dc0eba697b78178f4a88398b795769cfa` |
| All Core `Sources/ExteralessCore/AI*.swift` + `Tests/ExteralessCoreTests/AI*.swift`; **82 declared tests**, execution pending | 31 | `7db48311692fa5f835387a87a6de8fdbec1cf21e5a07b2efc9bdc837785688f9` |
| Native owned, membership below | 21 | `268bc2f3b6ec938fc02b63014c8f7954d1c9ffbcf86fabb27a1db21aea3c9f44` |
| Applied follow-up shared paths, membership below | 8 | `2eb3ed946b0ed027949f70621385158d750cb0f9f5cebf72b03aebdaf7ab9202` |

Native-owned membership: the three native Core files; all six
`TelegramCore/Sources/ExteralessAI/*.swift`; its `Tests/ExteralessAINativeTests.swift`;
UI AI `ExteralessAI{Integration,NativeAdapter,ChatActions,ResultController,RichTextTranslator,ChatPolicyObserver,NativeRequest}.swift`;
both `ExteralessClient/Speech/*.swift`; both `TelegramUI/Tests/AI/*.swift`.
Applied-shared membership: AccountContext `ExteralessAIHooks`, Core `ServerMessageMerge`
and `TelegramEngineMessages`, UI `ExteralessChatTranslation`, `ChatInterfaceStateContextMenus`,
`ChatControllerOpenMessageContextMenu`, `ChatMessageInteractiveInstantVideoNode`,
`ChatMessageRichDataBubbleContentNode` (all `.swift`, at the paths above).

Handoff artifact SHA-256:
`571ae26d4580a4a275258cfd3ecd7af91b80575d8b62d3b79f62303a41f66225`.

## Native/visual acceptance still pending

This Windows host has no Swift/iOS toolchain or XcodeBuildMCP simulator tools.
Recorded frames must follow `telegram-ios/AGENTS.md`. Before recording, expect:

- Hide/reset changes only the intended stock affordance/slot; IV summary has zero
  height while surviving details/embed identity and anchor destinations remain stable.
- Show More exposes B; Copy reflects the displayed page; a complete translation
  retains B and an incomplete preview retains an expansion route.
- Round-video requests follow the selected provider, Cancel clears progress, and
  late responses never repaint old transcript text. Existing component layout uses
  its 0.3 s transition and round/file transition keeps its 0.2 s choreography, with
  no video-shape or retention/time-hint glyph jump.
- Capture sheet open/close and these toggles in light/dark and relevant content
  states; evaluate timestamped frames for gaps, clipping, stale text and double draws.

The three visibility receipts are **implemented / ported=false**, finalized in
[`ai-visibility-integration.md`](ai-visibility-integration.md). No native/visual pass
is claimed. This owner ran no CI, commit, push, live HTTP, real-account requests,
external plugins or OOM fixtures; SDKConfig manifests and review reports were read-only.

## AIAF-01 addendum — same-preview server edit (2026-11-15)

**Residual AF-03 source fix applied**, following
[`reviews/ai-af-followup.md:22–44`](reviews/ai-af-followup.md).
The earlier cohort tables describe the pre-AIAF snapshot; current pins are below.

### Revision and both merge layers

- `ExteralessAIScope.swift:222–239` reads the actual
  **`EditedMessageAttribute.date`**, including `isHidden=true` edits. The display-only
  `Message.editedTime` accessor excludes hidden edits and is deliberately not used.
  A changed server revision makes `exteralessAITranslationSourceUnchanged` false even
  when text/entities and the incomplete preview are identical.
- `ServerMessageMerge.swift:22–35` consequently takes its existing invalidation
  branch: old translation is not carried over; fresh incoming summary `fromLang`
  eligibility survives without cached payloads.
- The only Seed change is the rich-cache admission header at
  `SyncCore_StandaloneAccountTransaction.swift:175–176`: previous full content may
  be restored only when these same server revisions match. The incoming partial
  page therefore stays `fullInstantPage=nil` after a new revision. Same-revision
  partial refresh still restores the native cache.
- Postbox `stableVersion` remains the operation/commit guard, not the server edit
  revision. Own derived commits retain `EditedMessageAttribute`; their confirmed
  version receipts and actual ResultAccess Retry behavior continue to work.

### New real-Postbox fixture

`TelegramUI/Tests/AI/ExteralessAIFollowupNativeTests.swift:293–405`:
**`testAIAF01SamePreviewServerEditReloadsFullSourceAndPreservesOwnCommitRetry`**.
Two bounded cases cover visible and hidden edit labels:

1. Store revision 100, incomplete preview `A`, full `A + OLD_B` and a complete
   translation. A same-revision partial server refresh passes through actual
   `mergedServerMessageUpdate` **and Postbox's Seed closure**, retaining full/translation.
2. Perform a real own translation commit. Assert actual version advancement,
   revision still 100, full cache retained, and successful `ResultAccess.begin/resolve`
   Retry. No expected version or receipt is fabricated.
3. Merge incoming revision 101, identical partial `A`, no full payload and fresh
   `fromLang="es"`. Read back after both real merge layers: no full cache or
   translation, fresh eligibility present, no stale summary payload. The old
   operation's subsequent Retry rejects this server edit.
4. Resolve a fresh `readyScope` from the actual stored message. The native whole-page
   completeness predicate now admits **one counted full fetch**. Its injected
   `A + NEW_C` response passes the production lease/version-guarded completion writer.
   Real markdown AI input contains C and not B; the real rich translator with scoped
   injected transport captures provider queries exactly `{A, NEW_C}`. Its own commit
   and subsequent Retry retain revision 101 and the new full page.

This is one new method (six in that UI follow-up file). Native-owner totals are now
**36 methods + 1 InstantPage fixture**. The injected response replaces network I/O;
the message merge, Seed merge, scope/receipt lifecycle and storage are production code.
Native XCTest execution/typecheck remain pending on this Windows host.

### Checks and exact source pins

- Swift syntax parse: **4 changed files, zero error/missing nodes**; not typecheck.
- PostboxImportCheck and scoped `git diff --check`: **exit 0**.
- Replacing only the new Seed admission header with its former line reproduces
  the review's complete-file pin
  `acc8b85b6bbe24a41b5bf5e5872f0db3dfe81f1a563bcc4ba681a75504977597`.
  Every other Seed byte is preserved.
- Removing only the new fixture method reproduces the former UI test-file pin
  `3ad6579a1892ab25432eddea9c24b92e19301873cbfbc625166785394e257e84`.
- All four review pins and sampled Root/Chat/AI lifecycle pins remained unchanged.
  Read-only `ai-af-followup.md` SHA-256:
  `22ac6876a53e0c15947aed9d433a957bef0d487b3e5d44e62aa3ce5fa927cd21`.

Working-source snapshot HEAD: `9c409eb88541ba948ad593f9096b8f4a3485de74`.
The manifest algorithm is the same sorted `path + NUL + raw-file-SHA256 + LF`
algorithm defined above.

| Changed file | Raw SHA-256 |
|---|---|
| `telegram-ios/submodules/TelegramCore/Sources/ExteralessAI/ExteralessAIScope.swift` | `1700bcaac12be032a51abd6f433df993848994d5cc0853679ceb25cad727ec40` |
| `telegram-ios/submodules/TelegramCore/Sources/State/ServerMessageMerge.swift` | `539233bee8e7460b3f501236390208a26a3d1fc5157bca3ec129d67a5e8f6a6e` |
| `telegram-ios/submodules/TelegramCore/Sources/SyncCore/SyncCore_StandaloneAccountTransaction.swift` | `d4510003bf9fffadb776aae502104a602756248bd511876cc610f6e8f52c280a` |
| `telegram-ios/submodules/TelegramUI/Tests/AI/ExteralessAIFollowupNativeTests.swift` | `b0b04693a66ca30c0b0b9079fef1e624974d01f727c248311ddaddfe582ebb4d` |

- **AIAF-01 four-file manifest:**
  `9df5d0efb888303b25e5c6d8953ea3ce1542791d0326f90a29a1e83f3af9371f`.
- Updated native-owned 21-file manifest (same membership):
  `a82c6fa466c3146bdc736207833d9530ca708bef4445e0395f64f13d68c90791`.
- Updated applied-shared eight-file manifest (Seed is separately pinned above):
  `7b04dfa76c52d18a3451ebf688239035d05c243ef8e8c23a3a74914d8e556610`.
- Frozen three-file native Core remains
  `c17e6a68591e3e23fd3052cfcefc4a8dc0eba697b78178f4a88398b795769cfa`;
  all 31 Core AI files also retain
  `7db48311692fa5f835387a87a6de8fdbec1cf21e5a07b2efc9bdc837785688f9`.

No CI, commit, live HTTP, Root or Chat/CMC source mutation was performed for this addendum.
