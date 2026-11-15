# Независимое ревью AI subwave 2 — 2026-11-15

## Вердикт и границы доказательств

**Есть дефекты P1; полную функциональную и privacy-паритетность принимать нельзя. P0 не обнаружен.** Ниже 5 findings P1 и 13 findings P2. Это независимое source/call-graph review, не отчёт автора реализации и не visual pass.

- Проверен рабочий tree при HEAD `4b3f706423c9879bb6e0cf64a07eb104e407ec51`, включая применённые common-file hunks. Проверены `AGENTS.md` и `CLAUDE.md` в `telegram-ios`, в том числе правила Postbox/TelegramEngine.
- Прочитаны все 15 Core `AI*.swift`, все 6 соответствующих test files (40 методов), owned TelegramUI AI/Speech, AccountContext hooks, TelegramCore helper и фактические chat/compose/summary/translation/render callsites. Для выводов использован код, а не статус в `ai-parity.json`.
- Оригинал: `app/exteraless/ai`, speech/Vosk, `PluginAiReview`/`PluginReviewTools`, Kotlin translators/LLM transport/ModelUtil, `NaConfig`, `MessageTrans`, `TranslateController`, `MessageObject`, `ChatActivity`, `TranscribeButton`, `LanguageSelectActivity`.
- Сообщённый координатором зелёный CI `43653040458`: Core 122 (включая 40 AI), Host 89, Hooks 16. CI здесь не запрашивался и не запускался. Исправленные actor-init/redeclaration не выставляются повторно.
- Ни iOS typecheck/link/runtime, ни Photos/Speech/Keychain на устройстве, ни реальные vendor requests, ни записанные кадры здесь не проверялись. Самостоятельные тесты не запускались: найденные пути доступны для проверки по исходникам; отсутствующий native runtime не подменён regex-проверкой.
- Единственная запись этого reviewer — данный файл. Реализация, Host/C/package/build files не изменялись; commit, CI, сеть и исполнение плагинов не выполнялись.

В ссылках ниже пути относительны корню репозитория. Сценарии — конкретные воспроизводимые условия, выведенные из кода; они не обозначают состоявшийся запуск на устройстве.

## P1

### AI-01 — Read aloud превращает защищённый текст в копируемый результат

