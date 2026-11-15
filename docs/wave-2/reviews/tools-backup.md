# Независимое ревью Tools / backup — 2026-11-15

**Итог: 2 P1 и 5 P2. P0 не найден.** Основные проблемы — потеря независимых
изменений при rollback/recovery, проверка cached favorites после небезопасного
декодирования и незавершённое владение файловыми операциями. Исправления и новые
XCTest ниже — рекомендации; исходники этим reviewer не изменены.

## Срез и доказательства

- Начальный source pin:
  **`b1424e109ce1562ffc2a74e428e7577b0432dbd0`**, тогда одновременно
  `HEAD -> refs/heads/main` и `refs/remotes/origin/main`.
- Во время чтения refs перешли на
  **`33ff6dce8751f30ec30b3a2cdee970fbec36e0ec`**. Между этими commits изменены
  только документы. Scoped `git diff b1424e10 -- .../Tools*.swift
  .../Tools*Tests.swift` пуст: все **15 Core Tools sources и 8 test files**
  соответствуют первому pin. Native/shared файлы — рабочее дерево; их SHA-256
  приведены ниже. Номер строки относится к прочитанному файлу, а не к handoff patch.
  При финальной сверке перечитаны изменившиеся Runtime/Root consumer-фрагменты,
  ToolsIntegration и Gallery adapter. Поздние Gallery hunks отмечены как применённый
  source, с отдельным fingerprint node; native execution ими не подтверждён.
- Прочитаны `telegram-ios/AGENTS.md`, `CLAUDE.md`, `docs/wave-2-contract.md`,
  `tools-phase-2.md`, `tools-ready-contract.md`, `host-maintenance.md`,
  gallery/favorites/retention handoffs. Проверены все Core `Tools*.swift`,
  соответствующие tests, native `ToolsLocalFavoriteStickers.swift` и 12 файлов
  `ExteralessClient/Tools`. Cloud archive/host, storage accessor, native composition,
  Postbox decode и camera callsites прочитаны как зависимости/потребители.
- Android сверка: `EtgBackup.java`, `GitHubUpdater.java`, `FaveStickersBackup.java`,
  `VideoSubtitlesHelper.java` под
  `third_party/exteraless-android/TMessagesProj/src/main/java/app/exteraless/`.
  Их source tree на pin — `5cc4ad2225889bcd149fa14dc6e447b92a3fc341`.
- Исходное сообщение о 122 baseline / 273+ cohort учтено. К концу чтения
  `docs/wave-2/progress.md:5–12` сообщает **Linux gate `43693106297` на
  `b1424e10`: 280 Core + 89 Host + 16 Hooks passed**. Это атрибутированное
  сообщение coordinator, не запущенный или заново проверенный здесь CI.
  Оно не покрывает текущие uncommitted SC/AI fixes и native UIKit integration.
- В Tools найден **51 XCTest method**, из них три directory-swap/recovery tests
  под `canImport(Darwin)`. Локальный `Get-Command swift,swiftc` ничего не нашёл.
  Swift, Python, CI, внешние плагины и реальные аккаунты здесь не исполнялись.
  Выполнены только read-only source/ref checks и две малые in-memory проверки
  данных, описанные в TB-03/TB-06. Файловые fixtures вне отчёта не создавались.
- SC-01…08 остаются у Settings owner. Их ошибки numeric decoding, secret migration
  и Core directory-sync retry не переименованы в Tools findings. TL/Host shared
  work остаётся активным; здесь оценён его опубликованный lease contract и
  потребители, без итогового verdict реализации Host.

## TB-01 — P1: `uncertain` recovery присваивает себе независимую client-запись

**Место:**
`swift/ExteralessCore/Sources/ExteralessCore/ToolsBackupRestore.swift:178–189,228–255,268–278`;
`ToolsBackupTests.swift:171–183,348–358`.

