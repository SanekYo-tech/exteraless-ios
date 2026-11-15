# Независимое ревью Settings Core — 2026-11-15

**Итог: один P1 и семь P2.** P0 не обнаружен. Findings основаны на трассировке
готовых исходников; числовые контрпримеры дополнительно проверены на IEEE-754.
Новые Swift regression cases ниже — рекомендации, а не выполненные XCTest.

## Срез и доказательства

Проверены полностью:

- `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift`;
- `swift/ExteralessCore/Sources/ExteralessCore/ClientSettingDefinition.swift`;
- `swift/ExteralessCore/Sources/ExteralessCore/ClientSettingValue.swift`;
- `swift/ExteralessCore/Sources/ExteralessCore/ClientSettingsObservation.swift`;
- `swift/ExteralessCore/Sources/ExteralessCore/ClientSecrets.swift`;
- `swift/ExteralessCore/Tests/ExteralessCoreTests/ClientSettingsTests.swift`;
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ClientSettingsBridgeExtension.swift`.

Пять Core sources и файл тестов совпали с
`4b3f706423c9879bb6e0cf64a07eb104e407ec51`: проверены scoped diff и содержимое
каждого файла через `git show` (с нормализацией CRLF). Bridge — **untracked
working-tree файл**, отсутствующий в этом commit; указанный CI его не покрывает.
SHA-256 прочитанного bridge:
`0d51fe46711eba3e1b066342f32fa72e63053221127985f32fe4eab27e44f906`.
Контракты прочитаны в `docs/wave-2/settings-batch.md` и
`docs/wave-2/core-settings.md` — именно там они находятся в репозитории.
Учтены `docs/wave-2-contract.md`, `telegram-ios/AGENTS.md` и `CLAUDE.md`.

CI `43653040458` на `4b3f7064`: **122 Core + 89 Host + 16 Hooks PASS**, включая
28 settings methods, по сообщению coordinator и `docs/wave-2/progress.md:10`.
Локально пересчитаны 28 методов, один условный `!canImport(Security)`.
`Get-Command swift,swiftc,python` нашёл только Python; Swift/XCTest локально не
исполнялись. Apple Keychain на реальном устройстве не проверен этим ревью или
указанным Linux CI.

Host прочитан только в местах допуска вызова provider/permission. Domain callsites
использованы только как контекст API. Tools/Host maintenance WIP и другие домены
не получают итогового verdict в этом документе.

## SC-01 — P1: неудачный secret rename оставляет исходный ключ публичным

**Место:** `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:509–517`,
`:341–367`, `:425–428`; выход наружу — `:281–289` и
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ClientSettingsBridgeExtension.swift:33–36,49–58`.

**Repro:** в изолированном store зарегистрировать публичный строковый
`review.old`, secret-строку `review.secure` с пустым default и обычный
`review.flag`. Сохранить синтетическое значение в `review.old`. В injected
backend включить отказ записи и вызвать
`migrateKey(from: "review.old", to: "review.secure")`.

Назначение проверяется и значение переносится только в локальном `document`.
После отказа Keychain исходный JSON правильно остаётся целым. Однако catch
обучается новым secret keys только из `.register` и прочитанного `secretKeys`.
Исходное имя `.migrateKey` нигде не классифицируется. Recovery снова публикует
`review.old` как public: `snapshot()` содержит исходное значение, `exportJSON()`
включает его, `getClientSetting` разрешает чтение с обычным settings permission.
Успешный `applyPublic` другого ключа также переписывает этот известный plaintext
credential: guard проверяет только secret-имя назначения.

Это отличается от проверенного same-key upgrade: после указания secret-назначения
Core уже знает чувствительность переносимого значения. Если старое имя вообще не
зарегистрировано, snapshot его скрывает, но public batch всё равно копирует его
как якобы неизвестное безопасное значение.

**Рекомендация / regression:** сохранять learned sensitivity исходного имени при
принятии secret migration, включая отказ до JSON commit. Учёт должен позволять
повторить native migration: простое добавление старого имени в текущий guard
`:510–512` заблокирует retry. Проверить после отказа redaction/отсутствие старого
имени в export, отказ `setPublic`, отказ unrelated batch при оставшемся plaintext,
затем успешный native retry с сохранением credential. Payload в diagnostics не
выводить. Тесты `ClientSettingsTests.swift:414–458,733–755` проверяют только
same-key регистрацию и этот alias-сценарий не закрывают.

## SC-02 — P2: overflowing integer JSON округляется, портит retention и CAS

