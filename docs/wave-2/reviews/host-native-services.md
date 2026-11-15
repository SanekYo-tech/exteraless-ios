# Независимое ревью PluginHost / NativeServices

## Основание

- Host: `20166b2c` + test correction `dcc13004`. Во время ревью HEAD перешёл на `ddc25d69`; diff этих коммитов в рассмотренных Host/native-consumer путях пустой.
- Native Runtime, PluginUI, NativeServices, Pill/TL consumers и SDK-вызовы на их границе рассмотрены по рабочему дереву. Ссылки ниже относятся к прочитанному коду, включая текущую композицию Runtime. Незавершённый `PluginConfigBridgeExtension` и его новый binding не получают verdict.
- Прочитаны `telegram-ios/AGENTS.md` и `telegram-ios/CLAUDE.md`. C bridge рассмотрен только как граница ownership/transport.
- Linux run `43698196787` green — предоставленное исходное свидетельство, не новый запуск reviewer. Новый real-CPython/native Mac gate ещё не выполнялся. Здесь — анализ исполняемых путей и имеющихся тестов; новых runtime-прогонов нет. Локально Swift отсутствует. Regex/source assertions не используются как runtime proof.

**Результат: 6 P1, 3 P2. P0 по прочитанному коду не обнаружен.**

## Findings

### HNS-01 · P1 — Schema cache считает весь interpreter epoch одной схемой

**Места:**

- `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift:344–365`, `:604–605`, `:665–684`.
- `swift/ExteralessCore/Sources/ExteralessCore/ToolsPluginSchemaCache.swift:49`, `:65–90`.
- `swift/ExteralessCore/Sources/ExteralessCore/ToolsBackupArchive.swift:174–188`; `ToolsBackupRestore.swift:164–173` в том же каталоге.
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Tools/ExteralessBackupController.swift:37–55`.

**Сценарий.** `create_settings()` строит slider/selector в зависимости от `mode`. UI прочитал вариант S1, Runtime закэшировал его. Затем callback плагина меняет `mode`/другие values; S2 скрывает поле, меняет его тип или сужает диапазон. Interpreter, account и `wireToken` прежние. `settingsSchemaToken` содержит только account/epoch, а `pruneSettingsSchemas` проверяет только их. Обычный `set_setting` проходит через native storage без инвалидирования этого кэша (`python/exteraless_runtime/_settings.py:23–34`). SDK действительно вызывает `instance.create_settings()` заново, а не объявляет схему постоянной (`python/sdk/extera_utils/plugin_loader.py:3420–3427`).

Экспорт читает **актуальный файл** через **старую S1**. Restore аналогично использует S1: `frozenSettingsLocation` снимается ещё **до** Host drain/unload; те могут дополнительно изменить values. Кроме того, экспорт передаёт в detached task уже отвязанную `ToolsBackupPluginLocation`: истечение owner или замена source после получения location больше не проверяются. В location нет source/settings revision либо проверки её актуальности.

**Impact.** Поле, которое текущая схема уже не разрешает, остаётся разрешённым для экспорта/записи; старый диапазон продолжает валидировать новые значения. Проверка owner на входе не доказывает соответствие schema прочитанным/восстанавливаемым данным. Изменение классификации поля может нарушить исключение непубличных данных.

**Fix/test.** Связать schema evidence с конкретными source и settings snapshot/revision, а не только epoch; инвалидировать на изменении зависимостей и проверять evidence в точке чтения/применения, в том числе после drain. Для произвольно динамической схемы нужен явно гарантированный immutable contract либо отказ/пропуск при отсутствии доказательства. Экспорт/inspection должны остаться data-only. Fixture: S1 → изменение values без reload → S2; отдельно изменение в unload и замена source/owner между `pluginLocation()` и чтением. Старое разрешение не должно экспортировать/восстанавливать поле; ни один тест не должен вызывать Python для самого экспорта.

### HNS-02 · P1 — Cleanup требует active owner, которого Host уже скрыл перед unload

**Места:**

- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginServices/PluginNativeServicesBridgeExtension.swift:155–158`, `:180–190`, `:248–251`.
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIBridgeExtension.swift:118–120`, `:300–303`.
- `swift/PluginHost/Sources/PluginHost/PluginHost.swift:252–259`, `:465–474`, `:835–866`.
- `python/exteraless_runtime/_callbacks.py:66–71`, `:130–142`; `__init__.py:164–178`, `:212–223` в том же каталоге.

**Сценарий.** У исправного плагина остался long-delay `postToOwner`, persistent native subscription или открытый UI lease. Host начинает retirement, ставит `unloading[id]`, затем вызывает SDK unload. `callbackOwner()` уже возвращает nil; при maintenance дополнительно закрыт callback admission. `CallbackLeases.end()` вызывает native cancel/dismiss. Но `cancelOwnerTask`, `nativeServiceCancel`, `notificationUnsubscribe`, UI dismissal требуют `captureOwner`, то есть **active**, не retiring owner. Получается `InvalidHandle`/`ServiceUnavailable`, хотя C token принадлежит именно уничтожаемому lifetime и общий bridge validator разрешает его cleanup.

`CallbackLeases.end()` собирает такую ошибку и пробрасывает её. Даже если последующее native destruction полностью успешно, `retireForSettingsMaintenance` после cleanup снова бросает `unloadError` на строке 866. Первый maintenance не возвращает file lease, Host остаётся в recovery. Для file/intent удалений тот же native отказ часто маскируется best-effort SDK cleanup; поэтому их одних недостаточно для утверждения, что любой unload бросит ошибку.

**Impact.** Штатные открытые native ресурсы превращают restore/master-off/safe-mode transition в ошибку maintenance. Fake engine, возвращающий `null` на строку unload, этого не обнаруживает.

**Fix/test.** Cleanup endpoints должны сверять переданный immutable token с **сохранённым owner конкретного lease**, разрешая только отзыв своего ресурса без выдачи нового active-owner capability. Уже имеющийся пример подхода — `PluginPillBridgeExtension.swift:215–228`. Real-CPython fixture: оставить scheduler/subscription/UI lease, выполнить maintenance, проверить успешный lease, единственный native cancel/release и запрет новых эффектов из retiring owner.

### HNS-03 · P1 — Обычные NativeServices callbacks не проверяют account/permission на worker

**Места:**

- `swift/PluginHost/Sources/PluginHost/NativeServiceCallback.swift:154–168`.
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginServices/PluginNativeServicesBridgeExtension.swift:81–91`, `:261–271`, `:433–453`, `:579–592`.
- `swift/PluginHost/Sources/PluginHost/PluginCallbackDispatcher.swift:85–88`, `:202–205`.

