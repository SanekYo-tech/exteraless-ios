# Settings Core — независимая перепроверка исправлений

**Восемь исходных контрпримеров SC-01–08 закрыты. Обнаружены два дополнительных
P2 в восстановлении: несколько pending aliases и несколько invalid plaintext
secret values.** Их исправление остаётся открытым. Новых P0/P1 не подтверждено.

`CLOSED` ниже означает закрытие исходного source finding с указанными
regressions. Это не результат проверки Apple Keychain или отключения питания.

## Проверенный срез и статус выполнения

- Полностью перечитаны пять settings sources и
  `swift/ExteralessCore/Tests/ExteralessCoreTests/ClientSettingsTests.swift`.
  Содержимое каждого файла через `git show` сравнено с `75cbe7a1`, с нормализацией
  CRLF: **совпадает**. В test file действительно 42 метода, включая conditional
  non-Apple case. HEAD на момент проверки — `e59bd30a`.
- Прочитаны актуальные `docs/wave-2/settings-remediation.md` и
  `docs/wave-2/settings-shape.md`. Их прежние пометки XCTest pending заменяются
  следующей предоставленной coordinator информацией: CI **43695307589** на
  **75cbe7a1 скомпилировал и выполнил все 42 settings cases без failures**.
  Общий run завершился ошибками AICredentials.remove и Identity era. Сообщённые
  исправления `e59bd30a` и последующий pending CI не объявляются здесь зелёными.
- Локально `swift`/`swiftc` отсутствуют. Новые сценарии SCF-01/02 доказаны
  трассировкой control flow; они не исполнялись как Swift tests. Проверки
  provenance выполнялись собственными inline Python-командами с timeout ≤30 s,
  без запуска plugin/runtime, сети, CI или чтения account data.
- Старый `reviews/settings-core.md` сохранён. Его SHA-256 до follow-up:
  `51c91137cb76c9a842373246bc80b60466fcda620bdd2bae4ae9826671d08ae6`.
- App composition и typed client bridge проверены в текущем working tree.
  AppDelegate/Share имеют локальный diff; typed bridge, client runtime,
  notification/private helpers — untracked source. Core CI сам по себе их
  компиляцию не доказывает.
- Во время финальной проверки fingerprint typed bridge изменился: появились
  `setClientSettings` и `getClientSettingMetadata` с compatibility helper.
  Актуальные исходные get/set boundaries перечитаны; дополнительные compatibility
  APIs являются продолжающимся WIP и не получают completed verdict этого follow-up.

## SC-01–08: disposition и проверенные основания

В таблице `ClientSettings.swift`, `ClientSettingValue.swift` и
`ClientSettingDefinition.swift` находятся в
`swift/ExteralessCore/Sources/ExteralessCore/`; номера tests относятся к
`swift/ExteralessCore/Tests/ExteralessCoreTests/ClientSettingsTests.swift`.

