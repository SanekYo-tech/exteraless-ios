# Settings recovery — независимый focused follow-up

**SCF-01 и SCF-02: исходные recovery-тупики устранены по source call paths;
execution pending.** Найден один дополнительный **P2 — SCR-01: потеря состояния
quarantined item в cache/presence**, включая подстановку default при public batch.
Нового подтверждённого удаления unrequested raw data или public доступа к нему
не обнаружено.

## Срез и граница доказательств

- Проверены изменения `ClientSettings.swift`, три новых XCTest и фактические
  пути `perform`, `runLocked`, `resolve`, `resolvePublic`, secret encoding/raw
  comparison и JSON commit. Сопоставление исходников выполнено через полный
  scoped diff и чтение call paths, не regex-проверками корректности.
- HEAD при чтении — `ddc25d69`; recovery patch находится в working tree.
  Frozen SHA-256:
  - `swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift`:
    `2c88c3778819c9c4637ec2668ebd37b025833dbbf7d0c5b3e9cf2b7303abfa93`;
  - `swift/ExteralessCore/Tests/ExteralessCoreTests/ClientSettingsTests.swift`:
    `fca5cc78b14a34b203919b636f78b62810d4743face3125092993578dfe79a09`.
- Учтён handoff `docs/wave-2/settings-remediation.md:90–116`.
  **45 settings tests ещё не исполнены.** Предыдущие 42 прошли CI
  `43696986849` по сообщению coordinator; этот результат не покрывает новый patch.
  Локального Swift toolchain нет. Приведённые ниже states — source trace и
  ожидаемые regression assertions, а не выданные за XCTest результаты модели.
- `docs/wave-2/reviews/settings-core-followup.md` сохранён;
  его исходный SHA-256 в этом review:
  `4d8422525b0c25df78c93603214036f7fc07a517d4aa65683d66b79bc5c7a4ef`.
  Реализация, CI, accounts и сеть не изменялись/не запускались.

## SCF-01 — CLOSED source, XCTest pending

**Source:**
`swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:600–625,636–724`.

Исходный counterexample — два old Bool sources, два secret destinations, две
неудачные миграции при отказе secret writes, затем восстановление backend.

Теперь explicit secret `migrateKey`:

1. Читает/валидирует настоящий requested Keychain destination.
2. Обходит **все** learned/persisted aliases, у которых остался plaintext source
   (`:606`), проверяет их классификацию и зарегистрированный secret destination.
3. Читает каждый destination один раз через `loadedSecrets`; existing destination
   выигрывает до validation проигравшего source. Удаление sources происходит
   пока только в локальном candidate.
4. Валидирует полученные значения и собирает необходимые secret writes.
   Все secure writes выполняются в `:716–719` **до** единственного JSON write.

Для `{a.old,b.old}` оба source теперь исчезают из одного candidate. У прежнего
guard `:926` нет оставшегося plaintext secret, и retry достигает commit. При
успехе только первого secret write и отказе второго JSON остаётся исходным;
следующий retry использует уже существующий первый destination и переносит
оставшийся. Потеря одного source до сохранения его destination не обнаружена.

Completed historical aliases без source пропускаются условием `where`; они не
требуют регистрации чужих domains. Matching native retry, monotonic source
classification, исключение retired sources из snapshots/export и public запреты
сохранены. При ошибке validation/read другого pending destination cohort не
коммитится — это реальная оставшаяся ошибка данных, не прежний циклический guard.

**Новый regression:**
`swift/ExteralessCore/Tests/ExteralessCoreTests/ClientSettingsTests.swift:1250–1298`
повторяет именно первоначальный сценарий. Проверяет сохранение JSON после двух
отказов, redaction/public denial, один cleanup rename для всей группы,
idempotent retries обоих aliases, реальные fake-backend значения, reopen и
последующую public mutation. Это meaningful fixture, но он пока не запускался.
Отдельный case «первый destination записан, второй write отказал» пока отсутствует.

## SCF-02 — CLOSED исходный progress failure по source, XCTest pending

**Source:**
`swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:664–719,788–805`.

Для маленького fixture `{"a":false,"b":false,"future":17}` с двумя secret String
definitions и пустым Keychain:

- `reset(a)` запрашивает удаление только A. B имеет **успешно прочитанное отсутствие**
  secure item, но plaintext `false` не проходит String validation.
- Вместо abort B копируется в secure store как JSON value — в этом случае
  ровно пять ASCII bytes `false`. Validation error B сохраняется в `next.error`;
  typed value B не публикуется.
