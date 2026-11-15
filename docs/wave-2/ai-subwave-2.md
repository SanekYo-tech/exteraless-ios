# AI subwave 2 — lifecycle, native interception and remaining families

This is the current handoff. `ai.md` retains first-slice provenance and provider
schemas; the old pending/unsupported classifications there are superseded below.
No CI, commit, push, account request or live AI request was performed by this agent.

## Coordinator: apply these exact patches, in this order

**Coordinator applied both patches**, including AccountContext facade/root install,
stock compose/summary/auto/article routes and renderer updates. Native Postbox
boundary correction remains with the AI owner. Linux CI `43651602940` caught an
actor-initializer autoclosure in `AIPluginReviewTools`; it now captures the two
emptiness values before `||`. The retry will determine Core XCTest results.

1. `docs/wave-2/ai-native-hunks.patch`.
2. `docs/wave-2/ai-render-hunks.patch`.

These are patch-tool-format hunks, with real current source anchors. They were
dry-applied **in memory** to the current tree (after your first two chat insertions),
and the resulting Swift was parsed. No common source file was written by this
agent. Deduplicate imports while merging other domains' changes.

The new AccountContext facade is necessary because TextProcessingScreen,
ChatMessageBubbleItemNode, TranslateUI and BrowserUI cannot import TelegramUI back
through their dependency graph. `ExteralessAINativeAdapter` is fully implemented
in owned AI source; the coordinator adds the facade, conformance and root install.
It is not a placeholder protocol waiting for future callbacks.

### Exact native call graph

| Family | Shared callsite in patch | Owned implementation / actual effect |
|---|---|---|
| Stock composer | `TextProcessingTranslateContentComponent.View.beginTranslationIfNecessary`, replacing its `engine.messages.composeAIMessage` expression | `ExteralessAINativeAdapter.compose`: current account Premium state, real AI request, plain entity reconstruction or rich markdown parsing, diff range, native result callback |
| Stock summary | `ChatMessageBubbleItemNode.toggleSummarization`, replacing its summary signal | `ExteralessAINativeAdapter.summarize`: current account Premium state, real request, atomic Postbox message update with `SummarizationMessageAttribute`, stale-version guard |
| Automatic/poll/audio/rich translation | `TranslateUI.translateMessageIds`, at the existing filtered batch's native request | `translateMessages`: real provider callbacks, all poll options/solution, audio transcript, rich page text leaves, native `TranslationMessageAttribute` writes |
| Article selection | `BrowserInstantPageContent.updateTextSelectionRects`, immediately before its existing TextProcessingScreen construction | `articleController` → `translationController(purpose: .article)`, separate/default provider policy and bulk DeepL fallback |
| Auto UI/non-Premium availability | `canTranslateChats`, `ChatHistoryListNode` premium gate, TranslateHeaderPanelComponent availability and controls | `AITranslationPolicy.canAutomaticallyTranslate`; stock Telegram provider still requires Premium, external providers do not |
| Mode and manual translation | Text bubble, rich bubble, poll bubble and transcript renderer | persisted per-account manual origin/visibility; keep-original prefix with corrected UTF-16 entity offsets; rich page graph is composed without flattening |
| Selected-text visibility | `TextSelectionNode` action construction | `AITranslationPolicy.showTextTranslate` determines whether the action exists |
| Message visibility | `ChatInterfaceStateContextMenus` stock entry plus already-applied `exteralessAIContextItems` | `showTranslate` and separate `showTranslateMessageLLM` rows have actual requests; stock visibility is mirrored bidirectionally |
| Plugin manager review | `PluginManagerController.renderPlugin` | `ExteralessAIEntry.reviewPlugin` → real host snapshot/provider/tools/result flow |
| Live policy changes | `ChatController.viewDidAppear`, TranslateUI policy signal | owned observer requests visible-message refresh; auto state is resubscribed on provider/availability changes |

The first two chat hunks are already present and are **not** included again. Owned
chat adapters extend them with translation/poll/draft behavior. They continue to
preserve the original selection, immutable input snapshot and reply state; no send
API is called by result insertion.

## 1. Lifecycle and restore

- `AISettings.inputLanguage(chatId:)` registers the exact dynamic key before its
  first read, including a fresh process. Empty override inherits the *current*
  global language; reset does not freeze an old default.
- `AISettingsRecovery.prepare` re-reads service records after configure/reload,
  registers all their secret definitions, then account history/manual state and
  requested chat keys. It is called before each operation and on every context
  update, even when AccountContext identity is unchanged.
