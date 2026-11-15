# Independent review — privacy / hidden accounts / retention

**Verdict: REQUEST CHANGES; полного pass нет.** Review от 2026-11-15, working tree над `ddc25d69`, включая незакоммиченные изменения других авторов. A–D из `privacy-extras-remediation.md` действительно исправлены в исходниках. Это не закрывает перечисленные ниже consumer/lifecycle defects и retention integration gates.

Прочитаны `telegram-ios/AGENTS.md`, полный `telegram-ios/CLAUDE.md`, `privacy-phase-2.md`, `privacy-extras-integration.md`, `privacy-extras-remediation.md`, `retention.md`, четыре retention patch handoff и `tools-retention-handoff.md`; сверены реальные Swift/Postbox consumers и оригинальные Java/Kotlin boundaries. Reviewer изменяет только этот файл.

Все findings ниже — **source conclusions**, не результаты запуска приложения. Ссылки относительно корня репозитория. Номера строк относятся к проверенному working tree; shared integration продолжалась во время review.

## P1

### PR01 — Chat-list projection вызывает Postbox precondition даже при выключенных фильтрах

- **Source:** `telegram-ios/submodules/TelegramCore/Sources/ExteralessPrivacyExtras/ExteralessFilteringSummaries.swift:38–43,59–60,125–130`; `telegram-ios/submodules/Postbox/Sources/Postbox.swift:1087–1092`; `telegram-ios/submodules/Postbox/Sources/MessageHistoryTable.swift:3293–3295`; `telegram-ios/submodules/Postbox/Sources/Message.swift:200–205`.
- **Минимальный сценарий:** один обычный chat-list item; все local filters выключены. `extrasChatSummary` всё равно вызывает `getMessages` с `.absoluteUpperBound()` / `.absoluteLowerBound()`. Они имеют разные peer и namespace (`PeerId.max/127` против `PeerId(0)/0`), а `fetch` требует равенства обоих. Активная ветка использует те же неверные границы.
- **Impact:** детерминированный trap основного списка; также затронуты filtered badge/summary callers. Privacy phase-2 починила bounds в observations, но этот файл в её fixtures не входит.
- **Regression/fix:** peer+namespace-local bounds на каждой странице; для неактивной проекции не выполнять ненужный preview lookup. Маленький native Postbox fixture с одной строкой: filters off/on, ordinary/forum/secret; настоящий `exteralessFilterChatList`, не только policy-модель.

### PR02 — Автоматический contents-read получает explicit authorization, переживающую изменение политики

