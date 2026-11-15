# Privacy / retention — independent focused follow-up

**Verdict: REQUEST CHANGES.** Исходные counterexamples получили реальные source fixes; остаются **2 P1 / 3 P2** в конфигурации, startup/recovery и retired-resource lifetime. Полного privacy/retention pass нет.

2026-11-15; проверен working tree поверх `4431b7dc`, включая applied shared PR02, final app composition и последующие TLN04/CA04 вставки. Последние проверены только на сохранение privacy admission/callpaths. Это review WIP source, не IPA/runtime/frame approval.

Прочитаны актуальные `privacy-extras-remediation.md` PR sections, `privacy-notification-admission-contract.md`, `privacy-review-remediation.md`, `retention-review-remediation.md`, `retention-process-scope-contract.md`, `final-app-composition.md`; действуют ранее прочитанные AGENTS/CLAUDE. Старый `privacy-retention.md` оставлен readonly, SHA-256: `c5691d57b669994abbbba01a6de55064d5c13d0dc3b43ae1e0338af269eb02af`.

## Открытые source-verified findings

### PFR01 · P1 — Invalid configuration не отзывает policy действующих retention owners

**Source:**
- `telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift:49–54,90–95,1720–1725`.
- `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionAccount.swift:96–118,222–250,324–327`.
- `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:454–455,770–771`: committed cache/error публикуется до выброса durability failure.

**Counterexample:** archive содержит 60-дневную строку, ранее сохранённую при 90-day policy. Owner получает 30-day configuration, но её prune удержан перед Postbox admission. Следующее изменение обратно на 90 дней коммитит settings и завершается storage/durability error. Environment правильно снимает `current` и публикует `nil`. Обе реальные подписки — Account и standalone scope — делают `guard let snapshot ... else { return }`. Owner сохраняет 30-day policy; его work epoch не инвалидируется. Отпущенный prune удаляет строку, пока configuration уже unavailable.

**Impact:** запрет factory admission при invalid snapshot не останавливает уже существующего writer. `loadedPolicy` и `performsMaintenance` остаются доступными, ready остаётся true. Cold unconfigured constructor исправлен, но valid → invalid transition не закрыт. Ошибка после settings commit не должна разрешать destructive работу со старым snapshot.

**Минимальный fix/regression:** versioned unavailable configuration должна доходить до owner, отзывать queued maintenance/media work и readiness/admission; recovery принимает только более новое valid состояние. Один synthetic Postbox row возрастом 60 дней, held transaction, injected settings error и subsequent recovery. Проверить обе native binding подписки, отсутствие удаления и успешное продолжение после valid 90-day configuration. Без реального account или power failure.

### PFR02 · P2 — Environment публикует snapshot/error вне сериализованного порядка

**Source:** `telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift:37–75,1465–1467,1720–1725`.

**Counterexample:** invalid configure A выполняет `snapshot = nil`, освобождает mutex и начинает `failure.set(.unavailable)`. Пока A приостановлен — в том числе в synchronous error observer — recovery B выполняет valid configure и публикует version N. После B старый A выполняет `value.set(nil)`. Возможен и обратный порядок двух valid publications. Mutex защищает memory snapshot, но не пару `failure/value`.

**Impact:** `current` может быть valid, а replayed `updates` — nil. Account, который уже прочитал nil при construction и подписался после этой перестановки, остаётся с inert owner на `ready`, хотя recovery завершилась. Проверка возраста **non-nil** snapshot не защищает от unversioned nil. После исправления PFR01 stale nil также сможет ошибочно отозвать уже восстановленного owner.

**Минимальный fix/regression:** единое versioned состояние success/unavailable и ordered/coalesced publication после внешнего unlock, с защитой reentry. Tiny two-producer/error-observer fixture: valid → invalid → recover с удержанным старым publication; финальный current и delivered state должны совпадать, новый subscriber получает последнюю версию, owner возобновляет readiness. Каждый wait ≤0.5 s. Новый `ExteralessAccountRetentionEnvironment` требует собственного regression; исправленный FilteringRuntime drain это место не покрывает.

### PFR03 · P2 — Настоящий NotificationService caller не отменяет startup до transfer

**Source:**
- `telegram-ios/Telegram/NotificationService/Sources/NotificationService.swift:968–988,2729–2732`.
- `telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift:98–119,2026–2091`.
- `telegram-ios/submodules/SSignalKit/SwiftSignalKit/Source/Disposable.swift:57–79,92–104`.

**Counterexample:** standalone retention scope создан, `ready` или `initializedNetwork` ещё не завершился; delivery expires/заменяется. Handler освобождается, но startup запускается через `let _ = (...standaloneStateManager...).start(...)`. Его disposable не сохранён; deinit отменяет только poll и connection уже присвоенного state manager. `ActionDisposable`/`MetaDisposable` deinit освобождает closure/child, но не вызывает `dispose()`.