**Сценарий:** исходный `tools.cameraStabilization` отсутствует, effective=false.
Импорт предлагает явный true. Restorer сохраняет `clientPending/uncertain`
**перед** вызовом `applyAtomically`. Независимый native writer сохраняет true,
после чего процесс прерывается до forward CAS. Эквивалентное окно: CAS уже
отвергнут, но `clientRejected` ещё не удалось записать на диск.

На следующем запуске видны правильный native true и журнал вида:

```json
{
  "version": 2,
  "transactionId": "11111111-1111-4111-8111-111111111111",
  "before": {"values": {"tools.cameraStabilization": false}, "storedKeys": []},
  "target": {"values": {"tools.cameraStabilization": true}, "storedKeys": ["tools.cameraStabilization"]},
  "phase": "clientPending",
  "clientWrite": "uncertain"
}
```

`recoverLocked` вызывает `rollback`; ветка `uncertain` делает CAS против target.
Он совпадает, поэтому чужой true сбрасывается в отсутствие override. Forward
write самого Tools в этом сценарии вообще не состоялся. Это не допустимый ABA
после собственной записи: изменение предшествует ей.

**Доказательство:** `testClientOnlyJournalRecoveryDoesNotRequirePluginBackup`
создаёт именно такую пару journal/current и ожидает её замену на false/absent.
Текущий тест rejection проверяет только непрерванный путь, в котором disposition
успели сохранить. В двух историях — «записал Tools» и «записал native до CAS» —
все данные, доступные `rollback`, одинаковы. Ещё одно чтение snapshot их не различит.
Повтор recovery имеет ту же проблему после успешного client rollback, если сбой
случился до terminal journal и native затем снова записал target.

**Исправление / test:** подтверждать происхождение forward/rollback записи
durable transaction receipt/revision в той же атомарной client transaction.
При отсутствии такого доказательства ambiguous journal должен сохраняться как
`needsRecovery`. Добавить real-Core fixture: независимый writer устанавливает
target, forward CAS не выполняется/отвергается, на диске остаётся pending journal;
новый restorer обязан сохранить native value и presence. Отдельно — повтор после
частичного rollback и отказа записи terminal marker.

## TB-02 — P1: plugin rollback отменяет native edit после отказа **до** directory swap

**Место:**
`swift/ExteralessCore/Sources/ExteralessCore/ToolsBackupRestore.swift:160–175,199–213,280–289`.

**Сценарий:** `fixture.json` содержит `{"style":"old"}`, staged target —
`{"style":"new"}`. После `.afterPrepared`, до проверки на строке 172,
независимый native файловый writer меняет live файл на ровно staged target.
Проверка `directoryManifest(root) == originalFiles` правильно отвергает commit;
`replaceDirectory` ещё не вызывался.

Но catch запускает `rollback`. Для plugin store нет аналога `clientWrite`:
`current == target` трактуется как собственная запись даже при `.prepared`.
Строка 289 заменяет каталог оригиналом. Native new теряется, client CAS не
вызывался, а вызывающая сторона получает обычную ошибку с outcome `rolledBack`.

**Доказательство:** достаточно имеющегося `fault(.afterPrepared)` для записи
точных target bytes. Отказ forward manifest уже предусмотрен самим restorer;
проверка target в rollback уничтожает именно распознанное независимое изменение.
Не требуется работающий Python или нарушение drain со стороны Host.

**Исправление / test:** в текущем вызове отдельно учитывать, был ли swap вообще
начат; pre-swap rejection не должен изменять plugin store. Для crash recovery
нужны достоверные swap/rollback receipts, а не вывод об авторстве по равенству
хэша. Darwin fixture с двумя маленькими JSON файлами и `.afterPrepared` должен
проверить сохранение native target, отсутствие client writes и корректное
завершение lease. Дополнительный control: native третье значение сохраняется с
`needsRecovery`, подтверждённый собственный swap штатно откатывается.

## TB-03 — P2: corrupt cached favorite blob может trap до проверки лимитов/версии