- **Source:** `telegram-ios/submodules/TelegramCore/Sources/State/ExteralessPrivacyPolicy.swift:17–33,38–45,98–110`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLNetworkRequest.swift:247–250,269–285`.
- **Минимальный сценарий:** automatic `exteralessReadMessageContents` проходит `allow()`; async TL prefix приостановлен; пользователь выключает receipts либо удаляет peer exception; prefix возвращает исходные bytes. Descriptor сохраняется, а его запись в `ExteralessExplicitReadRequests` проверяется **до** актуальных validated metadata/policy.
- **Impact:** automatic read уходит после отзыва разрешения. Это не проблема переноса exemption на изменённые bytes: такой перенос уже предотвращён. Ошибка — присвоение automatic request того же безусловного bypass, который нужен ручному explicit read.
- **Regression/fix:** отделить ручной grant от account/peer metadata автоматического request и перепроверять automatic policy непосредственно при admission. Fake suspended prefix + synthetic Network/transport recorder: unchanged bytes, policy revoke, zero submissions; отдельный контроль настоящего explicit read. Не запускать внешний plugin или реальные RPC.

### PR03 — Main-app notification использует устаревшее решение после async hops

- **Source:** `telegram-ios/submodules/TelegramCore/Sources/ExteralessPrivacyExtras/ExteralessFilteringNotifications.swift:10–19`; `telegram-ios/submodules/TelegramUI/Sources/ApplicationContext.swift:294–318,365–391,420–422`.
- **Минимальный сценарий:** batch разрешён в filtering transaction; остановить последующий `EngineData`/lock-state callback; скрыть account или добавить matching filter; отпустить callback при unlocked app.
- **Impact:** сохранённые `messages` доходят до sound/vibration и `ChatMessageNotificationItem` без повторной проверки hidden state/filter generation. Удаление уже доставленных OS notifications не отменяет этот in-flight in-app alert. Extension имеет delivery gate, main-app consumer — нет.
- **Regression/fix:** переносить identity+generation до конечного presentation boundary; перед звуком и enqueue перепроверять/переоценивать batch, отменять устаревший. Tiny controlled signals и recorder вместо звука/notification UI; обе смены политики, late completion и once-only delivery.

### PR05 — Missing retention scope: NotificationService standalone replay не получает retention owner/settings

- **Source:** `telegram-ios/Telegram/NotificationService/Sources/NotificationService.swift:957–979`; `telegram-ios/Telegram/NotificationService/Sources/ExteralessNotificationPrivacy.swift:21–25,34–42`; `telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift:1813–1833,1945–1956`, `standaloneStateManager` (`openPostbox(isMainProcess: false, isReadOnly: false)` → прямой `AccountStateManager`); `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionHooks.swift:16–18,44–46`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionAccount.swift:52–67,88–93`.
- **Минимальный сценарий:** main app suspended; extension получает update/delete для уже локально сохранённого сообщения и коммитит poll/replay. Здесь не создаётся `Account`, следовательно Account-owned observer/registry lease отсутствует. Extension также регистрирует только `PrivacyFeatures` + `PrivacyExtrasFeatures`, поэтому retention flags из файла не попадают в его registered settings snapshot.
- **Impact:** before-upsert capture не установлен, delete helper не находит owner; stock replay удаляет/заменяет единственную старую строку. Открытие app позже её уже не восстановит. Применённый Account lifetime hunk закрывает обычные Accounts, **но не эту отдельную запись в тот же Postbox**.
- **Gate/fix:** отдельно связать lifetime/settings/bootstrap standalone writer до replay и teardown, согласовать межпроцессное media ownership. Это конкретный недостающий scope, а не утверждение, что весь retention ещё не подключён. Regression — synthetic standalone Postbox writer, before-image edit/delete, неизменные PTS/QTS/seq, без Account login/APNs/network.

### PR14 — Share запускает destructive retention prune с defaults другого process role

- **Source:** `telegram-ios/Telegram/Share/ShareRootController.swift:47–54`; `telegram-ios/submodules/TelegramUI/Sources/SharedAccountContext.swift:655–674`; `telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift:299–312,1336–1348`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionAccount.swift:63–67,188–200`; `swift/ExteralessCore/Sources/ExteralessCore/RetentionPolicy.swift:139–141`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionStore.swift:198–205,353–355,377–390`.
- **Минимальный сценарий:** пользователь выбрал retention 90 дней и имеет 60-дневную retained строку. Открыть Share. Extension регистрирует только Privacy/PrivacyExtras; `ClientSettings` публикует значения только зарегистрированных definitions (`ClientSettings.swift:741–759`). Supplementary Account теперь безусловно создаёт retention owner, который на первом index emission выполняет `refresh(prune: true)` с `.current`: в этом процессе это default **30 дней**.
- **Impact:** простое открытие Share удаляет допустимую по пользовательской политике историю; более высокие message/media limits также сбрасываются до default при этом prune. `saveDeleted == false` по умолчанию не защищает от maintenance deletion. Это последствие уже применённого H2, а не отсутствующей UI кнопки.
- **Regression/fix:** каждый writing process должен загрузить/зарегистрировать полную retention policy до создания owner; при unavailable policy maintenance не должен выбирать destructive defaults. Tiny independent main/extension settings caches + synthetic aged Postbox row: opening supplementary owner сохраняет строку при 90 днях и корректно удаляет при явно заданных 30, без реального Share/account/network.

## P2

### PR04 — Реальный history caller теряет cancellation и захватывает observation epoch слишком поздно

