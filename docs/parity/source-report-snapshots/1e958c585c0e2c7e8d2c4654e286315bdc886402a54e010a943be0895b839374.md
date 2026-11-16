# Original settings reset — independent focused review

**Вердикт: REQUEST CHANGES — два оставшихся P2 (RSR01–02).** Три source scopes и их фактический native join подтверждены, но source-closure блокируют восстановление страницы после cancelled interactive pop и один post-commit retry counterexample. P1 в этом scope не найдено.

Проверены оба production reset Core-файла из `d1df6ad6`, актуальный fixture с `DialogFeatures.definitions` в `1880b663`, оба новых UI-файла и применённые coordinator Runtime/fingerprint hunks. Implementation read-only; этот документ — единственное изменение review. **17 Core fixtures здесь не исполнялись; native compilation/execution/frames не подтверждены.**

## Оставшиеся findings

### RSR01 · P2 — cancelled interactive pop не восстанавливает reset authority

**Источник:** `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/SettingsResetController.swift:42–64,197–198,230–238`.

**Реальный callpath:** `telegram-ios/submodules/Display/Source/Navigation/NavigationContainer.swift:312,517–527`. При начале swipe-back navigation вызывает `viewWillDisappear`, а при отмене возвращаемому controller вызывает **только `viewDidAppear(true)`**, без `viewWillAppear`. У expansion-pop такая же развязка (`NavigationContainer.swift:486–494`).

Reset controller инвалидирует `pageAuthority` и сбрасывает `needsPreviewWhenIdle` в `viewWillDisappear`. Восстановление authority, очистка старого session и запуск preview находятся только в `viewWillAppear`. Унаследованный `viewDidAppear` лишь устанавливает `isScreenVisible`; нового preview не создаёт (`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsUIHelpers.swift:187–200`; `telegram-ios/submodules/Display/Source/ViewController.swift:706–710`).

**Witness:**

1. Открыть готовый General/Exteraless/All preview, начать back-swipe и вернуть страницу назад, не завершая pop.
2. `pageAuthority` уже invalid; ожидаемый recovery hook не вызывается.
3. Если preview был готов, прежний Reset может выглядеть доступным, но `confirm` прекращается на `pageAuthority.isValid`. После следующего render кнопка disabled (`SettingsResetController.swift:151`).
4. Если prepare был в работе, его completion отбрасывается по старой authority; `needsPreviewWhenIdle == false` не запускает replacement preview. Busy снимается базовым `perform`, но native entries/Reset могут так и не появиться.

**Impact:** обычная отмена навигационного жеста оставляет reset page неработоспособной до ручного Refresh, смены scope или повторного открытия. Записи этим witness не возобновляются; дефект именно в возвращаемом UI/admission state.

**Regression / исправление границы:** восстановить свежую child authority и preview на фактическом return callback Display, включая `viewDidAppear` без preceding `viewWillAppear`; при outstanding work дождаться idle. В loginless native fixture проверить ready preview, pending prepare и pending reset с отменой swipe, а также настоящий pop/context retirement, после которых работа не должна возобновляться. Ожидать новый plan и работоспособный Reset, а не revival старого session. Native regression/frames здесь не запускались.

### RSR02 · P2 — post-rename failure + reentrant restoration оставляет старый CAS baseline для Retry

**Источник:** `swift/ExteralessCore/Sources/ExteralessCore/CoreSettingsResetOperation.swift:281–294,334–340`.

В error branch `publicExpected` заменяется на intended absent/default state **только если поздний cache snapshot ещё целиком равен `resetExpected`**. Иначе остаётся `plan.before`, а `.storage(.storageFailure)` не требует нового preview.

Это позднее наблюдение происходит после synchronous observers: `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:461–463` сначала доставляет callbacks, затем бросает сохранённую ошибку. Post-rename failure действительно уже публикует committed reset (`ClientSettings.swift:522–527,1063–1070`); observer может законно сделать следующую запись, поскольку writer/file locks освобождены.

**Конкретный bounded-data witness:** взять реальную `ToolsFeatures` definition `tools.downloadSpeedBoost` (default `0`) и General scope; остальные General поля оставить без overrides.

| Шаг | `tools.downloadSpeedBoost` | Состояние reset session |
|---|---|---|
| Prepare | `2`, override present | `publicExpected = (2, present)` |
| Единственный reset rename завершён, directory-sync reply ошибочен | `0`, override absent | `applyPublic` ещё доставляет observers |
| Одноразовый observer сохраняет **новый override `2`** | `2`, override present | Это отдельная запись после reset |
| Outer `applyPublic` бросает исходную storage error | `2`, override present | `after != resetExpected`; `publicExpected` остаётся старым, `publicConfirmed == false` |
| Пользователь нажимает Retry remaining steps | override снова удалён | Старый CAS проходит; новая запись стёрта |

