# Native AI remediation — implementer handoff, 2026-11-15

Scope: AI-01/02/03/06/07/08/09/10/14/15/16/18 from the read-only
`reviews/ai.md`. Baseline is the coordinator's already-applied native/render hunks.

## Coordination / API reservation

- This owner adds **only** `AINativePolicy*.swift` and `AINativePolicyTests.swift`
  to the Core package. Existing Core AI implementation/tests belong to the original
  author and are not modified here.
- Native callsites will continue using `AIManualTranslations.set/state` and existing
  configuration types. The original author's bounded-eviction fix is consumed via
  that API. No duplicate marker store is introduced.
- `ai-native-remediation.patch` contains exact incremental hunks for the shared
  AccountContext/TextProcessingScreen/chat/render/merge files. Those source files
  remain coordinator-owned; apply the complete patch together with the owned files.
- `AINativePolicy.swift` supplies the native operation lease/identity, effective
  display/provider policies and structural budget; TelegramCore supplies the actual
  Postbox scope, permission revalidation and commit implementations.
- Speech's endpoint/key form now consumes the original author's reserved
  `saveOpenAITranscription(baseURL:credential:authorizeDestinationChange:)` and
  `openAITranscriptionAPIKey(baseURL:)` contract in `ai-core-remediation.md`.
  The final Core contract is available in `AICredentials.swift`. The audio form
  captures the displayed endpoint before opening/saving the key editor; no async
  save rereads a mutable URL. Metadata-only changes use `.unchanged`.

## Implemented paths and evidence boundaries

`AI-xx` references below point to the exact original scenario in the independent,
read-only `reviews/ai.md`; its reported baseline green is not remediation evidence.