- **Source:** `telegram-ios/submodules/TelegramCore/Sources/State/AccountViewTracker.swift:1975–2005`; `telegram-ios/submodules/TelegramCore/Sources/State/ExteralessPrivacyObservations.swift:189–205,250–262`.
- **Минимальный сценарий:** history `next` уже поставлен на tracker queue; выполнить Clear observations и dispose history; затем выполнить queued block. Только теперь вызывается `exteralessObserveLoadedMessages`, захватывается **новый** epoch и запускается discarded `.start()`.
- **Impact:** старый batch может снова заполнить очищенные observations; dispose history не отменяет созданную observation subscription. Per-subscription guard в helper корректен, но фактический caller не удерживает его disposable.
- **Regression/fix:** capture epoch/work при приёме batch, связать work с lifetime конкретного history subscription и отменять на dispose. Fixture удерживает queue до clear/dispose и проверяет отсутствие записей после drain; другая subscription/account продолжает работать.

### PR06 — `SecretIncoming` ошибочно исключён из retention и secret unread projection

- **Source:** `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionStore.swift:252–256`; `telegram-ios/submodules/TelegramCore/Sources/State/ProcessSecretChatIncomingDecryptedOperations.swift:303–309,578,911`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessPrivacyExtras/ExteralessFilteringSummaries.swift:27–31,60–64,83–99`; `telegram-ios/submodules/TelegramCore/Sources/SyncCore/SyncCore_Namespaces.swift:5–8`.
- **Минимальный сценарий:** реально полученное secret message имеет namespace `SecretIncoming == 2`, тогда как eligible predicate разрешает только secret `Local == 1`. Remote clear захватывает только Local, затем stock clear удаляет `.all`.
- **Impact:** входящие secret messages/media теряются при remote delete/TTL/clear несмотря на включённый retention. После PR01 fix secret summary всё равно смотрит только outgoing Local: пропускает incoming preview/unread, выдаёт неполную проекцию.
- **Regression/fix:** явно поддержать оба настоящих secret namespaces; scan/capture каждого с локальными bounds и общим бюджетом, без слияния одинаковых numeric IDs. Две tiny native строки Local/SecretIncoming; отдельные delete, remote clear, TTL и filtered unread assertions.

### PR07 — Retained overlay возвращает скрытый текст/отправителя поверх уже отфильтрованной history

- **Source:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Retention/ExteralessRetentionHistoryAdapter.swift:25–47,54–67,91–98`; `telegram-ios/submodules/TelegramUI/Sources/ChatHistoryListNode.swift:2420–2422`, вызов `exteralessRetentionMergeDisplayEntries(baseFilteredEntries, retained: update.5, ...)`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessPrivacyExtras/ExteralessFiltering.swift:299–324`.
- **Минимальный сценарий:** message скрыт sender/regex filter и сохранён retention; сервер удаляет его. `liveIds` больше не содержит id, retained reader возвращает snapshot, merge добавляет его **после** privacy-filtered base без privacy decision.
- **Impact:** скрытое сообщение вновь появляется в обычном чате после удаления. Retained reactions также обходят presentation filtering. H7 callsite и root registration/lifecycle появились во время review; source composition уже имеет этот обход.
- **Regression/fix:** композиция privacy с retained display messages до merge, с теми же account/namespace/thread/album semantics и bounded budget. Не фильтровать второй раз уже спроецированные native counts. Tiny live→deleted fixture для sender, reply-sender, regex и смешанного альбома; backing history/read state неизменны.

### PR08 — Retention album merge сравнивает только `groupingKey`

- **Source:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Retention/ExteralessRetentionHistoryAdapter.swift:70–84,91–94`; для сравнения полный key в `telegram-ios/submodules/TelegramCore/Sources/ExteralessPrivacyExtras/ExteralessFiltering.swift:353–366`.
- **Минимальный сценарий:** live и retained entries имеют одинаковый groupingKey, но разные message namespace/thread. Условие merge принимает их как один album; guard на peer/namespace/thread отсутствует. Для нового retained-only альбома raw groupingKey также подставляется вместо native group-stable-id policy.
- **Impact:** смешиваются разные album scopes, меняется selection/menu/opacity grouping и identity display entry. Это отдельный дефект от исправленного B notification album helper.
- **Regression/fix:** один полный album key и согласованный native display-group identity allocator. In-memory pairs с одинаковым key и разными namespace/thread должны остаться раздельными; совпадающий полный scope должен объединиться один раз, с устойчивым stable ID.

