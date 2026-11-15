# Независимый финальный follow-up AI — 2026-11-15

## Вердикт

**AICF-01/02 закрыты по исходникам и содержанию новых regression tests. В native call graph остаются 1 P1 и 5 P2**, описанные ниже. Native acceptance не пройдена: UIKit/TelegramCore tests, full iOS typecheck/link, реальные Speech/Keychain/vendor requests и recorded frames в этой сессии не запускались.

Проверен текущий рабочий tree, включая применённые shared hunks, фактические нижние pipelines и новые native fixtures. Сведения автора о числе применённых hunks не использованы как доказательство корректности поведения. Старые `reviews/ai.md` и `reviews/ai-core-followup.md` сохранены.

`Closed/source` в таблице относится к исходному сценарию finding. Это не execution pass всего feature family.

| ID | Статус | Основание |
|---|---|---|
| AICF-01 | **Closed/source** | Эффективный HTML intent передаётся до Google Cloud fallback; protected-span validation остаётся. |
| AICF-02 | **Closed/source** | Nil/null/empty import keys используют reset; rollback сохраняет value и override presence. |
| AI-01 | **Closed/source** | Speak вызывает прямой AVSpeech; copyable result/Latest entry больше не создаётся. Общий поздний privacy gap — AF-01. |
| AI-02 | **Closed/source** | `canCopy=false` capability проходит через stock screen; compose hook не выбирает external adapter. |
| AI-03 | **Open — AF-01** | Source/reply/thread/account checks появились, но effective private-chat protection проверена не полностью. |
| AI-06 | **Open — AF-02/03** | Обычный rich-only edit инвалидирует перевод; повреждается новая summary eligibility, full-content path остаётся несогласованным. |
| AI-07 | **Closed/source, исходный сценарий** | Открытая summary не подменяется полным translation; effective manual language участвует в summary request и atomic translated-summary write. |
| AI-08 | **Closed/source** | Quiz solution callback использует тот же language resolver и сохраняет original solution media. |
| AI-09 | **Closed/source, исходный A/off/B сценарий** | Bubble хранит disposable/generation; A не может завершить generation B. |
| AI-10 | **Closed/source** | Effective provider override управляет context; auto не добавляет preceding history; empty reply IDs расходуют visit budget. |
| AI-14 | **Partial/open — AF-04** | Voice/custom/native-fallback commit получил lease/version/resource checks; round-video inline path их обходит. |
| AI-15 | **Partial/open — AF-04** | Voice button использует selected provider; отдельная round-video button осталась stock-only. |
| AI-16 | **Closed/source, исходный allocation defect** | Nil cells/unknown items/opaque children считаются; collection admission предшествует reserve; mapping вынесен с main. |
| AI-18 | **Open — AF-03/05**, дополнительный lifecycle **AF-06** | Manual plain display/actions согласованы, но expanded rich и default auto target расходятся; Retry теряет собственное обновление version. |

## Подтверждённые остаточные findings

### AF-01 — P1: `.myCopyProtectionEnabled` не отзывает native AI scope

**Место:** `telegram-ios/submodules/TelegramCore/Sources/ExteralessAI/ExteralessAIScope.swift:116–130,149–152,188–198`.

**Доказанный source-сценарий:** разрешённый private-chat message без `.CopyProtected` flag участвует в AI result/scope. Затем пользователь включает защиту чата. Native toggle устанавливает `CachedUserData.flags.myCopyProtectionEnabled` (`TelegramEngine/Peers/CopyProtection.swift:35–46`). Реальный UI считает effective protection как **copyProtectionEnabled OR myCopyProtectionEnabled** (`TelegramUI/Sources/ChatControllerContentData.swift:983–987`, `ChatHistoryListNode.swift:2324–2327`). Это не предположение о назначении флага: именно этот OR передаётся в `presentationInterfaceState.copyProtectionEnabled` через `Chat/ChatControllerLoadDisplayNode.swift:423–424`.

AI helper проверяет только `.copyProtectionEnabled` (`ExteralessAIScope.swift:119`). Изменение cached peer data не меняет message stableVersion. Поэтому `validateExteralessAIScope` продолжает возвращать true; validity observer не отзывает lease, и существующий result сохраняет Copy/Insert. Новый automatic translation/selected-provider transcription, где caller передаёт `canCopy:true`, также может получить разрешённый external scope и отправить content при активной native защите.

**Impact:** обход effective private-chat copy/export restriction при включении защиты самим пользователем, включая поздний Copy после смены protection. Wrong-account запись этим сценарием не утверждается.