Здесь намеренно проверяется восстановление **того же payload, который был в preview**, после собственного committed reset. Для отличающегося нового значения CAS корректно отклонит retry; этот finding не утверждает обратного. Но completed mutation не должна получать право стереть восстановленный override лишь потому, что его bytes совпали с первоначальным preview. Заявление о сохранении intended post-commit retry guard в handoff этим interleaving не покрывается.

**Impact:** Retry после уже совершённого reset может удалить более позднюю явную настройку и завершиться success без нового preview. В native page `.storage` оставляет Retry доступным (`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/SettingsResetController.swift:147–156,225–234`).

**Regression / исправление границы:** дополнить существующий post-rename fixture одноразовым failure hook и одноразовым публичным observer, который восстанавливает `2` после наблюдения absent override. Hook только бросает ошибку; reentry выполняется из observer, без lock waits/sleeps. Следующий `session.run()` должен сохранить новую запись и потребовать новый preview. При неопределённом outcome, уже отличающемся от intended reset, нельзя молча оставлять первоначальный destructive CAS для retry. Для этого не требуется рефакторинг ClientSettings/SCF/SCR. Witness выведен из source; новый Swift fixture здесь не добавлялся и не исполнялся.

## Подтверждённый scope / actual definitions

Проверены непосредственно Original bodies:

- `third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/general/GeneralHelper.java:130–160`: семь config resets + ровно 13 named fields; All дополнительно очищает `nekocloud`, **`nekox_config`** и `nkmrcfg`.
- `third_party/exteraless-android/TMessagesProj/src/main/kotlin/app/exteraless/general/GeneralConfig.kt:155–163`: только семь собственных ConfigItems.
- `third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/config/LegacyDefaults.java:64–67`: `keepPinned` пишет только два marker keys. Циклы BOOL/INT defaults относятся к другому методу `pin` (`:38–61`). Сохранение этих старых BOOL overrides reset не обещает.

Независимый source-data join к реальным declarations/helper expansions дал:

| Selected group | Original fields | Native keys |
|---|---:|---:|
| OpenExtera | 4 | 4 |
| General | 7 | 6 |
| Appearance / Player / AI visibility / Feed | 62 | 60 |
| Chats / Camera / Gallery | 42 | 40 |
| IconPacks | 5 | 4 |
| PillStack | 20 | 20 |
| Utils | 1 | 1 |
| Явные Neko/Na fields | 13 | 13 |
| **Exteraless total** | **141 + 13 = 154** | **148 distinct public keys** |

Шесть unavailable source fields: `GeneralConfig.showNagramSettings`, `AppearanceConfig.centerTitle`, `AppearanceConfig.iosChatHeader`, `ChatsConfig.cameraType`, `ChatsConfig.unmuteWithVolumeButtons`, `IconPacksConfig.customNotificationIcon`. Resolver возвращает их явно, controller показывает disclosure и reason; фиктивные definitions не регистрируются (`CoreSettingsResetOperation.swift:91–115`; `SettingsResetController.swift:134–145`).

Проверен именно Main registration (`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift:55–64,88–90,288–320`) и дополнительный AI visibility registration (`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/AI/ExteralessAIIntegration.swift:106`). В join вошли три настоящих `ChatFeatures` pill-layout keys и три archive-policy keys из `DialogFeatures`; SDK projection не использовался вместо actual definitions.

All содержит **512 source records**: 141 selected-group + 97 Neko + 248 Na + 5 Glyph + 3 cloud + 3 API + 15 других dynamic/legacy identities. Это не 512 native controls и не обещание полного Android raw-file `clear()`. Неизвестные/unregistered keys остаются сохранёнными.

`swift/ExteralessCore/Sources/ExteralessCore/CoreSettingsResetCatalog.swift:135–198` допускает exact/canonical symbols, перечисленные migration aliases и ограниченные bare-AI/dynamic-language joins. Domain prefix сам по себе не даёт reset authority. `CoreSettingsResetPreview.resolve` дедуплицирует по native key, сохраняя source provenance; shared/migrated counterpart сбрасывается один раз.

### Границы сохранения данных