**Место:**
`telegram-ios/submodules/TelegramCore/Sources/ExteralessTools/ToolsLocalFavoriteStickers.swift:28–34,49–54,70–77,90–96`;
`telegram-ios/submodules/Postbox/Sources/PreferencesEntry.swift:68–72`;
`telegram-ios/submodules/Postbox/Sources/Coding.swift:113–118,945–979,2018–2037`.

Внешний favorite archive действительно декодируется в ограниченные DTO. Однако
существующая локальная preference сначала поступает в `entry.get(...)`, и лишь
**после** native decode проверяются version, account, 10 000 records и field
limits. `get` не является throwing safety boundary: `PostboxDecoder` при совпадении
ключа/type возвращает offset без проверки длины matched object, затем передаёт
его signed length в `ReadBuffer.makeData()`.

**Малый counterexample cached preference:** 11 bytes

```text
01 5f 05 00 00 00 00 ff ff ff ff
```

Это ключ `_`, `ValueType.Object = 5`, произвольный type hash и object length=-1.
В in-memory PowerShell проверено: `FixtureBytes=11`, `SignedObjectLength=-1`,
`ActualBodyBytes=0`. По фактическому call chain отрицательная длина доходит до
`Data(bytes:count:)`, не до `ToolsError.invalidArchive`. Swift trap здесь локально
не запускался. Положительный length за концом buffer также не проверяется в этом
matched-key пути.

**Impact:** damaged preference блокирует чтение, import и remove; они все
декодируют старое значение первым. Добавленный picker consumer
`EmojiPagerContentSignals.swift:1729–1754` расширяет путь до обычной клавиатуры;
его Signal `catch` не перехватывает Swift trap. Native cloud cache также идёт
через `SavedStickerItem` и `_parse()` до Tools metadata validation.
`SyncCore_SavedStickerItem.swift:18–23` использует generic FlatBuffer/Postbox
decode. Android opaque TL blob (`FaveStickersBackup.java:95–107`) в новом import
формате не принимается; archive quota не доказывает безопасность этих cached
native blob readers.

**Исправление / test:** обеспечить bounded, checked storage decode **до** generic
Postbox/FlatBuffer construction, включая signed lengths, counts и byte ranges;
либо хранить Tools record в собственном versioned bounded data envelope с
проверенным извлечением bytes. Одной проверки `entry.data.count` недостаточно
для отрицательной вложенной длины. Native regression: tiny malformed entry выше,
truncated object, small oversized declared count и валидный record другого user;
получить error, сохранить исходные bytes, не trap и не записать пустой список.
`StickerFavoritesIntegrationTests.swift:6–7` явно не создаёт Postbox и этот путь
не проверяет.

## TB-04 — P2: path validation отделена от открываемого file descriptor

**Место:**
`swift/ExteralessCore/Sources/ExteralessCore/ToolsFileSafety.swift:45–71`;
экспорт — `ToolsBackupArchive.swift:165–172`;
copy — `ToolsFileSaving.swift:40–64,85–90`.

**Сценарий:** разрешённый `public.json` проходит `checkedChild` и проверку regular
file/size. Между `attributesOfItem` и `FileHandle(forReadingFrom:)` другой writer
заменяет его symlink на второй маленький JSON. `FileHandle` следует новой ссылке;
descriptor ни разу не проверяется через `fstat`, inode/identity с проверенным
объектом не сопоставляется. Export может включить одноимённый разрешённый field
из другого файла. Такой же промежуток существует у source в Files saver;
проверка directory ancestry тоже не удерживает directory descriptor.

Это конкретное TOCTOU, а не отсутствие проверки строк: статические symlink,
traversal и case aliases уже отвергаются. Export выполняется при работающих
plugin writers; `NSFileCoordinator` для picked file не сериализует произвольные
native/POSIX writers. Последующий byte cap ограничивает размер, но не источник.

