# Независимый follow-up AI Core — 2026-11-15

## Итог

Проверены только **AI-04/05/11/12/13/17** из `ai.md` и их remediation. **AI-04, AI-05, AI-12, AI-17 закрыты по source/fixture review. AI-11 и AI-13 исправляют исходные сценарии, но остаются частично открытыми: найдены два дополнительных P2 в этих же путях. Новых P0/P1 не найдено.**

`Closed` здесь означает устранение проверенного дефекта в исходниках и содержательные regression fixtures, а не live vendor acceptance, iOS runtime или visual pass. Старый `docs/wave-2/reviews/ai.md` не изменён.

| ID | Статус этого follow-up | Основание |
|---|---|---|
| AI-04 | **Closed — Core** | Credential bound к protected destination tuple; public metadata/setter не создаёт binding. Closed service shape закрывает nested-key snapshot/export. Cloud передаёт весь opaque envelope. |
| AI-05 | **Closed** | Нет per-line String arrays/всех regex matches; реальные общие byte/count/index budgets проверяются до соответствующих append/inflate. Excerpt mode выбирается до tools construction. |
| AI-11 | **Open — partial, P2 AICF-01** | 5xx/invalid/empty responses теперь повторяются и доходят до bounded fallback. Но Cloud fallback переводит сформированный HTML как plain text. |
| AI-12 | **Closed — supported continuation schema** | Allowlisted raw reasoning state replayed в assistant tool message; отдельно от display/history, с count/byte bounds. |
| AI-13 | **Open — partial, P2 AICF-02** | `.unchanged`, prepare-before-read и `e59` reset исправляют metadata-only Save/обычный Remove. Android import и его rollback всё ещё смешивают пустой override с отсутствием credential. |
| AI-17 | **Closed** | 2049-й marker сохраняется, скрытые/старые вытесняются; sequence переживает recreation и компактацию. |

Native AI-01/02/03/06/07/08/09/10/14/15/16/18 и применяемые native/shared hunks этим документом **не закрываются**. Native audio form — отдельный последующий scope; здесь проверен только её Core credential contract.

## Проверенный snapshot и evidence

- Начальный HEAD: `e59bd30a8d89bebe4537bb0d9a391a118b2f3fa9`; remediation commit: `75cbe7a1` плюс именно `e59` removal/presence correction.
- Во время review HEAD переместился на `20166b2c2d90b830a97c9d7340be613145520147` (Host integration). Scoped diff `e59bd30a..20166b2c` для Core AI source/tests и `ClientSettingDefinition/ClientSettingValue/ClientSettings` пуст.
- **28 Core AI source/test files** (18 source, 10 test; `AINativePolicy*` исключены) совпали с `e59` после нормализации CRLF/LF. Их raw-byte aggregate SHA-256 одинаков в двух замерах: `697518e1c6c7348754713358948eda40bcbaa29c045550ebec096de1146b2d72`.
- Aggregate: SHA-256 от UTF-8 concatenation `relative-posix-path + NUL + lowercase-SHA256(file-bytes) + LF`, в sorted path order, для `AI*.swift` в двух Core source/test directories, кроме `AINativePolicy*`. Это pin исходников, не тест компиляции.
- Прочитаны actual remediation implementation, все **73 AI XCTest methods**, фактические provider forms/review-construction callsites, supporting settings shape/codec/write paths, и узкий Cloud credential export/restore bridge. AGENTS/CLAUDE из предыдущего review применяются; правила recorded frames соблюдены отсутствием visual claim.
- По сообщению координатора CI `43695307589` прошёл 42 CoreSettings tests и выполнил AI suite, с исключением проверки nil после Remove, исправленной затем в `e59`. Результат нового CI не запрашивался. Ошибка Identity и остальная сборка не входят в этот follow-up.
- Здесь выполнялись только reads, scoped Git inspection и Python stdlib hashing/counting с `-B` и timeout ≤20 s. XCTest, CI, network, Keychain/device, paid requests и plugin code не исполнялись. Счётчик методов не выдаётся за XCTest run.

### Дополнительные pins

