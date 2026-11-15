# Privacy / retention — PFR01–05 source closure

**Вердикт: PFR01–PFR05 закрыты в source.** В пределах этих пяти findings оставшихся конкретных P1/P2 не найдено. **Native execution, supported Apple build и frames остаются pending.** Это не IPA/device/visual approval.

2026-11-15; working tree поверх `0ceafb7b`. Проверены исходные triggers из `privacy-retention-followup.md`, соответствующие production callpaths и supplied PFR regressions. General review PR01–14 не повторялся. Основание: актуальные PFR sections `final-app-composition.md`, `retention-review-remediation.md`, versioned/typed API в `retention-process-scope-contract.md` и frozen source manifests.

## PFR01 — unavailable отзывает действующих owners и старую queued работу

**Source-closed.** Available/unavailable теперь имеют одну возрастающую версию; общий writer binding передаёт обе формы непосредственно в owner без nil filter или main-queue hop. Им пользуются обычная и standalone factories: `telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift:10–27,129–181,191–258,945–964,2482–2493`.

`RetentionOwnerState.update` атомарно меняет configuration, work epoch, attempt и readiness; unavailable убирает policy, а stale/equal версии отклоняются. Policy и work захватываются вместе. Поэтому удержанный 30-day prune не допускается после unavailable, а последующий valid 90 не оживляет старый work: `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/RetentionReadiness.swift:59–84`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionAccount.swift:107–133,263–306`.

Дополнительно прослежены originating epochs в media leases, acknowledgements, materialize и GC/reset; быстрый unavailable → available не снимает отмену уже запущенной операции (`ExteralessRetentionAccount.swift:406–458,468–503,517–531,606–674`).

**Prepared proof:** `RetentionReviewRemediationTests.swift:405–484` и `PFRAppIntegrationTests.swift:411–473`. Второй использует настоящий ClientSettings post-rename fault, общий production scope/binding, paused Postbox и 60-day row; проверяет обе writer roles, committed 90-day cache/error, revocation и recovery. **Не executed.**

## PFR02 — stale error publication не перезаписывает recovery

**Source-closed.** Независимые unversioned nil/error publications заменены единым versioned snapshot. State commit выполняется под mutex, callbacks — после unlock; writer observers предлагаются раньше presentation/error observers. У каждого observer собственный monotonic/reentrant drain: старый publication не заменяет новый replay. Подписка на settings устанавливается до первого sample; error-only и unrelated-key failures участвуют в revalidation: `telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift:30–63,93–188`.

Owner readiness publisher также вызывает callbacks вне mutex, перечитывает current outcome и сохраняет unavailable epoch для старых waiters: `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/RetentionReadiness.swift:132–170`.

**Prepared proof:** `PFRAppIntegrationTests.swift:41–112` держит старый error observer, восстанавливает состояние другим producer, проверяет новый subscriber и nested recovery. Это actual environment implementation с injected immutable settings source. **Не executed.**

## PFR03 — delivery действительно владеет startup subscription

**Source-closed.** Handler и delivery разделяют `ExteralessStateManagerStartupLifetime`; в нём удерживаются и initial account-manager subscription, и заменяющая её standalone subscription. Completion/replacement/expiry/deinit явно dispose startup до освобождения queue-local handler: `telegram-ios/Telegram/NotificationService/Sources/NotificationService.swift:766–783,918–928,975–1003,2744–2748,2782–2784,2811–2827,2850–2864`.

Generation token проверяется после readiness и при final transfer. `ExteralessRetentionWriterLease` допускает один transfer/dispose; cancellation до transfer отзывает scope, после transfer его освобождает StateManager. Callback/disposal не выполняются под transfer mutex: `telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift:198–340,2485–2567`; `telegram-ios/submodules/TelegramCore/Sources/State/AccountStateManager.swift:394–435`.

**Prepared proof:** `PFRAppIntegrationTests.swift:129–212` — held ready/network, late transfer, replacement, caller deinit, successful writer teardown и once-only disposal. Реальный NotificationService caller проверен по source; fixtures не запускают service extension. **Не executed.**

## PFR04 — corrupt archive имеет конечный pre-Account recovery path

**Source-closed.** Ошибка index/no reset marker теперь превращается в typed `.archive(...)`; await имеет default 5 s и clamp 0.01…25 s, cancellation/retry ревокирует token. Fake ready и automatic index wipe не добавлены: `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/RetentionReadiness.swift:100–157`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionAccount.swift:211–240,274–306`.