**Исправление / regression:** использовать тот же effective protection predicate, что настоящий Chat UI, при acquisition и revalidation. Добавить к `ExteralessAINativeTests.swift:105–130` отдельный `.myCopyProtectionEnabled` case: stableVersion прежний, старый scope invalid, новые external/copy capabilities false, queued write не происходит. В UI/scoped-transport fixture проверить отзыв Copy и ноль новых body-bearing requests. Существующий тест проверяет только первый из двух флагов.

### AF-02 — P2: source edit удаляет новую серверную summary eligibility

**Место:** `telegram-ios/submodules/TelegramCore/Sources/State/ServerMessageMerge.swift:22–34`.

**Сценарий:** сервер присылает edit длинного summarizable message с изменённым text/rich page и новым `summaryFromLanguage`. `StoreMessage_Telegram.swift:1378–1379` создаёт из него `SummarizationMessageAttribute(fromLang: ...)` без cached summary. Новая else-ветка merge удаляет **все** incoming Summarization attributes, а не только старые derived results. Seed merge не восстанавливает этот attribute (`SyncCore_StandaloneAccountTransaction.swift:122–190`).

**Impact:** у всё ещё summarizable отредактированного сообщения исчезает штатная summary button: её eligibility проверяется по наличию attribute (`ChatMessageBubbleItemNode.swift:1932–1934`). Это происходит и для plain edits. Очистить старый результат необходимо, удалять свежую server capability — нет.

**Исправление / regression:** сохранять свежий incoming `fromLang`/eligibility, сбрасывая устаревшие summary/translated payloads. Real Postbox fixture: previous cached summary → actual merge с новым source и новым fromLang → старого текста нет, новый eligibility attribute есть. Существующий rich-edit fixture (`ExteralessAINativeTests.swift:215–233`) не передаёт новую summary metadata и этот эффект не замечает.

### AF-03 — P2: AI и Copy используют rich preview вместо доступного full content

**Места:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAINativeAdapter.swift:99–103,170–173,233–237`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessAI/ExteralessAIMessageDisplay.swift:85–89`; `telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageRichDataBubbleContentNode/Sources/ChatMessageRichDataBubbleContentNode.swift:360–386,1121–1140`.

**Сценарий:** сообщение содержит partial `instantPage` и уже загруженную complete `fullInstantPage`; пользователь нажал Show more. Renderer original ветки использует full page (`:386`). Общий display/actions resolver и AI summary/translation берут только `instantPage`. Следовательно, Copy/AI input получают сокращённый preview, а перевод или summary создаётся только для части сообщения. После применения partial translation renderer ставит `isTranslated=true`; Show more скрывается условием `:1129–1132`, даже если translated page incomplete.

Фактический full-content request тоже не проходит новый merge helper: `TelegramEngineMessages.swift:1966–2032` получает `messages.getRichMessage`, в `:2021–2028` заменяет `fullInstantPage` и оставляет существующие translation/summary attributes. Поэтому показанный в отчёте rich-aware `ServerMessageMerge` не доказывает invalidation этого пути.

**Impact:** потеря доступной части content при Copy/AI actions, неполный результат с состоянием готового перевода, отсутствие возможности раскрыть его. Сценарий требует обычного partial rich message, а не oversized simulation.

**Исправление / regression:** whole-message AI должен выбирать доступный full source; Copy должен получать реально отображаемую страницу. При необходимости загрузки full content — повторный scope/version check после native request; completion этого request должен инвалидировать результаты предыдущего source. Fixture из двух маленьких pages: preview `A`, full `A + SENTINEL_B`, `isComplete=false/true`; после Show more Copy и provider input содержат B, translation сохраняет complete content, смена full page инвалидирует старый cache. Во всех текущих native rich fixtures `fullInstantPage=nil` и страницы complete.

### AF-04 — P2: round-video inline transcription обходит selected provider и lease

**Место:** `telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageInteractiveInstantVideoNode/Sources/ChatMessageInteractiveInstantVideoNode.swift:829–867,1812–1898`.

**Сценарий:** выбрать explicit Apple/Gemini/Workers/compatible provider и нажать transcription button на круглом видео в `.free` layout. Этот отдельный node всё ещё проверяет старые Premium/trial условия (`:832,1817,1825–1833`) и вызывает `engine.messages.transcribeAudio` напрямую (`:1885`). Исправленный `ChatMessageInteractiveFileNode` здесь не является исполнителем: button closure вызывает собственный `transcribe()` (`:867`).

