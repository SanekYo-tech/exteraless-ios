# Settings reset — RSR01/RSR02 independent source closure

**Вердикт: RSR01 и RSR02 source-closed.** В этих двух исправлениях оставшихся конкретных P1/P2 не найдено. **Core 19, native execution и 10 Display/frame cases здесь не выполнялись; NativeNoCurrentRun.**

Дата: 2026-11-16. Проверены actual files при HEAD `4bd2f7e3`, включая применённые working-tree UI/fixture files, и postfix handoff `docs/wave-2/settings-reset-scopes.md:304–536`. Этот scoped verdict закрывает два counterexamples из `settings-reset-source-closure.md`; прежний report сохранён как исторический. Accepted catalogue 148 native / 154 selected Original / 512 All records сохранён по source identity.

## RSR01 — реальный Display return и свежий preview

**Production:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/SettingsResetController.swift:51–123,242–301`.

Проверен именно callback contract Display: обычный cancelled pop вызывает у возвращаемого controller `viewDidAppear(true)` без нового `viewWillAppear`; expansion cancel имеет такой же ending (`telegram-ios/submodules/Display/Source/Navigation/NavigationContainer.swift:486–494,517–527`).

Новый override сначала вызывает base `viewDidAppear`, который устанавливает `isScreenVisible = true`, затем восстанавливает invalid child только при действующем parent. `restorePageAfterAppearanceIfNeeded` создаёт **новую** authority, удаляет old plan/session/result и выставляет queued-preview flag (`SettingsResetController.swift:56–74`). Старый session не становится retry session новой страницы.

| Interleaving | Проверенное поведение |
|---|---|
| Ready page → cancelled pop | DidAppear восстанавливает child и запускает fresh prepare. Reset получает новый plan. |
| Old prepare/reset reply завершился до return | Старый callback отбрасывается, пока страница невидима. Replacement начинается из фактического DidAppear. |
| Old reply завершился после return | DidAppear оставляет queued preview за busy worker. Его stale completion запускает один fresh prepare после перехода в idle. |
| Обычный WillAppear → DidAppear | Prepare начинается через base refresh один раз; DidAppear не создаёт второй plan поверх уже действующей authority. |
| Actual pop / context retirement | Departure очищает queue и инвалидирует child; retirement также запрещает restoration. Late completion не запускает replacement. |

Критический порядок взят из actual base, а не из mock: `operationTask = nil` → `isBusy = false` → completion → render (`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsUIHelpers.swift:277–282`). Поэтому stale completion действительно может вызвать следующий `perform`; outer completion не затирает его task/busy state. Recovery helper требует одновременно queued flag, **visible**, **idle**, valid parent и valid child (`SettingsResetController.swift:282–287`). Base visibility transitions проверены в `ExteralessSettingsUIHelpers.swift:187–200`.

### Old confirmation / reply не оживают после page ABA

- Настоящий UIAlert positive handler и fixture вызывают одну `applyConfirmedPlan(_:authorityID:)` (`SettingsResetController.swift:227–260`). Перед begin проверяются текущие plan ID, scope, child ID и validity.
- Fresh preview меняет child ID и очищает session; old worker completion проверяет **захваченную** authority (`:107–122,262–279`). Возврат к тому же scope не оживляет прежний callback/confirmation.
- Actual pop и parent retirement не означают rollback admitted reset. Уже записанный public batch остаётся на диске; вернувшийся healthy controller готовит preview его действительного состояния, без автоматического повторного reset.
- Errors остаются inline; новые worker hooks не добавляют deferred error-alert path. После retirement принимается только context/error presentation, а не результат старого reset.

### Native fixture использует production work

`SettingsResetWorkHooks` — internal nil-default seams; shipping factory оставляет оба nil (`SettingsResetController.swift:7–22,37–45`). `afterPrepare` выполняется после actual provider reply через defer; `afterReset` — после возврата `session.run()`, включая освобождение его admission lock. Hooks не подменяют plan/report и не удерживают store/main-thread lock.

`telegram-ios/Tests/Exteraless/SettingsResetNavigationChecks.swift:51–60,115–158,205–292`:

- Монтирует production renderer/provider с actual General definitions, отдельным tiny settings file, rejecting secret backend и **переданным** AccountContext.
- Recorded subclass только записывает callbacks и вызывает super. Fixture вызывает реальные `NavigationContainer.interactivePopBegan/Changed/Ended`, а не вручную `controller.viewWill/DidAppear`.
- Проверяет точный observed cancelled sequence `willDisappear, didAppear`; actual pop — removal и detached view. Для returned page проверяются fresh authority/plan, отсутствующий старый session, ровно два prepare replies суммарно и настоящий mounted UIKit Reset cell.
- Pending-reset cases вызывают actual positive-confirmation continuation; gate удерживает reply уже после реального reset. File bytes до/после navigation и число reset replies проверяют отсутствие replay.

Десять отдельных case IDs присутствуют:

| Группа | Case IDs |
|---|---|
| Ready | `reset-ready-cancelled` |
| Pending prepare | `reset-prepare-before-return`, `reset-prepare-after-return` |
| Pending reset reply | `reset-reply-before-return`, `reset-reply-after-return` |
| Actual pop | `reset-prepare-actual-pop`, `reset-reply-actual-pop` |
| Retired parent | `reset-retired-ready`, `reset-retired-prepare`, `reset-retired-reply` |

Это **source-reviewed prepared coverage**, не запись реального прогона. Retired cases инвалидируют fixture parent authority; live account switch не исполняется. Reply gates ограничены 6 s, interaction deadline — 18 s, обычные waits — 2 s, cleanup — до 5 s; внешний process limit должен оставаться **30 s/case** (`SettingsResetNavigationChecks.swift:26–35,161–168,194–203`).

## RSR02 — typed failure сохранён, destructive retry отозван

**Production:** `swift/ExteralessCore/Sources/ExteralessCore/CoreSettingsResetOperation.swift:258–306,346–352,401–426`.

Новый error branch получает typed failure и post-observer snapshot. При `.storage(.storageFailure)`:

| Наблюдаемый public state | Первый report | Следующий `session.run()` |
|---|---|---|
| Полный intended absent/default reset | Исходная storage error, обычный progress, `requiresNewPreview == false`; expected становится **resetExpected** | Допускается guarded durability confirmation. Новые value/presence edits должны пройти тот же CAS и при отличии отклоняются. |
| Observer восстановил **тот же `2 + present`**, либо иной state, не равный intended reset | Исходная storage error/progress сохранены; private latch = `settingsChanged`, flag = true | Latch проверяется **до checkScope/reload/writer**; возвращается `settingsChanged`, новая запись не стирается. |
| Pre-rename fault оставил старое `2 + present` | Та же консервативная необходимость fresh preview; старый файл сохранён | Старый session отклонён; новый явно подготовленный/подтверждённый plan может сбросить настройку. |
| Malformed JSON parse failure | `.storage(.invalidJSON)`, файл сохранён; это не storageFailure branch | После восстановления файла explicit retry по-прежнему проверяет captured CAS. |

Первый storage error не заменяется на fictitious success/settingsChanged: latch ставится в `:299`, исходный failure бросается в `:302`, outer catch сохраняет его в report. Следующий run останавливается на `:276`; report затем лишь читает cache для observed progress. `publicConfirmed` не выставляется за failed reply. Новый UI показывает исходную ошибку, добавляет “Refresh the preview before continuing” и отключает старый Reset/Retry через report flag (`SettingsResetController.swift:177–186,270–278`).

### Additive state API receipt

`CoreSettingsResetOperation.swift:159–172`:

```text
CoreSettingsResetReport.requiresNewPreview: Bool
isComplete = error == nil && remainingKeys.isEmpty && !requiresNewPreview
```

Поля `confirmedKeys`, `observedResetKeys`, `remainingKeys`, `error` сохранены. Оба construction sites обновлены: reentrant `operationInProgress` reply и обычный report (`:262–264,421–426`). Reentrant admission по-прежнему освобождает `executionLock` перед store operations; latch не добавляет lock вокруг observers.

SHA-256 declaration от `public struct CoreSettingsResetReport: Sendable {` до closing `}\n` включительно, UTF-8/LF: **`8b764609bf7c79ea5e1e5a3759c66fe1fe762e7c581d34161431ce1c89bcee1a`**.

### Core regressions закрывают исходный witness

`swift/ExteralessCore/Tests/ExteralessCoreTests/CoreSettingsResetTests.swift`:

- `:338–390`: one-shot post-rename hook только бросает error. Публичный observer требует changed target + absent override + not-yet-restored, затем выполняет настоящий `applyPublic([key: 2], expected: afterReset)`. Второй callback с presence не переписывает target. Проверяются **два** replacements — reset и новая запись; первая typed storage error/flag; второй run, неизменные bytes, `2` и presence. Нет ожидания внешнего writer из hook/observer.
- `:392–423`: pre-rename fault, прежние bytes, отказ старого session и success нового plan.
- `:309–336`: retained intended-reset branch теперь использует actual Tools definition и дополнительно проверяет typed storage error/false flag; последующий retry не добавляет replacement/default override.
- Malformed-file repair (`:459–478`) сохранён. Все прежние **17** test names/assertions сохранены; 16 method blocks byte-identical, один усилен. Всего **19** методов. Новые witnesses здесь не запускались.

## Actual reset engine / проверенные границы

Source comparison с `1880b663` подтвердил совпадение шести используемых regions в `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift`: `applyPublic`, `reset`, `perform`, `runPublicBatchLocked`, `Change`, `ClientSettingsFile.write`. Работа Search над `definitionVersions` не меняет этих reset contracts.

В actual engine callbacks по-прежнему идут после unlock и **до** throw (`ClientSettings.swift:461–463`); post-rename failure публикует committed state (`:522–527,1063–1070`). Поэтому RSR02 проверен в том же реальном interleaving, что исходный finding. One-CAS public reset, remove-overrides и отдельные native credential phases сохраняются; нового cross-Keychain atomicity обещания нет.

`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/SettingsResetIntegration.swift` совпадает с прежним action binding: construction/context gate сохранён, hooks production action не передаёт. Identity `swift/ExteralessCore/Sources/ExteralessCore/CoreSettingsResetCatalog.swift` совпала с accepted review. Общие scopes/другие домены этим follow-up не переаудировались.

## Verification / native-gate handoff

- Read-only source-data checks прошли за **0.199 s**, shell timeout **30 s**: шесть engine regions, old 17 → new 19 methods/assertions, 10 unique native IDs, 22 существующих required-source paths, actual base finish order и accepted catalogue hash.
- **5/5 postfix SHA-256 pins** из handoff совпали с actual files. Это source evidence; static checks не исполняют Core provider или UIKit.
- На момент локальной проверки пять новых shared BUILD hunks ещё не были применены: export fixture (`telegram-ios/Tests/Exteraless/BUILD:9`), harness compile/fingerprint inclusion (`telegram-ios/Tests/ExteralessHarness/BUILD:70,98–110`), Tools/Privacy Core fingerprint inputs и четыре Display navigation inputs. В harness sources также ещё не было десяти RSR case IDs/dispatch. Их применение и проверка final ready manifest остаются работой native-gate owner.
- Native admission должно включать actual fixture, все 22 required inputs и dispatch к `SettingsResetNavigationChecks.run`, затем **10 реальных Display recordings** на финальной согласованной IPA/source cohort, **≤30 s/case**. Присутствие helper/fixture в source само по себе не является native admission или frame pass.
- Предыдущие **704 Core green / 17 reset tests** относятся к pre-fix cohort. Сообщённые новые Search/schema checks не являются Reset delta execution. CI не запрашивался; Core 19/native tests, live accounts, Keychain, network и plugins здесь не запускались.

**Frame expectations заданы до native recording** в handoff `:485–514`: cancelled return восстанавливает usable fresh preview; before/after-return replies не возвращают old session и не меняют file; actual pop/retirement не возвращают страницу; RSR02 сохраняет storage error/progress и требует Refresh для indeterminate state. Оценка требует actual labelled frames. В этом review таких frames нет.

## Postfix identities

Raw SHA-256; имена разрешаются в полные paths, указанные выше:

| Source | SHA-256 |
|---|---|
| `CoreSettingsResetOperation.swift` | `fd6b6d648c032e9026f8fab63448b6106200cd8488b26ce746e24db7d11eaeef` |
| `CoreSettingsResetTests.swift` | `3a31732cf54a17efe6e160a6bff76d9a8e7911afd854397d771dd86eebfb1b11` |
| `SettingsResetController.swift` | `ddf63e8843dca995003485d03df13bb112ae68e466f21aa633581a0a446a215d` |
| `SettingsResetNavigationChecks.swift` | `b8f42aedbf80a9d4b555323eefd331d1c8bf93ddfded650d8813e88f53aaeb32` |
| `SettingsResetIntegration.swift` | `bbbdae624a8a00ac07bc30e5402efee0347013ade5273b2a81618bd18cb67e4d` |
| `CoreSettingsResetCatalog.swift` | `1a5fa016add3d186b9b80bc7c148a0d2472cd06c039e173daaf22725f7e66a65` |
| `ExteralessSettingsUIHelpers.swift` | `92d974d7eaf88b71c2cf9157f4fd9fef3b73f913e2cd1cdc486aed85a4de630b` |

Прежний `docs/wave-2/reviews/settings-reset-source-closure.md` сохранён с raw SHA-256 **`1e958c585c0e2c7e8d2c4654e286315bdc886402a54e010a943be0895b839374`**. Изменён только новый report `docs/wave-2/reviews/settings-reset-rsr-closure.md`.
