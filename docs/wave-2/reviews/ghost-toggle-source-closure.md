# Ghost toggle — independent source closure

**Вердикт: source-closed** для legacy non-atomic toggle и locked-value/default-presence counterexamples в `1afee5f9`. В этом focused scope оставшихся конкретных P1/P2 не найдено. **Девять новых Core tests и native UI/presence execution здесь не выполнялись.**

Проверены `ghost-toggle-final-admission.md`, новый helper, все три production writers, их callers/admission guards и реальные `ClientSettings.applyPublic(expected:resetting:)` semantics. PFR/general review не повторялся. Проверенные source/test paths совпадают с `1afee5f9`; `ClientSettings.swift`, `PrivacyPolicy.swift`, `PillAccountLease` и SwiftSignalKit `runOn` этим commit не изменены.

## Почему исходные counterexamples закрыты

### 1. Один snapshot → один CAS → одна целая запись

`swift/ExteralessCore/Sources/ExteralessCore/PrivacyGhostModeMutation.swift:10–29` берёт ровно один `before`, выбирает направление через `PrivacyPolicy(values: before.values)`, строит batch и один раз вызывает `applyPublic`. Supplied `expectedBefore` не заменяется новым cache read.

Проверена реализация atomic engine, а не только имя API:

- `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:461–503`: affected set равен `values.keys ∪ resetting`; под одним file lock сравниваются **effective JSON value и stored-key presence каждого affected key**, до применения любых изменений.
- `ClientSettings.swift:504–520`: весь candidate document изменяется в памяти, затем выполняется один replace либо no-edit durability confirmation; cache публикуется целиком. Unrelated disk keys сохраняются.
- `ClientSettings.swift:1017–1050`: temp write/file sync предшествуют единственному rename. Pre-replace failure не оставляет первых двух/трёх ghost fields записанными; post-replace durability failure возвращается отдельно для публикации полного committed state.
- `ClientSettings.swift:379–455,890–900`: ошибки распространяются после соответствующего whole-state cache update; observer не получает пять последовательных half-states от одного toggle.

### 2. Все пять packet values и все пять locks — CAS dependencies

`PrivacyFeatures.ghostFields` содержит read, stories, online, typing/upload и offline-after-send (`swift/ExteralessCore/Sources/ExteralessCore/PrivacyFeatures.swift:5–8`). Policy меняет только unlocked values, сохраняя обратную полярность offline-after-send (`swift/ExteralessCore/Sources/ExteralessCore/PrivacyPolicy.swift:120–139`).

Для каждого не изменяемого dependency helper использует:

| Before | Batch | Следствие |
|---|---|---|
| Stored default или stored non-default | Точное прежнее значение в `values` | Presence и value сохраняются, оба проверяются CAS |
| Отсутствующий override | Ключ в `resetting` | Отсутствие проверяется CAS и остаётся отсутствием; default override не создаётся |
| Unlocked packet value | Целевое значение в `values` | Это намеренная запись toggle; его прежние value/presence всё равно проверяются |

Доказательство — `PrivacyGhostModeMutation.swift:15–25` вместе с `ClientSettings.swift:474–505`. Даже reset отсутствующего key входит в affected set. Поэтому external default insertion/reset, stale lock или stale locked value не проходят CAS незаметно. Sets `values/resetting` не пересекаются.

### 3. All-locked — guarded no-edit; result принадлежит своей операции

Когда все пять locks true, policy возвращает пустой change set и остаётся active. Helper всё равно передаёт десять dependencies в CAS, поэтому stale snapshot отклоняется даже для no-edit. При неизменном healthy registered document override presence и bytes остаются прежними; engine выполняет durability confirmation без replace/обычного change notification (`ClientSettings.swift:514–519,890–900`). Смена error/migration state остаётся семантикой самого engine.

Projected policy вычислена **до** `applyPublic`, а возвращается после его успешного завершения (`PrivacyGhostModeMutation.swift:27–29`). `ClientSettings` освобождает writer/file/cache locks до observer delivery (`ClientSettings.swift:458–460,453–455`). Поэтому synchronous observer может выполнить отдельный следующий toggle, но его результат не заменяет Bool первого batch. В Main worker устранён прежний post-observer `PrivacyPolicy.current.ghostModeActive` return; Core continuation также переносит полученный Bool. Pill намеренно использует только success/error.

## Проверены все три реальные writers