### PR09 — Native archive fetch обходит expiry check Engine facade

- **Source:** `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionLocalMedia.swift:96–104`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionAccount.swift:355–399,411–420`; защищённый facade для сравнения: `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionEngine.swift:226–250`.
- **Минимальный сценарий:** уже показанный archive resource пересекает retention deadline до следующего 60-second prune; native fetch запрашивает его по LocalFile ID. `materialize` проверяет raw index/epoch/token, но не наличие неистёкшего version owner и не cutoff.
- **Impact:** expired archive bytes могут быть восстановлены и выданы native reader после deadline. Проверки `retainedMedia` не помогают: `State/Fetch` идёт непосредственно в `owner.materialize`.
- **Regression/fix:** lifetime/ownership/expiry admission и повторная проверка перед выдачей должны быть общими для обоих путей. Tiny four-byte resource, controlled clock/near-expiry fixture, no prune event: native fetch должен terminal-fail без cloud fallback, Engine reader — тот же результат.

### PR10 — Clear теряет ownership plaintext copies, если ciphertext filename уже отсутствует

- **Source:** `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionAccount.swift:449–471,476–493,520–532`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionMediaVault.swift:134–143`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionStore.swift:384–405`.
- **Минимальный сценарий:** materialized retained resource имеет native complete file и extension alias; его `.bin` утрачен. Clear удаляет manifest entry (full reset — весь index), затем GC выводит удаляемые native IDs исключительно из существующих orphan `.bin` filenames.
- **Impact:** GC получает пустой set для этого ресурса, clear сообщает success, а plaintext copy/aliases остаются в MediaBox. Это не cloud refetch и не чужой ресурс: прежний manifest точно знал его ownership.
- **Regression/fix:** durable scoped deletion manifest/IDs до удаления основного index; union с обнаруженными ciphertext orphans, resume после прерывания. Fixture с четырьмя байтами и удалённым fixture `.bin`: message clear и full reset должны убрать только соответствующие complete/alias/derived files.

### PR11 — Vault success/recovery не замыкает directory durability barrier

- **Source:** `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionMediaVault.swift:16–24,37–45,68–76`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionAccount.swift:250–257,307–319`.
- **Минимальный сценарий:** first capture создаёт vault directory; parent directory link не синхронизируется. Отдельно: rename `.bin` прошёл, directory fsync завершился ошибкой; при retry existing-file recovery делает только authenticated read и сразу acknowledge, не повторяя failed fsync.
- **Impact:** `.stored` может публиковаться без выполненного durability barrier для каталога/rename. Это source-level отсутствие требуемых sync steps, **не воспроизведение power loss**.
- **Regression/fix:** sync newly created directory chain до заранее durable account/container root; recovery обязан завершить те же barriers перед ack. Injected filesystem recorder/fail-once fsync, tiny ciphertext; не тестировать отключением питания или реальными account files.

### PR12 — Panic notification cleanup выполняется до identity admission