**Impact:** правильный `afterDisposed { retentionScope.cancelBeforeTransfer() }` не получает отмену от реального outer caller. Pending writer owner, наблюдения/копирование и startup могут пережить delivery; weak-self guard в `next` лишь отбрасывает поздний результат. Особенно заметно при отсутствии ready после PFR04.

**Минимальный fix/regression:** handler-owned startup disposable, отменяемый при replacement/expiry/deinit до transfer. Controlled readiness/network producer с injected scope recorder: dispose настоящего caller lifetime до ready, затем late emission; zero transfer, owner disposed once. Контроль успешного transfer: scope жив до `AccountStateManager.Impl` teardown. Helper-only `afterDisposed` source assertion недостаточен.

### PFR04 · P1 — Ошибка retention index блокирует запуск Account без доступного recovery

**Source:**
- `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionAccount.swift:196–199,232–265,324–327`.
- `telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift:515–519,1404–1406,2026–2030`.
- `telegram-ios/submodules/TelegramUI/Sources/SharedAccountContext.swift:655–728`.

**Counterexample:** корректные настройки, обычный исправный Postbox и маленький unreadable/unsupported retention index; reset marker отсутствует. Initial refresh сообщает `.invalidArchive`/`.unsupportedFormat` только через `failure`, а `ready` никогда не выдаёт true. Account factory ждёт исключительно `ready`; standalone factory тоже. Recovery/error signal до app UI не доведён. Shared account construction ждёт результаты всех account factories.

**Impact:** повреждение необязательного local archive может навсегда оставить приложение на startup, включая доступ к другим accounts и UI explicit archive reset. Повторное чтение того же index не восстанавливает progress. Это отличается от корректного отказа unknown policy: policy уже валидна, нужен доступный non-destructive recovery outcome.

**Минимальный fix/regression:** typed readiness success/failure с bounded, видимым recovery/retry path до ожидания полноценного Account; не выдавать фиктивное ready и не стирать archive автоматически. Synthetic valid Postbox + invalid retention index: factory/presenter получает конечную ошибку, explicit fixture repair/reset позволяет одному продолжению завершиться; native PTS/QTS/seq сохраняются. 11 prepared retention tests проверяют interrupted reset marker, но не этот corrupt-index/no-marker startup path.

### PFR05 · P2 — После prune/clear native retained ID попадает в `.never()`, Engine reader — в failure