**Места:** `telegram-ios/submodules/TelegramUI/Sources/ChatController.swift:4440–4456`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIChatActions.swift:115–124`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIIntegration.swift:448–454`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIResultController.swift:85–86,261–262,296–300`.

**Сценарий / evidence:** открыть Speak для copy-protected сообщения. Stock menu передаёт `canCopy: false` (`ChatInterfaceStateContextMenus.swift:1484–1500`), но новый `.speak` перехват передаёт только строку. `exteralessAISpeakSelection` не проверяет capability. `presentSpeech` помещает исходный текст в обычный AI result; тот всегда включает selection и Copy при непустом тексте и пишет его в pasteboard. Последний результат также сохраняется через `trackResult` (`ExteralessAIIntegration.swift:276–284`). Credentials для этого обхода не нужны.

**Impact:** реальный обход запрета копирования через новую native UI-ветку. Старый путь в `ChatController.swift:4489–4496` только озвучивал текст.

**Исправление / тест:** переносить message/account/copy capability в speech result, учитывать её также в системном меню UITextView, Latest Result и при completion; либо использовать для защищённого текста прямую озвучку. Native fixture: `canCopy=false`, Speak завершён, explicit Copy и selection-copy недоступны; account/protection change не возвращает capability.

### AI-02 — Отказ protected translation повторно перехватывается штатным AI editor

**Места:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIChatActions.swift:98–100`; `telegram-ios/submodules/TelegramUI/Sources/ChatController.swift:4450–4461,4498–4572`; `telegram-ios/submodules/TelegramUI/Components/TextProcessingScreen/Sources/TextProcessingTranslateContentComponent.swift:237–242,280–289`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAINativeAdapter.swift:35–62`.

**Сценарий / evidence:** non-Premium account, configured assistant service, automatic/default replacement, `ai.showTranslate=true`, stock manual translation route не `.system`. У защищённого сообщения `canCopy=false`, поэтому owned selection adapter возвращает `false`. Stock fallback открывает `TextProcessingScreen` с `copyResult=nil`, но с полным текстом. Его новый compose hook заново выбирает external assistant. Ни `ComposedRichMessage`, ни hook signature не несут messageId/privacy capability; `compose` проверяет лишь context/Premium/configuration.

**Impact:** текст, который owned AI route намеренно отказался экспортировать, всё-таки отправляется стороннему провайдеру. Это повторный перехват fallback, а не бесконечная рекурсия.

**Исправление / тест:** передавать допустимость external processing и provenance через весь stock screen/hook, чтобы protected fallback оставался разрешённым native route. Fixture через реальный `performTextSelectionAction`: `canCopy=false`, default replacement, fake external transport получает **0** запросов; отдельно проверить explicit true/Premium и обычный разрешённый текст.

### AI-03 — Manual LLM context не проходит проверки защиты исходных сообщений

**Места:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIIntegration.swift:360–386`, особенно `374–380`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIChatActions.swift:34,63,102,168–170`.

**Сценарий / evidence:** доступное сообщение отвечает на защищённое сообщение; включены LLM и `llmUseContext`. Chat adapter передаёт reply IDs, а `translationController` делает EngineData lookup и без фильтра берёт `messages[id].text`. Здесь отсутствуют проверки secret namespace, `isCopyProtected`, secret media, допустимости peer scope и повторная проверка защиты source перед запросом. Проверка исходного message menu не является проверкой reply target. Native batch использует другой builder и другой guard (`ExteralessAINativeAdapter.swift:203–225`), поэтому наличие проверки там этот путь не закрывает.

У native guard есть дополнительная неполнота той же границы: `Message.isCopyProtected()` проверяет message/group/channel (`TelegramCore/Sources/Utils/MessageUtils.swift:538–547`), но не `CachedUserData.copyProtectionEnabled`. Реальная private-chat capability существует отдельно в `TelegramEngine/Data/PeersData.swift:2371–2403`. Внешняя auto/summary ветка её не читает. После await проверяется identity account, но не изменившиеся права source/reply.

**Impact:** защищённый контекст уходит внешнему LLM; запреты зависят от выбранной UI-ветки. Неправильный account не доказан: lookup действительно привязан к переданному engine.

**Исправление / тест:** общий engine-backed scope resolver для source и каждого context ID, с effective private-chat protection, разрешённым reply scope и проверкой lease/актуальных ограничений перед экспортом и публикацией. Fixtures: protected reply при разрешённом child, private-chat cached protection без message flag, secret/foreign-peer reply, изменение защиты во время pending operation; запрещённые строки отсутствуют в captured request и Copy/result.

### AI-04 — Public settings могут перенаправить Keychain credential на другой endpoint

**Места:** `swift/ExteralessCore/Sources/ExteralessCore/AIFeatures.swift:22–23,48,61`; `swift/ExteralessCore/Sources/ExteralessCore/AIModels.swift:122`; `swift/ExteralessCore/Sources/ExteralessCore/AISettings.swift:35–44`; `swift/ExteralessCore/Sources/ExteralessCore/AIRequest.swift:68–90`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ClientSettingsBridgeExtension.swift:30–45`.

**Сценарий / evidence:** plugin с `settings` permission читает public service metadata и меняет `ai.services` URL, сохраняя service ID. `setPublic` разрешает public array; key остаётся `ai.serviceKey.<same-id>`. Следующее обычное AI действие прочитает прежний secret из Keychain и отправит `Authorization: Bearer …` на новый HTTPS host. Аналогично public custom LLM/audio base URLs могут перенаправить отдельные secret keys. Запрет redirects этого не предотвращает: новый URL — первый адрес запроса.

Есть и schema-level snapshot проблема: `ai.services` — произвольный public array, а не закрытая service schema. Legacy/raw array с вложенным `key` проходит `ClientSettingDefinition.swift:49–59,139–142`; `ClientSettings.readSnapshot/exportJSON` редактируют лишь top-level secret keys (`ClientSettings.swift:73–82,273–289`). `AIService` Codable не содержит key, но `AISettings.services` лишь декодирует копию и не очищает сохранённый raw array. Нормальный `save/importAndroidServices` безопасен; generic/raw settings route — нет.