- **Source:** `telegram-ios/submodules/TelegramCore/Sources/ExteralessPrivacyExtras/ExteralessHiddenAccounts.swift:404–424,447–452`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PrivacyExtras/ExteralessPrivacyExtrasIntegration.swift:45–46`; `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Privacy/ExteralessNotificationClearing.swift:11–14,38,56–64`.
- **Минимальный сценарий:** consume valid configured/manual panic grant; target record уже имеет другой backup peer/environment либо не имеет достаточной identity metadata. CAS правильно отвергает logout, но `panicDidBegin` уже передал все planned record IDs в `clearAll`.
- **Impact:** очищаются notifications/diagnostics не прошедшего admission record; при замене identity — другой identity. Native logout, TempBox и private-field cleanup имеют правильный transaction-time guard; дефект относится именно к предварительному notification callback.
- **Regression/fix:** callback только для реально admitted identities после transaction result. Injected AccountManager-record/effects recorder: mismatch/missing metadata даёт **ноль любых** cleanup effects. Не вызывать production panic/logout/UNUserNotificationCenter в тесте.

### PR13 — Filtering collection writer публикует observers под внешним recursive lock

- **Source:** `telegram-ios/submodules/TelegramCore/Sources/ExteralessPrivacyExtras/ExteralessFiltering.swift:28–31,42–48,101–115,117–127`; `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:336–339,426–428`.
- **Минимальный сценарий:** `setPeer`/`setCollection` держит runtime recursive lock и вызывает synchronous `ClientSettings.set`; его observer входит в `reload`, освобождает только вложенное acquisition и вызывает `changesPromise.set`. Subscriber ждёт read `runtime.policy` с другой queue — writer держит lock, reader ждёт его, writer ждёт subscriber.
- **Impact:** cross-thread observer reentry deadlock при редактировании фильтров. Правильный outermost-unlock drain, добавленный для hidden C, в FilteringRuntime не применён.
- **Regression/fix:** публиковать после внешнего release, сохранить сериализацию read-modify-write и монотонность revisions. Tiny injected observer с reader на другой queue и bound 0.5 s, как native hidden-C regression; timeout должен давать failure, не зависший test process.

## Что действительно применено / что ещё pending

Сверка по source, а не только по handoff. Во время review появились Account/state, enqueue, privacy-import API, UI hunks, затем root registration и async preparation. Старые слова «pending» в `retention.md` не являются доказательством их отсутствия. Конкретные оставшиеся extension scopes — PR05/PR14; runtime/build/frame acceptance остаётся pending.

| Gate | Source state на последней сверке |
|---|---|
| Central cache allocation | **Applied:** `telegram-ios/submodules/TelegramCore/Sources/SyncCore/SyncCore_Namespaces.swift:174–176`, 63; privacy/blocked/retention используют разные prefixes. Collection-wide clear в проверенных helpers отсутствует. |
| Hidden A | **Applied-source:** actual primary + foreground + `accountPresentationReady(for:)`, timeout 5 s, затем opaque `finishUnlock`. Root readiness публикуется после `context.isReady`, identity check и `mainWindow.viewController = context.rootController` (`AppDelegate.swift:1603–1618`; `ExteralessClientRuntime.swift:380–389`). Native/runtime/frame proof pending. |
| Hidden C/D | **Applied-source:** outermost lock publication drain, `ObjectIdentifier(Account)` replacement, separate presentation/config revision, unknown snapshot versus confirmed-empty. Expected A→B не вызывает full extras teardown. |
| Native authentication | **Applied-source:** ordinary crypto PIN имеет priority и cooldown (`Passcode.swift:514–540`); alternate success не создаёт PasscodeSession. PasscodeUI ограничивает routing настоящим main-app `displayAppLock` и `.appUnlock`, проверяет lifecycle/attempt, cancel только собственного non-nil attempt. Biometry выбирает visible identity без panic. Settings entry выдаёт настоящий PIN-only `.settings` session (`PasscodeAuthenticationController.swift:14–74,76–111`). |
| Private store / SC07 callers | **Applied-source:** root, NotificationService и Share передают OS container URL, существующий `PasscodeEnvironment.sharedAccessGroup()` и scope. Private definitions не регистрируются в shared store. Backend использует `AfterFirstUnlockThisDeviceOnly`, `Synchronizable=false`; нет in-memory fallback. Это source wiring, не проверка entitlement/signing/Keychain на устройстве. |
| Read / typing / presence | **Applied-source:** typed suppression возвращает nil/false/completion и оставляет native finalizers; `SynchronizePeerReadState.swift:438–456` подтверждает queued operation без fake PTS и server validation против намеренно старого read mark. View-count request использует false increment с настоящим response; presence recomputes по settings и завершает busy state, timer/subscriptions disposed (`ManagedAccountPresence.swift:26–44,47–74`). Final-admission дефект automatic contents-read — PR02. |
| Raw TL metadata | **Applied-source:** exact Network + final descriptor, decode/validate final bytes (`TLRequestPrivacy.swift:150–195`); changed bytes получают новый descriptor (`TLNetworkRequest.swift:247–250`). Mixed/unresolved contents IDs требуют every-peer/global allowance (`PrivacyPolicy.swift:113–117`). Automatic requests не должны заимствовать explicit grant — PR02. |
| Observation rows / quotas | **Applied-source:** separate encrypted per-Postbox rows, first-read preservation, activity expiry на load/maintenance, 50k bounds и один batched read prune. UI queries проверяют account/testing identity и cancellation внутри transaction. Реальная subscription integration ограничена PR04. |
| Filtering B | **Applied-source:** `notificationDisposition` suppress → awaitMessage → allow; оба notification consumers используют общий decision; album key включает peer/namespace/thread/group. Incomplete NFA больше не является allow. PR03 и PR07 — другие boundaries. |
| Exactly-once list projection | **Applied-source:** `ChatListNodeLocation.swift:223–242` → `ExteralessDialogList.swift:66–71` — один privacy pass перед sorting; non-UI `TelegramEngineMessages.chatList` имеет собственный один pass. Native read-state values остаются presentation copies. Functional acceptance блокирует PR01. |
| Post-commit filtering invalidation | **Applied:** все шесть replay callers в `AccountStateManager.swift` имеют `afterNext` после transaction (optional result либо `finalStatte`). Старый HDO про отсутствие этих вставок устарел. |
| Extension deadline | **Applied-source:** per-delivery bound identity/generation; cached и post-poll evaluation; `finish` reloads public/private stores, проверяет gate, делает full-content lock redaction и снова проверяет gate (`NotificationService.swift:2734–2767`). Once-only callback через `PrivacyCompletion`. APNs/deadline execution не проверялись. |
| Retention H1 | **Applied:** Postbox before-upsert/before-update observer, native stable-id reservation, registration/disposal; add/update reentry preconditions (`Postbox.swift:56–59,2203–2213,3094–3118,4723–4732`). Retention callback пишет cache rows, не cloud messages. |
| Retention H2 / replay H3 | **Applied во время review:** Account-owned service, оба eviction-ready barriers и dispose (`Account.swift:1286,1345,1625–1664`); explicit/global/range replay capture + обе force-removal filters (`AccountStateManagementUtils.swift:4664–4689`). **Standalone scope PR05 и supplementary policy PR14 остаются открыты.** |
| Secret/TTL / force removal | **Applied:** secret delete/clear и TTL/media-expiry callsites; четыре `DeleteMessages.swift` force-removal consumers фильтруют ownership. Secret namespace coverage блокирует PR06. |
| MediaBox lifetime / H4–H5 | **Applied-source:** native fetch hook (`State/Fetch.swift:89–91`), synchronous keep admission и size-worker unlink в одном lock; skipped inode group не засчитывается как freed bytes (`TimeBasedCleanup.swift:530–549`). LocalFile remap исключает cloud identity; owned-but-missing fetch terminal-fails. Expiry/clear/durability ограничены PR09–PR11. |
| Retention rows / vault budgets | **Applied-source:** fixed 20k slots, 32 versions/message, 32 MiB index+rows cap, bounded media references и reservation encrypted+native bytes. 256 KiB authenticated chunks с account/epoch/token/resource-length/id/total-length/chunk-index AAD; cancellation между chunks. SQLCipher rows не становятся shared settings. Durable reset marker и 256-row cleanup batches присутствуют; PR10–PR11 ограничивают утверждения об erase/durability. |
| Privacy import APIs | **Applied во время review:** `ExteralessPrivacyObservations.swift:272–303`: epoch work, snapshot, prepared encoded commit. Не отмечать их как missing symbols. |
| New-send deleted quote / H8 | **Applied во время review:** `EnqueueMessage.swift:958–965`; failure возвращает nil на каждый input до native enqueue. Draft preservation, actual native send cancellation и reply/thread/album rendering требуют runtime regression. |
| Retention root / H6 | **Applied в конце review:** `ExteralessClientRuntime.swift:54–60,162,277,294,374` — definitions, owner, construction, update/clear. Ранее замеченное отсутствие root integration больше не является текущим missing gate. |
| Retention UI / H7–H9 | **Applied-source в конце review:** history input/merge (`ChatHistoryListNode.swift:2071–2077,2420–2422`) сохраняет `originalView: view`; side-effect exclusions, early message/poll/todo context menus и reaction/poll/replies/todo guards присутствуют. Найдены все **16** date/status retention arguments из HDO и opacity helper. Functional/read-only/visual acceptance требует native execution; PR07–PR08 остаются. |
| Main Bootstrap async I/O | **Coordinator acceptance pending.** Во время финальной сверки появились serial settings worker (`ExteralessClientRuntime.swift:63–103`) и AppDelegate prepare/ready path (`AppDelegate.swift:909–910,1984–2018`). Это applied-source late change; ни полное asynchronous startup, ни slow-I/O/cancel/retry native behavior, ни frames здесь не сертифицированы. |

### Ayu import: подтверждённые границы и оставшиеся ограничения

- Реальный read-only SQLite adapter: regular-file/64 MiB gate, fixed SQL/table whitelist, `query_only`, `trusted_schema=OFF`, `table_xinfo` rejection generated/hidden columns, 20 s interrupt и общий 16 MiB serialized staging budget (`ExteralessAyuDatabaseReader.swift:75–157,160–205`). Нет загрузки SQL extensions и следования Android media paths.
- Message/read owner `userId` сверяется с настоящим Telegram user id; negative dialog требует однозначный locally-known group/channel или проверенный explicit mapping, Android secret-session IDs не переименовываются в iOS (`ExteralessAyuDatabaseImport.swift:92–145`). `fakeId` используется как reaction foreign key, не native message/stable ID.
- Aux dates: Unix seconds, alias `entityCreateDate` только при **отсутствующем** `date`, zero/null не превращаются в now; first read wins, LastSeenEntity имеет priority перед SpyLastSeen, known users/self handling и quota merge (`RetentionPrivacyImport.swift:31–84,90–143`). Проверено по оригинальным `AyuDatabaseImport.java:167–218,221–317`, `AyuSpyController`, `LastSeenHelper` и `AyuDeletedDialogs`.
- Import сначала готовит snapshots/privacy/descriptors, затем коммитит local cache rows; cloud history/PTS не заполняются. DeletedDialog — отдельный bounded encrypted descriptor, не fabricated dialog. Исходные time fields/metadata сохраняются; photo/document conversion explicit, unsupported TL media отклоняется. Это не byte-compatible Room export и не перенос отсутствующих attachment bytes.
- Native same-account cancellation/epoch tests, malformed-media conversion, source identity and import interruption остаются обязательными. Существующие fixtures описывают эти обязанности, но не дают выполненного native pass.

## Выполненная проверка и предел доказательств

| Команда | Результат |
|---|---|
| `python -B docs/wave-2/tests/privacy_source_fixtures.py` | **8 static tests passed**, первоначально 0.013 s; после shared hunks повторно **8 passed, 0.015 s**. Проверяют исходники, не Swift signals/native startup. Они не покрывают PR01–PR14. |
| `python -B build-system/Make/PostboxImportCheck.py` из `telegram-ios` | **Exit 0**, включая повтор после появления shared hunks. |
| `Get-Command swift,swiftc -ErrorAction SilentlyContinue` | Не найдено, exit 1. Swift/XCTest/native build не запускались. |
| Read-only validation отчёта | UTF-8, whitespace, 44 full-path file/line ranges и 14 уникальных finding IDs — OK. |

Новые fixture/source files не создавались. Проверенные hidden/retention fixtures используют synthetic messages/identities и injected effects/secret stores; этот review не вызывал настоящий logout, panic, account deletion, network, external plugins или CI. Ни simulator/device, ни APNs, ни power-loss, ни visual verification не выполнялись. Ранее полученные CI/test receipts не переносятся на новые shared hunks.

После исправлений нужны bounded native regressions перечисленных сценариев (tiny/in-memory, отдельный process timeout ≤30 s), поддерживаемый полный native build и labelled frames по AGENTS. Для hidden handoff cover должен оставаться до установки target root; отдельно снять same-account reveal, A→B, replacement, timeout/background/cancel. Для retention — live→deleted transition, mixed albums, date/opacity recycling и read-only interactions. До этих проверок source исправления A–D и установленные hooks не являются visual/native approval.