| Finding | Статус | Source evidence и regression |
|---|---|---|
| **SC-01**, failed secret alias доступен export/bridge | **CLOSED — исходная утечка** | `ClientSettings.swift:555–565` записывает learned alias до I/O; `:378–422` сохраняет sensitivity и исключает retired source из definitions/values при ошибке; `:578–580,450–452,483–485` запрещают public write/copy. Alias metadata загружается/сохраняется в `:851–870,883`. Matching retry разрешён. Test **861–891** проверяет отказ, неизменность JSON, отсутствие source в snapshot/export, retry, повтор после успеха и reopen. Новый multi-alias stall описан отдельно в **SCF-01**. |
| **SC-02**, wide integer округляется до сравнения/записи | **CLOSED — file/Keychain и canonical C→bridge input** | Raw parser: `ClientSettingValue.swift:210–246,275–309`; integer-valued spellings допускаются только в Int64, fractional spelling сравнивается с decimal round-trip Double. File/Keychain используют `decodeJSON` (`ClientSettings.swift:753,828,889`), native integral Double кодируется точным Int64 (`ClientSettingValue.swift:77–84`). Tests **920–964** проверяют UInt64 overflow, отрицательный overflow, decimal/exponent spelling, excess precision, nested/request payloads, сохранение unknown values/metadata при отказе и строковый control. Native forwarding рассмотрен ниже. |
| **SC-03**, structured/nullable enum ломается после JSON round-trip | **CLOSED** | `ClientSettingDefinition.swift:104–110` выбирает canonical option через recursive JSON equivalence; `:168` аналогично запрещает equivalent duplicates. Test **966–988** проверяет own encode/reopen, явный integer-token legacy JSON, nullable option, отличие Bool от integer и duplicate option. |
| **SC-04**, Int64 bounds округляются | **CLOSED** | `ClientSettingDefinition.swift:215–225` сравнивает Int64 с точным integer bound до Double work. Дополнительное последующее сравнение монотонно и не отменяет точную проверку. Test **990–1008** содержит обе границы ±2^53, значения внутри/снаружи и integer step выше 2^53. |
| **SC-05**, explicit secret default теряет presence | **CLOSED** | `ClientSettings.swift:583–584` всегда создаёт `.set(validated)`; plaintext migration сохраняет validated value даже при равенстве default (`:660–663`). Только `.reset` выбирает delete. Test **1010–1038** проверяет legacy false/0, explicit empty collection, изменение defaults, reopen, explicit default set и последующий reset. Сохранённая пустая строка теперь действительно item, а не delete; consumer remove должен использовать reset. |
| **SC-06**, identical retry снимает post-rename sync error без sync | **CLOSED** | Public no-op вызывает `confirmDurability` в `ClientSettings.swift:489–490`; native mutations — `:698–700`. `:956–970` делает file fsync при наличии файла и directory sync. Test **1040–1070** оставляет sync fault активным, проверяет одинаковые batch/set retries и новый экземпляр, считает 1 rename и повторные sync attempts; success появляется только после снятия fault. |
| **SC-07**, второй creator пропускает новые ancestors | **CLOSED — Core protocol и проверенные source bindings** | Root выбирается из явно заданного durable boundary либо стабильных OS roots (`ClientSettings.swift:932–954`), а не из ближайшего existing ancestor. Под flock всегда синхронизируется вся цепочка root→leaf (`:995–1007`). Test **1072–1119** останавливает первого creator после mkdir и даёт второму завершить сохранение; **1121–1150** проверяет повтор sync после ошибки при уже видимых directories. Реальная передача App Group root прослежена до public/private store ниже. |
| **SC-08**, проигравший alias валидируется раньше существующего Keychain destination | **CLOSED** | `ClientSettings.swift:600–607` сначала читает/валидирует Keychain destination; invalid source проверяется только при действительно отсутствующем destination. Test **893–918** проверяет valid destination + obsolete object source, отсутствие дополнительных secret writes, idempotent retry и absent destination + invalid source с сохранением файла. |

Value/presence CAS остаётся под writer/flock; unaffected keys и labels не входят
в guard, изменившийся default влияет на affected absent value. Recursive Bool
distinction сохранён. Same-state/ABA по договорённости не является defect.

## Новые открытые findings

### SCF-01 — P2: две неудачные alias migrations взаимно блокируют native retry

**Место:**
`swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:562–565,571–572,600–608,624–626,687–695,877`.

**Воспроизводимый сценарий на существующем injected backend:**

1. Зарегистрировать public Bool `a.old`/`b.old`, secret Bool `a.new`/`b.new`,
   defaults false; сохранить собственные true fixtures в оба old key.
2. Включить `SettingsTestSecrets.failWrites`. По отдельности попытаться
   `migrateKey(a.old → a.new)` и `migrateKey(b.old → b.new)`, перехватив обе ошибки.
   Оба alias теперь learned, оба source всё ещё в исходном JSON.
3. Отключить отказ. Повторить A, затем B, затем A ещё раз.

**Трассировка:** каждый retry удаляет из candidate `document.values` только
свой source (`:606`). Обход definitions пропускает *все* alias sources (`:626`),
но не завершает миграцию остальных. Перед `write` в `secretKeys` находятся оба
source, а в `values` остаётся source другой миграции. Guard `:877` всегда бросает
`invalidJSON`. Failed candidate не заменяет исходный JSON, поэтому следующий
retry снова начинается с обоих source.

После первой успешной Keychain записи и даже после успешных записей **обоих**
destination ни один retry не может завершить JSON cleanup. Простая перестановка
очередности не помогает: для множества pending sources `{A,B}` кандидат одного
вызова оставляет `{B}` или `{A}`, тогда как commit требует пустого пересечения.
`set/reset` retired source запрещены в `:578,590`, public batch также запрещён.
Обычные subsequent writes упираются в тот же guard. В том же экземпляре store
нет API, завершающего обе миграции совместно.

**Impact:** после нескольких ошибок разных domain migrations восстановившийся
backend не восстанавливает работу settings; требуется пересоздание процесса/store
и последовательный bootstrap либо внешнее восстановление. Redaction при этом
работает: это не возобновление старой P1-утечки и не претензия к отсутствию
атомарности Keychain+JSON. Defect — отсутствие достижимого успешного retry.

**Рекомендация / test:** native migration должна уметь завершить все накопленные
aliases в одном candidate либо иметь native batch completion/repair. Для каждого
source сначала подтвердить durable destination по destination-wins правилам,
затем scrub; запрет plaintext на public path сохранять. Добавить bounded test
двух failed aliases, восстановления backend, завершения обеих migrations,
сохранения destination, redaction и последующей обычной записи. Existing test
`ClientSettingsTests.swift:861–891` содержит ровно один alias и этот цикл не видит.

