# Tools / backup — focused follow-up

**Итог: 1 P1 и 5 P2 остаются ниже.** Исходные ambiguous-restart и pre-swap
rejection counterexamples исправлены в source. Полное закрытие TB-02/03/04
пока не подтверждается: появились проверяемые обходы новых границ. CA-01/02
и production default-deny для HNS-01 исправлены на прочитанном срезе.

## Версия и граница проверки

- Core pin: **`6f718b1108b9f90b5d498e07ee324325842bbe5d`**.
  На проверке `refs/heads/main` и `refs/remotes/origin/main` указывают на него.
  Scoped diff Core `Tools*.swift` / `Tools*Tests.swift` относительно pin пуст.
- Native Tools/Root/Cloud/UI-cache файлы прочитаны из working tree; они не входят
  в Core commit. Runtime и Host также имеют dirty changes. SHA-256 существенных
  файлов приведены в конце. Host прочитан только на maintenance consumer seam.
- Прочитаны `tools-remediation.md`, `tools-schema-evidence-contract.md`,
  `tools-owner-completion.md`, исходные TB/CA/HNS reports и относящиеся к ним
  implementation/tests. Указания AGENTS/CLAUDE из предыдущего ревью учтены.
- Последний предоставленный green —
  **`7d04a35a3612a2dc32dba6fb54744e38c07cabe9`: 545 Core / 169 Host / 30 Hooks**.
  Он **не включает новый Tools cohort**. Новый CI здесь не читался и не запускался.
  Пересчитаны 84 Core Tools XCTest methods в 16 test files; число не означает pass.
- `swift`/`swiftc` локально отсутствуют. Выводы ниже — source/control-flow proof,
  с малыми детерминированными regression recipes, а не выполненные Swift tests.
  Native decoder, UIKit, Darwin filesystem/power-loss и frames не исполнялись.
  Собственные процессы/сетевые/account/plugin fixtures не запускались.
- Старый `tools-backup.md` сохранён read-only. Этот follow-up касается TB-01…07,
  admitted projection CA-01/02 и schema authority HNS-01.

## Оставшиеся findings

### TBF-01 — P1 — TB-02: swap receipt не связан с проверенным manifest кандидата

**Место:**
`swift/ExteralessCore/Sources/ExteralessCore/ToolsBackupRestore.swift:180,194–218,243–272,447–481,570–588`.

**Forward counterexample:** маленький разрешённый `nativeImmutable` fixture,
`fixture.json = {"style":"old","token":"local-only"}`, import меняет только
`style` на строку `new`. После подготовки `targetFiles` в имеющемся
`fault(.afterPrepared)` заменить **stage/fixture.json** на `{"style":false}`.
Live original, schema source, evidence и account остаются прежними.

Перед swap проверяются original live manifest и original schema snapshot.
Но `replaceDirectory` заново снимает identity/versions **уже изменённого stage**
и не получает ожидаемый `targetFiles`. Его post-swap checks доказывают только,
что эти свежеснятые bytes/inodes переставились без следующего изменения.
Далее записывается `.committed` и возвращается success: в live оказываются
невалидный для schema Bool и потерянный local token вместо проверенного target.

**Rollback counterexample того же пробела:** после confirmed forward write
бросить ошибку в `.afterClientCommit`. Rollback проверит backup manifest на
строке 453 и выполнит client CAS. В `.afterClientRollback` изменить файл в backup.
Строка 478 копирует backup повторно и **отбрасывает возвращённый manifest**.
Последняя проверка относится только к live receipt; изменённая копия попадает
в live, после чего журнал объявляется `.rolledBack` и originals удаляются.

Это не старое присвоение native target до swap: его новая ветка действительно
отвергает. Здесь receipt удостоверяет перестановку неправильного кандидата.
Сценарии относятся к разрешённой immutable ветке Core API; текущий arbitrary
Python producer её не открывает — он правильно выдаёт nil evidence.

**Fix / regression:** связать receipt с записанным expected target/original
manifest и с теми же fd-bound bytes, из которых строится replacement. Перед
publication подтвердить expected manifest, а после — expected image; при
несовпадении сохранить evidence и `needsRecovery`. Копия для rollback обязана
совпадать с original manifest, а не с новым чтением backup по имени.
Два Darwin tests с указанными существующими fault points и одним маленьким
JSON должны проверить: чужие stage/backup bytes не становятся live, нет ложного
committed/rolledBack, нет удаления единственного recovery evidence. Сохранить
positive controls `ToolsBackupTests.swift:221–250`.