**Сценарий.** Ответ `nativeGetUser`/`nativeDownload` либо очередное значение `nativeObservePeer` принят `.send()` и ждёт занятого owner-worker. Затем account scope удалён/заменён или отозвано `messages.read`/`files`. `makeLease.isCurrent` умеет проверять scope/permissions, но `.send()` использует его **только при постановке**. Production callback closure вызывает `dispatcher.callback` без `shouldExecute`, следовательно worker получает `{ true }` для этих ограничений.

Account teardown закрывает native lease и ставит release в FIFO **после** уже принятого callback. Это ещё не закрывает Python wrapper: SDK узнаёт о закрытии при выполнении `release_handles_json`. Поэтому callback перед release действительно может исполнить пользовательское тело со старым payload. Host проверяет interpreter generation, но account generation/permission в его handle не закодированы.

**Impact.** После отзыва доступа/замены аккаунта доставляются старые account data и запускаются их user callbacks; такой callback может создать UI-эффект уже в новом текущем account scope. Notification/result route защищён `NativeServiceCallbackControl`; проблема именно в admission-only `.send()` route.

**Fix/test.** Передавать immutable, отзывной execution guard до actual worker для каждого callback. Для terminal delivery guard должен сохраняться после закрытия native admission, иначе terminal callback всегда будет пропущен. Fixture: заблокированный worker → принять ответ/значение → заменить account или отозвать permission → отпустить worker. User body не выполняется, release остаётся в правильном FIFO и выполняется один раз.

### HNS-04 · P1 — Старые settings controls могут выполнить mutation после смены account scope

**Места:**

- `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift:368–379`, `:444–475`.
- `telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginSettingsController.swift:54–64`, `:309–335`.
- `swift/PluginHost/Sources/PluginHost/PluginHost.swift:1071–1085`, `:1485–1512`.