| Файл | SHA-256 |
|---|---|
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAISettingsControllers.swift` | `f5bd9727bd9742c13a3b6789ea21d36074c173f3df9088d000849ed15fb06d74` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIPluginReviewController.swift` | `d3e77ec01f04300f2443623354afd766d876faf9b789374efd4ea993c0292105` |
| `swift/ExteralessCore/Sources/ExteralessCore/ClientSettingDefinition.swift` | `20fb90687568b90057475a9a41f7dd00e9e587d10d91d0c3af47d0ec9588038d` |
| `swift/ExteralessCore/Sources/ExteralessCore/ClientSettingValue.swift` | `ce214f72be402dde1ddfd830f2b0a8b67ba5882e7e28276e5599ef614907a5e4` |
| `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift` | `6a8a9998744f2e34aafc1d5c230e43c4b61237228755ace65950414412f88305` |
| `swift/ExteralessCore/Sources/ExteralessCore/CloudAICredentialBridge.swift` | `f222cf50e05d3b130533c67d927a3a5a0a1dbf8eb00464043ab014b8f8f58128` |
| `swift/ExteralessCore/Sources/ExteralessCore/CloudCredentials.swift` | `2cf94911771c36201964d4efd641d627d97a23cf1ee61f9b2a51cd72b6513209` |
| `swift/ExteralessCore/Sources/ExteralessCore/CloudArchive.swift` | `0ad9a51a4d26810f79b5085113a64b880edb30ac123f8829d512d8611268db23` |
| Старый `docs/wave-2/reviews/ai.md`, до/после inspection | `fb5eec0b918538065937e753811613a244e05e3bdfa6d32e9263c6d5f0b12b84` |

## Остаточные findings

### AICF-01 — P2 / AI-11: Google Cloud fallback теряет HTML mode

**Места:** `swift/ExteralessCore/Sources/ExteralessCore/AITranslation.swift:139–149,180–217`, особенно `215`, и `:313–316`; `swift/ExteralessCore/Sources/ExteralessCore/AITextFormatting.swift:102–139`.

**Сценарий:** `preserveFormatting=true`, input содержит bold/link/entity, Google Cloud key настроен, experimental Google не выбран/без experimental key. LLM возвращает три 502/503 либо empty/invalid responses.

**Evidence:** верхний translation path уже преобразовал input в HTML с `data-e`. Обычный Google Cloud route передаёт `html: !original.spans.isEmpty`. В `llm` утеряна эта информация, и fallback всегда вызывает builder с `html: false`. В реальном request это становится `format=text` при `q=<b data-e="0">Hello</b>`. После ответа всё ещё вызывается decoder, требующий HTML tags с original span IDs.

Например, text-mode response с literal escaped markup `&lt;b data-e="0"&gt;Bonjour&lt;/b&gt;` не содержит tags во время regex pass. Последующий `unescape` создаёт видимый `<b…>`, но `merged` остаётся пустым, и `:139` бросает `.formattingLost`. Перевод literal markup как текста также не обещает сохранения `data-e`. Live Google здесь не вызывался: source-доказаны неправильный request mode и отказ decoder для указанного response.

**Impact:** retry correction работает на plain fixtures, но fallback для форматированного сообщения может завершиться ошибкой вместо восстановленного перевода. Это существовавший смежный дефект fallback path, ставший видимым при проверке AI-11, а не отсутствие нового 5xx predicate.

**Исправление:** передать formatting/HTML intent в fallback либо вызвать общий Google translation path с исходным `AIFormattedText`, сохранив single fallback и credential/cancellation policy. Не снимать protected-span validation.

**Regression:** три scripted 502 → Cloud response; input с emoji и bold/TextUrl spans. Проверить четвёртый request: тот же encoded `q`, `format=html`, без LLM Authorization; результат содержит ожидаемые переведённые spans/UTF-16 ranges. Также plain input должен давать `format=text`. `AIRetryTests.swift:22–49` сейчас использует только plain text и Google app response.

### AICF-02 — P2 / AI-13: Android import и rollback создают пустой Keychain override вместо удаления/отсутствия

**Места:** `swift/ExteralessCore/Sources/ExteralessCore/AISettings.swift:192–218`, особенно `201,208,212,218`; `swift/ExteralessCore/Sources/ExteralessCore/AICredentials.swift:53–60`; `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:576–584,656–683`.