**Impact:** native-only credential boundary обходится через управление назначением запроса; raw legacy key может попасть в snapshot/export. Это не утверждение об исполнении плагина в этом review.

**Исправление / тест:** credential-bearing destinations должны изменяться только native credential operation либо иметь защищённую привязку key→origin с инвалидированием при смене origin; валидировать/санитизировать service records на границе public persistence. Offline test с fixture key: public смена URL не приводит к запросу с прежним Authorization на новый host; raw nested `key` отвергается/мигрируется и отсутствует в snapshots. Упомянутого в задании literal `_Settings` в текущем tree не найдено; проверен фактический `getClientSetting/setClientSetting` путь и его snapshot.

### AI-05 — Лимиты plugin review не ограничивают промежуточные allocations

**Места:** `swift/ExteralessCore/Sources/ExteralessCore/AIPluginReview.swift:47–64,77–84,178–208`; `swift/ExteralessCore/Sources/ExteralessCore/AIReviewArchive.swift:48–95`; native entry `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIPluginReviewController.swift:123–142`.

**Сценарий / evidence:** выбранный ZIP с четырьмя текстовыми entries по 8 MiB, состоящими преимущественно из `\n`, проходит 16 MiB compressed / 32 MiB inflated limits. `components(separatedBy: "\n")` создаёт около 33.5 млн String entries; `(lines + [""])` дополнительно копирует массив. Лимит 400 строк действует только при последующем ответе tool. Disabled-tools путь тоже создаёт весь tools snapshot, затем склеивает **весь** source перед `prefix(48 KiB)`.

Лимит 500 blobs также не является глобальным: `inline.matches` сначала материализует все matches одной строки, проверка `blobs.count >= 500` стоит после полного inner loop, а результаты разных файлов суммируются без общего cap. Для injected multi-file snapshot суммарные inflated entries проверяются лишь после `entries += unpackedArchive` для всех архивов.

**Impact:** локальный review небольшого сжатого файла может исчерпать память/занять worker до первого provider request, без исполнения исходника. Оценка allocations следует из кода; OOM здесь не запускался.

**Исправление / тест:** проверять remaining aggregate budget до inflation/append, индексировать строки лениво или ограниченным индексом, перечислять regex matches с остановкой, иметь общий blob count/bytes budget, собирать bounded excerpt без полного join. Adversarial pure fixtures с маленьким внедряемым budget: newline-dense ZIP, >500 blobs в одной строке/нескольких files, несколько ZIPs; проверять раннюю остановку и allocation bounds, а не только длину возвращённого текста.

## P2

### AI-06 — Уже сохранённый rich translation переживает изменение исходной страницы

**Места:** `telegram-ios/submodules/TelegramCore/Sources/State/ServerMessageMerge.swift:22–28`; `telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageRichDataBubbleContentNode/Sources/ChatMessageRichDataBubbleContentNode.swift:363–373`; `telegram-ios/submodules/TranslateUI/Sources/ChatTranslation.swift:161–163`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessAI/ExteralessAIMessageOperations.swift:51–57`.

**Сценарий / impact:** перевести rich message, затем получить его edit с другой `RichTextMessageAttribute`, но теми же пустыми plain text/entities. Merge сохраняет старую `TranslationMessageAttribute`. Renderer принимает её только по language, а auto фильтр считает сообщение уже переведённым. Пользователь продолжает видеть перевод предыдущей страницы. Transaction stableVersion guard защищает от edit **во время** generation, но не от edit **после** commit.

**Оригинал:** `MessageTrans.kt:78–114` проверяет cache для текущих text leaves/current rich message. Старый перевод изменённого leaf не считается full cache. Native merge defect существовал в stock интеграции; AI2 его наследует.

**Исправление / тест:** source fingerprint/version metadata или invalidation перевода при изменении rich content в merge. Real in-memory Postbox: commit translation → edit только rich page → старый перевод не отображается и новая страница допускается к переводу.

### AI-07 — Manual translation и открытая summary используют разные language states

**Места:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAINativeAdapter.swift:171–193`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIIntegration.swift:325–355`; `telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift:420–454`; `telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift:7820–7830`.

**Сценарий / impact:** auto выключено, original summary открыта, затем Translate in chat в `fr`. Adapter переводит полный original и записывает только Translation attribute/manual marker. Renderer ищет `summaryForLang("fr")`, не находит, показывает полный translation и оставляет `isTranslating=true`, поскольку `isSummarized=true`. Запроса недостающей translated summary нет. Обратный порядок тоже расходится: toggle summary выбирает только associated auto language, renderer — manual language.

**Оригинал:** `MessageTrans.kt:309–322,349–369` отдельно переводит и сохраняет открытое summary.

**Исправление / тест:** единый effective language для summary request и renderer; переводить выбранное summary в его native attribute, корректно завершать loading. Fixture обоих порядков действий с auto off, modes 0/1/2, emoji entities; summary остаётся summary, spinner завершается.

### AI-08 — Перевод quiz solution сохраняется, но никогда не показывается

**Места:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAINativeAdapter.swift:179–187`; `telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessagePollBubbleContentNode/Sources/ChatMessagePollBubbleContentNode.swift:2348–2352,2795–2805`.