**Source:**
- `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionAccount.swift:173–177,270–278`.
- `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionLocalMedia.swift:96–104`.
- `telegram-ios/submodules/TelegramCore/Sources/State/Fetch.swift:89–91,139–179`.
- `telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift:1913–1924`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionEngine.swift:248–266`.

**Counterexample:** native image/resource consumer ещё держит ранее выданный retained `LocalFileMediaResource`. Expiry prune/clear удалил index media entry, reconcile убрал `archiveSources`, GC удалил cache bytes. Следующий fetch этого ID больше не распознаётся retention adapter: возвращается nil. Stock fetch не обрабатывает такой LocalFile ID и `setupAccount` выбирает `.never()`.

**Impact:** cloud refetch действительно исключён, но terminal failure/expiry contract расходится с Engine facade. 25-second materialization timeout не участвует: materialize вообще не вызван. Новый expiry fixture намеренно сохраняет unpruned index и этот переход не проверяет.

**Минимальный fix/regression:** retired archive resource должен оставаться распознаваемым для terminal rejection существующих consumers либо failure должен обрабатываться на их native fetch boundary. Four-byte fixture: получить resource, prune/clear + reconcile/GC, сохранить только старый native reference; actual fetch path даёт одну `.generic`, ноль cloud calls и completion не зависает. Отдельный обычный LocalFile control сохраняет stock semantics.

## Closure исходных PR01–14

«Закрыт source» здесь означает устранение **первоначального counterexample** по проверенному callpath. Выполненного native/XCTest/frame результата для этих paths нет.

| PR | Независимая source сверка | Статус |
|---|---|---|
| PR01 | `ExteralessFilteringSummaries.swift:54–63,90–108,180–193`: filters-off возвращает исходный list; peer-inactive не читает preview history. Active ordinary/forum queries используют согласованные peer/namespace bounds; forum передаёт thread в настоящий Postbox API. | **Закрыт source** |
| PR02 | `ExteralessPrivacyPolicy.swift:49–70,112–132,145–170,222–239`: automatic annotation перепроверяет текущую policy и validated final metadata; manual lease связан с owner/network/descriptor/bytes, single begin/admit, cancel tombstone. After-send — отдельный revocable intent. | **Закрыт source** |
| PR03 | `ApplicationContext.swift:294–328,370–400,430–433`: один admission переносится через EngineData и lock hop; active app/installed root проверяются; все три effects непосредственно внутри `performIfCurrent`. `ExteralessNotificationAdmission.swift:60–120` отзывает superseded/disposed batch. | **Закрыт source** |
| PR04 | `AccountViewTracker.swift:1975–2007`: capture до queue hop, synchronous lifetime disposal до tracker cleanup. `ExteralessPrivacyObservations.swift:199–225,231–313,340–352`: один captured epoch work до factory/hop, child disposal вне mutex, inside-Postbox cancellation/identity admission. | **Закрыт source** |
| PR05 | Все process bootstraps теперь configured; отдельный standalone owner создаётся до ready/network/replay и передаётся в StateManager. Impl освобождает его после native operations (`AccountStateManager.swift:393–435`). | Missing owner **исправлен**, lifecycle/recovery **PFR01–04 открыты** |
| PR06 | Store допускает Local=1 и SecretIncoming=2 (`ExteralessRetentionStore.swift:257–263`); remote clear передаёт оба namespace (`ProcessSecretChatIncomingDecryptedOperations.swift:308`). Range hook имеет отдельные cursors и общий scan/capture budget (`ExteralessRetentionHooks.swift:71–100`). Filtering summary сливает namespace heads, считает fetched rows в общий budget и проверяет unread coverage отдельно (`ExteralessFilteringSummaries.swift:46–47,90–165`). | **Закрыт source** |
| PR07 | `ChatHistoryListNode.swift:2420–2422` фильтрует retained entries до merge; `RetentionDisplayScope.swift:82–111` использует raw live album context, known reply author и frozen source reactions, не вычитает live counts второй раз. Changes invalidation подключена в `ExteralessRetentionHistoryAdapter.swift:36`. | **Закрыт source** |
| PR08 | Full album key содержит peer/namespace/thread/group; merge проверяет всех членов существующей группы (`ExteralessRetentionHistoryAdapter.swift:70–98`). Encrypted bounded registry резервирует native stable counter и tagged display-group ID (`RetentionDisplayScope.swift:6–18,51–76`), не raw groupingKey. | **Закрыт source** |
| PR09 | `RetentionMediaOwnership.swift:75–88`: live unexpired version ownership; Engine и native materialize сходятся на этой проверке, с повтором после restore (`ExteralessRetentionAccount.swift:432–451`). | Unpruned-expiry counterexample **закрыт source**; retired-ID boundary **PFR05 открыт** |
| PR10 | Independent encrypted ownership journal сохраняется перед index/row removal (`ExteralessRetentionStore.swift:413–421`). Clear/reset журналирует IDs до wipe; GC fresh transaction union, native aliases и ciphertext removal, directory sync перед ack (`ExteralessRetentionAccount.swift:488–555,581–615`). `.bin` existence больше не единственный ownership источник. | **Закрыт source**, fault/runtime proof pending |
| PR11 | `ExteralessRetentionMediaVault.swift:89–108`: file sync → rename → directory chain; authenticated existing-file recovery повторяет file и ancestor-directory barriers. `RetentionFileSystem.swift:13–28` доходит до supplied durable root. | **Закрыт source**, power-loss claim отсутствует |
| PR12 | `ExteralessPanicAdmission.swift:12–39` выдаёт proof только exact record/one backup/one environment. Transaction result управляет Temp/private/notification effects (`ExteralessHiddenAccounts.swift:414–432,454–458`); прежнего planned-target callback нет. UI callback принимает одну admitted identity (`ExteralessPrivacyExtrasIntegration.swift:45–46`). | **Закрыт source** |
| PR13 | FilteringRuntime использует `HiddenAccountPresentationLock`; nested setPeer → setCollection → settings callback только отмечает dirty. Публикация после outermost release, drain без callback под mutex (`ExteralessFiltering.swift:36–58,111–137`; `HiddenAccountRuntimeState.swift:25–64`). | **Закрыт source**; новый Environment — отдельный PFR02 |
| PR14 | Share регистрирует Retention definitions до configuration и Account factory; только main role автоматически prune/GC. Unconfigured owner inert, не выбирает 30-day default (`RetentionProcessScope.swift:17–31`; `ExteralessRetentionAccount.swift:73–81,111–118,222–245`). | Cold Share/defaults counterexample **закрыт source**; valid→invalid/recovery **PFR01–02 открыты** |

## Process roots, locks и hidden readiness

- **Все пять roots:** main worker `ExteralessClientRuntime.swift:54–60,63–105`; Share `Telegram/Share/ShareRootController.swift:47–68`; service `Telegram/NotificationService/Sources/NotificationService.swift:813–826`; notification content `Telegram/NotificationContent/NotificationViewController.swift:38–58`; Siri `Telegram/SiriIntents/IntentHandler.swift:159–177`. Каждый читает реальный shared file, регистрирует Retention, валидирует snapshot и передаёт OS container URL до своего account-producing path. Siri/content используют согласованный non-maintenance `.shareExtension` role. Failure не выбирает destructive defaults. Continuing owners ограничены PFR01.
- **Main startup:** prepare/ready gate стоит перед shared-context factory; public/private store I/O вынесено в serial worker. Включённые source checks подтверждают initial failure/retry/retired completion ordering. Весь native startup и reload recovery ещё не приняты: см. PFR01–04.
- **A–D сохраняются:** hidden unlock ждёт actual primary + foreground + installed-root readiness (`ExteralessPrivacyExtrasIntegration.swift:58–69`; `AppDelegate.swift:1603–1618`), затем opaque `finishUnlock` и собственную PasscodeUI lifecycle acceptance. Existing native PIN priority, alternate-without-PasscodeSession, visible-only biometry, loading/confirmed-empty и Account-object replacement boundaries не заменены Bool-подтверждением. No-old-account-flash требует frames.
- **File/Postbox lock order:** все production `fileLock.withLock` paths находятся на media worker; затем идут fresh bounded Postbox admission/ack. Postbox capture/store callbacks не ожидают OS file lock. `retentionFileTransaction` отменяет ещё не admitted queued body после timeout/dispose (`RetentionFileTransactions.swift:7–32`). GC ждёт completion native removal, а не его progress (`ExteralessRetentionAccount.swift:518`).
- **Межпроцессный read:** `Postbox.swift:2646–2660` сбрасывает table caches при external transaction version change; GC планирует под общим lock из свежей transaction, а reservations исключают journal-owned native IDs (`ExteralessRetentionStore.swift:309–320`). Reset не удаляет lock inode. Эта source ordering сверка не является запуском нескольких iOS processes.
- **Counters/rows:** before-image helpers по-прежнему пишут только retention cache rows; оригинальные replay/delete/TTL и native PTS/QTS/seq paths сохранены. Filtered unread/reaction copies не записываются обратно. NFA incomplete продолжает означать await/suppress, не notification approval. Новая retained projection сохраняет `originalView: view`.

## Проверки и остающаяся доказательная база

В этом follow-up выполнены только bounded offline/source checks:

| Проверка | Результат |
|---|---|
| `python -B docs/wave-2/tests/privacy_source_fixtures.py` | **10 passed, 0.014 s** |
| Шесть focused tests из `test_final_app_composition.py`: worker; pre-account gate; retry/retirement; process roots; writer ownership; three notification effects | **6 passed, 0.022 s** |
| `python -B build-system/Make/PostboxImportCheck.py .` из `telegram-ios` | **Exit 0** |
| Старый report SHA-256 | Совпадает с readonly исходным hash выше |
| Swift / swiftc probe | `Get-Command` не нашёл toolchain, exit 1; native compilation не выполнялась |
| Follow-up document check | UTF-8/whitespace, source line ranges, 5 уникальных findings и 14 original PR rows — OK |

Source checks не воспроизводят PFR01–05: в частности, проверка наличия `afterDisposed` внутри factory не проверяет владение её subscription в NotificationService.

Прочитаны **11** `RetentionReviewRemediationTests` с four-byte media, real disposable encrypted Postbox и injected clocks/filesystem; native fetch-before/after restore expiry, missing-ciphertext clear/reset и fsync retry действительно обращаются к production adapters. Native suites для summaries/admission/history lifetime подготовлены. **Ни эти 11 tests, ни native PR regressions здесь не исполнялись.** Separate-handles lock fixture не доказывает межпроцессный или power-loss результат.

`telegram-ios/submodules/TelegramCore/BUILD:137–141` уже включает `FinalAppNotificationAdmissionTests.swift` и `RetentionReviewRemediationTests.swift` в dedicated native source list: старый hdo про missing retention test-list line не является текущим gate. `ExteralessFilteringSummaryReviewTests` / `ExteralessPrivacyAdmissionReviewTests` не найдены в этом explicit list; общий `TelegramCoreTestsLib` видит их через glob. При выборе native test target необходимо сохранить их фактическое покрытие.

По сообщению координатора: Core **515** на `4431b7dc` имеет **1 Cloud retry failure**; новые **48 settings/Chat** и **158 Host** прошли, полные logs ещё собираются. Это внешние сообщённые receipts, не выполненные этим reviewer проверки и не native retention/notification/Passcode execution evidence.

Изменён только новый follow-up report. Implementation, старый report и fixtures не редактировались; CI/network/plugins, настоящий account/logout/panic и power-loss simulation не запускались. Для закрытия remaining findings нужны tiny controlled adapter regressions с внешним timeout ≤30 s, затем native build/test evidence и labelled frames по AGENTS. **Native, APNs, device и visual acceptance остаются pending независимо от source-closure исходных PR.**
