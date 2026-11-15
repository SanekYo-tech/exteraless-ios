# HNS01–09: focused follow-up

## Версия и граница проверки

База: `aae32be6019297372c6b4ef0373d60775d05d851`. Во время чтения HEAD стал `7d04a35a3612a2dc32dba6fb54744e38c07cabe9`: в рассмотренном Host/Hooks scope изменились только `PluginSettingsExecutionTests.swift` и `PluginTLHostTests.swift`. Production Host/Hooks соответствует `aae32be6`; native consumers / SDK / Tools рассмотрены по рабочему дереву.

Прочитаны remediation-контракты Host, NativeServices, UI, применённый Runtime stitch, settings-execution и Tools schema-evidence. Все три coordinator insertion **есть в actual source**:

- Runtime `observe`: `reserveDeliveryBytes` до Task (`ExteralessPluginRuntime.swift:979–983`).
- Native send: capture `currentSendExecutionPredicate` до Task и передача в Host (`:953–964`).
- `PluginNativeCallLease.init` захватывает `PluginNativeExecutionContext.captureGuard()` (`swift/PluginHost/Sources/PluginHost/PluginServiceModels.swift:234–237`). Batch fixtures используют этот реальный конструктор.

Новый CI не читался. Предыдущие 158 Host + 24 Hooks passed и Core/Cloud retry failure — предоставленный контекст, не результат этого follow-up. Swift/CPython/native/frames здесь не запускались; три подготовленных native child не считаются выполненными. `PluginConfig` не получает отдельного verdict. Старый report сохранён read-only.

**Осталось: 1 P1 и 3 P2 ниже.** Исходные mutation/cleanup/budget/marker/stop counterexamples в основном закрыты на уровне source; blanket native acceptance пока нет.

## Оставшиеся findings

### HNS-F01 · P1 · HNS07 — Batch revocation не доходит до некоторых реальных native-effect consumers

**Места:**

- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIRetainedEffect.swift:11–17`.
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIBridgeExtension.swift:245–276`.
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLBridgeExtension.swift:139–144`, `:187–204`, `:244–253`.
- `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift:216–218`.

**Сценарий.** В batch A уже закончил свой hook, B ещё выполняется. A успел поставить `Runtime.addToClipboard` / `openURL`; main work пока удерживается. Batch истекает либо native send отменён. A остаётся loaded, его owner, account и permissions актуальны. `PluginUIRetainedEffect` проверяет только ticket и переданный `isCurrent`; в этом route он проверяет owner/account/UI permission. Batch guard не захватывается. После освобождения main queue старый эффект выполняется. Общий `PluginNativeCallLease` исправлен, но UI provider, первым принимающий эти Runtime methods, его не создаёт.

Второй конкретный путь — A вызывает `Runtime.sendMedia` с text-моделью. Ticket хранит ancestry, но не execution revocation; `startText` передаёт в Core только `!registry.contains(ticket) || !permission(...)`. Если deferred start либо bot-authorization wait завершается после timeout родительского batch, ticket A всё ещё valid. Новый Core commit permit получает разрешающий predicate и допускает запись. Наличие правильного `beginCommit` в Core само по себе не восстанавливает потерянный parent guard.

**Impact.** Сохраняются поздние UI-эффекты и отправка сообщения после уже завершённого fallback/cancellation. Это не отсутствие трёх coordinator hunks: потеря происходит в consumers, обходящих общий lease constructor. Legacy `Runtime.sendMessage` использует исправленный общий lease; finding относится к указанным другим routes.

**Fix/test.** Захватить revocation на исходном C owner-worker при admission и удержать его в UI effect / TL ticket; проверять до actual native effect/commit, вместе с owner/account/permissions. Cleanup и budget credit должны доживать до фактического освобождения retained work. Дополнить batch fixture: A создаёт **реальный `PluginUIRetainedEffect`**, B блокируется, timeout/cancel, затем manual-main drain — sink не вызывается. Для text-provider проверить тот predicate, который реально доходит до `ExteralessTLEnqueueCommit`; успешный batch должен оставаться positive control. Нынешний `PluginBatchOwnershipTests.swift:12–27,45–47` проверяет общий constructor, но не эти consumer routes.

### HNS-F02 · P2 · settings scope — Queued `create_settings` всё ещё может войти в replacement owner

**Места:**

- `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift:353–370`.
- `swift/PluginHost/Sources/PluginHost/PluginHost.swift:1061–1065`, `:1347–1361`.
- `swift/PluginHost/Sources/PluginHost/ExtensionPoints.swift:387–389`.

**Сценарий.** Settings read захватил owner P1/account A и прошёл Runtime precheck. Его `.createSettings` стоит за другим event. В это время P перезагружается до P2 либо account scope меняется. `CreateSettingsPayload` несёт только pluginId/account; для read не переданы expectedOwner или worker execution predicate. `handleEvent` берёт текущий `eventTargets()` и выполняет `create_settings` у P2. Runtime отклонит результат только после вызова. Account expiry также не отзывает этот queued read; page action gate управляет mutations, а не данным envelope.

**Impact.** Старый refresh вызывает произвольный Python-код и перестраивает callback registry новой генерации, хотя его результат больше не принадлежит странице. `create_settings()` не является гарантированно чистой функцией. Исправленные `updateSetting`/`clickSetting` исходный HNS04 counterexample закрывают; read route остаётся отдельным отверстием.

**Fix/test.** Передать captured owner и lock-only read/account/page guard через settings envelope до actual worker. Post-result проверка должна остаться дополнительной. Fixture: очередь занята другим plugin event → settings read P1 принят → reload P2 → очередь освобождена; ни одного `create_settings` в P2 от старого запроса. Отдельно заменить account при неизменном interpreter. Проверять отсутствие Python entry, а не только ошибку старому UI caller.

### HNS-F03 · P2 · native gate — Новый HNS probe передаёт Set в array API

**Места:** `python/runtime/smoke/swift_sdk_hns_probe.swift:77–78`, `:132`, `:171`; API — `swift/PluginHost/Sources/PluginHost/PluginHost.swift:1045`.

`grants` явно имеет тип `Set<PluginPermission>`, а единственный `setGrantedPermissions` принимает `[PluginPermission]`. Все три вызова передают Set без преобразования. Это source type mismatch, не предположение о поведении CPython. `tools/runtime/check_swift_plugin_embedding.py:313–317,355–358` компилирует HNS probe вместе с остальными native children, поэтому ошибка блокирует общий probe executable.

**Fix/test.** Использовать array либо явное преобразование на этих вызовах; сохранить необходимые grants. Проверить compilation тем же составом sources и Swift 6 flags, затем выполнить bounded native children. Здесь compile не запускался.

### HNS-F04 · P2 · native gate — Probe требует successful cleanup уже уничтоженного C owner

**Места:** `python/runtime/smoke/swift_sdk_hns_probe.swift:185–190`, `:201–207`; `swift/PluginHost/Sources/PluginHost/PluginHost.swift:475–482`, `:592–595`; `BridgeServices.swift:208–212` в том же Host каталоге.

После успешного maintenance probe повторяет cleanup через **`current.bridge.dispatchJSON`** и требует `{ok:true,value:false/null}`. Но Host уже удалил owner token и держит maintenance admission закрытым: общий validator возвращает `SecurityError` **до** fixture provider. После resume replay старого token против replacement lease закономерно получает тот же отказ, а строка 207 снова требует success-envelope. После исправления F03 эти assertions всё равно остановят native gate на корректном Host rejection.

**Fix/test.** На Host boundary ожидать typed denial и неизменные replacement resource counts. Идемпотентный stored-resource cleanup проверять во время разрешённого retiring unload либо непосредственно на production cleanup route. Не расширять Host admission ради ожидания fixture. Сохранить реальные проверки `CallbackLeases.end`, duplicate revoke и single release.

## Итог по исходным counterexamples — source, не native pass

| HNS | Follow-up |
|---|---|
| 01 | Runtime использует `PluginUIUnprovenSchemaCache`: `evidence:nil`, `validity:nil`. `ToolsPluginSchemaCache.location` требует `.nativeImmutable` + validity; dynamic UI result не выдаёт полей. Перед maintenance cache очищается, location берётся после drain (`Runtime:634–645`). Экспорт пропускает plugin fields; restore непустых plugin fields отвергается. Epoch, одинаковые bytes и Python Bool не считаются immutable proof. |
| 02 | Native cleanup идёт через `NativeServiceCleanupRoute` до active-owner lookup; token сравнивается с сохранённым lease под registry lock. UI `revoke` аналогично использует stored owner, включая retirement/tombstone. Исходный отказ корректному SDK cleanup во время unload закрыт в source. F04 — ошибочное ожидание **после** retirement. |
| 03 | Обязательный пятый control в production factory; independent delivery entitlement проверяет owner/account/permissions на worker. Close отзывает pending body, successful terminal сохраняет entitlement до FIFO; account/permission expiry всё равно отказывает. Release acknowledgement/backpressure и terminal positive control сохранены. |
| 04 | Все четыре mutation UI paths захватывают invocation до Task; Runtime передаёт exact owner/SDK index/predicate, Host проверяет worker, SDK `_scope(platform, account)` охватывает запись и callback (`__init__.py:344–369`). Исходные click/change races закрыты в source; queued read — F02. |
| 05 | UI reserve count/bytes до main hop; executing/deferred/cancelled-retained work держит ticket, UI budget не reset на account/unload. Исходный безлимитный clipboard/URL ingress закрыт. Revocation родительского batch — отдельный F01. |
| 06 | Общий Host ingress применяется к awaiting/non-TL/coalesced и pre-actor paths. Credits сохраняются через handler/native work и stop/restart. Router credit переносится value copies и overlap с Host admission; actual Runtime reserve-before-Task вставлен. Исходный обход `maxQueueDepth` закрыт. |
| 07 | `PluginEventExecution.runningHandles` принадлежит конкретному batch; посторонний plugin C не выбирается по общему inflight. Между fanout steps и на worker проверяется cap, поздний D не продолжается. Common effect lease реально захватывает guard; consumer coverage остаётся F01. Нового cross-plugin timeout victim в прочитанном пути не найдено. |
| 08 | Cancellable sleep возвращается при отмене; generation/marker/active-risky-operations перепроверяются в actor. Exact risky token закрывается Host. Timer A не удаляет B; overlapping loads и duplicate exit покрыты source fixtures. |
| 09 | Один stop deadline передаёт remaining budget в `destroyAll(timeout:)`. Destruction запускается для всех независимых workers до ожидания; timeout сохраняет `.destroying`/mailbox evidence, достигает provider retirement и no-finalize decision. Late completion сверяет original handle/completion. Исходный бесконечный await stop после maintenance timeout закрыт. |

### Дополнительная Legacy text / TLN02 стыковка

`BridgeServices.swift:762–766` берёт ancestry из C-owned token/worker scope и кладёт её в immutable `PluginTextMessageRequest.origin`. `TelegramPluginServices.swift:281–300` фиксирует опубликованную под lock AccountContext identity в ticket predicate; `:383–389` передаёт origin и lease cancellation в `exteralessTLSendText`. Core проверяет `tlCommit.allowsContinuation` после bot authorization и `beginCommit` в transaction перед writes (`telegram-ios/submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift:946–970`). Correlation tracking живёт отдельно от subscriber cancellation после claimed commit (`TLRequestOrigin.swift:158–218`). По source эта Legacy стыковка присутствует; full TL/native acceptance не заявляется. Она не устраняет F01 у `PluginTLBridgeExtension.startText`.

## Source fingerprint для движущегося Tools/native working tree

Raw SHA-256 на финальной вычитке; эти receipts фиксируют версию source, не результаты тестов. Core пути ниже относительно `swift/ExteralessCore/Sources/ExteralessCore/`.

| Файл | SHA-256 |
|---|---|
| `ToolsPluginSchemaCache.swift` | `e35908f6ee1b236a6af93a2c68635d66c273ea5324a5a5a4a33e433d539e82b9` |
| `ToolsPluginSchemaEvidence.swift` | `eac7a75499939aba86e9d8b551c166d85c41c61d2ecaf5e971c03e8572e8c760` |
| `ToolsBackupArchive.swift` | `d1e9b5cde4e19fa2f6b1899653ee1ee185dee34657197912d46f85fd2aa3992c` |
| `ToolsBackupRestore.swift` | `8eabbf32b4288d7aa4347f03585e0c4b55826e2d175d9d38988a22a3542817da` |
| `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift` | `0760f7701e963c1ea052f6dbe6d5b3b7924293b323bfba273922d3d3ad63af65` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIRetainedEffect.swift` | `b43feca771835ee10a04f0240282ce93d09c0dd78c66ce31e1acd30a92a6974b` |
| `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/TL/PluginTLBridgeExtension.swift` | `1e68e32adc383e9b2cc93c5b4f7923a4a87074584c4bd084eb2f87dc2168e873` |
| `python/runtime/smoke/swift_sdk_hns_probe.swift` | `c430a8c04f7c18d5f2c11b843e5fc4fa247904b30e3fbc6469dc9c6caa78156d` |
| `python/exteraless_runtime/__init__.py` | `02526f84911a0dfdbcb9927885f947730cbf4671e37f79ea28d44a656a3f16c6` |

Core contract проверен на соответствующих границах: `ToolsBackupArchive.swift:74–97,223–254` и `ToolsBackupRestore.swift:162–184,212–223`. Будущая выдача `.nativeImmutable` требует полноценного native pin по `tools-schema-evidence-contract.md`; текущий dynamic producer его не выдаёт. Последние CA/TB изменения других owners и их полный acceptance этим focused follow-up не утверждаются.