**Сценарий / impact:** перевести quiz и открыть объяснение ответа. `pollSolution` получен и сохранён, однако UI безусловно передаёт `poll.results.solution`. Переведены title/options, explanation остаётся исходным. В original `ChatActivity.java:29103–29105` выбирается `translatedPoll.solution`.

**Исправление / тест:** выбрать solution для того же effective manual/auto language, сохранив native media/entity payload. Fixture: title, option и solution с разными sentinel переводами; explanation callback получает translated solution и корректные UTF-16 entities.

### AI-09 — Toggle summary не отменяет запрос; старый error сбрасывает новый success

**Места:** `telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift:7813–7818,7829–7846`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAINativeAdapter.swift:103–111`.

**Сценарий / impact:** on (медленный A), off, on (быстрый B). Disposable обоих запросов отброшен. Off только удаляет ID. B сохраняет summary и увеличивает stableVersion; A получает `updated=false` → generic error. Error closure A без request identity удаляет summarized ID уже успешного B. Кроме неверного UI, выключение summary не останавливает внешний запрос.

**Исправление / тест:** per-message operation/disposable + generation; off отменяет его, stale callbacks не меняют состояние нового запроса. Native delayed-transport/Postbox test для обоих порядков завершения A/B и failure после success, с assert числа запросов/terminal callbacks.

### AI-10 — Context policy зависит от default provider вместо фактически выбранного route

**Места:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIIntegration.swift:367–380`; `swift/ExteralessCore/Sources/ExteralessCore/AITranslationPolicy.swift:43–45`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAINativeAdapter.swift:138–143,203–220`.

**Сценарий / impact:** default Google, LLM configured, `llmUseContext=true`, отдельная Translate with LLM. Строка 369 выставляет override `.llm`, но строка 370 проверяет default policy provider, поэтому контекст отключён. В original `MessageTrans.kt:729–731` учитывается override.

Есть противоположное расширение auto scope: native builder добавляет preceding history при отсутствии/недостатке replies (`:213–219`). Original auto builder `TranslateController.java:2720–2762` отправляет **только reply chain**, а surrounding history относится к manual builder (`MessageTrans.kt:770–790`). Поэтому auto action без reply теперь экспортирует дополнительные сообщения. Наличие `trackHoles:false` не делает scopes равными.

**Исправление / тест:** вычислять context policy после выбора effective provider и отдельно для manual/automatic purposes; зафиксировать оригинальный auto scope. Fixtures: Google+explicit LLM, LLM+explicit non-LLM, auto без reply, broadcast/reply/thread scopes. Ограничить также число посещённых reply IDs: сейчас `while result.count < limit` не ограничивает цепочку пустых/media-only родителей.

### AI-11 — LLM 5xx больше не получает retry и Google fallback

**Место:** `swift/ExteralessCore/Sources/ExteralessCore/AITranslation.swift:193–208`.

**Сценарий / impact:** provider возвращает 500/502/503. Transport выдаёт `.http(status)`, но retry predicate принимает лишь `.network`, `.timeout`, `.http(429)`; исключение сразу уходит пользователю. Original `LLMTranslator.kt:220–228,144–169` преобразует non-4xx provider failures в IOException, повторяет и затем вызывает Google. То же отличие для пустого/непарсируемого успешного response: original относил его к recoverable provider failure.

**Исправление / тест:** явно определить retryable server/response errors и сохранить bounded retry/fallback, не повторяя cancelled/401/403 или partial generation. Scripted transport tests: 503→success; три 502→Google; 401 и cancellation→без fallback. Имеющиеся 40 tests этот policy не проверяют.

### AI-12 — Tool round отбрасывает reasoning state, необходимый reasoning-enabled compatible models

**Место:** `swift/ExteralessCore/Sources/ExteralessCore/AIClient.swift:158–175`, особенно `162`.

**Сценарий / impact:** compatible provider/model с обязательным replay `reasoning_content` (например, reasoning-mode DeepSeek tool calls) возвращает reasoning и tool_calls. Клиент показывает reasoning, но следующий assistant message реконструирует только из role/content/tool_calls. Следующий provider round получает неполный transcript и может отвергнуть запрос. Структурированное provider reasoning тоже сохраняется только как display string, не как wire state.

**Оригинал / уверенность:** тот же дефект присутствует в `app/exteraless/ai/network/Client.java:419–446`; это не расхождение переноса, а унаследованная protocol-compatibility проблема. Утрата поля доказана исходником; поведение конкретной текущей модели по сети здесь не проверялось.

**Исправление / тест:** сохранять allowlisted provider-specific continuation state отдельно от отображаемого reasoning и replay его в tool conversation. Stateful offline fixture возвращает sentinel reasoning и проверяет его во втором assistant message. Реальный vendor acceptance — отдельная необходимая проверка, не результат такого fixture.

### AI-13 — Save после reload нового service может стереть ещё не зарегистрированный Keychain key

**Места:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift:93–101`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAISettingsControllers.swift:146–153`; `swift/ExteralessCore/Sources/ExteralessCore/AISettings.swift:44,46–57`.

**Сценарий / impact:** после внешнего restore/reload metadata содержит service ID, ранее не зарегистрированный в этом process, а его credential уже есть в persistent secret store. Foreground reload обновляет только ClientSettings; provider UI не делает recovery перед чтением. `apiKey(for:)` возвращает пустой fallback для неизвестного dynamic key. Save метаданных захватывает эту пустую строку, затем `AISettings.save` регистрирует secret и немедленно удаляет его запись пустым `set`. Пользователь не выбирал удаление key.

**Исправление / тест:** prepare перед первым UI read и различать «key не изменён» от «удалить key» в save API. Core fixture двух store instances: второй добавляет service+key → первый reload → metadata-only save с UI semantics → credential сохранён. Имеющийся lifecycle test вызывает `recovery.prepare` явно и не покрывает этот UI route.

### AI-14 — Speech commit не защищён от cancel/account teardown и смены media внутри transaction

**Места:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIIntegration.swift:433–442,533–538`; `telegram-ios/submodules/TelegramCore/Sources/TelegramEngine/Messages/TelegramEngineMessages.swift:811–823`; `telegram-ios/submodules/Postbox/Sources/Postbox.swift:3359–3386`.