**Сценарий 1:** импортировать Android service с отсутствующим/пустым `key` в store без этого credential.

1. Import явно выбирает `.remove` (`AISettings.swift:201`). Binding helper возвращает `""`.
2. Import writer всё ещё делает `store.set(.string(key))` (`:212`), а не `reset`.
3. После SC-05 явный default сохраняется: Keychain содержит JSON string `""`, `storedKeys` включает service key. Это не отсутствие item и не удаление. Правильное поведение SC-05 закреплено `ClientSettingsTests.swift:1010–1037`; менять его обратно нельзя.
4. Последующий add-only Cloud restore с настоящим bound credential получает `errSecDuplicateItem` → `.alreadyPresent` (`CloudCredentials.swift:153–161`). `CloudArchive.swift:186–196` засчитывает retained credential, хотя `apiKey(for:)` остаётся пустым. Provider form может показывать бесполезный «Use stored key»: `ExteralessAISettingsControllers.swift:141–143`, тогда как rebind пустого previous в `AICredentials.swift:60` не делает mutation.

**Сценарий 2:** второй secret write во multi-service import fails. Rollback хранит только `store.string` (`:208`), где absent и present-empty одинаковы, и для ранее отсутствовавших keys делает `set(.string(""))` (`:218`). После неудачного импорта остаются новые пустые overrides; plain metadata/selection rollback также не сохраняет prior override presence.

**Impact:** импорт без credentials или неудачный import создаёт «существующий» пустой credential, мешает штатному add-only восстановлению и нарушает обещанную семантику Remove/rollback. Это не credential leak.

**Исправление:** довести `e59` correction до import: при текущей `.remove` семантике использовать `reset`; snapshot rollback должен хранить prior presence вместе со значением для secret/public affected keys и восстанавливать absence через reset. `.unchanged` metadata-save contract и SC-05 сохранить.

**Regression:** импорт nil/empty key → backend item nil и `storedKeys` absent; затем fixture Cloud insertIfAbsent действительно вставляет bound key и native reader его возвращает. Отдельно fault-inject второй secret write, проверить отсутствие новых keys и byte-for-byte сохранение ранее существовавших credentials/override presence. `AILifecycleTests.swift:6–20` импортирует только непустые keys; `AICredentialsTests.swift:152–175` проверяет обычный `save(.remove)`, но не import/rollback.

## Что исправлено и почему это не только doc claim

### AI-04 — credential binding и service shape

- `AICredentials.swift:14–34`: destination включает `settingKey`, normalized scheme/host/effective port, **percent-encoded base path** и wire protocol. Сравнение проводится с тем же service/URL snapshot, который затем получает request builder.
- `AISettings.swift:44–47`, `AICredentials.swift:100–112`: unbound/mismatched record возвращает пустой key/список. Fixed presets дополнительно сравнивают service ID, code-defined destination и protocol. Normal metadata/model rename допускается без смены credential authority.
- `AICredentials.swift:37–91`: opaque string prefix с newline, protected tuple и credential в одной записи. `.unchanged` при `authorizeDestinationChange=false` возвращает nil. Public `setPublic` не может записать эту secret запись (`ClientSettings.swift:578–584`). Public URL edit сам по себе не вызывает native authorization.
- `AITranslation.swift:62–63` и `AITranscription.swift:71–73` действительно употребляют validated readers, а не прежний `store.string` для variable destinations.
- `AIFeatures.swift:4–11` устанавливает closed service shape на persistence definition: 100 records, required fields, unknown/nested credential fields запрещены. `ClientSettingDefinition.swift:23–46,100–102` выполняет shape validation. После tightening/load failure `ClientSettings.swift:410–421` удаляет из snapshot невалидное старое значение; слабая промежуточная схема не публикуется.
- `AICredentialsTests.swift:9–149,177–210`: не только сверка строк binding, но реальные public writes → native readers → `AIClient.generate`, с assert **zero transport requests** и отсутствием Authorization у model discovery; есть host/port/path/protocol/ID, fixed/custom/audio, legacy-unbound, explicit rebind и raw shape cases.