**Исправление / test:** открывать проверяемый объект без следования symlink и
проверять regular-file/size на полученном fd; привязывать traversal к directory
fd/identity. Destination publication должна сохранять no-replace гарантию вместе
с проверкой каталога. Provider coordination следует выполнять на фактическом
Files destination. Bounded race fixture: два собственных маленьких файла,
барьер после metadata check, замена leaf/ancestor; ожидать отказ и отсутствие
чужих bytes в export/output. Существующий `ToolsBackupTests.swift:93–103`
проверяет только заранее установленный symlink.

## TB-05 — P2: updater возвращает cancellation до завершения владельца `.partial`

**Место:**
`swift/ExteralessCore/Sources/ExteralessCore/ToolsReleaseClient.swift:53–64,178–188,233–267,275–290`.

`cancel()` сразу возобновляет continuation с `CancellationError`. Внешний
`download` удаляет folder и возвращает, пока serial delegate ещё может создавать
partial, писать в handle или вызывать progress. В `didReceive(response/data)`
проверки cancelled нет; закрытие handle принадлежит только позднему
`didCompleteWithError`.

**Failure schedule:** отменить после принятия response, когда его delegate block
ещё выполняется. Cleanup каталога пересекается с созданием partial. При отказе
удаления непустого/занятого каталога единственный `try? removeItem` проглатывает
ошибку; позднее закрытие файла его уже не удаляет. Даже при успешном POSIX unlink
возврат cancellation не подтверждает освобождение открытого файла. UI generation
guard подавляет старый progress, но не завершает его файлового владельца.

**Исправление / test:** сериализовать terminal cancellation и cleanup с delegate
file operations; запретить поздний create/write/progress и поручить последнему
владельцу handle окончательное удаление. Быстрый ответ caller допустим, если
остаётся явный cleanup owner и повтор удаления после закрытия. Tiny URLProtocol
fixture должен остановиться на headers/first chunk, отмениться, затем доставить
queued callbacks; после drain не должно быть partial/folder, открытого handle
или late progress. Текущий cancellation test (`ToolsReleaseTests.swift:94–105`)
останавливает **metadata** request и вообще не создаёт output file. Filesystem
interleaving на Darwin этим ревью не исполнен.

## TB-06 — P2: plugin export применяет суммарный бюджет после накопления всех файлов

**Место:**
`swift/ExteralessCore/Sources/ExteralessCore/ToolsBackupArchive.swift:162–179,182–188,271–284`.

В цикле export есть 1 MiB/file и 256 files, но нет running payload budget.
Все разрешённые значения сохраняются в `files`; `validatePayload` снова
сериализует каждый файл, затем сериализуется **весь** payload. Только после этого
проверяются 16 MiB. Отказ не защищает от уже выполненной большой аллокации.

**Проверенные размеры:** один собственный JSON из 16 строк по 65 000 ASCII bytes
занимает **1 040 209 bytes** — меньше file cap, каждое значение меньше schema
`maximumLength=65_536`. 17 таких файлов уже дают **17 683 553 bytes**; допускаемые
256 — **266 293 504 bytes** до outer payload encoding. В проверке создавался
только один in-memory JSON; большие массивы/файлы и OOM не запускались.

**Impact:** малый заявленный archive limit допускает накопление сотен MiB и ещё
одну большую encoding allocation до сообщения об ошибке. На iOS это делает
завершение export зависимым от memory pressure вместо штатного раннего size error.

**Исправление / test:** учитывать суммарный размер во время чтения/добавления
entries и использовать bounded encoding/output. При возможности строгий лимит
проверять до materialization очередного JSON. Fixture с уменьшенным injectable
budget либо 17 небольшими по суммарному размеру файлами: остановить чтение сразу
после исчерпания бюджета, не строить oversized payload; разрешённый small export
должен round-trip. Ошибка не требует увеличивать production limits.

## TB-07 — P2: native schema-location getter мутирует storage до Host lease