**Сценарий / impact:** transcript уже получен; storage transaction поставлена в очередь; пользователь нажимает Cancel/меняет account до её выполнения. Signal disposal не отменяет Postbox closure: `transaction` возвращает `EmptyDisposable`. `storeLocallyTranscribedAudio` не проверяет cancellation, expected stableVersion или resource ID и всё равно записывает результат. При изменении media/новом transcription старый результат может заменить актуальный. Перед transaction есть account identity check, но внутри — нет; запись привязана к старому engine, а не к новому account.

**Исправление / тест:** узкий engine commit с thread-safe operation lease, expected source resource/version и Bool результата, аналогичный уже исправленным AI summary/translation helpers. Real Postbox queue-barrier fixture: отмена/teardown до исполнения closure даёт ноль mutations; смена media/новый transcript не перезаписывается старым callback.

### AI-15 — transcribeProvider не управляет штатной кнопкой транскрипции

**Места:** `telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageInteractiveFileNode/Sources/ChatMessageInteractiveFileNode.swift:418–478`; owned entry `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIChatActions.swift:69–79`.

**Сценарий / impact:** выбрать Workers/Gemini/OpenAI/Apple, затем нажать привычную inline transcription button. Она всё ещё выбирает только stock experimental local transcription или `engine.messages.transcribeAudio`. Новый provider доступен через отдельный context-menu action, но не заменяет native button/Premium gate.

