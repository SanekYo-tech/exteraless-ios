# AI / speech / translation — implementation and handoff

**Current subwave:** [ai-subwave-2.md](ai-subwave-2.md), with exact
`ai-native-hunks.patch` and `ai-render-hunks.patch`. The first two chat hunks below
have now been applied by the coordinator. Lifecycle, replacement adapters, mode/
visibility/article/auto policies, images, Bing TTL and plugin-review tools are
implemented in the second slice. Its status/gates supersede first-slice pending
and unsupported notes retained below as provenance.

Base: `68bb1adf`, wave-2 contract. Source-only patch, no commits/push/CI dispatch,
no calls to Telegram accounts or AI/translation endpoints during implementation.
All generation/transcription fixtures use local data or URLProtocol/custom transport.

## Integration status

Implemented domain code:

- `swift/ExteralessCore/Sources/ExteralessCore/AI*.swift`: definitions, configuration,
  native HTTP transport, request builders, SSE/JSON/reasoning parsers, model catalog,
  bounded tools, formatting, translation and speech HTTP clients.
- `swift/ExteralessCore/Tests/ExteralessCoreTests/AIClientTests.swift`,
  `AITranslationTests.swift`: bounded offline fixtures; URLSession is exercised via
  URLProtocol which intercepts **every** request, including unregistered fixture URLs.
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/**`: integration,
  providers/models/roles/prompt editors, text actions, result screen, chat adapters.
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Speech/**`: file/voice
  transcription, installed voice selection, synthesis/pause/resume/stop.

`ExteralessAIIntegration` has the contracted `init()`, `update(context:)`,
`clearContext()` on main. `ExteralessClientRuntime` is the coordinator's composition
root. Its existing update/clear calls are the required lifecycle owner. Settings
actions registered by this domain: `ai.services`, `ai.roles`, `ai.editor`,
`ai.result`, `ai.translationModels`, `ai.speech`. Result screens are constructed by
those editor/actions and by the chat adapters; they are not standalone unused types.

**Pending coordinator application:** the two exact shared-file hunks below. Until
they are applied, settings → editor/speech → result works through composition, but
message-menu and stock selection entry points must not be counted as connected.

### Hunk 1: actual message menu (AI, current draft, downloaded voice/video)

File: `telegram-ios/submodules/TelegramUI/Sources/Chat/ChatControllerOpenMessageContextMenu.swift`.
Inside the main-queue `combineLatest(...).startStandalone(next:)`, immediately after
`var actions = actions` and before its existing `switch actions.content`:

```diff
                 var actions = actions
+                if case let .list(items) = actions.content {
+                    let aiItems = MainActor.assumeIsolated {
+                        self.exteralessAIContextItems(message: message)
+                    }
+                    if !aiItems.isEmpty {
+                        let separator: [ContextMenuItem] = items.isEmpty ? [] : [.separator]
+                        actions.content = .list(items + separator + aiItems)
+                    }
+                }
                 switch actions.content {
```

No new import in that common file. `ExteralessAIChatActions.swift` supplies the
implementation. It obtains the actual displayed text (translation/summary/rich
markdown/transcription/restriction text), honors copy/secret/expired/ad restrictions,
and offers **AI Draft Actions** when there is a draft. It routes voice and round-video
files to real resource data and `storeLocallyTranscribedAudio` after success.

### Hunk 2: selected text translate / speak

File: `telegram-ios/submodules/TelegramUI/Sources/ChatController.swift`.
Inside `performTextSelectionAction: { [weak self] message, canCopy, text, entities, action in`,
after the existing `self.performTextSelectionAction` override/return, before
`switch action` (baseline near line 4450):

```diff
             if let performTextSelectionAction = self.performTextSelectionAction {
                 performTextSelectionAction(message, canCopy, text, entities, action)
                 return
             }
+            let handledByExteraless = MainActor.assumeIsolated {
+                switch action {
+                case .translate:
+                    return self.exteralessAITranslateSelection(
+                        message: message, canCopy: canCopy, text: text, entities: entities)
+                case .speak:
+                    return self.exteralessAISpeakSelection(text.string)
+                default:
+                    return false
+                }
+            }
+            if handledByExteraless {
+                return
+            }
             switch action {
```

No new common import. All source selection/draft access is in the owned adapter.
Selection input uses the stock callback's already-relative text/entities. The
result insertion checks the complete captured `ChatTextInputState` against the
current one, then uses `replacingFlatRange(_:with:)` on **the current structural
state**, inside `withUpdatedEffectiveInputState`. It does not reconstruct the draft
from `inputText`, change reply subjects, or invoke any send API. A changed draft
leaves Insert unapplied with a visible explanation; Copy remains available.

Presentation API was checked in-repo: `ContextController.dismiss(completion:)`
is used before pushing from menus. `Display.ViewController.dismiss(animated:
completion:)` drops its completion on Telegram navigation, so it is **not** used
to sequence these actions. Screen closing uses `dismiss(animated:)` without a
dependent completion. UI document-picker presentation is the existing UIViewController
presentation path, with its delegate followed by a main-queue push.

### Public closure API for other coordinator-owned surfaces

All are main-actor, installed only for the active composition context:

```swift
ExteralessAIEntry.textActions: ((AccountContext, ViewController, ExteralessAITextInput) -> Void)?
ExteralessAIEntry.translate: ((AccountContext, ViewController, ExteralessAITextInput) -> Void)?
ExteralessAIEntry.transcribe: ((AccountContext, ViewController, EngineMessage.Id, TelegramMediaFile) -> Void)?
ExteralessAIEntry.speak: ((AccountContext, ViewController, String) -> Void)?

ExteralessAITextInput(
    text: String, entities: [MessageTextEntity] = [], selectedRange: NSRange? = nil,
    messageId: EngineMessage.Id? = nil, chatId: EnginePeer.Id? = nil,
    contextMessageIds: [EngineMessage.Id] = [],
    applyResult: ((ExteralessAIInsertion) -> Bool)? = nil)
// insertion: text, entities, asQuote, attributedText()
```

`contextMessageIds` is explicit and fetched through
`engine.data.get(TelegramEngine.EngineData.Item.Messages.Messages(ids:))` (local
Postbox-backed EngineData). Current chat adapters supply reply IDs. Native Telegram
translation calls `context.engine.messages.translate(text:toLang:entities:)`;
transcription reads `context.engine.resources.data(resource:incremental:)` and
writes `context.engine.messages.storeLocallyTranscribedAudio(...)`. Every native
signal uses a disposable, one-shot continuation and 60 s timeout, including empty
completion and cancel-before-start. No account singleton is synthesized.

## Original symbols, defaults, native mapping

Source root: `third_party/exteraless-android/TMessagesProj/src/main/`.
Both `java` and `kotlin` were examined. Relevant Kotlin lives in **both** roots.

| Original | Default / wire behavior | Native implementation / disposition |
|---|---|---|
| `app/exteraless/ai/AiConfig.DEFAULT_SERVICE`, `Provider.PRESETS` | Gemini first, `gemini-3.5-flash`, empty key | `AIService.default`, exact four preset URLs/models below |
| `AiConfig.KEY_SERVICES`, `Service.id/name/url/model/key` | services `[]`, stable UUID, selected fallback first/default | `AISettings.services/save/remove`; JSON service contains **no key**; dynamic `ai.serviceKey.<id>` is secret |
| `selectedServiceId`, legacy `selectedService` hash | unset → default/first; hash formerly includes key | `ai.selectedServiceId = "default"`; no key-derived hash retained; Android-storage migration hash is not used on iOS |
| `KEY_ROLES`, `KEY_SELECTED_ROLE`, `Suggestions` | custom `[]`, selected `Assistant` | exact Assistant/Summarizer/Proofreader prompts; custom name/prompt editor, select/delete, clone suggested role; `ai.roles` is private JSON **inside a secret string** |
| `KEY_HISTORY`, save/remove/clear/trim history | empty; max 32 messages / 24000 Java chars; discard leading assistant | `AISettings` account-scoped secret `ai.history.<accountId>`; strips images; strict UTF-16 cap; append only on complete success, Clear action |
| `saveHistory` | true | `ai.saveHistory`; Ask AI only; disabling clears current account history; independent text/translation requests never upload it |
| `responseStreaming` | true | `ai.responseStreaming`; real incremental URLSession SSE and ordinary JSON path |
| `temperature` | integer 10, divided by 10 | `ai.temperature`; sent as 1.0 by default |
| `showResponseOnly` | false | `ai.showResponseOnly`; selected-text preview in result header |
| `insertAsQuote` | true | `ai.insertAsQuote`; assistant result inserts a real Telegram quote attribute |
| `disableTools` | false | `AIFeatures.toolDefinitions` only registered by `installTools(_:)`; genuine callback/allowlist/24-round protocol. No inert default UI toggle |
| `replaceTelegramEditor`, `replaceTelegramSummaries` | `!UserConfig.isPremium()` | **pending stock-AI replacement policy**; separate native text actions work for all accounts. These two toggles are deliberately not registered without the stock compose/summary interception |
| `AiController.canUseAI/getSelected/saveService/removeService` | URL/model/key required | real builder validation and service editor, missing-key error screen |
| `AiController` roles and selected role | three suggestions + custom | `AISettings.roles/selectedRole/save/remove`, role UI |
| `Service.REASONING_OFF/LOW/MEDIUM/HIGH` | 0/1/2/3; legacy enabled → medium | four effort choices; `reasoning_effort` off omitted unless metadata says reasoning-capable |
| `Client.getResponse/generate/cancel/stopRequest/cancelAll` | OpenAI compatible; default separate request; optional history/image | `AIClient.generate`; native Tasks cancel actual sessions; image data URL encoder ≤4 MiB. UI image attachment picker is **not wired**; text/voice scope is wired as above |
| `Client.listModels`, `ModelsCatalog` | GET `/models`; `https://models.dev/api.json` | user-triggered model list/catalog; no network on construction; metadata drives reasoning-off behavior |
| `ReasoningFilter`, `GenerationCallback` | `<think>` and reasoning fields | incremental tag filter, text/reasoning/thinking/tool events, single final return; handles content + reasoning in one chunk |
| `ToolHandler` | definitions/call/describe/fallback; 24 rounds | `AIToolHandler` supplied allowlist + async callback; rejects missing/unknown/invalid tools; non-streaming rounds; genuine tool messages; fallback on supported rejection class |
| `AiResponseSheet` | partial output, reasoning, copy/insert/cancel, cached response | native result controller, selectable text, explicit formatted/source view, retry/cancel/insert/copy/read; Latest Result is account-lifetime memory cache |
| `TelegramAiReplacement` | proofread, summarize <3 sentences/<60 words, translate, emojify, default/custom tones | exact original task/tone language; editor wrapper preserves markdown and owned HTML attributes; no answer to quoted input instructions |
| `NekoConfig.translationProvider` | 1 (Google), 2 deprecated | `ai.translationProvider`; 1,3,4,5,6,7,8,9,10; coverage below |
| `NekoConfig.translateToLang` / storage `TransToLang` | empty → current app language | `ai.translateToLang` with PresentationStrings base language fallback |
| `translateInputLang` / `TransInputToLang` | `en` | `ai.translateInputLang`, draft-target editor, per-chat `ai.translateInputLang_<peerId>` |
| `googleCloudTranslateKey` | empty | `ai.googleCloudTranslateKey`, secret, real v2 form request |
| `NaConfig.translatorKeepMarkdown` | true | `ai.translatorKeepMarkdown`, owned HTML span IDs + original Telegram payload kept out-of-band; changed protected links/code fail instead of using stale offsets |
| `NaConfig.googleTranslateExp` | true | `ai.googleTranslateExp`; user experimental key replaces embedded Android credential. Without it, use configured Cloud key or original Google app endpoint; never copy repository tokens |
| `NaConfig.deepLTranslateKey`, `deepLFormality` | empty, 0; informal 1/formal 2 | secret `ai.deepLTranslateKey`; `prefer_less`/`prefer_more`; free/pro endpoint selection by `:fx` |
| `LlmConfig`, `NaConfig.llmProviderPreset` | custom = 0 | `AILLMPreset` exact integer mapping / endpoints |
| `llmApiUrl`, `llmApiKey`, `llmModelName` | empty persisted; Android resource fallbacks | `ai.<field>`; custom URL/model must be entered or model discovered; resources are absent from source snapshot, so fallback values are not guessed |
| `llmProvider{OpenAI,Gemini,Groq,DeepSeek,XAI,Cerebras,OllamaCloud,OpenRouter,VercelAIGateway,Vertex}{Key,Model}` | empty persisted | all 20 exact `ai.<field>` definitions; every Key secret; per-provider model/key selection; Vertex built-in list from source |
| `llmSystemPrompt`, `llmUserPrompt` | empty → embedded instructions; @text/@toLang | exact original default prompt, private custom prompts, template substitution |
| `llmTemperature`, `llmUseContext`, `llmContextSize` | 0.7, false, index 2 → 5; choices 1/3/5/7/10 | matching defaults; only explicitly supplied context IDs, latest N; never assistant history |
| `LLMTranslator` key rotation/retry/fallback | comma-separated unique keys, 3 attempts, backoff, Google on exhausted I/O/429 | implemented rotation, 1/2 s bounded waits, no auth-error fallback; UI identifies a Google fallback |
| `ModelUtil` | provider/model-specific temperature, reasoning, Gemini thinking, router/providerOptions | exact source rule port; metadata/list normalization and non-text filtering; optional params retried once after HTTP 400 |
| `Translator.translateWithContext/translatePoll/translateArticle` | explicit context; bulk DeepL → Google | context + ordered bounded `translateBatch` core API. **Poll/article/automatic chat UI callsites pending**; not registered as pretend UI options |
| `showTranslate`, `showTextTranslate`, `showTranslateMessageLLM`, `translatorMode`, `telegramUIAutoTranslate`, `enableSeparateArticleTranslator`, `articleTranslationProvider`, `preferredTranslateTargetLang`, `llmUseContextInAutoTranslate` | Android entry/display/auto-translation policies | **stock-equivalent or pending integration**, not re-registered as disconnected settings; manual selection and draft routes above are implemented |
| `TranscribeHelper` providers 0,2,3,4,5 | Auto/Gemini/OpenAI/Workers AI/Vosk | exact IDs, cloud wire clients, Apple on-device replacement for 5; iOS Auto adds Apple when no cloud credentials configured |
| `transcribeProviderCfAccountID/ApiToken`, `GeminiApiKey/Prompt`, `OpenAiApiBase/Model/ApiKey/Prompt` | all empty | matching `ai.<field>`; tokens secret; prompts private; actual callbacks and strict response parsing |
| `TranscribeHelper.GEMINI_API_ENDPOINT` | model from missing `LlmModelNameDefault` resource | iOS explicit `ai.transcribeProviderGeminiModel`, default `gemini-3.5-flash` from checked-in AI preset; documented adaptation |
| `VoskManager.KEY_LANGUAGE` (`OEVoskLanguage`) | locale guess, fallback en-us | `ai.OEVoskLanguage`; empty → device locale, interpreted as Apple Speech locale |
| `VoskManager` install/delete/download/listeners, `VoskModels` | external Android model packages | **platform adaptation**: OS-managed Speech languages; no fabricated Vosk download/install success. UI shows support and prerequisites |
| `VoskTranscriber.transcribe/releaseModel` | MediaCodec/Recognizer PCM16 mono | Telegram native SoftwareAudioSource → real WAV → SFSpeechURLRecognitionRequest; cancellation/partial/final/error, no microphone requirement |
| Android speech synthesis | no TextToSpeech implementation found in checked-in AI/speech trees | iOS AVSpeechSynthesizer adaptation; actual installed voices/rate/pause/resume/stop/final callbacks |

## Provider endpoints and schemas

### Assistant (`app/exteraless/ai/data/Provider.java`)

All POST `base + /chat/completions`, `Authorization: Bearer <user key>`, JSON
`model/messages/stream/temperature` and optional `reasoning_effort`; GET `/models`.
Responses are `choices[0].message.content` or SSE `choices[0].delta.content` plus
reasoning fields, with finish reason / `[DONE]`. Four exact presets:

| Provider | Base URL | Model |
|---|---|---|
| Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | `gemini-3.5-flash` |
| OpenAI | `https://api.openai.com/v1` | `gpt-5-mini` |
| OpenRouter | `https://openrouter.ai/api/v1` | `openai/gpt-5-mini` |
| DeepSeek | `https://api.deepseek.com/v1` | `deepseek-chat` |

Custom providers use that same actual schema. No Anthropic-native endpoint or
invented model names are introduced.

### LLM translation (`nekogram/llm/preset/PresetRegistry.kt`)

| ID | Provider | Base | Protocol |
|---|---|---|---|
| 0 | Custom | entered by user | OpenAI compatible |
| 1 | OpenAI | `https://api.openai.com/v1` | OpenAI compatible |
| 2 | Google AI Studio | `https://generativelanguage.googleapis.com/v1beta/openai` | OpenAI compatible |
| 3 | Groq | `https://api.groq.com/openai/v1` | OpenAI compatible |
| 4 | DeepSeek | `https://api.deepseek.com/v1` | OpenAI compatible |
| 5 | xAI | `https://api.x.ai/v1` | OpenAI compatible |
| 6 | Cerebras | `https://api.cerebras.ai/v1` | OpenAI compatible |
| 7 | Ollama Cloud | `https://ollama.com/v1` | OpenAI compatible |
| 8 | OpenRouter | `https://openrouter.ai/api/v1` | OpenAI compatible |
| 9 | Vercel AI Gateway | `https://ai-gateway.vercel.sh/v1` | OpenAI compatible |
| 10 | Google Agent Platform | `https://aiplatform.googleapis.com/v1` | Vertex generateContent |

Vertex POST `/publishers/google/models/<model>:generateContent`, `x-goog-api-key`,
`contents[{role,parts[{text}]}]`, `systemInstruction.parts`,
`generationConfig.thinkingConfig`; consecutive user turns merged; parse
`candidates[0].content.parts` and exclude `thought:true` from visible response.
Original Vertex is non-streaming, and the port does not fabricate a streaming
endpoint. Its seven model IDs are exactly `VertexGeminiClient.MODELS`.

### Classical translation (`nekogram/translate/source/**`)

| ID | Request | Parsed result / status |
|---|---|---|
| 1 Google app | GET `https://translate.google.com/translate_a/single`, dj/q/sl/tl/ie/oe/client=at/dt=t/otf=2, original app UA | `sentences[].trans`, joined |
| 1 Google experimental | GET `https://translate-pa.googleapis.com/v1/translate`, params.client/query.source_language/query.target_language/query.display_language/data_types/query.text + **user** key | `translation`; Chinese newline repair |
| 1 Google Cloud | POST form `https://translation.googleapis.com/language/translate/v2`, q/target/source?/format/key | `data.translations[0].translatedText`; html mode for formatted input |
| 3 Yandex | POST form `https://translate.yandex.net/api/v1/tr.json/translate?srv=android&uuid=…&id=…-9-0`, text/lang | `code == 200`, `text[0]` |
| 4 Lingo | POST `https://api.interpreter.caiyunai.com/v1/translator`, X-Authorization token; source lines/trans_type/request_id/detect | `target[]`, newline-joined; requires user token |
| 5 Microsoft | GET `https://www.bing.com/translator` extracts IG/IID/AbusePreventionHelper; POST `/ttranslatev3`, fromLang/to/text/token/key/gender fields | `translations[0].text`, gender-debiased second request when signaled |
| 6 Real Microsoft | same working Bing iOS adapter, visibly named | **adapted**, not a claim to have ported hidden Android dependency transport |
| 7 DeepL | POST form `https://api[-free].deepl.com/v2/translate`, DeepL-Auth-Key, text/target_lang/source_lang?/tag_handling?/formality? | `translations[0].text`; key required; anonymous path pending |
| 8 Telegram | real TelegramEngine translation signal | returned text **and full new entity payloads** retained |
| 9 TranSmart | POST `https://transmart.qq.com/api/imt`, header/source/target/model_category/text_domain/type | `auto_translation[]`; exact source target-language set |
| 10 LLM | above provider/prompt/parameter clients | complete non-streaming text; context and retry rules above |

The snapshot references `app.nekogram.translator:translator:1.6.1` but does not
vendor its implementations. Public Maven POM and source JAR were inspected only
as reference, not executed; the source JAR contains only META-INF (SHA-256
`c6deada2fac53b8ea6523dbda77597b128006674616f140f04df23264c6d1aa3`).
The linked GitHub source returned 404. Therefore neither its RealMicrosoft
transport nor anonymous DeepL is falsely labeled exact/native parity. Lingo and
experimental Google embedded Android credentials were not copied or exercised.

### Speech (`nekogram/helpers/TranscribeHelper.java`)

- Workers AI: POST `https://api.cloudflare.com/client/v4/accounts/<account>/ai/run/@cf/openai/whisper-large-v3-turbo`,
  Bearer token, `{audio: base64}`, require `success:true` + `result.text`.
- Gemini: POST `https://generativelanguage.googleapis.com/v1beta/models/<configured-model>:generateContent`,
  `contents.parts` text + `inlineData{mimeType,data}`; parse all visible candidate
  text parts. Key is moved from Android's query parameter to `x-goog-api-key`.
- OpenAI-compatible audio: POST normalized base `/chat/completions`, Bearer,
  text + `input_audio{data,format}`, `modalities:["text"]` for gpt models;
  `choices[0].message.content`. It is **not** a fabricated `/audio/transcriptions`
  call; source uses chat/audio-understanding. Actual WAV/MP3 format is validated.
- Apple: `SFSpeechRecognizer.requestAuthorization`, check `isAvailable` and
  `supportsOnDeviceRecognition` (never write that capability),
  `SFSpeechURLRecognitionRequest.requiresOnDeviceRecognition = true`, partial/final
  callbacks, addsPunctuation on iOS 16+, cleanup/cancel/timeout.
- Synthesis: `AVSpeechSynthesisVoice.speechVoices`, `AVSpeechUtterance`,
  `AVSpeechSynthesizer.speak/pauseSpeaking/continueSpeaking/stopSpeaking`; delegate
  checks utterance identity for late callbacks. `usesApplicationAudioSession=false`;
  no audio-session category mutations under Telegram calls.

## Bounds, privacy and lifecycle

- Foundation-only Core, conditional FoundationNetworking. URLSession delegate
  streaming works without Apple-only `URLSession.bytes` APIs.
- 30 s idle request timeout, 300 s per HTTP operation, real cancellation and total
  operation timer. Fixtures lower this to 2 s. Native engine/Speech waits: 60 s.
- 16384 UTF-16 AI visible/reasoning output, 64000 input/classical translation output,
  32/24000 history, 256 KiB SSE
  event, 4 MiB response (catalog 16 MiB), 24 tool rounds / 32 calls per round.
  Truncation and incomplete SSE are errors, never completed partial successes.
- PCM/WAV 20 MiB, native audio ≤60 s, cloud ≤180 s, input file ≤50 MiB. Decode uses
  `SoftwareAudioSource` (existing Telegram FFmpeg path) so OGG/Opus actually works;
  cooperative 30 s decode budget checked between frames, cancellation per frame.
- No cookies/cache/credential storage in provider sessions. Redirects are rejected
  rather than forwarding private POSTs or keys. HTTP errors contain status only;
  no server body, URLSession localized error, Authorization or prompt is logged.
- ClientSettings owns all storage. API keys are `isSecret=true`; service records
  omit credentials entirely; history and custom prompts are private secret strings.
  JSON/export fixtures verify secret exclusion. There is no pretend persistent
  memory secret backend in production; only injected test storage.
- Account clear invalidates screens, cancels tasks/speech/engine operations, clears
  Latest Result and installed tool handlers. Callback generations reject late work.
- External prerequisites are in provider/speech/error UI: own key/service access,
  selected model, supported/installed Speech language/voice, existing Speech usage
  description and device permission, downloaded voice file. No paid request is
  automatically used as a settings validation probe.

## Build/dependency handoff (build-agent owns edits)

- Core: Foundation and conditional FoundationNetworking only; Package already
  globs source/tests. No new package dependency.
- TelegramUI: AVFoundation, Speech, CoreMedia, UniformTypeIdentifiers system
  frameworks; existing `UniversalMediaPlayer`, BrowserUI, TextFormat, Pasteboard,
  ContextUI, AccountContext, Display, AsyncDisplayKit, TelegramCore, SwiftSignalKit,
  TelegramPresentationData plus ExteralessCore. `UniversalMediaPlayer` is already
  present at `TelegramUI/BUILD:90`; ensure Speech framework linkage/autolinking.
- `Telegram/BUILD` already has `NSSpeechRecognitionUsageDescription` (baseline
  around line 1782). Audio-file recognition adds no microphone permission request.
- No SDK, C, PluginHost, BUILD/MODULE or common settings implementation was edited
  by this domain.

## Verification and pending review

- Swift XCTest fixtures added: preset/auth/endpoint schemas; Vertex merging and
  thoughts; SSE UTF-8 byte splits/CRLF/multiline/BOM; split reasoning tags and
  mixed deltas; malformed/incomplete/length failures; URLProtocol real-delegate
  streaming/cancellation/timeout; bounded optional-parameter retry; allowlisted
  tool callback/result messages; secret/history isolation; crossing/selected UTF-16
  spans and protected links; language mappings; all classical provider payloads;
  Bing's two-step callback; LLM context/rotation; native translation injection;
  PCM WAV header and all three cloud audio schemas.
- **Not run here:** no `swift`/`swiftc`, WSL distribution, Xcode or device available.
  Coordinator: `swift test --package-path swift/ExteralessCore --filter 'AI'` on
  Swift 6 host, with a 30 s fixture execution bound after compilation. Typechecking,
  iOS linking and runtime checks remain mandatory; syntax checks are not a build.
- Local syntax check uses pinned temporary tree-sitter 0.26.1 + Swift grammar 0.7.4,
  downloaded with SHA-256 verification, outside the repository: **19 Swift files,
  0 syntax errors, 24 offline XCTest methods prepared**. Separate source checks for
  the Foundation boundary, absence of domain logging and exclusion of original
  embedded Android keys passed. Domain-scoped `git diff --check` passed.
- No XcodeBuildMCP is exposed in this session. **No visual pass claimed.**

### Expected frames before recording

Record the real two chat entry points and settings → editor/provider/voice routes
on light/dark, narrow phone + iPad/Duo safe insets, large Dynamic Type, keyboard open
and closed, long markdown + emoji selection. Expect normal navigation push/pop
timing (~0.3 s, driven by Telegram), header/content/buttons moving together with no
white flash or clipped controls. Source header ≤3 lines, scrollable result between
header and two ≥44 pt control rows. Content must not go under navigation/safe areas.

During streaming, chunks extend text without moving a user's active selection or
scrolling someone reading earlier text. Cancel immediately stops updates and leaves
explicitly partial text; Insert stays disabled. Completion enables Insert/Read;
formatted/source switching is user-initiated (no surprise selection remap at EOF).
Reasoning toggles between separately selectable answer/reasoning. Rotation keeps
the controls and selected text visible. A failed key/rate/format request shows an
error + Retry, never a success state or raw response body. Changing draft/reply
while a request runs must preserve them; a changed draft rejects insertion.

Voice tests: installed/missing voice; read → pause → resume → stop; old utterance
finish arriving after a new one; Speech denied/unsupported/offline; downloaded OGG
voice and round video; 60/180 s bounds; cancel during decode/recognition/HTTP; account
switch during partial recognition. Confirm real final transcript updates the chat
bubble only after successful completion. Record via simctl and inspect timestamped
frames as required by AGENTS.md before claiming visual completion.

## Machine-readable parity fragment

`docs/wave-2/ai-parity.json` maps **80 original feature IDs** from the 567-entry
`docs/parity/client-features.json`, plus `module.ai` and `module.speech`. The
chat-owned `chats.translateInSheet` is excluded to avoid an independent ownership
override. Actual keys replace proposed `chats.*` keys where this implementation
uses `ai.*`; computed history/per-peer keys are marked as templates. Null keys
mean no registered ClientSettings field, including request-local Bing state.

Feature statuses: **64 partial, 13 pending, 3 unsupported, zero verified**. Both
module statuses are partial. No entry claims `ported=true`. Shared chat hunks
remain unapplied; source references to XCTest methods are explicitly unexecuted
fixtures. A UI row, definition, setter or stock capability alone is not verification.

Bounded read-only validation passed against the real `merge_parity` implementation:
IDs/scope, all **258** evidence/callsite paths and nonblank 1-based lines, fixture
classification, no verified promotion, and an unchanged main inventory. Core
settings' native `value`/`string` versus redacted snapshot/export contract was
checked against `docs/wave-2/core-settings.md`.

The fragment also retains lifecycle gaps for review: per-chat dynamic keys are
currently registered by their setter, so persisted keys need registration before
the first read after restart; service-key registration needs a recreation/app-group
reconfiguration fixture. These are not presented as verified persistence effects.