| Finding / review lines | Actual correction | Prepared semantic fixture / status |
|---|---|---|
| AI-01, 18–26 | `ExteralessAIEntry.speak` carries input provenance. Chat selection, AI action and speech-preview entries call direct AVSpeech; no speech AI result is made or cached. Result text view's system Copy routes through the same validator as explicit Copy/Insert; active source scopes revoke on message/peer updates. | Native UIKit `testProtectedResultHasNoSystemSelectionCopyOrShare`; scope revocation fixtures. **Not run**; full Speak → account/protection change → Latest UI sequence still needs native execution. |
| AI-02, 28–36 | Explicit `ExteralessAIProcessingCapability` flows from the chat through stock `TextProcessingScreen`'s sheet/content/text-area and `ExteralessAIHooks.compose`. Denied external processing chooses only the original native fallback. `copyResult == nil` has no permission meaning. Shared screen factories carry provenance too, including gallery message/OCR and gift message sources. Stock Copy/share handlers revalidate the engine scope. | Actual scope/transport refusal fixtures assert denied export starts no base transport; **not run**. The full `performTextSelectionAction` → default/Premium stock-screen interception matrix is a native harness check, not claimed from those narrower fixtures. |
| AI-03, 38–48 | `TelegramCore/Sources/ExteralessAI/ExteralessAIScope.swift` samples source, reply chain and explicit local context in real transactions. It reads effective cached user data (PeerView's identity rule), current peer/message protection, secret media and peer/thread scope. Every message-bearing HTTP request, retry/fallback/tool round revalidates; native commits revalidate the entire lease inside the transaction. Scoped assistant turns are not persisted as provenance-free history. | Native Postbox `testProtectedReplyPrivateCachedProtectionAndSourceLeaseRevalidation`, `testReplyProtectionChangeAfterAcquisitionBlocksCommitAndCopyValidation`, `testContextScopeRejectsForeignPeerThreadAndSecretIdsAndBoundsEmptyChain`; scoped transport fixture. **Not run**. |
| AI-06, 76–84 | Structural source comparison includes the native rich page, rather than just empty plain text/entities. The incremental `ServerMessageMerge` hunk invalidates translations/summaries for changed source content. A successful owned commit reads back **actual Postbox stableVersion** into its lease. A stale manual marker without an attribute no longer creates a permanent manual spinner. | Native in-memory commit → real server merge → rich-only edit fixture checks stored attribute removal, actual version change and new-page display/auto eligibility. **Not run**; merge hunk must be applied. |
| AI-07, 86–94 | `ExteralessAIMessageDisplay` is shared by text/rich/poll/transcript rendering and actions. Manual and automatic language/origin choose one state. A stored summary is translated into `SummarizationMessageAttribute` in the same atomic write as the full translation; an open summary never falls through to full translated text. Both action orders finish without a summary spinner. Rich summary rendering uses native TextFormat conversion and a bounded stable-page cache. | Native `testManualSummaryBothOrdersRemainSummaryAndPreserveUTF16Entities` covers both orders and modes 0/1/2; **not run**. |
| AI-08, 96–102 | Quiz title/options and explanation callback consume the same display resolver. Solution text/entities come from `pollSolution`; its original media payload is retained. | Native `testQuizExplanationUsesEffectiveLanguageAndPreservesSolutionMedia`; **not run**. |
| AI-09, 104–110 | Bubble's per-message registry owns the disposable and generation. Off disposes A. Success/error retire only the matching generation; a stale A error cannot remove B's summarized ID. Binding after synchronous completion is handled. | Native Postbox `testSummaryOffOnOrdersCancelAWithoutRetiringB` plus pure generation/disposal fixture cover both A/B orders. **Not run**; actual bubble event/animation execution remains pending. |
| AI-10, 112–120 | Context permission uses the **effective override** provider. Automatic acquisition follows only the reply chain and ignores caller-supplied surrounding IDs. Manual-only history is local, bounded, thread-scoped and excluded for broadcast channels. Every visited reply ID counts, including empty/media/missing parents. | Effective override/scope-policy fixture and real Postbox empty-chain/foreign/thread/secret fixtures. **Not run**. |
| AI-14, 148–154 | Custom/Apple/provider transcription uses `storeExteralessAITranscription`, with account, source/context permissions, cancellation lease, actual expected version and resource ID checked inside the real transaction. The native Telegram fallback carries the lease into its real response/trial-state transaction via an optional narrow stock helper hook. Experimental inline-local partial/final updates also await guarded commits. Cancel revokes synchronously before async disposal. Message transcription progress UI retains no second copy of the transcript. | Native queue-barrier fixture disposes/cancels before executing the real closure and checks zero mutations; separate old-version, wrong-resource and late-A/new-B assertions; native fallback commit-body/error fixture. **Not run**. |
| AI-15, 156–164 | Inline availability, Premium/trial gate and execution use the selected-provider policy, with provider changes refreshing the chat. Auto/Premium uses real Telegram, Auto/non-Premium chooses Gemini → configured compatible audio → Workers; missing configuration fails instead of inventing an Apple/default success. Explicit routes do not silently change provider. Actual native `.error` becomes an error. Inline disposal and stale-generation callbacks are retained. | Pure Premium × provider/configuration matrix; native Speech injected decoder/recognizer, Workers response/error and native commit-body fixtures. **Not run**. Full inline UI/native-Telegram callback matrix requires native harness execution. |
| AI-16, 166–172 | Actual Mapper counts page/media entries, blocks/text, captions/buttons, rows/cells, unknown items, articles and opaque text children. Collections are checked before output reservation; collect-only traversal retains no mapped output graph. Collection/string/aggregate-response budgets and cooperative cancellation bound both passes. Mapping and rich markdown preflight run off main; five-leaf concurrency remains bounded. | Native Mapper fixtures use shared 8,193 nil cells/unknown items (small bounded arrays), depth 48/49, opaque nesting; actual translator fixtures gate five requests and cancel before remaining leaves. **Not run**; no OOM experiment. |
| AI-18, 182–190 | Native Copy, translation/AI input and speech use the displayed manual/auto/summary/original text and UTF-16 shifted entities. Rich copy uses the same composed page. Hide is available only when removing the manual marker actually hides translation; active incoming auto never receives a false “hidden” confirmation. | Native plain/summary emoji-link entity fixtures and hide/auto policy assertions. **Not run**; no clipboard/UI/frame pass claimed. |

### Owned source and integration

- Six assigned TelegramUI AI files and both `Speech/*.swift` files are updated.
- TelegramCore AI adds `ExteralessAIScope.swift`, `ExteralessAIMessageDisplay.swift`,
  `ExteralessAITranscriptionError.swift` and extends `ExteralessAIMessageOperations.swift`.
- No raw Postbox access/import is introduced in owned UI. Existing engine equivalents
  were inspected: `Peer.CopyProtectionEnabled` is a view reader; stock translation,
  summary and audio entry points generate/store through different network paths.
  None supplies the source/context/resource/version lease needed for custom commits.
- Public helper payloads use Engine/native types. The internal transaction functions
  are shared by the facade and the real in-memory fixtures; tests do not simulate
  a second version of the commit algorithm.
- Coordinator applies the **whole incremental patch** against the already-applied
  35 native/render hunks. It also adjusts shared factory signatures/generated harness
  conformance and adds `//submodules/TelegramUI:ExteralessAINativeTests`.
  TelegramCore's existing test glob already includes its new fixture; its
  ExteralessCore test dependency was added by the build owner while this work ran.
- The additional stock `TelegramEngine/Messages/Transcription.swift` hunks are part
  of that same patch: native response/trial-state mutations acquire the operation
  lease, while source edits/resource changes/cancel refuse the queued body. Replacing
  a transcript also invalidates its old translation. Inline local partial/final
  commits wait for storage before completing their disposable.

## Verification status

Windows has Python, but no `swift`, `swiftc`, Xcode or simulator tools.

- **23 XCTest methods prepared**: `AINativePolicyTests.swift` (5),
  `TelegramCore/Tests/ExteralessAINativeTests.swift` (10),
  `TelegramUI/Tests/AI/ExteralessAINativeUITests.swift` (8). **Zero executed here.**
  Core author's 73 AI tests are separate. No old CI number is counted as native proof.
- Native database fixtures use real in-memory Postbox, synthetic peers/IDs, private
  temporary settings with an injected secret store and 3 s waits. They create no
  Account/Network, block MediaBox fetches and never construct a real secret account.
- Native component fixtures inject bounded PCM/recognition and captured HTTP streams.
  They call no vendor, Speech permission dialog, plugin or account service.
- Official `python build-system/Make/PostboxImportCheck.py .` was run from
  `telegram-ios`: **exit 0, no diagnostics**.
- Patch application is checked in memory by
  `python docs/wave-2/tests/check_ai_native_patch.py`; this is an applicability check,
  not a test of Swift behavior. Final check: **30 files / 89 uniquely applicable
  hunks, no failures**. No common source file was written by this owner.
- The existing local tree-sitter Swift parser was used without any download.
  **All 16 owned Swift files parse without errors.** Proposed shared files retain two
  baseline parser recoveries: `playOnce.invoke(())` in `TextProcessingScreen.swift`
  and `/* … */ do` in `StoryItemSetContainerViewSendMessage.swift`; the same recoveries
  were confirmed in the untouched source. They are not introduced compiler diagnoses.
  The final pass scanned **29 proposed Swift files** and found **zero new parser
  diagnostics** relative to those baselines; this is not Swift typechecking.
- Scoped `git diff --check` passed. Many assigned native files were already untracked
  at baseline, so that check alone is not proof about their full contents.

Native typecheck/link, XCTest execution, stock hook/inline callback matrices and
recorded visual frames are **not run**. No CI, commit/push, real account/provider
request, external plugin or OOM fixture was performed.

### Expected native frames (before recording)

1. Protected Speak immediately speaks locally; no result/copy screen or Latest entry.
   Protected Translate uses the permitted stock route and offers no Copy/Share.
2. Manual fr with auto off uses the same visible text for Copy/AI/Speak; emoji/link
   ranges remain aligned with original prefixes in modes 0/1/2. Auto-on exposes no
   false hide completion. Opening/translating a summary keeps summary content and
   ends shimmer. Quiz explanation matches title/options language.
3. Summary on/off/on cancels A; both completion orders leave B visible without flashes
   or an A error clearing it. Rich-only edits show the new page and allow retranslation.
4. Each inline speech route shows real progress, cancellation or a meaningful failure,
   not Premium upsell for an explicit provider, false completion or a stuck spinner.
   Account/source/resource changes cannot publish a late custom transcript/result.

Record these on a fresh loginless, network-blocked harness per `telegram-ios/AGENTS.md`,
then inspect timestamp-labelled frames. None is presented as visually verified here.