**Место:**
`telegram-ios/submodules/TelegramUI/Sources/Exteraless/ExteralessPluginRuntime.swift:206–207,545–548,597–615`;
`swift/PluginHost/Sources/PluginHost/PluginServiceStorage.swift:41–45,147–158`;
`ExteralessClient/Tools/ExteralessBackupController.swift:35–39`.

**Статус:** defect supplied consumer binding в текущем shared working tree.
MainRoot ещё не подключил этот binding к Tools UI; startup recovery call уже есть.
Это не итоговое ревью активной реализации Host.

`liveSettingsLocation()` вызывает `settingsDirectory()`. Это не read-only path
getter: он делает `createDirectory` для root и settings. Freeze вызывает его
**до** `host.beginSettingsMaintenance`; export вызывает тот же getter без lease.
Startup также получает settings directory перед `recoverBeforeStart`.

**Сценарий:** settings directory отсутствует, begin maintenance позднее
отказывает/отменяется. Каталог уже создан, хотя lease не был выдан. При startup
recovery существование пустого каталога создаётся до проверки journal; при export
чтение тоже меняет native namespace. Контракт `host-maintenance.md:21–23,70–72`
требует начинать protected mutation только после возвращённого lease.

**Исправление / test:** разделить canonical, non-creating path resolution и
создание storage под lease; frozen schema/owner map должен сниматься без файловых
эффектов. В fresh-root fixture принудительно отказать begin: директории и файлы
должны остаться исходными. Для pending journal до recovery также не должно быть
pre-lease mkdir. Проверить существующий no-Host proof отдельно от `!isRunning`.

## Проверенные контракты и текущее подключение

### Backup / archive / secret handling

- V2 presence действительно различает absent и explicit default; reset использует
  **нынешний** default. V1 import оставляет explicit semantics. Snapshot объединяет
  learned secret keys с `isSecret`; affected-key images строятся до forward write.
  Стабильный adapter вызывает один `applyPublic(values, resetting:expected:)`.
  Uninterrupted known rejection не откатывает client values — TB-01 относится к
  отдельному crash/uncertain пути.
- Journal v2 хранит before/target/presence, client disposition и оба file manifests.
  Journal и копируемые файлы проходят file sync и sync непосредственного parent;
  swap синхронизирует parent каталога. Backup копируется для rollback, terminal
  cleanup допускает повтор. Nonterminal v1 journal сохраняется, committed v1
  очищает scratch. Ошибки/неожиданный третий file image остаются `rollbackFailed`.
  Darwin crash/power-loss proof, сбои самого rename и durable publication новых
  ancestors пока не выполнены. SC-06/07 относятся к другой, активно исправляемой
  CoreSettings реализации.
- `.exteraless-backup` — JSON/Base64 envelope, не ZIP. В Tools config/favorite
  import нет ZIP extraction, inflate или CRC verifier. Raw ZIP не принимается
  как этот формат. IPA path проверяет length/hash и `PK\x03\x04`, но не выдаёт
  это за проверку всех ZIP entries/CRC, iOS signatures или установку. SHA-256 и
  legacy InvisibleUnicode нигде в просмотренном Tools коде не названы encryption.
- JSON preflight ограничивает bytes/depth/separators до decoder; metadata version,
  date, key/file counts, per-file bytes, `.json` path/case aliases проверяются.
  Избыточные данные в public APIs encoder остаются предметом TB-06.
- Plugin export требует allowlist; неизвестные widgets и text inputs без
  `backup_exportable: true` не экспортируются. `is_secret`, `sensitive`, explicit
  deny и credential-key detection учитываются; nested secret dictionaries
  фильтруются, credential arrays пропускаются целиком, merge защищает сохранённые
  credential subtrees. Это classification contract, не способность угадать
  произвольную credential в явно разрешённой строке.