| Callpath | Source / итог |
|---|---|
| Privacy overview / PeerInfo → Core | `telegram-ios/submodules/TelegramCore/Sources/State/ExteralessOutgoingPrivacy.swift:7–25` вызывает helper один раз вместо `.set` loop. Реальные entry points: `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Privacy/ExteralessPrivacyControllers.swift:55–60` и `telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift:287–298`. Ошибка локального batch идёт в error branch; status continuation находится только в success `mapToSignal`. |
| Main Settings worker | `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift:122–134`: context/op проверяются до и после snapshot capture; именно этот snapshot передаётся как `expectedBefore`. Completion возвращает сохранённый `active`, не перечитывает позднее observer state. |
| Pill runtime | `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Pills/ExteralessPillRuntime.swift:117–128`: helper находится внутри существующего `lease.withCurrent`; прежняя сборка batch с manufactured default lock-presence удалена. Cancellation/error handling и guarded main completion сохранены. |

### Cancellation и presence — точные границы

- Main shortcut сохраняет Task cancellation → `operation.invalidate()`, проверки context/lease до dispatch и после continuation; context teardown инвалидирует token (`ExteralessClientRuntime.swift:341–351,375–377`). Отмена до worker admission прекращает изменение; уже допущенный synchronous batch может закончиться целиком, но retired caller не объявляет success.
- Pill admission использует account-generation recursive lease вокруг batch; invalidation и main completion проверяют ту же lease (`swift/ExteralessCore/Sources/ExteralessCore/PillModel.swift:97–108`). Его реальный ghost-settings observer dispatches UI update асинхронно (`ExteralessPillRuntime.swift:249–255`). Это не обещание rollback после admission.
- Core сохранил `runOn` и signal disposal: queued-start cancellation проверяется до запуска producer (`telegram-ios/submodules/SSignalKit/SwiftSignalKit/Source/Signal_Dispatch.swift:54–87`); overview хранит disposable и снимает его при account invalidation (`ExteralessPrivacyControllers.swift:23–27`). PeerInfo сохраняет существующий one-shot start. Новый helper не добавляет отдельного account/op token в этот legacy API.
- Core `account.updateStatus` continuation вызывается только после **успешного локального batch**. Он выбирает offline по **актуальному `sendOnlinePackets`**, поэтому не подменяет locked online value общим `ghostModeActive`. Network errors по-прежнему не превращают локальную запись в rollback; returned Bool описывает локальную projection, не RPC acknowledgement (`ExteralessOutgoingPrivacy.swift:20–24`).
- Остальные два writers публикуют обычное settings change; существующий presence manager перечитывает policy и меняет presence только при изменении effective online state (`telegram-ios/submodules/TelegramCore/Sources/State/ManagedAccountPresence.swift:26–37,47–74`). Locked/default-presence сохранение не означает принудительный offline packet.

## Supplied regressions — source reviewed, не executed

Прочитаны все **9** методов `swift/ExteralessCore/Tests/ExteralessCoreTests/PrivacyGhostModeMutationTests.swift`:

1. Both directions/reset/reopen: одна запись и одно whole-state observation.
2. Mixed locks: absent, explicit default и non-default presence, unrelated setting.
3. All-locked: true, unchanged bytes/presence, ноль replacements/observations.
4. Реальные pre-/post-replace fault seams: только complete old/committed states, error propagation и retry от действительного состояния.
5. Stale value каждого из пяти locks.
6. Stale packet values при unlocked и all-locked snapshots.
7. Presence-only default insertion/reset всех десяти dependencies.
8. Supplied `before` после локального reload остаётся authoritative.
9. Reentrant observer делает второй real toggle; первый return остаётся своей projection.

Fixtures используют tiny isolated files, настоящий `ClientSettings`/CAS и injected secret backend; external-writer interleavings задаются вторым store без sleeps. Fault hooks только считают/бросают, reentry выполняется из публичного observer. Всего 36 external-writer cases и две fault cases. Эти Core tests не исполняют три native UI/cancellation/status callpaths — их source wiring проверено отдельно выше.

## Выполненные проверки / pending evidence

- Commit diff: все три toggle functions действительно заменены; diff atomic engine/Policy/lease/`runOn` пуст. Scoped working-tree diff против `1afee5f9` пуст.
- Source search: ровно **3 production calls** `PrivacyGhostModeMutation.toggle`, без оставшегося native `ghostModeChanges` batch builder.
- `python -B docs/wave-2/tests/privacy_source_fixtures.py`: **10 passed, 0.019 s**, command timeout 30 s. Это прежние static privacy contracts, не execution нового helper.
- `Get-Command swift,swiftc`: toolchain не найден, exit 1. **Новые Core 9 здесь не запускались**, их runtime ≤30 s не измерен.
- Сообщённый предыдущий Mac baseline **671 Core / 3 SDK / 219 native-components green** предшествует fix и не переносится на него. Новое Linux CI принадлежит координатору; его результат в этот review не включён.

Изменён только этот report. CI, account/network/plugin execution и новые fixtures не запускались/не добавлялись. Source-closure ограничена atomic toggle, locks/presence, сохранёнными admission/cancel boundaries и captured return. Fresh Core execution, native UI/status/cancel tests и visual/device evidence остаются pending.