Авторизованная factory выдаёт `AccountResult.retentionRecovery` до Network/Account construction и сохраняет explicit retry continuation; standalone возвращает typed failure. Readiness проверяется после phone-number hop и при final transfer: `telegram-ios/submodules/TelegramCore/Sources/Account/Account.swift:350–523,945–969,2485–2567`. Оба eviction callbacks тоже проверяют актуальность token (`Account.swift:2201–2233`).

Прослежены реальные consumers:

- `SharedAccountContext` учитывает recovery как обработанный недоступный record, пропускает его при nil-account removal / `beginNewAuth`, сохраняет здоровые accounts и повторно использует уже установленный Account: `telegram-ios/submodules/TelegramUI/Sources/SharedAccountContext.swift:664–726,763–853`.
- `currentAccount` передаёт recovery; cleanup не заходит в logout/removal branch при этом результате: `telegram-ios/submodules/TelegramCore/Sources/Account/AccountManager.swift:322–336,501–534`.
- AppDelegate подписан на recovery до подготовки accounts и показывает alert без AuthorizedApplicationContext. Retry / explicit Reset / Later имеют handle/status guards: `telegram-ios/submodules/TelegramUI/Sources/AppDelegate.swift:2019–2059,2076–2125`.
- Retry/reset проходят успешную serial public/private settings preparation и возобновляют handle один раз: `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift:201–241`.

**Prepared proof:** `RetentionReviewRemediationTests.swift:486–546`; `PFRAppIntegrationTests.swift:214–304,481–563`. Fixtures используют реальный typed startup/recovery center и disposable encrypted Postbox, injected network/writer и healthy sibling control; проверяют preserved corrupt bytes, repair/reset, один continuation и прежние PTS/QTS/seq. UIAlert/SharedAccountContext interaction и Later визуально не исполнялись. **Не executed.**

## PFR05 — retired native reference terminal-fails после GC/disposal

**Source-closed.** Реальный snapshot renderer возвращает `ExteralessRetainedLocalFileMediaResource`, сохраняя native LocalFile ID и bounded immutable routing provenance. Native adapter распознаёт subtype независимо от `archiveSources`; отсутствующий owner, invalid tag или retired ownership дают `.generic`, не nil → stock `.never()`. Provenance не заменяет live ownership/expiry admission: `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/RetentionResourceProvenance.swift:4–84`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionLocalMedia.swift:21–25,96–116`; `telegram-ios/submodules/TelegramCore/Sources/ExteralessRetention/ExteralessRetentionAccount.swift:468–503`.

Handed-off registration действительно applied в существующем once-only coding initialization, сразу после LocalFile declaration; runtime registration в renderer не требуется: `telegram-ios/submodules/TelegramCore/Sources/Account/AccountManager.swift:88–89,130–131,257–259`.

**Prepared proof:** `RetentionReviewRemediationTests.swift:549–590` берёт reference из production snapshot renderer, делает native coding round-trip, materialize четырёх байт, clear/reconcile/GC и затем передаёт старый reference в native adapter. Проверяет одну generic failure, повтор после owner disposal и stock ordinary-LocalFile control. **Не executed.**

## Проверки этой closure-сессии

| Проверка | Наблюдаемый результат |
|---|---|
| `final-app-pfr-freeze.sha256` | **13/13 совпали**, normalized UTF-8/LF, без BOM |
| `retention-followup-freeze.sha256` | **25/25 совпали**, та же нормализация |
| Пять focused `test_final_app_composition.py` tests: `test_pfr01…`, `test_pfr02…`, `test_pfr03…`, `test_pfr04…`, `test_pfr_native_fixtures…` | **5 passed, 0.051 s**, external command timeout 30 s |
| Fixture inventory | **17 retention methods** (6 новых PFR) + **10 App methods** (7 controlled + 3 native-storage); source inventory, не test results |

Выполненные Python checks читают source и проверяют contracts; они не исполняют Swift, Postbox, recovery UI или extension. Сверка hashes подтверждает только совпадение inspected files с frozen receipts. Изменён только этот новый report; implementation, fixtures и предыдущие reports readonly.

## Native / frame acceptance — pending

- Supported Apple full build/typecheck/link ещё готовится; его результата здесь нет.
- **17 retention + 10 App native regressions не запускались.** Runner должен действительно включать оба класса `PFRAppIntegrationTests` / `PFRNativeAccountStartupTests`; Build changes независимы от этого source review.
- Требуются actual Root recovery→Retry/Reset/Later, healthy-account continuity, extension replacement/expiry и native resource teardown evidence. Frames — по AGENTS, с индексами/временем.
- Реальные accounts/logout/panic, CI/network/plugins и power-loss simulation в review не использовались. Source closure этих пяти findings не переносит approval на device, APNs, durability under power loss или visuals.