- A Keychain/read failure is stored only as a recoverable diagnostic. Successful
  preparation clears it; the next action retries rather than remaining blocked by
  the first failure. Request configuration is captured after successful recovery.
- `AILifecycleTests`: fresh store/per-chat first read, reset/global fallback,
  recreation and app-group reconfiguration, secure-store failure/retry, explicit
  Android service import and legacy selection migration. Fixtures use temporary
  files and injected secret stores.
- Explicit **Import Android AI services** is now in the provider screen. It accepts
  a service array or Android-style services envelope/string. It validates all
  records, resolves `selectedServiceId`, then the original signed Java UTF-16 hash,
  then first service; absent IDs become stable UUIDs. Credentials go to Keychain.
  The old hash is not persisted as a native setting. This is service import, not
  an implicit import of arbitrary Android preferences/history.

## 2. Editor and summary replacements

Keys `ai.replaceTelegramEditor` / `ai.replaceTelegramSummaries` are tri-state:
null means the original `!isPremium` default, true/false are explicit overrides.
Premium is read from the request's actual AccountContext through EngineData.
Configured URL/model/key are required to select the replacement. Otherwise the
real stock engine request is used; native failure enums, including Premium flood,
are forwarded rather than converted to successful empty results.

Composer handles proofread, translation, every original default tone, actual
custom tone prompts/titles from the stock style list, emojify and the iOS stock
generate mode. Text remains a transformation task, not a conversation response.
The plain path preserves original entity payloads with updated ranges. The rich
path uses the existing Telegram markdown/InstantPage parser. Summary writes only
the requested message and only if its stable version is unchanged.

`AIComposeTask` / `AITextDifference` and Premium-default decisions have offline
fixtures. Actual stock interception is **pending the patch**, not counted from an
independent button. The facade serializes admission on main, rejects stale account
leases, propagates disposal and never recursively calls its own hook.

## 3. Translation policies and rendering

All formerly pending fields have definitions plus implementations:

| Original fields | Defaults and consumption |
|---|---|
| `NekoConfig.showTranslate` | false; bidirectional native TranslationSettings mirror, message actions |
| `NaConfig.showTextTranslate` | true; actual selection-menu construction hunk |
| `showTranslateMessageLLM` | false; separate owned LLM action → real translation client |
| `translatorMode` | 0 never, 1 manual, 2 manual + auto; this controls keeping the original, not whether translation runs |
| `translatorModeWithOriginalMigrated` | false before initialization; original migration 0→1, 1/other→0 only for legacy stored values; fresh default stays 0 |
| `preferredTranslateTargetLang` | empty; canonicalized/deduplicated comma list used by the actual language picker after default language |
| `keepTranslatorPreferences` | false; app-language changes update real ignored languages, retaining unrelated exclusions; true keeps the set unchanged |
| `telegramUIAutoTranslate` | true; feature/header/history gating, auto-request cancellation and native provider routing |
| `llmUseContextInAutoTranslate` | false; requires `llmUseContext` as well; only then reads bounded local reply/preceding context for LLM auto requests |
| `enableSeparateArticleTranslator` / `articleTranslationProvider` | false / Google 1; article requests pick separate provider when enabled; original bulk DeepL→Google policy |

Migration has a write-ahead target journal so an interrupted mode/flag write cannot
flip 0/1 again. The two known Android storage names are migrated explicitly before
installing the strict native enum. Invalid legacy enum values are clamped as in
`NaConfig.fixConfig`. Native metadata/cache rows use section `AI state`; the root
settings hunk hides these internal records rather than exposing migration/cache
state as user switches. They still participate in persistence/export as appropriate.

`AIManualTranslations` stores only origin/visibility/language metadata in an
account-scoped secret value (up to 2048 entries). Raw translated content is in
Telegram's native message attributes. Setting a mode changes rendering, not the
stored translation. Plain-text and translated-summary ranges are shifted by the
original prefix length. Poll answers/options are translated independently without
changing option IDs. Audio uses the original transcript's selected translation.

`ExteralessAIRichTextTranslator.Mapper` walks actual InstantPage/RichText types:
headings, paragraphs, nested quotes/lists, captions, tables/cells, details, covers,
embedded posts, galleries and button labels; media IDs, actions, links, formulas,
code and mention/entity payloads are retained. Requests are limited to five at a
time, 512 unique leaves / 256000 UTF-16 input, graph depth 48 / 8192 nodes. Rich chat
translation forces Google, matching `RichMessageTransHelper`. No half-translated
page is committed. Original-plus-translated rich rendering uses a 32-entry identity
cache that retains its source pages, preventing identity reuse or per-frame churn.