**Оригинал:** `TranscribeHelper.java:105–109` учитывает Premium/default/explicit provider; `TranscribeButton.java:127,702–715,852–865` использует его для доступности и выполнения. Следовательно, имеющийся отдельный entry — частичный перенос этой настройки.

**Исправление / тест:** связать typed speech adapter со штатной кнопкой и исходной Premium-dependent policy, сохранив fallback/errors/disposal. Native route matrix: Premium/non-Premium × auto/каждый explicit provider × configured/missing credentials; assert фактически выбранного callback/transport.

### AI-16 — Заявленный rich graph budget не считает все элементы и выделяет массивы до проверки

**Место:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIRichTextTranslator.swift:49–55,66,97–105,118–124`.

**Сценарий / impact:** table с >8192 пустыми cells/rows (`cell.text=nil`) проходит Mapper: budget увеличивается только на block/text, не на row/cell. `.unknown` list items имеют ту же проблему. `map` также резервирует массивы размером входной коллекции до per-node guard. В итоге 8192-node limit не ограничивает реальные allocations/work; работа первого обхода выполняется на MainActor.

**Исправление / тест:** считать все структурные элементы, проверять collection count/remaining budget до `map`, строить bounded output и проверять cancellation в длинных обходах. Pure Mapper fixture с 8193 nil-text cells/unknown items должен завершаться budget error до создания полного output; отдельно depth 48/49 и пять concurrent leaves.

### AI-17 — После 2048 manual translations новые сообщения перестают нормально переводиться

**Место:** `swift/ExteralessCore/Sources/ExteralessCore/AITranslationPolicy.swift:168–176`; consumer `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAINativeAdapter.swift:147–159`.

**Сценарий / impact:** аккаунт накопил 2048 manual markers, включая hidden. На 2049-м перевод уже записан в native attribute, затем metadata set бросает `inputTooLarge`. Eviction нет; hide сохраняет entry с `visible=false`. Все последующие новые manual translations показывают failure/не получают видимый marker, хотя provider request выполнен. Internal AI-state record скрыт из обычных настроек.

**Исправление / тест:** bounded eviction с понятной recency policy либо очистка неактуальных/hidden metadata; не превращать успешный provider result в необратимое исчерпание функции. Fixture на 2049 записей: новый marker доступен, размер остаётся ≤2048, предыдущая Keychain запись не повреждена.

### AI-18 — Native Copy/AI text actions не учитывают отображаемый manual translation

**Места:** `telegram-ios/submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift:1392–1402,1490–1498`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIChatActions.swift:181–195`; renderer `telegram-ios/submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift:417–450`.

**Сценарий / impact:** auto off, Translate in chat выполнен, manual marker visible. Bubble показывает перевод, однако long-press Copy и `exteralessAIVisibleText` смотрят только `presentationInterfaceState.translationState` и выбирают оригинал. При keep-original mode actions также не знают composed display text/entity offsets. Получается расхождение между видимым текстом и материалом последующего copy/AI/speech action.

Смежный UI эффект: `presentMessageTranslation` (`ExteralessAIIntegration.swift:335–338`) пишет `visible=false` и сообщает «Translation hidden in chat», но renderer при active auto language немедленно выбирает auto translation. Original menu ограничивал Undo Translate состоянием `isOutgoingOrNotTranslatingDialog` (`ChatActivity.java:51004–51017`).

**Исправление / тест:** единый resolver effective source/display (manual, auto, summary, original, protection) для renderer и actions; hide должен иметь согласованную семантику/доступность. Native fixture auto off/manual visible + emoji/link entities проверяет Copy и AI-input; auto on проверяет отсутствие ложного hide confirmation.

## Сверка без дополнительных блокеров