### TBF-02 — P2 — TB-03: структурно корректный Postbox с неправильным типом всё ещё trap

**Место:**
`telegram-ios/submodules/TelegramCore/Sources/ExteralessTools/ToolsLocalFavoriteStickers.swift:36–43,54–58`;
`swift/ExteralessCore/Sources/ExteralessCore/ToolsPostboxPreflight.swift:54–95`;
`telegram-ios/submodules/Postbox/Sources/Utils/Decoder/AdaptedPostboxKeyedDecodingContainer.swift:36–47`;
`telegram-ios/submodules/Postbox/Sources/Utils/Decoder/AdaptedPostboxUnkeyedDecodingContainer.swift:80–126`.

**Малый fixture:** тем же реальным `EnginePreferencesEntry` encoder, который
использован в новом native test, закодировать:

```swift
struct WrongLegacy: Codable {
    let version: Int = 1
    let userId: Int64 = 101
    let stickers: [String] = ["x"]
}
```

Все signed lengths, UTF-8, counts, nested boundaries и field budgets легальны.
Новый grammar preflight принимает `StringArray` (type 12). Затем
`PreferencesEntry.get(ToolsLocalFavoriteRecord.self)` ожидает
`[ToolsFavoriteSticker]`. Keyed adapter выбирает decoder по **wire type**, а
generic unkeyed reader на строке 126 выполняет `String as! ToolsFavoriteSticker`.
Это process trap до проверки `record.version`, account и DTO validation;
`get`/Signal catch такой trap не преобразуют в error.

Другой простой вход — object вместо ожидаемого array: structural preflight
принимает его, а `_AdaptedPostboxDecoder.unkeyedContainer()` вызывает
`preconditionFailure` для `.object`
(`.../AdaptedPostboxDecoder.swift:113–125`). Аналогичный unchecked generic
adapter остаётся на извлечении cloud `fd/sr` перед FlatBuffer verifier.

**Что исправлено:** исходные отрицательные 11 bytes теперь отвергаются в
`ToolsPostboxPreflight.length:29–36`. Новый raw v2 record и собственно
`getCheckedRoot` не используют прежний unchecked media `_parse` путь. Проблема
остаётся в **typed shape**, а не в уже исправленной проверке длины.

**Fix / regression:** проверять ожидаемую схему legacy local / cloud wrapper до
generic construction либо заменить эти adapters на полностью throwing typed
decode. Structural grammar сама по себе не делает данный Postbox decoder safe.
Добавить tiny valid-wire/wrong-type fixtures для `stickers`, `aliases`, `fd/sr`,
object-vs-array и primitive arrays. Требование: error с исходными bytes intact,
без cast/precondition trap; реальный корректный v1 record всё ещё мигрирует в v2.
Новые native tests сейчас покрывают negative length и один valid v1 record,
но не эти случаи (`ToolsFavoriteStorageNativeTests.swift:21–45`).

### TBF-03 — P2 — TB-04: terminal cleanup удаляет каталоги по имени без ownership

**Место:**
`swift/ExteralessCore/Sources/ExteralessCore/ToolsBackupRestore.swift:607–618`;
аналогичные path-based cleanup — `:189–191,475–477`.

`cleanup(journal, ...)` сразу отбрасывает все journal metadata и передаёт только
UUID. Два computed scratch names удаляются через recursive
`FileManager.removeItem`, без проверки directory inode или принадлежности файлов.

**Детерминированный counterexample даже для client-only restore:** в
`.afterPrepared` прочитать transactionId из маленького journal и создать
`tools-settings-original-<id>/foreign.bin`. Эта транзакция вообще не создавала
plugin stage/backup (`originalFiles == nil`). Дать client commit завершиться.
Cleanup удаляет чужой каталог только потому, что его имя совпало с шаблоном.
Для plugin restore аналогично заменить stage directory другим inode в
`.beforeCommitMarker`: чужие файлы будут удалены после успешного commit.

`checkedChild` отвергает symlink, но обычный replacement directory проходит.
Новый `ToolsDirectoryDescriptor.removeOwnedChecked` здесь не используется.