**Impact:** non-Premium получает stock gate/upsell вместо выбранного provider, Premium использует Telegram независимо от explicit selection. Этот вызов также передаёт `commitScope=nil` по умолчанию в `_internal_transcribeAudio` (`TelegramCore/.../Transcription.swift:18,100–103`), поэтому queued response/trial-state transaction выполняется без нового lease/version/resource guard. Generation/cancel semantics исправленной voice button к нему не применяются.

**Исправление / regression:** провести round-video availability, execution и cancellation через тот же typed hook/policy, сохранив его UI callback contracts. Native fixture должен нажимать именно round-video button для Premium/non-Premium × explicit/auto, а не вызывать `AINativeSpeechPolicy` отдельно. Queue barrier case проверяет cancel и поздний response этого route. В текущих 8 UIKit tests round-video node не создаётся.

### AF-05 — P2: default auto target отсутствует в Copy/AI/Speak resolver

**Места:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIChatActions.swift:181–194`; `telegram-ios/submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift:1321,1385,1463,1472`.

**Сценарий:** включить auto translation без ручного выбора языка (`translationState.isEnabled=true`, `toLang=nil`), app language `en`. Это реальное начальное состояние: toggle меняет только `isEnabled` (`Chat/ChatControllerLoadDisplayNode.swift:4285–4291`). History renderer вычисляет target как `toLang ?? appLanguage`, нормализует его и передаёт в item (`ChatHistoryListNode.swift:2337–2344`). Новые action callsites вместо этого передают голое optional `toLang`, т.е. nil.

**Impact:** bubble показывает English translation, а Copy/AI/Speak получают original. Если есть manual override, тот же nil ошибочно разрешает Hide; action сообщает «Translation hidden», хотя actual renderer продолжает показывать incoming auto translation. Таким образом, исходный false-hide эффект AI-18 остаётся для стандартного target.

**Исправление / regression:** общий effective-target resolver для history и actions с одинаковыми enabled/availability/default-language/normalization rules. Fixture: auto enabled, nil target, app `en`, incoming message с `toLang=en` attribute; renderer и Copy/AI/Speak совпадают, Hide manual не заявляет скрытие auto translation. Новые tests используют только явно заданные `"fr"`/`"de"` (`AINativePolicyTests.swift:84–101`, `ExteralessAINativeTests.swift:83–102`).

### AF-06 — P2: Retry после собственного translation commit использует устаревшую capability version

**Места:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIIntegration.swift:399–414,599–612`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIResultController.swift:195–198,273–274,307`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessAI/ExteralessAIScope.swift:144–146`.

**Сценарий:** первый Translate in chat успешно пишет attribute. Access создан с `.message(message)` и expected version V. Commit правильно обновляет `scope.expectedVersions` до фактического V′ (`ExteralessAIMessageOperations.swift:136`), однако `ExteralessAIResultAccess.capability` остаётся V. Нажатие видимой кнопки Retry вызывает `begin()`: updated scope удаляется, затем `resolve()` повторяет исходную capability V. Реальный Postbox уже V′, поэтому acquisition возвращает nil и Retry завершается Cancelled, хотя пользователь source не редактировал.

**Impact:** повторное действие после успешного собственного commit ломается из-за derived-attribute version bump. Проверка V′ действительно сделана в commit tests, но её сохранение через result-screen restart не проверяется.

**Исправление / regression:** переносить подтверждённое own-commit advancement в новый operation scope при Retry, одновременно отклоняя настоящие source edits. Fixture через `ExteralessAIResultAccess`/result lifecycle: success commit → Retry без edit допускается; external edit между этими действиями — отказ; repeated completion не обходит lease.

## AICF-01/02: проверка закрытия

### AICF-01

`AITranslation.swift:131–143,180,217` передаёт `html: !original.spans.isEmpty` после применения `preserveFormatting`, не выводит его из исходных spans до policy. Fallback создаёт fresh Google request, а затем проходит прежний decoder (`:153–162`).

`AIRetryTests.testAICF01CloudFallbackKeepsHTMLIntentSpansAndSeparateCredentials` (`:37–91`) проверяет четыре cases: HTML, plain, formatting disabled и изменённый protected emoji. Это реальные вызовы клиента с injected transport: три 502, четвёртый Cloud request, exact q/format/key, отсутствие LLM Authorization/keys, изменённые UTF-16 ranges и `.formattingLost`. Scope исходного finding закрыт. Vendor acceptance не проверялась.

### AICF-02

`AISettings.swift:208–227` хранит prior presence отдельно от value; nil/empty import key делает `reset`. Public rollback восстанавливается update/reset batch; secret rollback различает absent и explicit-empty. SC-05 не изменён ради этого исправления.