- Tools definitions содержат обычные flags/numbers/folder label. Files bookmark
  находится в отдельном Keychain service, а не в `tools.customSavePath`.
  Просмотренная актуальная `AIFeatures.servicesDefinition` уже имеет closed
  valueShape без `key/apiKey`; старый AI-04 public-array дефект остаётся в AI
  remediation, не новым Tools finding.

### Lease, schema epoch и Cloud consumer

- `ExteralessToolsBackupService.restore:77–93` получает lease до restorer,
  завершает `committed` после успеха, `needsRecovery` при durability/rollback
  failure, иначе `rolledBack`. Finish вызван вне success catch: его ошибка не
  вызывает второй finish с противоречивым outcome. После finish защищённых
  файловых writes в service нет. Noncancellable commit продолжает cleanup при
  закрытии presentation. Верность исходного rollback ограничена TB-01/02.
- `ExteralessToolsHostMaintenance` вызывает реальный nonterminal API и отображает
  outcomes на Bool; startup wrapper держит тот же lease вокруг recovery и при
  failure завершает resume=false. Никакого stop→start/finalize в адаптере нет.
  Data-only inspection/export не вызывает Python/get_settings.
- Runtime source уже содержит normal settings-completion producer
  (`ExteralessPluginRuntime.swift:325–347`), captured account + owner проверку до
  cache record, invalidation при failed settings request, account clear, owner
  pruning и invalidate перед reload/source installation (`:782–790`, `:756–770`).
  Freeze сохраняет значение location до
  retirement и до finish. Проверено его потребление по контракту; полноценная
  native install/reload/epoch race execution ещё отсутствует. TB-07 касается
  побочного эффекта получения directory, а не содержимого schema cache.
- **Binding остаётся partial:** `ExteralessClientRuntime.swift:91,102` создаёт
  `ExteralessToolsIntegration()` и вызывает update; `tools.configure` / вызова
  `toolsBackupBindings(context:)` в root нет. Apply disabled — предусмотренное
  поведение (`ExteralessBackupController.swift:142–145`), не работающий restore.
  Source producer и startup recovery уже есть, поэтому старое утверждение handoff
  «всё ещё надо добавить» также не соответствует этому pin.
- `ExteralessCloudArchiveHost.swift:17–51` read-only проверен как внешний consumer:
  один shared binding/lease, `admission.beginCommit()` после lease, Tools restorer
  с preview CAS, затем add-only credential phase. После public commit ошибка
  keys завершает `.committed` и сообщает partial application; до commit
  rollback/durability failure завершает `.needsRecovery`. Finish не дублируется.
  `CloudArchive.swift:111–193` держит credentials отдельно от Tools journal,
  требует отсутствия plugin settings и сравнивает remote owner.
  Source Cloud shared hunks ещё не применены: это consumer-contract review,
  не green end-to-end Cloud restore.

### Updater / Files / favorites / subtitles / camera

- Updater использует реальный public Releases array API и `browser_download_url`,
  фильтрует draft/prerelease/IPA, предпочитает arm64. Numeric marketing/build
  comparison не использует Double; неизвестная metadata остаётся `.unknown`.
  `.github/workflows/ios-build.yml:133–194` передаёт настоящий run number в
  CFBundleVersion и публикует CI artifact; публикация Release с tag/build metadata
  остаётся distribution prerequisite. URL API не подменён artifact endpoint.
- HTTPS/domain allowlist, redirect credential stripping, ephemeral session без
  cookies/cache/credential storage, header/body quotas, streaming hash, exact
  advertised size и checksum-before-rename присутствуют. Missing digest, 404,
  rate limit, partial size и checksum failures имеют отдельные errors. UI говорит
  **Ready for manual signing**, а не Installed. Непокрытое cancel/file окно — TB-05.