### SCF-02 — P2: cold repair не продвигается при двух invalid legacy secrets

**Место:**
`swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:588–592,637–663,687–695`.

**Repro:** собственный well-formed legacy JSON содержит `a: false, b: false`;
Keychain пуст. Зарегистрировать оба ключа как secret String с empty defaults.
Регистрация бросает type error, но новые valid definitions остаются addressable.
Вызвать `reset(a)`, затем `reset(b)`; аналогично попробовать valid replacement
одного ключа через native `set`.

Целевой reset удаляет только свой plaintext. Обход другого secret получает
`previous == nil` из исправного Keychain и доходит до проверки plaintext
`:663`. Type/shape error возникает **вне** catch `:647–652`, разрешающего repair
при unreadable *Keychain* другого ключа. Ошибка случается до выполнения собранных
secret writes и до JSON commit. Каждый reset сохраняет оба invalid source без
прогресса. Public batch не может сбросить secret keys совместно.

**Impact:** опубликованная schema делает поля видимыми для native repair, но
реально починить их по одному невозможно, в том числе после relaunch. Сценарий
также применим к двум legacy secret values, отвергнутым новой closed shape.
Это additional follow-up finding, а не утверждение, что именно commit 75cbe7a1
впервые создал проблему.

**Рекомендация / test:** предусмотреть native multi-key repair либо recoverable
quarantine для других invalid plaintext values. Repair не должен тихо удалять
чужие значения или обходить public secret guard. Добавить cold fixture с двумя
well-formed, но type/shape-invalid legacy values и доказать завершение repair
через native APIs. Текущий cold test **1152–1168** портит два *Keychain items*,
не plaintext JSON; эта успешная проверка данный путь не покрывает.

## New shape и cold-start Keychain: что подтверждено

`swift/ExteralessCore/Sources/ExteralessCore/ClientSettingDefinition.swift:3–48`
задаёт закрытые native metadata: required⊆fields, exact field allowlist,
неотрицательный maximumCount и глубину ≤60. Array count проверяется до обхода
элементов. `.number` допускает integer, `.integer` — точно представимый integral
number; Bool не становится числом. `.any` всё равно проходит JSON validation.

Shape проверяется на values, defaults и options (`:100–102,121,165,174`), входит
в definition equality. При valid schema + invalid stored value декларация
публикуется для repair (`ClientSettings.swift:536–550`), а старое cached value,
не проходящее новую shape, удаляется из public cache (`:413–421`). Это осознанное
изменение прежнего «schema publication только после чтения всех values» договора.

Tests **1176–1200** закрывают extra credential field, missing field, wrong type,
oversized array до вложенного NaN, file preservation и reopen. **1202–1224**
проверяют malformed schema, default/options, excessive schema depth и числовые
типы; **1226–1242** — tightening, quarantine cached value/export и replacement.
Source boundary именно 60; positive depth-60/value-depth boundary отдельным
fixture не закреплён.

Shape подключена к реальной `ai.services` definition:
`swift/ExteralessCore/Sources/ExteralessCore/AIFeatures.swift:4–10,31`, максимум
100, закрытый список шести полей. Main composition регистрирует эту definition
через `AIFeatures.definitions`. Это проверка settings shape binding, не полное
повторное AI domain review.

**Cold invalid Keychain repair — CLOSED для заявленного случая.** Valid schema
остаётся addressable, explicit target допускает замену invalid item, другая
unreadable credential не подменяется выдуманным значением (`ClientSettings.swift:642–652`).
Test **1152–1168** доказывает targeted delete при сохраняющейся/брошенной ошибке
второго item, затем успешную замену второго и очистку lastError. SCF-02 — иная
стадия ошибки. `lastError` по обновлённому договору означает последнюю операцию,
а не глобальное здоровье Keychain; успешный public batch не проверяет secrets.

## Coordinator bindings: actual signatures и provenance

### Original JSON до typed client bridge

- `python/bridge/_exteraless_bridge.c:1956–1994` удаляет supplied identity fields
  и вставляет `st->plugin_id`/owner token в собственный root перед сериализацией.
- `swift/PluginHost/Sources/PluginHost/BridgeServices.swift:208–232` проверяет
  native owner и при совпадении canonical `pluginId` передаёт **исходный** `json`,
  без повторной numeric serialization. Для noncanonical native callers fallback
  по-прежнему re-encodes root; этим fallback не обосновывается lossless guarantee.
- `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ClientSettingsBridgeExtension.swift:24–42`
  сначала читает только Route strings, затем передаёт исходные bytes в
  `ClientSettingValue.decodeJSON`. Set и fallback используют typed args напрямую
  (`:74,85` в последнем прочитанном срезе); permission/secret guards сохранены
  (`:44–46,65–68`). Новая compatibility validation исходного get/set не заменяет
  strict raw decode повторной numeric serialization.