- Registered public targets теряют overrides; native-only keys без соответствующего source symbol, неизвестные JSON entries и unrelated metadata сохраняются. Это не filesystem deletion API.
- `AiConfig`/`Service.key`, Assistant roles/history/services, экспериментальные native-only translation keys и `compat.exteraconfig` не входят в source allowlist. Private hidden-account store, Postbox/account-local identity data и authorization не становятся targets. Shared preferences с явно перечисленным source symbol, включая некоторые account-keyed collections, остаются частью объявленного All scope.
- Original custom API mode/ID/hash действительно находятся в `nekox_config` (`third_party/exteraless-android/TMessagesProj/src/main/java/tw/nekomimi/nekogram/NekoXConfig.java:43–47`). `ClientAPIFeatures.swift:19–36` даёт production/test counterparts: **4 public keys и 2 native credential keys**. Global draft reset не меняет account-pinned vault identities и не очищает pending-save journal: provider не обращается к vault. `ClientAPISettings.swift:33–49` продолжает показывать/reject pending repair. Сброс global hash не означает очистку API identities всех аккаунтов.
- Translation/transcription credentials из Neko/Na и `network.customDoH` входят только в All. Их наличие в scope не даёт права удалить installed plugins/packs/fonts, remote backups либо account databases. Marker keys не создаются; совпавшие registered Original markers также исключаются (`CoreSettingsResetOperation.swift:101`).

## Atomicity, phases, context и redaction

- **Public:** `CoreSettingsResetOperation.swift:281–294` вызывает один `applyPublic([:], resetting: publicKeys, expected: publicExpected)`. Реальный engine проверяет value **и override presence** affected keys под file lock, до удаления, сохраняет unrelated disk keys и публикует одну целую cache generation (`ClientSettings.swift:476–527`). Нет per-key `.set(default)` и public half-reset от одного batch. RSR02 относится к разрешению следующего retry, не к атомарности первого batch.
- **Secrets:** отдельные explicit native `reset(key)`; preparation читает только cache, подтверждённый run reloads/rechecks live native state перед шагами (`CoreSettingsResetOperation.swift:179–196,275–280,298–354`). Это не cross-Keychain/JSON transaction и не atomic secret CAS. Один уже admitted шаг может закончиться после cancellation; следующая credential mutation требует действительной authority.
- **Progress:** confirmed keys означают successful replies, observed keys — текущие absent/default observations. Delete-with-error остаётся pending; intended absent presence защищает обычный credential retry от нового explicit-empty override (`:307–328,396–416`). Успешная поздняя repair другого key не стирает ранее полученную ошибку. Public/credential edits после confirmed phase вызывают `settingsChanged`, без повторного reset подтверждённых фаз (`:380–386`). Ограничение после ошибочного public reply — RSR02.
- **Conflicts:** value/presence CAS conflict превращается в `settingsChanged`; changed selected schema/membership — в `scopeChanged`; эти исходы и retirement latch новый preview (`:334–378,418–423`). Malformed storage не перезаписывается; отдельный explicit retry после восстановления прежнего файла остаётся guarded CAS. Unavailable public typed values блокируют prepare.
- **Reentry:** `executionLock` защищает только admission flag; во время store callbacks lock не удерживается. Nested `run()` возвращает `operationInProgress`, не повторяя mutation (`:255–271`). Core store тоже доставляет callbacks за пределами writer/cache/flock. Deadlock от этого reset lock не найден; RSR02 показывает отдельную проблему interleaving outcome.
- **Context / action:** Root создаёт integration после readiness/регистрации, обновляет после domains и очищает при context retirement (`ExteralessClientRuntime.swift:273–324,382–390`). Parent/child authority и provider/authority IDs проверяются до begin/следующих шагов. Gate проверяет `requested === current` **до controller construction**, затем authority перед presentation (`CoreSettingsResetOperation.swift:30–40`; `SettingsResetIntegration.swift:22–52`).
- **Search:** `ClientSettingsSourceRoutes.swift:315` переводит Original `other.resetSettings/resetSettingsRow` в action `general.settingsReset`. Root переизвлекает актуальную action, Search проверяет context/ticket повторно после `endEditing` (`ExteralessSettingsController.swift:240–253`; `ExteralessSettingsSearch.swift:173–215`). Action открывает preview; reset требует отдельного подтверждения на странице.
- **Deferred UI / sensitive values:** prepare/run completions проверяют captured authority до принятия результата (`SettingsResetController.swift:78–92,225–244`); их ошибки остаются inline, без отложенного error-alert callback. Search error presentation также проверяет current context. Plan/session descriptions и reflection скрывают private baselines (`CoreSettingsResetOperation.swift:119–156,232`); preview/confirmation/progress показывают schema names, keys, counts/presence, не values. Ошибки используют typed `ClientSettingsError`, без raw Keychain/JSON/underlying descriptions (`ClientSettings.swift:8–63,923–936`). Source action URL не содержит reset values. Cancelled-pop recovery отдельно не проходит — RSR01.