| Семейство | Проверено по коду; существенные границы |
|---|---|
| Assistant presets, roles, service migration | `AIModels.swift:17–22,134–138` совпадают с `Provider.java:13–33`/`Suggestions.java`. Java UTF-16 signed hash и null-key semantics сохранены (`AISettings.swift:194–197`, `Service.java:157–159`), legacy import отдельно от arbitrary preferences. Native normal service serialization не содержит key. |
| Provider schemas | Google app/experimental/cloud, Yandex, Caiyun, Bing forms, DeepL free/pro/formality, TranSmart и audio JSON сверены с реальными Java/Kotlin builders/parsers. ModelUtil temperature/reasoning dispatch и Vertex contents/systemInstruction/path совпадают. Это доказательство переноса schema, не ответа текущего vendor. |
| Известные адаптации | RealMicrosoft→Bing, anonymous DeepL→key API, Apple Speech вместо Vosk и пустые resource-defined LLM defaults — реальные ограничения паритета. Отсутствующие Android resources/dependency protocol нельзя считать реализованными через похожий endpoint. Vosk download/model management не перенесён. |
| SSE/JSON/reasoning | Byte-level CR/LF/BOM/multiline SSE, split UTF-8, смешанные content+reasoning, `<think>` filter, usage-only choices, `[DONE]`, length/refusal/error и JSON content-type fallback прочитаны. Swift лучше оригинального `Client.java:591–608`, где выбиралось только одно из content/reasoning. Один 400 retry не воспроизводит уже выданный partial response. Tool rounds non-streaming, names allowlisted, аргументы не превращаются в путь/код. AI-12 остаётся. |
| Transport lifetime | Реальный delegate transport имеет byte limit, отдельный resource timer, once-only finish, onTermination cancellation и запрет redirects. Source не выявил отдельного подтверждённого double-finish дефекта. Fixtures не проверяют terminal `[DONE]` при не закрывающем соединение сервере, error→late success, redirected request или long-running tool cancellation. |
| Bing | Timestamp и TTL используются в **миллисекундах**, key→Int64 и overflow/expiry checks согласованы с `BingTranslatorRaw.java:74–77,176–177`. Cached secret coherent; отдельный waiter cancel не отменяет остальных, последний отменяет acquisition; после await есть cancellation check. Regional redirect discovery отличается от оригинала. Тесты с часами 1000/1200 не доказывают совместимость live HTML/auth/session. |
| Settings/recovery | Fresh per-chat registration и empty→текущий global fallback действительно есть. History account-scoped, image не сохраняется в turns; recovery retry не sticky. Secret классификации сохраняются даже после неудачной регистрации; generic snapshots скрывают top-level secrets. Проблемы actual UI/public metadata — AI-04/13. |
| Modes/migration | 0/1/2 — keep-original, а не включение перевода. Legacy 0→1, 1/other→0 и journal для interrupted write сверены с `NaConfig.kt:1594–1607`. **Отсутствие original prefix у polls и voice transcripts не выставляется дефектом:** original `MessageObject.java:3913` их исключает, `:7812` выбирает только translated transcript; `ChatMessageCell.java:11735–11736,11948–11952` заменяет poll labels. |
| Preferences/article/context | Preferred-language order и ignored-language change policy сопоставлены с `Translator.kt:374–454` и `LanguageSelectActivity.java:347–363`; article separate-provider и bulk DeepL→Google реально употреблены. Scope/override mismatch — AI-03/10. |
| Postbox summary/translation | Helper действительно выполняет expected stableVersion и thread-safe cancellation predicate **внутри** update closure, в engine's account, сохраняя остальные fields. Это не просто предшествующая async проверка. Actual cancellation/version tests отсутствуют; speech отличается — AI-14, последующие rich edits — AI-06. |
| Native routing/Premium | Tri-state `null→!isPremium` реализован через actual AccountContext EngineData. Не выбранный replacement вызывает stock engine напрямую, без рекурсии того же hook; typed native errors сохраняются. Facade queued lease и adapter generation предотвращают старт для другого account. Protected fallback admission — AI-02. |
| Image | File representation читается **внутри** Photos callback, ImageIO thumbnail использует transform/orientation, source≤32 MiB, side≤2048, новый JPEG≤4 MiB. Encoder не переносит EXIF/location properties; editor удерживает picker и проверяет text/image snapshot перед insertion. Ни metadata stripping реального изображения, ни memory/Photos lifetime на device тестами не доказаны. |
| Native APIs / queues | Сверены actual constructors `TelegramAIComposeMessageResult`, `SummarizationMessageAttribute.Summary`, `TranslationMessageAttribute.Additional`, `InstantPageButton/TableCell/TableRow`, RichText cases, `SoftwareAudioSource(path:)`/48kHz mono decoder и `inputRichTextAttributeFromText`. NSSpeechRecognitionUsageDescription есть в `Telegram/BUILD:1782`. Result Operation имеет `@MainActor`, events переходят через `MainActor.run`, notification observers через MainActor Task, signal bridge через deliverOnMainQueue, speech delegates через MainActor Task. Неподтверждённый Swift isolation/typecheck диагноз не выдаётся за compiler error. |