`AILifecycleTests.testAICF02AndroidImportRemovalAndRollbackKeepOverridePresence` (`:23–104`) включает 3 key forms × 3 prior states, subsequent add-only Cloud insertion и 4 second-write failures. Проверяет backend bytes/key set, storedKeys, public effective values и файл. Fixture storage действительно считает empty item существующим (`:173–202`); ложный pass из-за специальной трактовки empty backend исключён. Scope исходного finding закрыт; новый CI здесь не запрашивался.

Изменение canonical `showTextTranslate` reader/definition и выполняемая App-owner root migration — отдельная координационная задача; она не использована ни для закрытия, ни для повторного открытия AICF-01/02.

## Что прослежено в native call graph

- **Speak:** `ChatController.swift:4464–4470` → `ExteralessAIChatActions.swift:119–127` → `ExteralessAIIntegration.swift:524–531` → AVSpeech. Нет создания result/cache; ordinary result text view перенаправляет system Copy в validator (`ExteralessAIResultController.swift:312–343,380–392`).
- **Protected stock translate:** `ChatController.swift:4574–4588` передаёт capability в async screen; root/sheet/content/text area её сохраняют. `ExteralessAIHooks.swift:65–69` не выбирает external adapter при запрете; `withCopyCapability(:79–90)` проверяет engine scope и active adapter до и после await. `copyResult=nil` не превращён в разрешение.
- **Account/protection/reply scope:** source/resolved context читаются реальными transactions; peer/thread/namespace и visited-ID ограничения находятся в `ExteralessAIScope.swift:133–185`. Scope хранит actual accountId и participating versions. `ExteralessAIScopedTransport` проверяет scope перед каждым base transport admission (`ExteralessAIIntegration.swift:537–558`), включая retry/fallback/tool rounds. AF-01 остаётся в самом predicate.
- **Context override:** `ExteralessAIIntegration.swift:453–456` использует effective provider; `resolveScope(:245–269)` исключает supplied preceding IDs для auto, manual history local и повторно разрешается после await. Пустые reply parents учитываются в limit, а не только успешные text leaves.
- **Summary/poll/display:** `ExteralessAIMessageDisplay.swift` действительно употреблён text/rich/poll/transcript renderers, Copy и AI input. Summary language участвует в stock toggle (`ChatMessageBubbleItemNode.swift:7828–7843`); translated summary пишется в той же transaction с translation (`ExteralessAIMessageOperations.swift:109–120`). Quiz explanation callback (`ChatMessagePollBubbleContentNode.swift:2348–2354`) выбирает resolved solution; media payload сохраняется (`ExteralessAIMessageDisplay.swift:72–74`). AF-02/03/05 ограничивают полную согласованность.
- **Summary lifecycle:** `ChatMessageBubbleItemNode.swift:7812–7862` владеет MetaDisposable/generation; Off отменяет A, callbacks проверяют generation через registry. Это actual callsite, не только unused helper.
- **Transcription storage:** voice hook идёт через `ExteralessAINativeAdapter.transcribe`. Custom commit проверяет account/scope, resource ID и version под `lease.withActive`; native Telegram response/trial body также обёрнут (`ExteralessAIMessageOperations.swift:123–172`, `Transcription.swift:49–103`). Experimental-local partial/final commits ожидают guarded storage. Отдельный round-video route — AF-04.
- **Rich budgets:** actual Mapper проверяет collections перед reserve, считает rows/cells/unknown items/opaque children, ограничивает text/output и обходит граф off-main. Collect mode не удерживает полный новый mapped graph; five-leaf task group сохраняет предел concurrent requests. Full-content selection — отдельный AF-03, не исправляется structural budget.
- **SDK/root:** текущий `Telegram/BUILD:169` задаёт iOS **15.0**, а Speech punctuation API отдельно guarded `#available(iOS 16.0, *)`. Shared factory требует capability (`AccountContext.swift:1704–1712`) и forwarding передаёт её до async `TextProcessingScreen` init (`SharedAccountContext.swift:4863–4880`). Root публикует AI adapter только после `isPrepared/rootPath/clientAPIConfiguration` gate (`ExteralessClientRuntime.swift:251–289`), teardown снимает hook и отменяет домен (`:354–369`). Проверены также gallery/OCR/gift capability callers. Это source tracing pre-await publication, а не полный UI navigation/account-switch execution pass.

### Семантика существующих tests