## Проверки и pending execution

- Read-only Python source-data check, timeout **30 s**, **0.013 s**: **25/25** embedded Original raw-byte SHA-256 pins; точное совпадение десяти ConfigItem tables (9 Kotlin + Neko Java), включая `glassOutlineStyle` object ConfigItem; точные 13 external symbols; counts 141/154/512 и 17 test methods.
- Независимый source-data join к actual declarations/helper expansions, timeout **30 s**, **0.029 s**: **148** selected native keys и ровно шесть unavailable выше. Это статическое чтение исходников, не execution Swift resolver.
- Прочитаны все **17** `swift/ExteralessCore/Tests/ExteralessCoreTests/CoreSettingsResetTests.swift` fixtures: source scopes/actual defs, exclusions/dedup, real-file CAS/presence/unknown preservation, authority, secret partial/retry/repair, redaction, malformed-file recovery, schema change, reentry, actual API vault/journal и native-action gate. В актуальном fixture исправлено включение `DialogFeatures.definitions`; оба production reset Core-файла относительно `d1df6ad6` не менялись. Связанный Search assertion проверяет action route, не выполнение reset.
- Во время review появился отдельный owner working-tree diff `ClientSettings.definitionVersions`. Проверен его ограниченный эффект на используемый contract: version меняется при schema/classification change, **не** при value/presence/error changes (`ClientSettings.swift:898–920`); public CAS и порядок callbacks → throw сохранены. RSR02 этим schema versioning не закрыт. Ссылки на ClientSettings и hash ниже относятся к этому актуальному файлу; review его не редактировал.
- RSR01 не покрывается Core action-gate fixture: там нет Display navigation lifecycle. RSR02 не покрывается раздельными post-rename/reentrant tests (`CoreSettingsResetTests.swift:309–334,465–480`): нужен их interleaving с новой записью.
- Оба новых Core/UI файла включены production globs; applied harness fingerprint patterns присутствуют в `swift/ExteralessCore/BUILD.bazel:12` и `telegram-ios/submodules/TelegramUI/BUILD:61`. Это source provenance, не build acceptance.
- **Core 17 не запускались на Windows.** Сообщённые **687 Core green** предшествуют reset change. Новый Linux CI не запрашивался; его результат не используется для этого verdict. Native factory, живые accounts/Keychain/network/plugins и power-loss scenarios не запускались.

**Frame expectations / NativeNoCurrentRun:** после исправлений нужны loginless native frames для трёх previews, confirmation cancel, success/partial/retry, context retirement и обоих порядков завершения worker относительно cancelled pop. Вернувшаяся страница должна автоматически получить usable fresh preview; ошибка/partial progress должны быть видны, без secret values, premature dismissal или late result старой authority. Реальные Appearance/chat/pill updates оцениваются по кадрам существующих observers. Записей и labelled-frame evidence здесь нет.

### Reviewed working-tree identities (raw SHA-256)

| File | SHA-256 |
|---|---|
| `CoreSettingsResetCatalog.swift` | `1a5fa016add3d186b9b80bc7c148a0d2472cd06c039e173daaf22725f7e66a65` |
| `CoreSettingsResetOperation.swift` | `fb64f55b1721afd0522749a6daa17664c3710420417e63c4c77370c4f03a524a` |
| `CoreSettingsResetTests.swift` | `95eabe08cdb884122ddae664ec2f1cb7f59508491cbe0018b14a3860ac901a0e` |
| `ClientSettings.swift` | `8677713c19c4ff623caf9437f4ff2613d8665a5f48b89e53a45b348873320701` |
| `SettingsResetController.swift` | `bd97d5f2b322134c78d07616d344c02fc8ee95d00fd1de405fa2282b44fb0ecc` |
| `SettingsResetIntegration.swift` | `bbbdae624a8a00ac07bc30e5402efee0347013ade5273b2a81618bd18cb67e4d` |
| `ExteralessClientRuntime.swift` | `5041de7b3d2e5d0098ec61773eef3617a63984dd167b946e443e1c5242fd48e8` |

Ранее созданные reports сохранены. Review ограничен reset providers/UI и необходимыми caller/store contracts; NativeTitle, Widget и прежние общие audits не переоткрывались.