Auto context uses local Postbox-backed history with `trackHoles:false`, follows
the reply chain, excludes broadcast-channel surrounding history, deduplicates IDs
and checks the source's copy/secret restrictions. Model tool calls cannot expand
that scope. Disabling auto or switching providers cancels admitted auto operations.

## 4. Images

AI Text Editor → **Attach an image** opens PHPicker. The selected representation is
read during its valid callback lifetime, downsampled by ImageIO to ≤2048 px, oriented
correctly, encoded as JPEG ≤4 MiB and passed to `AIMessage.image`/`imageMIMEType`.
No EXIF/location data is carried through the newly encoded JPEG. Image-only requests
omit an empty text part. Source input ≤32 MiB, generation supports the original data
URL schema, image bytes never enter conversation history. Stale text/image snapshots
cannot replace a newly edited draft. The chosen provider/model needs image support.

Image request shape and invalid MIME rejection have an offline fixture; Photos UI
and final rendered frames remain device verification.

## 5. Bing session state

`AIBingSessionCache` implements host/IG/IID/key/token/timestamp/expiry as one atomic
secret `ai.bingSession` value. It reads the actual AbusePreventionHelper timestamp
and TTL, validates expiry, reuses a valid persisted session after recreation, and
renews expired sessions. SFX increases within the active session; auth rejection
invalidates and retries session acquisition once. The cache never stores message
text and never logs its credentials.

Acquisition is coalesced. One cancelled waiter does not cancel another; cancelling
the last waiter cancels the actual transport. Tokens and TTL are no longer marked
unsupported. Regional cached hosts are limited to the known Bing hosts; the general
transport still refuses automatic redirects. Fixtures pin reuse, recreation,
expiry, secret exclusion and waiter cancellation with a two-second fake transport
ceiling. All external requests remain mocked.

## 6. Real plugin-review tools

Original inspected: `PluginAiReview.java` and `PluginReviewTools.java`. Tool names
are exactly `read_source`, `list_blobs`, `decode_base64`.

- Default `ExteralessInstalledPluginReviewSource` reads the real PluginHost snapshot
  and configured plugin root, resolves the selected installed plugin, verifies
  canonical root containment, and takes a bounded immutable snapshot. It calls no
  Python metadata loader and does not enable/execute the plugin.
- The settings review screen already offers installed plugins and a document picker.
  The additional plugin-manager hunk adds the convenient per-plugin entry.
- `AIPluginReviewSource` is injectable with `descriptors()` and
  `snapshot(pluginId:)`; `installReviewSource(_:)` is the exact optional coordinator
  seam. Snapshot carries descriptor/revision and bounded named file bytes, never
  account/secret access or a generic path resolver.
- Tools read only those snapshot names, paginate up to 400 lines / 30000 UTF-16
  result, identify embedded base64/binary blobs, and decode gzip/zlib/ZIP/readable
  binary strings. `AIReviewArchive` is a bounded portable Swift decoder: stored,
  fixed and dynamic DEFLATE, checksums, ZIP central directory, no filesystem writes.
  Limits follow the source: 16 MiB plugin, 8 MiB ZIP entry, 32 MiB inflated,
  500 entries/blobs, three nested compression layers. Encrypted/unsupported ZIP
  methods fail; they do not return fabricated contents.
- `disableTools` now has a real default consumer. Disabled review sends a bounded
  source excerpt; enabled review supplies these allowlisted callbacks. Binary-only
  files cannot pretend to have a plain source excerpt. Model-selected file names,
  accounts, shell commands and settings have no corresponding capability.
- Review cache uses content SHA-256/revision, locale, service/model and tools mode,
  with five-minute TTL and 32 results. It is memory-only and cleared on context exit.
- Source/XML for the original localized role/prompt strings is absent from this
  snapshot; the native review wording is an explicit iOS adaptation, not a claimed
  verbatim resource port.

## Build and checks

No new vendor/package dependency. Native additions use existing PluginHost,
TelegramCore/Postbox/BrowserUI/TextFormat/TranslateUI plus system PhotosUI, ImageIO
and CryptoKit. Build-agent must add ExteralessCore dependencies to AccountContext,
TranslateUI, TextSelectionNode, TranslateHeaderPanelComponent and affected renderer
targets that now import it. TelegramUI source glob already includes owned files.