- JSON удаляет plaintext A/B только после успешного удаления A и сохранения B.
  Unknown `future:17` остаётся. Операция всё ещё throws с ошибкой B, но repair A
  действительно продвинулся. Subsequent explicit B set/reset завершает repair.

Это не delete-to-make-test-pass: unrequested B остаётся recoverable в Keychain.
Сохраняется семантический JSON value, а не whitespace/original byte spelling
исходного документа — именно такой договор записан в handoff.

### Retry после частичного secure commit

При порядке definitions `[b,a]` B raw copy может завершиться, а requested A
write — отказать. Исходный JSON тогда остаётся целым. На следующей native repair
попытке typed B read даёт `invalidSecret`; `hasStoredRawSecret` сравнивает
**тот же key** и удаляет JSON duplicate только при JSON-equivalent secure value.

- Совпавший raw `false`/`null` — подтверждённая копия; `Data("null")` не считается
  отсутствующим item.
- `false` против `0` или против строки `"false"` не совпадает: используется
  `ClientSettingValue.isSameJSONValue`, а не NSNumber/Python equality.
- Отличающийся, malformed или unreadable secure value не удаляется/перезаписывается
  как unrequested repair. Plaintext сохраняется; JSON guard блокирует commit,
  пока пользователь явно не разрешит нужную замену/удаление этого key.

**Новые regressions:**

- `ClientSettingsTests.swift:1300–1333` проверяет false/false, отсутствие secret
  writes у public attempts, точную `.invalidValue(b,.type)` первого partial repair,
  сохранённый raw B, omitted typed B, unknown retention, reopen и завершение B.
- `:1335–1373` действительно инъецирует failure **после** успешной B copy:
  новый `failWriteKey` проверяется перед записью соответствующего item
  (`:42–45`), B стоит первым. A не записан, B уже сохранён, JSON прежний;
  повтор завершает A/JSON cleanup, сохраняя B до explicit reset.

Эти tests проверяют progress и retention. Они не проверяют наличие quarantined B
в `storedKeys` и его состояние после unrelated public batch — см. SCR-01.

## SCR-01 — P2 OPEN: quarantined item превращается в «не задан» в cache

**Место:**
`swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift:664–676,689–696,711–712,507–509`.
Видимый consumer:
`telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsController.swift:181–188`.

**Repro:** продолжить новый test `testSCF02InvalidLegacySecretStringsAllowPerKeyResetThenSet`
сразу после первого `reset(a)` (`ClientSettingsTests.swift:1314–1323`).

| Состояние | Backend / ожидаемый смысл | Фактический cache по source |
|---|---|---|
| A после explicit reset | Item отсутствует | Default A, `storedKeys` не содержит A — верно |
| B после successful raw quarantine | Item существует, JSON bytes `false`; typed value invalid | `value(b) == nil`, но `storedKeys` **не содержит B** |
| После `applyPublic([flag: true])` | B не читался и не менялся; должен остаться тот же native cache state | `value(b)` становится `.string("")`, `storedKeys` всё ещё не содержит B |

**Причина:** quarantine branch делает `continue` до единственного добавления
secret presence в `:712`. В raw-duplicate retry branch происходит то же самое,
хотя raw helper только что подтвердил существующий item. Затем `resolvePublic`
заменяет отсутствующее cached typed value default-ом (`:508`). При отсутствии
других ошибок public batch возвращает success; `lastError` очищается как статус
последней операции, хотя native B по-прежнему invalid.

Это не претензия к согласованному last-operation значению `lastError`. Нарушены
независимые данные **presence** и договор сохранения последнего native credential
cache без Keychain I/O (`docs/wave-2/settings-batch.md:15–16`). Quarantined item
реально существует и намеренно сохранён, но UI выбирает **“Not set”**, а native
`value()` после public batch получает default вместо прежнего отсутствия typed
value. Raw данные при этом физически сохраняются; plugin secret guard не обойдён.

**Рекомендация:** представить known stored-but-invalid state отдельно от absent.
После подтверждённой raw copy/equality presence должен оставаться true, typed
value — отсутствовать. `resolvePublic` должен сохранять это native состояние,
а не заполнять его default. При unreadable backend нельзя выдавать неизвестную
presence за подтверждённое отсутствие. API может использовать отдельный status,
но не должен смешивать physical absence и quarantine.

**Необходимые assertions, execution pending:**