**Fix / regression:** не очищать scratch, которого операция не создавала;
сохранять receipts созданных/обменённых directory identities и ограничивать
cleanup принадлежащими операции entries через pinned descriptors. При foreign
replacement сохранить его и cleanup debt. Добавить client-only foreign-name
fixture выше и rename/replacement для обоих scratch directories; проверить
foreign bytes intact, удаление собственных partial и повтор terminal cleanup.

### TBF-04 — P2 — TB-04/05 intersection: verified IPA публикуется уже без fd receipt

**Место:**
`swift/ExteralessCore/Sources/ExteralessCore/ToolsReleaseClient.swift:63–81,322–350,368–377`.

Transfer теперь правильно сериализует cancellation, close и unlink. Однако
успешный finish закрывает fd и делает `handle = nil` **до** передачи результата.
Caller проверяет только сохранённые count/digest/prefix, а затем выполняет
path-based `FileManager.moveItem(partial, complete)`.

**Малый воспроизводимый сценарий:** URLProtocol отдаёт шесть bytes A с `PK` prefix
и правильным SHA(A). В уже существующем `transferHooks.afterCleanup` атомарно
заменить `fixture-arm64.ipa.partial` шестью другими bytes B. Вся замена помещается
между close и `continuation.resume`. Caller принимает digest(A), перемещает B и
возвращает `ToolsDownloadedUpdate(sha256: SHA(A), ...)`, хотя файл содержит B.
Сеть и настоящий IPA для этого fixture не нужны.

В error/cancel ветке тот же caller recursively удаляет `folder` по пути. Если
его inode заменён, эта внешняя уборка также не ограничена созданной директорией.
Таким образом, новый transfer owner исправляет late callback race, но его
file capability теряется перед final publication/outer cleanup.

**Fix / regression:** передавать caller retained output/parent receipt и
выполнять final no-replace publication и cleanup через него. Проверять version
проверенного файла, включая замену между hash/close/publication, и не возвращать
verified result для другой identity. Использовать `afterCleanup` для теста A→B;
ожидать отказ, отсутствие ready result и сохранение foreign files. Отдельно
проверить замену folder до error cleanup и положительный download control.

### TBF-05 — P2 — TB-01 native tail: «Keep current» не возобновляет blocked startup

**Место:**
`telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift:103–139,234–235,275–289,669–685,739`;
`swift/PluginHost/Sources/PluginHost/PluginHost.swift:872–904`;
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Tools/ExteralessBackupController.swift:104–120,264–279`.

**Сценарий:** cold launch с ambiguous journal. Runtime уже сохранил новый Host,
но `recoverBeforeStart` бросает до `host.start()`. Завершившийся `startup` Task
остаётся в свойстве, а `startupError` содержит старую ошибку.

Реальные bindings доступны, пользователь открывает Recovery и успешно выбирает
Keep current. Journal архивируется/retired; finish возвращает success. Однако
Host lease снят с `wasRunning=false`: его `finish(resume:true)` правильно
**не запускает Python**. Runtime не очищает failed startup/error и не продолжает
прерванную startup sequence. Последующий `start()` отсекается `startup != nil`,
`ready()` получает `!host.isRunning`, mode toggle отказывает из-за startupError.
Данные сохранены, но штатный повтор запуска не восстановлен; остаётся перезапуск
приложения, не действие заявленного recovery flow.

**Fix / regression:** после успешного reconciliation продолжить именно этот
неинициализированный Host через owned startup/retry state, с текущим account
scope и manager policy, без второго Host или terminal stop→start. Обновить
startup/error state только по реальному результату. Fake-engine native fixture:
ambiguous cold start → actual recovery service → Keep current → один обычный
start и рабочий manager; account retirement/failed reconciliation не стартуют
ничего. Core test «unblocks next restore» не проверяет Runtime startup.

### TBF-06 — P2 — HNS-01 evidence fixture завершается до restore/positive проверки

**Место:**
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/Tests/PluginUIRemediationFixture.swift:127–138,284–290`;
`swift/ExteralessCore/Sources/ExteralessCore/ToolsBackupArchive.swift:264–269,369–374`.