- Files import держит security scope и `NSFileCoordinator` на чтение. Saved
  destination bookmark разрешается с проверкой stale; ошибки Keychain/provider
  доходят до UI. Copy читает 64 KiB chunks, проверяет cancellation и полный размер
  против исходного, оставляет numbered destination при коллизии и удаляет partial
  на выходе. Static collision проверен supplied test; реальные revoked grants,
  concurrent provider rename/collision и source growth не исполнены. Повторные
  path checks не устраняют TB-04. `SaveMediaToFiles.swift:71–79` вызывает helper
  только для complete native resource; account/copy-protection остаются
  обязанностью исходного caller.
- Favorites: строгие account-user-ID keys, duplicate/count/resource limits,
  checksum, фиксированные DTO и native reconstruction. Import — одна Postbox
  preference transaction, без favorite/send RPC; current list сохраняет порядок.
  **Picker hunk уже частично применён:** `EmojiPagerContentSignals.swift:1729–1754`
  подключает local signal, `:1878` вызывает native favorites projection. Это
  source evidence, не тест клавиатуры. Документ `tools-favorites-hooks.md` всё ещё
  помечает применение pending; menu/account persistence/native frames требуют
  отдельной проверки. Supplied 3 native projection tests не покрывают cached decode.
- Subtitles: 1 MiB UTF-8, 16 KiB/cue, 10 000 cues, конечные timestamps и bounded
  hour range, overlap/end-exclusive lookup. `ToolsSubtitleStore` actor
  сериализует per-identity operations, filename — SHA-256 identity; envelope
  проверяет raw sidecar hash. Clock учитывает pause/buffer/rate/seek; Gallery
  adapter содержит generation/cancel/dispose guards. Store имеет per-file cap,
  но не общий count/byte eviction budget. **Во время финальной сверки появились
  Gallery hunks:** `ToolsIntegration.swift:126–157` регистрирует account/context
  factory; `GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift:1249–1314`
  связывает identity/clock/layout/PiP visibility, `:1865` — native status callback,
  `:3764–3785` — реальные picker/clear menu actions с identity recheck. Новый
  adapter учитывает foreground/window, отмену picker и поздние generation results.
  Эти consumer-фрагменты перечитаны. Полный новый Gallery cohort, bridge runtime,
  native compile и recorded frames остаются pending; старый handoff «hooks ещё
  отсутствуют» уже не описывает поздний source pin. Standalone Files AVPlayer
  не считается проверкой normal Gallery integration.
- Camera source действительно меняет AVFoundation frame durations/format selection
  и stabilization: `CameraDevice.swift:69–158`, `CameraNeo.swift:833–947`.
  Multi-camera budget сохраняет native rate. Front mirror применяется к preview,
  photo, output transforms; round size задан **512×512** в обоих backend.
  `VideoMessageCameraScreen.swift:453–463` останавливает запись по native duration
  >59.5 s; прогресс нормирован на 60 s. Это source limit, не измеренная максимальная
  длительность под нагрузкой. Re-export adjusted video на `:2133` всё ещё
  запрашивает 30 fps; capture flag не доказывает 60 fps каждого отправленного файла.
  Zoom получает active-device KVO/stops и вызывает native ramp. Device capture,
  фактические FPS/mirroring, flash restoration и camera/Files/Gallery/UI frames
  остаются pending. Source regex, Core tests и наличие BUILD deps их не заменяют.

## Fingerprints рабочего дерева

Ниже SHA-256 bytes прочитанных native/shared файлов. Префиксы:

- `C/` = `swift/ExteralessCore/Sources/ExteralessCore/`
- `T/` = `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Tools/`
- `UI/` = `telegram-ios/submodules/TelegramUI/`
- `TC/` = `telegram-ios/submodules/TelegramCore/Sources/`
- `PB/` = `telegram-ios/submodules/Postbox/Sources/`
- `H/` = `swift/PluginHost/Sources/PluginHost/`
- `GU/` = `telegram-ios/submodules/GalleryUI/Sources/`