### Что означают 40 зелёных AI tests

| Test class | Методов | Реально проверяемая семантика / основные пробелы |
|---|---:|---|
| `AIClientTests` | 13 | Encoding, parser framing/reasoning, one optional-parameter retry, один allowlisted tool, URLProtocol delegate/cancel/timeout. Image fixture — четыре marker bytes, не JPEG decode. Preset tests лишь ожидают те же URL/model/temperature; vendor acceptance из них не следует. Нет reasoning-state continuation, second-round errors, tool limit, cancellation внутри tool, JSON-stream fallback и terminal-repeat matrices. |
| `AITranslationTests` | 12 | Secret exclusion для нормального save, provider builders и fabricated JSON, UTF-16 protected spans, explicit supplied context, key rotation, native **closure** и WAV header. Не реальный Telegram engine/renderer, не network, не Photos/Speech decoder. Нет 5xx retry, rich page/poll solution/native transaction/protected context/public raw-service tests. |
| `AIPolicyTests` | 6 | Чистые Premium/mode/provider/preferences predicates, migration journal fixture, prompt/diff. Не stock interception, не фактический renderer или отмена transaction. |
| `AILifecycleTests` | 4 | Fake secret stores, recreation/configure при явном prepare, per-chat reset/import/recovery. Не Keychain entitlements/accessibility и не metadata-only UI save после reload. |
| `AIBingCacheTests` | 2 | Fake milliseconds/TTL/recreation и waiter cancellation. Sleep-based admission вместо детерминированного barrier; fixture termination flag не различает cancel и normal finish. Live host/session protocol не проверен. |
| `AIPluginReviewTests` | 3 | Маленькие gzip/zlib/ZIP fixtures, CRC/маленький output cap, pagination 500 обычных строк, unknown path/tool refusal, cache TTL/disableTools. Не compressed bombs, global allocations, many blobs, malformed central directory, native filesystem TOCTOU или model multi-round protocol. |

`ExteralessAIHooks`/UIKit/renderers/Photos не входят в эти Core XCTest методы. Число Hooks 16 из координаторского build также не означает, что AccountContext AI hooks были собраны и испытаны.

## Остаток до принятия

1. Закрыть P1 и semantic P2 actual callsites, добавляя meaningful fixtures на описанные сценарии, прежде всего protection propagation и transaction cancellation.
2. Выполнить native full typecheck/link и loginless/in-memory Postbox/UI harness: actual hooks, failure/success/retry ordering, account/protection changes, translated summary/poll/rich pages, stock speech button, Photos orientations.
3. Vendor compatibility подтвердить отдельно разрешёнными protocol fixtures/реальными запросами владельца ключей. Offline green не выдавать за такой результат.
4. Затем записать и оценить кадры по `telegram-ios/AGENTS.md`: ожидаются отсутствие stale flashes/вечного shimmer, корректные UTF-16 entities и показ original/translation, сохранение draft/selection, штатные close/cancel/loading states. В этой сессии кадров нет, visual pass отсутствует.

Известная координационная коллизия `ai.showTextTranslate` / `chats.showTextTranslate` (fix готовится Chat owner) учтена и **не продублирована** как новый blocker. Остальные findings выше от неё не зависят.