Local checks: **34 owned Swift files, 40 prepared offline XCTest methods, zero
syntax errors**; 35 new hunks applicable in memory to 18 proposed common files;
proposed Swift syntax; fixture gzip/zlib/ZIP bytes independently checked by Python
standard libraries. Parity merge and 193 source references validated: 80 original
feature IDs, 55 implemented / 25 partial, zero pending/unsupported/verified in this
fragment. **These are not Swift typechecking or XCTest passes.**
Run the Core suite on Swift 6 after compilation, bounding fixture execution at 30 s:

`timeout 30s swift test --package-path swift/ExteralessCore --skip-build --filter AI`

No device/XcodeBuildMCP is available here, and no visual or verified parity claim is
made. Remaining source ambiguity: Android dependency translator 1.6.1 has no source
in the snapshot/source JAR, so RealMicrosoft transport remains visibly adapted to
Bing and anonymous DeepL is replaced by its real key-based API. Provider keys,
available models and installed/authorized Apple speech services are prerequisites.

### Expected frames for this subwave

Record stock composer proofread/style/translate/generate and stock summary with
automatic/explicit on/off, Premium/non-Premium, missing credentials, cancel, failure
and account switch. They must use the original stock result/bubble callbacks, not
open an unrelated editor. Changing styles during a request must cancel stale output.

Record manual mode 0/1/2 and auto mode 0/1/2 on text with emoji, URLs, nested quotes,
polls and rich tables/media. Original and translation must share the native bubble
layout without clipped labels or stale ranges; mode changes/hide/show must repaint
the visible message. Favorites must retain their order. Changing app language must
update or preserve ignored languages exactly according to the toggle.

Record Photos picker cancel/select/replace, a large oriented photo and a failed
image-capability request. The editor must retain its selection/text and the image
must only leave the device after the selected AI action. Review frames: choosing
an installed plugin/file, tools on/off, paged read/decode, cancel/retry, cached result;
no key, private log body or arbitrary path should appear in status/error chrome.

## Postbox boundary correction

Read `telegram-ios/CLAUDE.md:1384–1488` before this correction. Discovery in
`TelegramCore/Sources/TelegramEngine` found no facade for committing an already
generated summary/translation with the expected-version check. `summarizeMessage`
and `translateMessages` perform network requests; `storeLocallyTranscribedAudio`
and `storeLocallyDerivedData` write different attributes. The nearby feed-history
facade is channel-only, fills holes and filters/reorders results, so it cannot
replace the AI context window without changing behavior.

Added only `TelegramCore/Sources/ExteralessAI/ExteralessAIMessageOperations.swift`:

- `TelegramEngine.Messages.storeExteralessAISummary` accepts `EngineMessage.Id`,
  expected `UInt32` stable version, the existing native `Summary`, target language
  and a thread-safe cancellation predicate; emits the actual commit `Bool`.
- `storeExteralessAITranslation` accepts the existing `TranslationMessageAttribute`
  (including poll additions/solution and rich page) with the same version/predicate
  contract. It makes no new provider or Telegram request.
- `localExteralessAIContextMessages` uses `EnginePeer.Id`, `EngineMessage.Index`
  and `[EngineMessage]`. It preserves the original one-shot view, thread, anchor,
  count, order and `trackHoles: false`.

The native adapter no longer imports Postbox, obtains a transaction, constructs
StoreMessage or exposes raw MessageAttribute types. The two write bodies now run
inside the engine's bound account. Attribute replacement, existing summary-language
variants and all other message fields preserve their former values. The version
checks remain inside the transaction. Request cancellation/account teardown sets
the existing thread-safe token; its predicate is also tested inside the transaction,
alongside the automatic-translation flag. Main-actor account/generation checks and
post-await cancellation checks remain in the caller. No new umbrella aliases,
wrapper structs, allowlist exceptions, TL-owner code or build declarations were added.

The existing TelegramCore recursive source glob includes the helper. Public adapter
signatures used by the coordinator's 18 common-file hunks are unchanged; those
common files and the patch documents were not edited in this correction.

Validation: ran **once**, from `C:\exteraless-ios\telegram-ios`:

`python build-system/Make/PostboxImportCheck.py .`

Actual result: **exit code 0, no diagnostics**. The two changed native Swift files
also parsed without syntax errors. All **21 frozen SPM AI source/test files** kept
their aggregate SHA-256 `32aa72d16a9ffbc28b000458c2728ac68ff47ffdaf420d879a8e8872de817d90`.
This is official boundary/source validation only; Swift compilation, runtime and
visual claims still wait for coordinator CI/device evidence.