**Cloud contract проверен отдельно по source:** `CloudAICredentialBridge.swift:9–14` проверяет key по native destination и возвращает **raw**, а не extracted key. `CloudCredentials.swift:81–94,148–157` экспортирует эту строку и сохраняет именно её. Restore validation не выводит binding из public URL (`CloudAICredentialBridge.swift:37–46`). `CloudLegacyImportTests.swift:133–169` проверяет whole protected value и отсутствие rebinding существующего key. Эти untracked Cloud sources pinned выше; full Cloud suite/runtime здесь не принимается по факту этого узкого просмотра. AICF-02 относится к empty-item presence, а не к потере opaque envelope в Cloud.

### AI-05 — allocation boundaries

- `AIReviewSourceContext.swift:58–108`: один UTF-8 buffer, scalar validation и sparse checkpoints. Проверка `checkpoints.count < maximumIndexEntries` находится **до append**. Глобальный remaining index budget передаётся каждому файлу (`:375–388`), поэтому поздние файлы не получают ещё по 4096 записей.
- `AIReviewArchive.swift:71–85,104–127`: исходный архив ограничен перед копией в bytes; declared entry size проверяется против remaining aggregate bytes **до compressedData/inflate**. Stored entry также требует `compressed == uncompressed` до копии. Visitor не создаёт общий inflated array. Remaining aggregate bytes/count передаются между отдельными ZIPs (`AIReviewSourceContext.swift:393–402`).
- `AIReviewSourceContext.swift:227–305`: shared binary/base64 count/bytes/candidate state; incremental scan вместо `.matches`. Oversized candidate проверяется до encoded copy/decode; invalid candidates также расходуют бюджет. `stopped` применяется между файлами.
- `AIPluginReview.swift:103–114,117–165,170–224`: создаются только bounded line prefixes, list/text/binary pages; нет полной склейки source/decoded strings ради одной страницы. `AIReviewBoundedText` обрезает по UTF-8 scalar boundary (`AIReviewSourceContext.swift:186–212`).
- `ExteralessAIPluginReviewController.swift:128–130` читает disabled flag **до** construction и передаёт `.sourceExcerpt`; этот режим не строит индекс/не сканирует blobs и останавливает дальнейшую enumeration после заполнения excerpt.
- `AIReviewAllocationTests.swift:9–57`: newline-dense multi-entry ZIP с общим index budget; malformed следующий DEFLATE не достигается при исчерпании aggregate budget, в том числе между двумя архивами. `:60–117` проверяет stop внутри одной строки, общий blob budget и invalid-candidate cap. `:119–175` — Unicode prefix, excerpt early stop и cooperative/actual Task cancellation.

**Граница вывода:** source/fixture counters действительно соответствуют bounded retained structures. Они не измеряют peak RSS. Проверка UTF-8/line count всё ещё обходит первый файл целиком, а ZIP entry для excerpt может быть целиком inflated в пределах entry budget; «ленивый excerpt» не означает чтение ровно 48 KiB с диска. Старый неограниченный per-line/object amplification устранён.

### AI-11 — retry correction, кроме AICF-01

- `AITranslation.swift:194–217`: три логических non-streaming attempts, delays 1/2 s, затем один Google fallback. Retryable: network/timeout/429/5xx/invalid/empty. Credentials/configuration/cancel/blocked/length/incomplete errors terminal.
- `AIClient.swift:44–55,190–195`: progress latch запрещает optional-parameter replay после любого выданного event; это проверяется `AIClientTests.swift:188–200` с partial SSE + поздним failure.
- `AIRetryTests.swift:6–93` проверяет количество/адреса requests, key rotation, delay sequence, Google fallback без LLM Authorization, nonretryable errors, cancellation во время backoff и настоящий parser path `finish_reason=length`.
- Три attempts — не универсальный максимум трёх HTTP calls: каждый `AIClient.generate` дополнительно допускает один 400 retry до output. Worst-case 400→5xx в каждом logical attempt даёт шесть LLM HTTP calls плюс один fallback. Это всё ещё конечный bound; fixture обычных трёх 502 проверяет четыре total requests.