В `dynamicSchemasNeverAuthorize` payload создаётся с `createdAt: "fixture"`.
`ToolsBackupArchive.encode` требует ISO-8601 date и бросает **до** `hnsReject`
на restore. Этот throw выходит в `main`: `sourceAndUnloadSnapshotsAreChecked`
и последующие worker scenarios вообще не выполняются при включении
`PLUGIN_UI_REMEDIATION_FIXTURE`. Это source failure подготовленного fixture,
не результат прочитанного CI и не дефект production nil-evidence denial.

**Fix / regression:** валидная fixed ISO timestamp; отдельно подтвердить, что
archive действительно построен, а отказ приходит именно из schema authority
boundary при вызванном restore. После этого выполнить существующие positive
native-declaration/source/unload/ABA controls, не выдавая их за enforcement
immutability произвольного SDK `create_settings`.

## Closure по исходным counterexamples

### TB-01 — исходная client-authorship ошибка закрыта в Core source

- `ToolsBackupRestore.swift:194–243` отделяет invocation-local disposition от
  journal. Known rejection и failure до forward call не становятся `.applied`.
  Для uncertain/durability нет автоматического setter rollback (`:251–268`).
- Restart v1/v2/v3 не вызывает target-to-before setter: `recoverLocked:398–433`
  использует только optional readonly `isAlreadyBefore:488–496`, иначе hold.
  `clientSettings` намеренно не выдаёт cache/reload за fresh read (`:63–71`).
- Live confirmed write допускает один target-image CAS (`:458–471`); после
  rejection есть только fresh readonly check, второго setter нет. Повтор после
  rollback-marker failure попадает в restart policy, а не второй rollback.
- `ToolsRecoveryRegressionTests:32–103` покрывают native exact target до forward,
  repeated recovery после выполненного rollback, настоящий Core post-rename
  failure и no-setter already-before. `ToolsBackupTests:278–310,360–369`
  сохраняют actual confirmed live CAS positive/negative controls.
- Это value/presence CAS, не новая ревизионная транзакция Core. Source не доказывает
  более сильное распознавание произвольного ABA после подтверждённого live write;
  future receipt API в remediation остаётся именно future API.
- Keep-current Core API действительно не вызывает live setters, сравнивает review,
  сохраняет evidence и убирает active journal (`:295–330`). UI route реальный, но cold
  startup continuation остаётся TBF-05.

### TB-02 — исходный pre-swap rejection закрыт; receipt coverage неполна

`notStarted/swapAttempted/confirmed` и `.rollingBack` есть. Native exact target/
third image до swap приводит к `rollbackFailed` без client setter и без plugin
replacement. Darwin regression — `ToolsRecoveryRegressionTests:128–158`.
Restart больше не выводит swap ownership из target hashes. Для confirmed live
rollback проверяются directory inode и file metadata, включая mtime/ctime.
Не хватает привязки самого replacement к ожидаемому manifest — TBF-01.

### TB-03 — negative length и unchecked FlatBuffer entry исправлены частично

Original 11-byte fixture отсекается до generic get; counts/depth/work/UTF-8
ограничены. Current `fd` проходит реальный throwing `getCheckedRoot` с
`maxDepth=24`, `maxTableCount=4096`, `maxApparentSize=4 MiB`; проверена его
реализация `TelegramCore/FlatBuffers/Sources/Root.swift:92–105`. Legacy cloud `f`
явно отвергается. Новый local raw JSON v2 идёт напрямую через checked JSON decode,
валидный v1 мигрирует при следующей успешной mutation. При этом generic typed
legacy wrappers ещё не защищены от valid-wire/wrong-type — TBF-02.

### TB-04 — fd-bound чтение и Files no-replace исправлены; cleanup/publication tails открыты

`ToolsFileDescriptors.swift:108–147,281–328` держит ancestor descriptors,
использует `openat/O_NOFOLLOW/O_NONBLOCK`, сравнивает fd/path metadata до/после
read. `ToolsFileSaving.swift:41–74` проверяет source повторно перед publication;
Darwin `RENAME_EXCL` / Glibc `linkat` не затирают racing destination
(`ToolsFileDescriptors:242–268`). Destination coordination реально находится
в `ExteralessFileSaving.swift:45–57`. Пять `ToolsFileRaceTests` используют реальные
малые файлы/барьеры и проверяют старые leaf/ancestor/source/collision сценарии.
Эта граница не охватывает recursive restorer cleanup и updater handoff — TBF-03/04.