1. После raw B copy: `storedKeys.contains(b) == true`, `value(b) == nil`, A absent;
   тот же результат после matching-duplicate retry и reopen/error recovery.
2. После unrelated `applyPublic`: B по-прежнему typed-nil/present, raw bytes и
   secret read/write counters не изменились. Проверить `false` и `null` fixtures.
3. После explicit B reset: presence false; после explicit default-equal B set:
   presence true. Существующий assert `:1329` проверяет только отсутствие A,
   а `:1371–1372` — финальный repaired state, поэтому defect остаётся незамеченным.
4. Повторить публикацию при injected post-rename directory error: actual
   committed presence должна отражаться и при брошенной durability error.

## Failure-stage audit: фактическая сохранность и error status

Все ссылки в таблице — к `ClientSettings.swift` из frozen source выше.

| Стадия отказа | Фактические изменения / retry | Error/cache semantics |
|---|---|---|
| Alias destination read/validation до secret writes | JSON и secure backend не изменены; learned classification остаётся | Sanitized error; sources скрыты. Body candidate не публикуется |
| Один alias secure write завершён, следующий отказал | JSON прежний, один destination уже durable. Retry использует destination-wins и завершает группу | `perform:387–399` пытается reread; при валидном оставшемся backend может отразить partial secure progress. Это не cross-store rollback |
| B quarantine copy отказала | JSON cleanup не вызывается. Более ранний explicit A write/delete мог уже завершиться | `.secretStorageFailure`, а не ложный success. Original legacy B сохранён |
| B copy завершилась, A write отказал | B raw durable, A не записан, JSON прежний. Matching-raw retry теперь достигает cleanup | Failure backend имеет приоритет над ранее собранной validation error. Новый test `:1335–1373` моделирует именно эту стадию |
| Все secure writes завершились, JSON encode/create/write/rename отказали | Secure changes могут быть committed; JSON не заменён. Копии raw B остаются в обоих местах до retry | General catch выполняет read-only recovery. `resolve:741–760` всё ещё all-or-nothing: invalid B может прервать refresh и сохранить last cache с error; нельзя считать этот cache точной physical backend snapshot |
| Rename завершён, directory sync отказал | JSON cleanup и secure writes уже committed. Повтор — sync/repair, не предположение о rollback | `write:971–974` возвращает durability error; `runLocked:725` ставит её выше validation error и публикует candidate. Presence-defect SCR-01 затрагивает и этот candidate |
| Cleanup завершён, unrequested B остаётся invalid raw | Requested repair завершён, raw B сохранён | Первый quarantine pass возвращает исходную validation error B; matching retry — `invalidSecret`. Explicit repair B устраняет её |

Сохранение старого cache при неуспешном полном recovery — существующий failure
договор, а не заявление, что Keychain откатился. Особенно важен отсутствующий
fixture: valid A commit + raw B commit + JSON **pre-rename** failure. Новый test
проверяет более ранний A backend failure; эти стадии нельзя смешивать.

## Public boundary, retention и оставшиеся проверки

- `requestedSecrets` появляется только у native secret set/reset
  (`ClientSettings.swift:576–592`). Public `setPublic` отклоняет secret key до
  назначения mutation; public normal key не активирует quarantine. `applyPublic`
  имеет отдельный путь и не обращается к raw helper/secret backend.
- Quarantine допустима только после достоверного отсутствия предыдущего secure
  value. Непрошедший typed read существующего item идёт в другой catch; raw
  overwrite другого ключа там не выполняется.
- JSON source удаляется физически только после всех требуемых successful secure
  writes. Exact-match helper не принимает nil, malformed JSON, Bool/number
  coercion или чужой key как подтверждение копии. Existing valid destination-wins
  сохраняет прежний договор; explicit replacement/reset вправе заменить raw data
  только своего target.
- Unknown values/metadata остаются в исходном Document и переживают rewrite;
  формат не изменён. Отказ encode raw value остаётся ошибкой, а не причиной
  удалить его из исходного файла.
- Writer/flock охватывают stage/read/write; callback delivery остаётся после
  unlock (`:426–427`). Пользовательский validation callback не добавлен.
- Для дальнейшего gate нужны исполнение 45 tests, SCR-01 assertions, mismatch /
  unreadable raw retry, partial alias write и JSON pre-rename failure после
  successful raw copy. Apple Keychain/device и hardware power-loss по-прежнему
  не измерены; их pass здесь не заявляется.