- Host test `swift/PluginHost/Tests/PluginHostTests/PluginBridgeExtensionTests.swift:56–68`
  сравнивает captured request с original string, включая UInt64 token и пробел.
  Core test **920–940** проверяет strict codec на request-shaped values.
  Это две реальные части evidence, но они не являются запуском конкретного
  TelegramUI provider end-to-end. Полный get→set round-trip этого provider,
  включая large integral `.number` replies, требует отдельного native fixture:
  response использует `PluginJSONValue` encoder, не Core exact-integral encoder.

### App Group durability root — source binding CLOSED

| Путь | Подтверждённая передача |
|---|---|
| **Main public** | `telegram-ios/submodules/TelegramUI/Sources/AppDelegate.swift:746,891–903`: `containerURL(...)` → appGroupUrl, отдельно derived rootPath → `configure(..., durabilityRootURL: appGroupUrl)`. `ExteralessClientRuntime.swift:36–45` сохраняет container и передаёт его в Core. Повторный account update `:88` использует сохранённый container. |
| **Share public/private** | `telegram-ios/Telegram/Share/ShareRootController.swift:41–54`: actual appGroupUrl → public ClientSettings и `ExteralessHiddenAccounts.configure`. `telegram-data` является descendant, а не durability root. |
| **Notification public/private** | `telegram-ios/Telegram/NotificationService/Sources/ExteralessNotificationPrivacy.swift:9–16,21–25,34–42`: actual container lookup отдельно от root; оба public paths и private configure получают container. |
| **Main private helper** | `telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift:58` → `PrivacyExtras/ExteralessNativeHiddenSettingsAuthorization.swift:24–25`: фактическая helper signature уже принимает `durabilityRootURL: URL` и передаёт его дальше. |
| **Private factory, не только callsite** | `telegram-ios/submodules/TelegramCore/Sources/ExteralessPrivacyExtras/ExteralessHiddenAccounts.swift:97–109,123–140`: actual configure signature содержит `durabilityRootURL: URL?`, factory принимает четвёртый argument, `:103` передаёт его в `ClientSettings`. Fast-path сравнивает сохранённый root (`:127`). |

Private binding закрыт после чтения фактической изменённой signature и factory,
не по обещанию owner. Это source verification; compilation всего app graph,
App Group entitlements, private repair UI и actual Apple Keychain здесь не
исполнялись. В проверенных production callers nil root не передаётся.

Typed client bridge SHA-256 первоначального среза:
`b3b30a5f20c018b13ff61faf89163c3892f8c934a915a67c8aaf5bf1c39e65c4`;
последнего перечитанного среза с новыми compatibility APIs:
`15e9881a4359d90b76608f6a81edf1973ccc0fd5c1748562bfbf8cb63a9fde9a`.

## Проверка failure stages и оставшаяся граница доказательств

- Ancestor fixtures используют реальный mkdir/flock/fsync. Первый creator
  останавливается **до flock** после mkdir; второй действительно помогает
  опубликовать chain. Hook фиксирует sync entry, а последующий успешный вызов
  проходит настоящий fsync. В тесте проверено присутствие всех ancestors,
  root→leaf порядок дополнительно подтверждён source loop.
- Directory-sync fixture бросает непосредственно перед соответствующим
  open/fsync; rename уже состоялся. Counted no-op retries не делают лишнего
  rename и повторно доходят до sync. Это сильнее прежнего rollback-only case,
  но не симуляция hardware power loss.
- Fake secret write failure по-прежнему возникает до изменения fake item.
  Cold repair тестирует несколько invalid items, но не Keychain commit-then-error
  и не все комбинации Keychain success → JSON pre-commit failure. Cross-store
  atomicity не обещана. SCF-01 касается невозможности **завершить retry после
  восстановления**, а не самого факта частичного secure commit.
- Writer/cache lock ordering и delivery после unlock сохранены
  (`ClientSettings.swift:361–428`). Schema publication не вызывает callbacks под
  file/writer lock. Старые bounded reentrant/cancellation/CAS tests входят в 42.
  Отдельного нового multi-process или reentrant-register stress pass здесь нет.
- Apple Security/access-group/locked-device поведение и survival при реальном
  power loss остаются **неизмеренными**. Итог всего CI run и pending next run
  не подменяют это evidence и не скрывают два новых P2.

Для завершения follow-up нужны regressions SCF-01/02 на реальном Core-коде и
исправление подтверждённых recovery stalls владельцем. Исходные SC-01–08 при этом
не возвращаются в статус P1/P2 автоматически: их конкретные прежние причины
устранены, а новые сценарии имеют собственные IDs.