```text
0ad9a51a4d26810f79b5085113a64b880edb30ac123f8829d512d8611268db23  C/CloudArchive.swift
8408510d52ea7803dc796f4d153fb5071b9d8169286030a193e8d24fbd3a7981  UI/Sources/ExteralessClient/Cloud/ExteralessCloudArchiveHost.swift
4b07481c896bad40b9cdad593d9668b1cba1cf4cbf71ec8cdac27f5f8ecd6eb9  UI/Sources/Exteraless/ExteralessPluginRuntime.swift
58ed7a23b07479320e5577cbcdd78c3698f36ab7deba75a8011ce17e9914c8ee  UI/Sources/ExteralessClient/ExteralessClientRuntime.swift
b0320f303e724a1d8219ab825a32039ba30cde024c74d78f4b73508dbcd0d249  TC/ExteralessTools/ToolsLocalFavoriteStickers.swift
11260b3d9fbef095b30771b71f5b67503a875f53aa33edf225b4a70ad49f22dc  UI/Components/EntityKeyboard/Sources/EmojiPagerContentSignals.swift
2a2a2e1babef6df499e4297ad565d8400e61990f5c96d021fe7543bbcd3622f4  UI/Components/VideoMessageCameraScreen/Sources/VideoMessageCameraScreen.swift
9e21129c84fe2df70c60d90d78bd21a152a2ab369127b3ef52faf15ebd4b9bdc  UI/Sources/SaveMediaToFiles.swift
dc00c694f318ea694ecbc1f3390ede4edd98197ead79cbf8d76a0ecc58e4693f  H/PluginServiceStorage.swift
66f8d03c6f71407fc8f180e7f9dc083d679785118c32b4ece8cda35629ba0346  PB/PreferencesEntry.swift
33a43a51e3cea199af4fead0a64d85e711490360683e90313e8c7eb2bac41131  PB/Coding.swift
e2e2d9c6ca25f843510a2b9714b95bf73ebfaf587ed7a70f6ae060e577c39928  T/ExteralessBackupController.swift
59b62f59e0389e4a746345af34f4e7346f722b977e5c61a373f734e6ce54969b  T/ExteralessDiagnosticsController.swift
1630bd0831aa7598346ba67b880765e33b2367b135dcb433acd664062baaf42c  T/ExteralessFavoriteStickersController.swift
c54e1004a17b0f08ce40c4ae3533fe3d51425d306d824808e693fb1dd1f0865d  T/ExteralessFileSaving.swift
84c5ec03a0c5ba33f50bf252d10ea07b8fa542d72057a4118842fbf763bd5f25  T/ExteralessFileUtilitiesController.swift
fa442540093709630abae79d3961cb2f4a98e1395822599854f924a2c4d51a4d  T/ExteralessGallerySubtitleAdapter.swift
92c07bd2f9441b81da3960ca7348b57bbc814c456b8b9ef7ac49291e148d0a32  T/ExteralessToolsHostMaintenance.swift
d4b4a8806ac96752ca3cf7bf58c4ed43dd1504024d7cff25f1a0f7b84f27b646  T/ExteralessToolsIntegration.swift
76c841efdc9864419a11c0d7fa61d7eb0f04f01320bc1bd9d548afc309c81692  T/ExteralessToolsSignal.swift
c3c9c82372dde1a911bb2c62b32e2f0c69c2e40047b6e706c04c38b5bf5c26ef  T/ExteralessToolsUI.swift
f806c9e09dce54c3d67214ea9dc7ce9b7a2da44ed9eb7d666397d9c0c048b980  T/ExteralessToolsVideoController.swift
5b8504183626a085d6fc87ef51c429ff267867b4f5c8858d67bccae932803ead  T/ExteralessUpdateController.swift
255ad0875e5aa0fc5723b51cd2a4ec4600607472bcf8d68eecc34a8bba2cd649  GU/Items/UniversalVideoGalleryItem.swift
```

Для исправленного cohort нужны targeted regression cases по TB-01…07, затем
Darwin directory/provider/cancellation execution и отдельный native app build.
Visual acceptance требует реальных записанных кадров по AGENTS.md.