**Место:** `swift/ExteralessCore/Sources/ExteralessCore/ClientSettingValue.swift:24–28`;
использование — `ClientSettings.swift:415–416,692,733` и
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ClientSettingsBridgeExtension.swift:40–42,51–58`.

**Repro:** зарегистрировать nullable/object setting. Подать в JSON числовой токен
`18446744073709551614`, взять snapshot, затем другим writer заменить его на
`18446744073709551615`. Оба Int64 decode не проходят; оба Double decode дают
одинаковое `2^64`. `applyPublic(..., expected: before)` принимает изменённое
значение как прежнее. Это коллизия представления разных значений, а не допустимый
same-state/ABA сценарий.

То же происходит с unregistered value или extra metadata: обычная запись другого
поля кодирует уже округлённое число. Bridge принимает UInt64 JSON в свободно
типизированное значение либо fallback неизвестного ключа и возвращает/сохраняет
изменённое число. Строка с такими цифрами остаётся строкой; проблема именно в
некавыченном числовом токене.

**Impact:** тихая порча неизвестных данных при read/modify/write; CAS может
перезаписать реальное конкурирующее изменение. Enum API не обязан получать новый
UInt64 case, но неподдерживаемый integer должен отклоняться до изменения файла,
а не приниматься с потерей точности.

**Рекомендация / regression:** lossless разбор таких integer tokens либо явный
отказ. Проверить UInt64.max и max−1 в scalar/nested values, unknown metadata и
bridge fallback; исходный файл при отказе должен остаться побайтно целым.
Добавить строковый control case. `ClientSettingsTests.swift:826–858` защищает
Int64.max от сравнения с rounded Double, но не точность самого JSON decode.
Схлопывание двух чисел независимо подтверждено локальной арифметической проверкой.

## SC-03 — P2: structured enum не переживает допустимую JSON-нормализацию чисел

**Место:** `swift/ExteralessCore/Sources/ExteralessCore/ClientSettingDefinition.swift:51–55,109–117,139–148`;
`ClientSettingValue.swift:24–28`.

**Repro:** definition имеет default и единственный option
`.object(["n": .number(1.0)])`. Регистрация и `set` этого option валидны.
При JSON integer-token представлении `{"n":1}` reload декодирует вложенное
число как `.integer(1)`. `typedValue` восстанавливает numeric kind только для
верхнего уровня numeric definition. Проверка `allowed.contains(value)` сравнивает
enum cases, поэтому математически тот же object отвергается с `.option`.

Integral Double → integer token — разрешённое и прямо документированное свойство
формата (`core-settings.md:74–78`), в том числе результат собственного encoder.
После такого round-trip новый экземпляр не может зарегистрировать definition;
старый не может выполнить обычную unrelated mutation, валидирующую все поля.
Аналогичен nullable enum с options `.null` и `.number(1.0)`.

**Рекомендация / regression:** enum membership и uniqueness должны использовать
согласованную с JSON рекурсивную эквивалентность/канонизацию, сохраняя различие
Bool и integer и точность Int64. Проверить set → encode → новый store → register,
а также явно заданный integer-token файл, чтобы fixture не зависел от выбора
encoder. Текущие enum tests используют строковые options; nested numeric test
проверяет CAS, а не enum validation.

## SC-04 — P2: проверка Int64 bounds допускает значения вне диапазона

**Место:** `swift/ExteralessCore/Sources/ExteralessCore/ClientSettingDefinition.swift:159–170`.

**Repro:** integer definition с default `0`, minimum `0`, maximum
`9007199254740992` (`2^53`); установить `.integer(9007199254740993)`.
Definition легален: bound точно представим и как Double, и как Int64.
Но `validateRange` округляет значение до Double, получает ровно maximum и
разрешает запись значения, которое строго больше максимума. Похожий контрпример
есть для нижней границы при округлении вверх.

**Impact:** нарушение объявленного диапазона без ошибки; сам сохранённый Int64
остаётся точным, поэтому потребитель действительно получает out-of-range value.

**Рекомендация / regression:** для integer definition сравнивать Int64 с точными
integer bounds; `validateDefinition:83–87` уже требует их представимости.
Проверить ±1 вокруг больших положительных/отрицательных bounds и сохранить
существующие точные integer-step проверки. Локальный IEEE-754 counterexample
подтверждён; small-range fixtures `ClientSettingsTests.swift:215–247,513–546`
этого случая не достигают.

## SC-05 — P2: secret migration теряет явно сохранённый default

**Место:** `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:499–501,554–556,571–572`;
разрешённые scalar defaults/их обновление — `ClientSettingDefinition.swift:95–105,129–136`.

**Repro:** собственный legacy JSON содержит явный `review.privateFlag: false`.
Зарегистрировать secret Bool definition с default `false`. Миграция удаляет
plaintext, но вместо сохранения override выбирает `desired = nil`: Keychain item
отсутствует, `storedKeys` теряет ключ. Обновить definition до default `true` —
native getter возвращает `true`, хотя пользователь не делал reset. Явный
`set(.bool(false))` при default `false` теряет presence тем же способом.

**Impact:** изменение пользовательского выбора при обновлении defaults; успешно
завершённая миграция необратимо стирает различие absent/explicit default. Это
происходит без I/O failure и не связано с атомарностью двух backend.
Для secret strings с обязательным пустым default очистка может быть осознанной
политикой credentials, но API также разрешает Bool/Int64/Double defaults и их
same-type изменение. Public settings это различие правильно сохраняют.

**Рекомендация / regression:** сохранять explicit presence для scalar secret
settings и при миграции; удаление override должно быть явным reset. Проверить
legacy/default-equal migration и explicit set с последующим изменением default
на новом и существующем store. В `ClientSettingsTests.swift:594–613` аналогичная
гарантия проверена только для public settings.

## SC-06 — P2: повтор сохранения после post-rename ошибки объявляет успех без sync

**Место:** `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:430–434,582–585,765–771`.

**Repro:** существующая директория; `afterFileReplace` бросает ошибку после
реального rename. `applyPublic(["review.a": .integer(1)])` корректно бросает
ошибку и публикует новое значение. Повторить тот же patch без старого expected
(либо с matching intended state). `document == original`, поэтому весь `write`
пропускается. Возвращается success и `lastError == nil`; повторного directory
fsync нет. Это произойдёт и с оставленным включённым post-rename fault fixture.
Обычный `set` имеет тот же no-op shortcut.

**Impact:** retry снимает ошибку долговечности, хотя неизвестная сохранность
directory entry не устранена. При crash/power loss после подтверждённого retry
первое изменение всё ещё может быть потеряно. Новый экземпляр, увидевший файл
после неуспешного sync другого writer, также не восстанавливает эту гарантию
равным patch. Сохранность при реальном отключении питания здесь не измерялась.

**Рекомендация / regression:** успешная повторная mutation должна подтверждать
неразрешённую namespace durability, даже если новый rename не нужен. Нельзя
снимать такую ошибку только на основании равенства прочитанного JSON. Добавить
наблюдаемую/injectable directory-sync стадию и bounded test: real rename → sync
failure → identical retry → проверка повторного sync/его ошибки → успешный sync.
Текущий `ClientSettingsTests.swift:789–824` после отказа откатывает *другие*
значения; этот путь обязательно делает новый rename и пропуск retry не выявляет.

## SC-07 — P2: concurrent first configure может обойти sync новой цепочки каталогов

**Место:** `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:780–802,803–812,767–771`.

**Repro / допустимое расписание:**

1. Writer A замечает отсутствующие parent directories, создаёт всю цепочку и
   останавливается перед `sync new directory parent`.
2. Writer B начинает configure после mkdir. Все directories уже видимы, поэтому
   его `missingDirectories` пуст. Он может взять file flock и сохранить settings.
3. B синхронизирует только непосредственный parent JSON и возвращает success.
   A завершается/получает ошибку до sync ссылки верхнего нового каталога.

Наличие каталога не доказывает долговечность его записи в родителе. Ни один
успешный путь B не синхронизировал верхнюю новую ссылку. При потере несохранённой
ссылки теряется доступ ко всему settings subtree. Сходный single-writer путь:
mkdir → parent-sync failure → retry замечает уже существующие directories и
больше не синхронизирует их parents.

**Рекомендация / regression:** обеспечить durable ancestor publication для
каждого успешно подтверждённого первого сохранения, включая помощь/ожидание
конкурирующего creator и retry после ошибки. Сам file flock берётся слишком
поздно, чтобы защищать этот mkdir/sync протокол. Нужен bounded fixture с двумя
writer instances, барьером после mkdir до ancestor-sync и наблюдением sync
операций на собственном temp subtree; отдельно проверить retry failure.
`ClientSettingsTests.swift:85–100` создаёт вложенные каталоги последовательно,
а `:272–278,642–646` создают оба store до concurrent writes. Power-loss поведение
Darwin/APFS и Linux filesystem в этом ревью не исполнялось; finding — пробел в
порядке обязательных sync, а не заявление о наблюдённой потере на устройстве.

## SC-08 — P2: secret destination-wins проверяет проигравший source раньше назначения

**Место:** `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:515–517,539–555`;
контракт destination-wins — `docs/wave-2/core-settings.md:107–110`.

**Repro:** secret-строка назначения уже имеет валидное значение в injected
Keychain. В JSON есть старый alias с значением другого типа, например object.
Зарегистрировать только secret-назначение: unknown source сохраняется,
регистрация проходит. `migrateKey(from: old, to: destination)` должен сохранить
существующее назначение и удалить проигравший alias. Вместо этого он считает
назначение отсутствующим по `document.values[key] == nil` и валидирует old как
строку до чтения Keychain. Получается `.invalidValue(.type)`.

**Impact:** валидная текущая credential не позволяет завершить заявленную
destination-wins миграцию; устаревший source продолжает блокировать её и остаётся
в plaintext JSON. Это не требование скрывать ошибку чтения Keychain: в сценарии
назначение доступно и валидно.

**Рекомендация / regression:** определять наличие/валидность secret-назначения
в его фактическом backend до проверки значения проигрывающего source. Тестировать
valid destination + invalid source (назначение сохранено, source убран), absent
destination + invalid source (отказ без изменений), повтор после успеха.
Текущий `ClientSettingsTests.swift:177–203` проверяет только public rename.

## Проверенные границы и семантика без отдельного finding

- **Cache и observers.** Getters используют только cache lock; `readSnapshot`
  снимает definitions/values/presence/classification/error одним поколением.
  `perform:371–372` освобождает writer lock до callback; `withLock` освобождает
  flock до выхода к delivery. `ClientSettingsObserver.notify:34–38` также
  вызывает callback после unlock. Reentrant set проверен тестом; прямые
  reentrant register/observe и concurrent cancellation отдельным тестом не
  выполнены. Порядок событий не обещает порядок значений; callback должен re-query.
- **CAS.** Affected set, override presence, current default при отсутствии
  override, live/learned/persisted secret checks находятся внутри writer/flock.
  Unaffected edits и изменение label не конфликтуют; missing expected value
  конфликтует. Exact Int64/Double и recursive Bool distinction реализованы в
  `isSameJSONValue`. Допустимый same-state/ABA не записан как bug; SC-02 касается
  потери различия *разных* входных чисел ещё до этого comparator.
- **Snapshot redaction.** Public constructor объединяет переданные secret keys
  с secret definitions и заменяет соответствующие `values` на `.null`.
  Export убирает secret keys целиком. Native `value`/typed getters намеренно
  могут читать credentials. Same-key failed upgrade сохраняет learned
  classification и блокирует последующие plaintext writes; SC-01 — другой путь.
- **Bridge access.** Provider требует непустой key и settings permission,
  читает coherent snapshot, запрещает secret definition/learned classification;
  `setPublic` повторяет проверку в writer transaction. Пустой/отсутствующий
  native owner не доходит до provider через
  `swift/PluginHost/Sources/PluginHost/BridgeServices.swift:208–215`.
  Provider самостоятельно принимает `pluginId` от native dispatcher, а не из
  аргументов plugin. Это scoped access-boundary trace, не verdict Host WIP.
- **Public batch / native backend.** `applyPublic` и его recovery действительно
  не читают/пишут Keychain. `setPublic` использует общий native `runLocked`:
  отказ записи secret key проверен атомарно, но unrelated secret reads/migration
  этого пути не исключены его контрактом. Смешивать эти две гарантии нельзя.
- **Persistence.** Изменение JSON: exclusive sibling flock, свежий read/merge,
  temp 0600 в том же каталоге, complete write с EINTR retry, file fsync, rename,
  directory fsync. Remove-then-move отсутствует. Public batch публикуется под
  flock; native cache publication после flock всё равно цельное, а свежесть
  между экземплярами требует explicit reload по контракту.
- **Defaults/recovery.** Public explicit defaults и отсутствие override
  различаются; reset удаляет override. Initial all-public registration не
  создаёт JSON с defaults, configure создаёт directory/lock; secret metadata
  сама по себе требует записи. Corrupt/unsupported JSON защищён от mutation;
  failed configure выбирает новый target и не записывает прежний файл.
  Legacy/v0 и unknown metadata сохраняются в пределах возможностей codec
  (ограничение SC-02). Ошибки backend преобразуются в коды без его descriptions.

## Что именно доказывают failure fixtures и что остаётся непроверенным

- Post-rename test использует **реальный rename**: hook вызывается в
  `ClientSettings.swift:765` после `rename` и до открытия/fsync директории.
  Он доказывает committed-cache/error/rollback control flow на этой стадии;
  hook не является фактическим отказом Apple fsync. SC-06/SC-07 не покрыты.
- `SettingsTestSecrets.set:41–44` бросает **до** изменения fake backend.
  Эти fixtures не моделируют commit-then-error Keychain, успешную первую и
  неуспешную вторую запись разных secret keys или Keychain success → pre-rename
  filesystem failure. Общий путь пишет Keychain в `ClientSettings.swift:576–579`
  до полного JSON encode/size check в `write`; атомарность двух backend не
  предоставляется и прямо исключена контрактом. Сам факт такого partial commit
  не оформлен как дефект single-file atomicity.
- Cold-start corrupt Keychain требует дополнительной проверки recovery UX/API.
  Текущий repair test `ClientSettingsTests.swift:460–478` портит item **после**
  успешной регистрации. Если item уже invalid при первой регистрации, schema
  не публикуется (`ClientSettings.swift:588`), а `set/reset` требуют registered
  key. Документированную процедуру native bootstrap repair нужно проверять
  отдельно; существующий тест её не подтверждает.
- **Error status имеет ограниченную силу:** успешный `applyPublic` создаёт новый
  cache с `error == nil` (`resolvePublic:442`), сохраняя старые native credentials
  и не проверяя Keychain. Поэтому `lastError == nil` после public batch не
  доказывает устранение предшествующей ошибки secure read. Требуется явная
  consumer-интерпретация как статуса последней операции либо отдельный статус
  secure recovery; самостоятельный P-level finding на неоднозначность имени
  `lastError` не выставлен.
- Два concurrent store fixture используют независимые lock descriptors, но один
  процесс и последовательно завершённый bootstrap. Multi-process launch,
  ancestor-sync failures, write/fsync/rename pre-commit faults, interruption и
  реальные Apple access-group/lock-state/accessibility cases не проверены.
  Apple source задаёт generic-password, AfterFirstUnlockThisDeviceOnly,
  synchronizable=false и только явно переданный access group. Это source
  verification, а не device Keychain pass.

## Сверка с Android original

- `third_party/exteraless-android/TMessagesProj/src/main/java/com/exteragram/messenger/ExteraConfig.java:48–51,80–96`
  разделяет mapped native preferences и compatibility-only storage. Наличие
  getter само по себе не доказывает реализованную feature; этот review проверяет
  store seam, а не перенос всего перечня функций.
- Там же `:186–192,1253–1258,2177–2255`: typed SharedPreferences, явные
  putBoolean/putLong и отдельный remove/clear. `MappedEditor` для mapped keys
  вызывает setters сразу; его delegate commit не обещает атомарность всех
  domain backend. Требовать от iOS двуххранилищной транзакции на этом основании
  было бы неверно. Long в original signed; SC-02 требует безопасного отказа
  неподдерживаемому integer, а не новой Android-parity функции UInt64.
- `third_party/exteraless-android/TMessagesProj/src/main/kotlin/app/exteraless/OpenExteraConfig.kt:116–145,148–157`
  читает default при отсутствии preference и сбрасывает через remove. Это
  согласуется с public stored-presence контрактом и подчёркивает проблему
  secret scalar migration SC-05. JSON/Keychain, explicit cross-process reload и
  value/presence CAS являются документированными iOS adaptations.

## Локальная bounded проверка

Выполнено через `python -B -` с timeout 20 секунд, без создания fixture files,
импорта plugin/runtime или обращения к сети:

```python
from decimal import Decimal

a, b = (1 << 64) - 2, (1 << 64) - 1
assert a != b
assert float(a) == float(b) == float(1 << 64)
assert all(Decimal(v) != Decimal.from_float(float(v)) for v in (a, b))

maximum = 1 << 53
assert maximum + 1 > maximum
assert float(maximum + 1) == float(maximum)
```

Exit 0; отдельно тем же запуском подтверждено 28 XCTest method declarations.
Это доказательство числовых контрпримеров SC-02/SC-04 и source coverage count,
не исполнение Swift JSONDecoder, POSIX failure tests или Apple Security.
Для закрытия findings нужны перечисленные bounded regressions на реальном
Core-коде после исправлений владельцем.