### TB-05 — исходный late callback cancellation race закрыт в source

`ToolsReleaseClient.swift:207–215,236–279,282–350` закрывает admission под lock,
ставит cleanup на ту же serial queue и возобновляет caller после close/unlink.
Response/data/redirect после cancelled/finished не создают файл и не публикуют
progress. Retained cleanup owner имеет retry на terminal/invalidation callbacks.
Новые `ToolsReleaseTests:114–178` используют actual URLProtocol, headers/first-write
barriers и late provider callbacks; последнее — Darwin-only. Success publication
из отдельного caller остаётся TBF-04, не прежним late delegate race.

### TB-06 — исходная aggregate allocation ошибка закрыта в source

`ToolsBackupArchive.swift:218–261` не удерживает массив всех plugin files:
остаток raw/encoded budget проверяется до открытия/чтения очередного JSON.
`ToolsBoundedJSON.swift:12–68` проверяет каждый append/escape/value, depth и nodes.
Base64 размер проверяется до аллокации (`ToolsBackupArchive:288–298`).
Programmatic payload и favorite encoders также используют bounded output.
`ToolsArchiveBudgetTests` применяют уменьшенный cap и read counter, а не OOM;
source paths подтверждают остановку до materialization третьего файла.

### TB-07 — исходный creating-getter вызов закрыт в source

`PluginServiceStorage.settingsDirectoryURL():50–58` не вызывает mkdir.
Runtime startup (`:234–235`) и live location (`:706–709`) используют именно его;
post-drain freeze берётся после actual lease (`:637–641`).
`PluginServiceStorageTests.testBackupLocationResolutionDoesNotCreateStorageBeforeItsLease`
— supplied regression, не новый pass этого reviewer.

### CA-01/02 — admitted write set и native-managed exclusion закрыты в source

- `ToolsBackupInspection.admittedPayload:44–51` строится из подтверждённых
  `settings/resetting`, не raw original fields. Revalidate (`:272–285`) допускает
  только subset keys и отдельно subset setters/resets. Restorer использует его
  (`ToolsBackupRestore:138`); UI include-plugin toggle использует ту же projection
  (`ExteralessBackupController:73–75`). Новые definitions не превращают ignored
  key в write/reset; source stored-default presence сохраняется.
- Native Cloud `perform:49–62` валидирует `CloudPublicRestoreProjection` и
  передаёт тот же inspection в реальный Tools restorer. Projection проверяет
  exact payload/setter/reset/presence correspondence, а не только counts.
- `isPortableClientKey:109–112` исключает весь case-folded `clientAPI.*` и
  `cloud.includeApiKeys`; policy вызывается на export, new encode, old-archive
  inspection, admitted projection и **после alias resolution** в legacy rules.
  Native API hash/tuple/pins и opt-in permission не становятся general-backup
  writes или resets. `cloud.autoSync` при этом не включает key permission.
- `ToolsAdmittedProjectionTests:25–120` используют actual Core store/restorer,
  independent bot-ID edit, new definition, stored/absent cases, старые v1/v2
  envelopes, два synthetic credential stores и alias с forbidden canonical key.
  Их ожидаемые no-secret-read/write assertions соответствуют source path.

### HNS-01 — dynamic default-deny закрыт; positive Core proof не равен native guarantee

- Runtime использует `PluginUIUnprovenSchemaCache`: `recordDynamic` всегда
  передаёт `evidence:nil`, location — `validity:nil` (`:14–22`). Epoch, одинаковые
  past bytes и JSON annotation не могут создать `.nativeImmutable`.
- Core cache eligibility требует immutable evidence + validity; actual I/O повторно
  проверяет schema/evidence/field-map и actual source/settings hashes.
  Arbitrary UI schemas дают пустой export и отказ непустому plugin restore.
  Перед drain Runtime очищает cache; location снимается после lease. Нет Python
  schema refresh из backup/recovery.
- `ToolsSchemaEvidenceTests:35–99` и `ToolsSchemaFixture` — отдельный positive
  native-declaration **fixture**. Source/owner/account/revision rejection, cache
  revocation и post-unload bytes проверяются через реальный Core interface.
  Production native immutable issuer/ревизионный writer этим fixture не создан.