- AICF-owner набор теперь **75** методов; новые два прочитаны целиком, прежний набор рассмотрен в предыдущем follow-up.
- Actual native-remediator files содержат **25**, а не прежние 23, declared methods: 6 `AINativePolicyTests`, 11 `TelegramCore/Tests/ExteralessAINativeTests`, 8 `TelegramUI/Tests/AI/ExteralessAINativeUITests`. Два добавленных метода относятся к visibility.
- Postbox fixtures используют настоящие production commit/merge functions и queue barrier, не вторую реализацию mutation algorithm. Они содержательно покрывают `.copyProtectionEnabled`, foreign/thread/secret IDs, empty chain, resource/version/cancel, basic rich edit, summary/quiz data. Это **не** вызовы настоящей inline button, Root lifecycle или full-rich request.
- Summary «оба порядка» fixture вручную подготавливает нужные summary attributes (`ExteralessAINativeTests.swift:245–253`). Он проверяет storage/resolver и UTF-16, но сам по себе не доказывает фактическую последовательность UI/provider callbacks.
- UIKit fixture protected-copy создаёт один `ExteralessAIResultTextView` и проверяет Copy callback; это не полный Speak → protect/account switch → Latest flow. Scope transport fixture использует injected cancellation predicate, а не оба настоящих private-chat flags.
- Native target уже существует в текущем `TelegramUI/BUILD:672–691`; прежняя handoff-фраза о deferred BUILD не актуальна для просмотренного tree. Наличие target не означает, что его компилировали/запускали здесь.

## Source fingerprints и выполненные проверки

Во время чтения HEAD изменился с `ddc25d69` на **`f99909b58968b69dfb57132db9dd84d2e28889cc`**. Выводы относятся к рабочим source bytes, включая untracked native additions, а не только commit contents.

Manifest algorithm: SHA-256 от UTF-8 concatenation `relative POSIX path + NUL + SHA256(raw file bytes) + LF` в sorted unique path order. Группы могут пересекаться.

| Группа | Файлов | Manifest SHA-256 |
|---|---:|---|
| AICF: `AISettings.swift`, `AITranslation.swift`, `AILifecycleTests.swift`, `AIRetryTests.swift` | 4 | `38b943fb548e3f3c83d89d1b1988ae1fd5201353d99581ad5a8b1d4feb7796dc` |
| Native owned: Core `AINativePolicy*.swift` + test; TelegramCore `Sources/ExteralessAI/*.swift` + native test; 6 AI integration/adapter/result/chat-actions/chat-observer/rich-mapper files; оба Speech files + native UI test | 18 | `1c725e4af45683c03efb9d44767d07eec74ca7362fe43ef7704734d33c47f9f9` |
| Swift paths из headers `docs/wave-2/ai-native-remediation.patch` (BUILD исключён) | 29 | `a49e522b9f162cf875ec0da2da65ba6a08aafdf0ec3d8c6396c2b789a6273525` |
| Supporting: `ChatControllerContentData`, `ChatHistoryListNode`, `ExteralessClientRuntime`, `ChatMessageInteractiveInstantVideoNode`, `SyncCore_RichTextMessageAttribute`, `SyncCore_StandaloneAccountTransaction`, `TelegramEngineMessages`, `StoreMessage_Telegram` | 8 | `36dd4c38732fb5245384b5f7b4de2b6e8478b123693d30e8d2daf42e956045b7` |

Key pins:

- `ExteralessAIScope.swift`: `3730b09db57042a46600fb94ba8be37865d90c92a679270b72b734b53f41a44d`.
- `ServerMessageMerge.swift`: `403781e761f5e5e041ecd0e66791e1bdec37529560073072269456ae89bfa00c`.
- `ChatMessageInteractiveInstantVideoNode.swift`: `e62cc8bec071fe498b202a69ba823f3b354cbc89470674f7b2cbb7463e589b1e`.
- Старый `reviews/ai.md`: `fb5eec0b918538065937e753811613a244e05e3bdfa6d32e9263c6d5f0b12b84`.
- Старый `reviews/ai-core-followup.md`: `e34fec7d3b64ccf766756fda74c0c489f9ceb9362bc36135609508ebe071ebbe`.

После записи отчёта повторно проверены AICF/native-owned/shared manifests: все три остались неизменными; SHA-256 обоих старых отчётов также совпали.

Выполнялись только source reads/grep, локальный Git inspection и Python stdlib hashing с `-B`, timeout ≤20 s. Ни source fixes, ни commit/CI/live HTTP, ни реальные plugin/vendor calls, ни memory-heavy simulations не выполнялись. Единственная запись reviewer — этот новый отчёт.

Visibility gates `hideAiEditor/hideIvSummary/hideMessageSummary` прочитаны как текущая дополнительная wiring работа; они не заменяют acceptance перечисленных native findings. Visual/layout/animation conclusions требуют будущих записанных кадров по `telegram-ios/AGENTS.md`. В этой сессии execution/visual pass отсутствует.