### AI-12 — continuation replay

- `AIReasoningContinuation.swift:10–52` отделяет raw wire value от display text, применяет allowlist, ≤64 details и ≤256 KiB encoded state. Unknown fields/types details не replayed; malformed known values отклоняются.
- `AIClient.swift:161–170` создаёт continuation **до tool execution**, затем добавляет её в assistant message. Tool result messages её не получают. History persistence получает только final text.
- `AIClientTests.swift:203–257` проверяет второй request transcript: DeepSeek sentinel, object signature, encrypted details/data/index, exclusion неизвестных полей и отсутствие opaque data в display reasoning; oversized state не достигает tool callback.
- Это закрывает утерю поддержанного continuation state. Fixture provider всегда scripted; real DeepSeek/OpenRouter/Gemini acceptance и неподдержанные provider extensions требуют самостоятельной vendor проверки. Exact replay здесь — семантическое сохранение allowlisted JSON values, не byte-identical JSON serialization.

### AI-13 — metadata-only save и prepare, кроме AICF-02

- `AISettings.swift:50–78`: register/recovery предшествует чтению secret; `.unchanged` не заменяет credential пустым fallback. Metadata и selection идут одним public batch.
- `e59` действительно изменил normal service Remove, fixed LLM Remove и custom/audio Remove на `reset`: `AISettings.swift:64–74,80–86`; `AICredentials.swift:127–140,149–166`. Rollback этих save APIs хранит `previouslyStored` и восстанавливает absence, а не explicit default. Сам SC-05 не откатан.
- `ExteralessAISettingsControllers.swift:20–30,110–122,323–333` делает prepare до первого credential read и предоставляет retry state. Service Save формирует typed intent из **наличия keyDraft**, не из результата `apiKey()` (`:177–185`). Custom key edit использует captured displayed URL (`:337,351–359`), а не поздний mutable URL lookup. Metadata-only Save не выставляет authorize flag.
- `AICredentialsTests.swift:152–175`: два store instances, reload с незарегистрированным dynamic key, metadata-only save, exact backend-byte equality и явное удаление. Дополнения `e59` в `:120–126` проверяют absence для ещё трёх remove APIs. Это meaningful semantic coverage; post-`e59` execution pending coordinator CI, UI frames не выполнены.

### AI-17 — bounded recency

- `AITranslationPolicy.swift:161–175`: прежние records без sequence декодируются как zero; malformed secure record не молча заменяется новым dictionary (`:216–222`).
- `:186–211`: just-written marker сохраняется; candidates исключают его, hidden идут первыми, затем sequence/key ordering; удаляется ровно overflow count. При UInt64.max sequence компактизируется до выдачи нового номера.
- Recency обновляется на **mutation**, не на каждый renderer read (`:183–198`), поэтому это mutation-recency eviction, а не read-access LRU. Такая семантика соответствует remediation contract и не создаёт записей при отрисовке.
- `AIManualTranslationTests.swift:6–61`: реальный original-format dictionary из 2048 records, 2049/2050-й, hidden/newest/oldest, account store recreation, nil removal, overflow и сохранность malformed bytes. Постоянного исчерпания manual-marker capacity больше нет.

## Test ledger и следующий шаг

Все 73 AI methods прочитаны: `AIClientTests` 17; `AICredentialsTests` 8; `AIReviewAllocationTests` 12; `AIRetryTests` 6; `AIManualTranslationTests` 3; `AITranslationTests` 12; `AILifecycleTests` 4; `AIPolicyTests` 6; `AIPluginReviewTests` 3; `AIBingCacheTests` 2. `AINativePolicyTests` не входит в эти 73 и не является основанием закрытия native findings.

Для этого scope нужны две адресные regression corrections AICF-01/02 и координаторский post-`e59` AI run. Повторная компиляция/запуск 73 tests на этой Windows машине не предпринимались. Подтверждённый источник live CI остаётся сообщение координатора, не проверка в этой сессии.

Следующее independent review native/audio/shared hunks должно опираться на отдельный окончательный отчёт native-remediator и актуальный snapshot. Старый AI review не редактировался; ни одна native finding не закрыта косвенно через данный Core follow-up.