- Нынешний native HNS positive/ABA fixture явно отзывает pin после возврата bytes
  к прежнему состоянию (`PluginUIRemediationFixture:297–324`). Это проверяет
  отзыв предоставленной authority; не доказывает автоматический ABA revision
  tracking у произвольного SDK. Его последовательный запуск сейчас блокирует
  TBF-06. Статус HNS production denial и статус этого evidence различаются.

## Реальная recovery composition / lifetime

`AppDelegate.swift:1593–1594` сначала публикует context в PluginRuntime, затем
вызывает `ExteralessClientRuntime.bindPluginRuntime`. Root выдаёт **тот же binding**
Tools и Cloud до проверки доступности shortcut manager (`:307–320`); поэтому
failed startup не скрывает Recovery. На teardown token инвалидируется, screens
закрываются и bindings очищаются (`:360–384`).

Runtime begin не требует `host.isRunning`/successful ready: ждёт имеющийся startup,
получает настоящий повторный maintenance lease либо использует доказанный no-Host
case. Context проверяется в captured closures. UI runner проверяет generation/
context/cancellation **до** operation (`ExteralessToolsUI.swift:110–114`);
после lease service ещё раз получает context-bound location. Keep-current finish
называется committed именно для reconciliation, ошибки сохраняют needsRecovery;
finish не вызывается повторно с противоположным исходом. Дефект оставшегося
startup continuation описан в TBF-05.

## Fingerprints native/shared source

Префиксы: `UI/` = `telegram-ios/submodules/TelegramUI/`,
`TC/` = `telegram-ios/submodules/TelegramCore/`,
`H/` = `swift/PluginHost/Sources/PluginHost/`,
`NTests/` = `telegram-ios/Tests/Exteraless/`.

```text
0760f7701e963c1ea052f6dbe6d5b3b7924293b323bfba273922d3d3ad63af65  UI/Sources/Exteraless/ExteralessPluginRuntime.swift
68bf0031a8f309251776610c36e782bb53a5674aa8449756272104b43c6a86b1  UI/Sources/ExteralessClient/ExteralessClientRuntime.swift
392c9f2cf76a090454403d9ee4466c019c2259ce5492810d70d80b5195553438  UI/Sources/ExteralessClient/Tools/ExteralessBackupController.swift
18de65c08983a260e61f7807863fbf28549a46ee4073133903c44c2d419a58b8  UI/Sources/ExteralessClient/Tools/ExteralessToolsUI.swift
9cb7a07fa3c0944498d00d3ca52c60842cd66c24dac8eee06def7af0a24fa4cc  UI/Sources/ExteralessClient/Tools/ExteralessFileSaving.swift
5a0ace71ba47d3dba48f0528467a6851fb9f132a81a220dd70f1aa00c39afa2c  TC/Sources/ExteralessTools/ToolsLocalFavoriteStickers.swift
4b7a0d43670f232fcdceb41aaaa2b67e357a769a3bb666281044c3ef9af46d67  UI/Sources/ExteralessClient/Cloud/ExteralessCloudArchiveHost.swift
efdae501c1c6d572df99c402331ff181b351f9b1fccc88f20f9deb47cb52e1e7  UI/Sources/ExteralessClient/PluginUI/PluginUIUnprovenSchemaCache.swift
68f952859af2c02fb93493b6bd8c66a57c9cfdbe63a0c70642fec4477d00ab41  UI/Sources/ExteralessClient/PluginUI/Tests/PluginUIRemediationFixture.swift
db6dad816dcf11ccd82400f753c42dc46d20acfb4ec11fed33db541fb1435837  H/PluginHost.swift
75f2a6b70c433ea5ef7fd87e712db9a5d02a94f85744a9c7664a523e56b26cea  H/PluginServiceStorage.swift
5dc5eee94906c5d47722790c94adcc69a3eed55b7db42135092eab126ebf80b1  NTests/ToolsFavoriteStorageNativeTests.swift
```

Old report SHA-256 на follow-up:
`556bab814c3a01d20ebe42f20813620f8e72ff29abf31f53447ade3b3fe548ef`.
Source closure здесь не является native compilation, recorded-frame acceptance
или доказательством Darwin power-loss durability.