**Сценарий.** Страница аккаунта A проходит `requirePluginSettingsScope`, ставит update/click, а worker занят предыдущим вызовом. Runtime переключается на B; страница правильно помечается expired. Но `Host.updateSetting`/`clickSetting` уже поставили вызов с default `shouldExecute = true`; к нему не передаются account scope, rendered-settings revision или ожидаемый owner страницы. Если interpreter тот же, worker пропускает mutation. Есть и окно до захвата target: Runtime сначала awaits `operationHost()`, после чего Host заново разрешает pluginId.

Проверки после `actions.settings` защищают отображение результата, а не уже выполненную запись/`on_change`/`on_click`. Python `setting_changed_json` и `setting_click_json` входят в `_scope(platform)` без account (`python/exteraless_runtime/__init__.py:344–360`), поэтому побочные действия callback могут пользоваться новым selected account.

**Impact.** UI визуально отозван, но старое действие меняет settings или запускает callback после account replacement; в соответствующем race возможен вход в другой interpreter lifetime.

**Fix/test.** Захватывать expected owner и lock-only account/settings execution token в момент действия; передавать их до predicate на actual owner-worker, а account — в SDK scope. Нельзя синхронно ждать MainActor из этого predicate. Fixture: принять click/change A за заблокированным worker, заменить scope, затем освободить очередь; ни запись, ни пользовательский callback не происходят. Отдельно проверить reload между предварительной scope-проверкой и Host admission.

### HNS-05 · P1 — UI provider обходит bounded native-effect admission

**Места:**

- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIBridgeExtension.swift:267–291`.
- `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift:207–209`.
- Для сравнения: `telegram-ios/submodules/TelegramUI/Sources/Exteraless/TelegramPluginServices.swift:225–260`; `swift/PluginHost/Sources/PluginHost/BridgeServices.swift:215–235`.

**Сценарий.** SDK `copy_to_clipboard` вызывает Runtime `addToClipboard`. Первым его забирает `ui` в composite. Этот route принимает bounded **один** текст, но для каждого вызова без count/aggregate-byte reservation создаёт `DispatchQueue.main.async`, удерживающий текст. `openURL` устроен аналогично. Более поздний `TelegramPluginServices.effectBudget` здесь вообще не вызывается.

**Impact.** При занятой main queue либо producer быстрее consumer число closures и суммарный payload не ограничены. Проверка owner перед фактическим эффектом предотвращает stale эффект, но не ограничивает накопленную память. Callback/UI presentation quotas на эти операции не распространяются.

**Fix/test.** Резервировать count/bytes синхронно до main hop и удерживать reservation до завершения/освобождения фактической работы, включая deferred URL barrier; либо объединить route с уже бюджетируемым platform effect. Fixture с ручной main-work queue и маленькими лимитами: переполнение возвращает отказ до enqueue, выполняющаяся/терминальная работа всё ещё занимает кредит, смена owner не позволяет бесконечно накапливать отменённые closures.

### HNS-06 · P1 — `maxQueueDepth` практически не ограничивает non-TL event ingress

**Места:**

- `swift/PluginHost/Sources/PluginHost/PluginEventQueue.swift:127–128`, `:148–205`.
- `swift/PluginHost/Sources/PluginHost/ExtensionPoints.swift:319–347`.
- Upstream: `swift/PluginHooks/Sources/PluginHooks/PluginHookRouter.swift:78–98`; native handoff — `telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift:941–945`.

**Сценарий.** Host dispatch занят, а pre/post observations продолжают поступать. Они имеют request priority и не проходят условие drop на строках 195–196 (`priority >= updates`). Update/updates вообще возвращаются из coalescing-ветки на строке 188 **до** этой проверки: есть лимит одного bucket, но нет общего лимита количества buckets/bytes. Awaited send/settings также обходят общий предел. Реальный строгий depth/byte admission добавлен лишь для `.tlTransform`.

256-event upstream quota не ограничивает этот backlog: `releaseObservation()` вызывается, когда handler только создал следующий MainActor Task, до обработки Host event. `submitAsync` добавляет ещё один небюджетируемый Task hop.

**Impact.** Документированный предел 1024 не является верхней границей retained non-TL событий; длительный поток при медленном, но не зависшем плагине способен неограниченно удерживать JSON/Tasks. Таймаут одного вызова не исправляет producer/consumer imbalance.

**Fix/test.** Общие count/byte reservations для всех ingress routes, включая coalesced items и pre-actor hops; удерживать кредит до фактического окончания retained work. Явная overflow policy для fire-and-forget и typed rejection для awaiting. Маленький fixture: blocked handler, `maxQueueDepth = 2`, несколько pre/post и update keys; проверить фактическое число удержанных/доставленных событий и bytes, а не только счётчик enqueued.

### HNS-07 · P2 — Batch timeout не владеет точным набором invocations и не отзывает оставшийся fanout

**Места:**

- `swift/PluginHost/Sources/PluginHost/PluginHost.swift:375–396`, `:1338–1363`, `:1449–1477`, `:1536–1542`.
- `swift/PluginHost/Sources/PluginHost/PluginEventQueue.swift:269–279`, `:305–333`.

**Сценарий.** Event batch выполняет A/B. Параллельно C, не подписанный на этот event, выполняет обычный UI callback. `beginBatch` сохраняет **все** handles, а `batchInflightSnapshot` пересекает их с общим `inflight`, куда попал C. При истечении batch deadline Host вызывает `reportTimeout(C)`, хотя callback C только начался и его собственный timeout не истёк.

Одновременно `withDispatchTimeout` не отменяет handler. После abandon B старый non-TL handler ловит ошибку и продолжает `for target in subscribers`; не начатый D может войти в Python уже после возврата timeout/native fallback. Следующий batch способен работать параллельно с остатком предыдущего. Generation checks защищают replacement interpreter, но не устанавливают принадлежность invocation к batch.

**Impact.** Неверное `notResponding`/abandon независимого плагина и поздние user hooks после завершённого native решения. Это не ошибка TLS ancestry: causal origin и timeout ownership — разные механизмы.

**Fix/test.** Отдельный batch capability и учёт invocations по его id; timeout отзывает дальнейший fanout и worker admission только этого batch. Сохранить учёт уже исполняющейся native работы до её реального исхода. Fixture: C callback вне batch остаётся живым, D после timeout не вызывается, новый batch не наследует старые timeout victims. Для native send cancellation аналогично довести отзыв до Host predicate, а не только подавить completion в MainActor Task.

### HNS-08 · P2 — Отменённый watchdog timer удаляет маркер следующей загрузки

**Места:**

- `swift/PluginHost/Sources/PluginHost/PluginWatchdog.swift:222–246`.
- `swift/PluginHost/Sources/PluginHost/PluginHost.swift:1216–1222`, `:1262`.

**Сценарий.** A загрузился и вызвал `scheduleMarkerClear`. Начинается B: `noteRiskyOperation(B)` отменяет timer A и записывает B. Отмена прерывает `Task.sleep`, но `try?` поглощает её; старый task всё равно вызывает `clearMarkerNow()`. Тот удаляет текущий маркер B и может отменить уже новый clear task. Это достижимо и в обычной последовательной загрузке enabled plugins, и при resume.

**Impact.** Падение внутри B перестаёт иметь правильную plugin attribution; strike/recovery может не отключить виновника. Проблема в существующем timer-коде, используемом новым lifecycle, а не в C clear.

**Fix/test.** Возврат при cancellation плюс generation/marker identity check непосредственно в actor перед clear. Проверять также перекрывающиеся risky loads. Fixture: A scheduled clear → B entered → завершение отменённого A task; маркер должен оставаться B до окончания B и его собственного idle interval.

### HNS-09 · P2 — Stop снова навечно ждёт destruction, уже признанный timed out maintenance

**Места:**

- `swift/PluginHost/Sources/PluginHost/SubinterpreterManager.swift:469–484`, `:487–510`, `:565–570`.
- `swift/PluginHost/Sources/PluginHost/PluginHost.swift:730–766`.
- Native boundary: `python/runtime/engine.c:366–378`; `python/runtime/cpython312_compat.c:43–52`.

**Сценарий.** SDK unload вернулся, но native `destroyInterpreter` завис, например в `atexit` внутри `Py_EndInterpreter`. Maintenance корректно завершает ожидание по deadline и сохраняет `.destroying`/mailbox evidence. Затем вызывается `stop()`. Его попытка invoke получает отказ для `.destroying`, после чего `destroyAll()` вызывает `destroy()`. Для `.destroying` `beginDestruction` возвращает старый completion, а `destroy()` ждёт его с `cancellable: false`, без deadline.

Проверка дополнительных Python threads перед `Py_EndInterpreter` не исключает зависание самого `atexit`; код даже специально закрывает создание threads перед его выполнением.

**Impact.** Ошибка bounded maintenance превращается в неограниченное ожидание `Runtime.terminate()`. Provider cleanup и no-finalize shutdown decision расположены после этого ожидания и не достигаются. Доказательства живого worker сохранены правильно; проблема — повторный безусловный await.

**Fix/test.** Bounded terminal drain для already-destroying/unknown native work; после исчерпания бюджета сохранить pool slot/evidence, запретить finalize и завершить native provider retirement без ожидания Python. Нельзя отмечать interpreter destroyed или терять mailbox при timeout. Fixture: задержанный `onDestroy` → maintenance timeout → stop завершается в бюджете с finalize count 0 → поздний реальный exit корректно обновляет только старый slot.

## Проверенные границы и ограничения вывода

- **Exclusive maintenance / recovery:** reservation до первого await, single-decision finish, ожидание принятого dispatcher work, pause manager, строгая проверка пустого Host/manager и suppression resume при stop прослеживаются в `PluginHostLifecycle.swift:145–155,205–287,289–316` и `PluginHost.swift:778–910`. Ни begin, ни finish maintenance не вызывают finalize. Не найден путь выдачи lease при известном pending/abandoned interpreter.
- **Unknown/abandoned evidence:** `SubinterpreterManager.swift:281–310,368–400,513–537` сохраняет pending creation / abandoned slot и ждёт mailbox exit после успешного native destroy. Отмена наблюдателя не делает destruction успешным. HNS-09 относится к terminal ожиданию этих evidence.
- **Owner binding / rollback:** Host публикует случайный token и связывает C до user load (`PluginHost.swift:1220–1233`). C инжектирует identity из immutable state (`python/bridge/_exteraless_bridge.c:1961–2000,3202–3249`); native handle transaction получает success/failure результата (`:2147–2184,3252–3279`). Retiring cleanup admission на общей границе существует; HNS-02 — несогласие consumers с ним.
- **Dispatcher FIFO / budgets:** callback, result и release проходят одну owner FIFO; executing work учитывается до `finished`, cancellation result-waiter не освобождает queued reservation (`PluginCallbackDispatcher.swift:117–218`). Release retry в NativeServices сохраняет pool credit до принятия release (`NativeServiceReleaseQueue.swift:25–72`). Это ACK **admission в FIFO**, не ACK фактического DECREF; после admission работу учитывает dispatcher.
- **Result против admission / void:** before intent принимает только actual JSON Bool true, file callback — любой успешный результат (`NativeServiceOpenBarrier.swift:101–119`). Production result transport awaits `dispatcher.result` (`NativeServiceCallback.swift:79–103`). SDK adapters для file/UI/Runnable/TL delegate нормализуют ignored return в `None`; `invoke_handle_json` сериализует его как JSON `null`. Основания повторять дефект «admission true = handled» в этих путях нет.
- **Cancellation publication:** `NativeServiceCallbackControl.bindCancellation`, pending result pins, `NativeServiceOperations.bindCancellation` и `TLRequestRegistry.bindCancellation` учитывают finish-before-bind. Account snapshot publisher tokens и notification delivery controls отсекают устаревшие публикации; для admission-only callbacks действует HNS-03.
- **Ancestry:** worker устанавливает конкретный `PluginTLInvocationScope`, callback registry связывает его с owner/handle; fanout исключает только `originPluginIds`, а siblings не добавляются в общий mutable origin (`PluginHost.swift:1370–1416,1492–1512`, `PluginTLInvocationOrigin.swift`). Проверенные direct/TL-result routes не дают основания заявлять global skip всех plugins.
- **MainActor:** reverse Python calls асинхронны; holding Host/lifecycle locks не охватывает вызов Python. PluginUI readback имеет 750 ms bound и read-only body. Реального native run для подтверждения всего lock graph нет.
- **Data-only / readonly:** актуальный `PluginServiceStorage.settingsDirectoryURL()` не делает mkdir; Tools export/inspection не вызывают `create_settings`. Исправленный TB07 не переоткрывается. HNS-01 касается актуальности schema evidence, а не наличия readonly accessor.
- **Тестовый пробел:** `HostLifecycleTestSupport.swift:64–79` и `NativeServiceDispatcherTests.swift:9–15` отвечают заранее заданным JSON, не исполняя SDK unload/registration cleanup. Green Linux Host/Hooks/Core полезен для моделей, но не снимает HNS-02 и native composition findings. Рекомендуемые fixtures выше — короткие собственные сценарии; внешние плагины и реальные аккаунтные действия для них не нужны.
