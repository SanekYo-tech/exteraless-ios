# SDK-01–09 — независимая проверка source-closure

2026-11-15. **Все девять контрпримеров из `sdk-config-adapters.md` закрыты на уровне текущего source. Остаточных P1/P2 в этих девяти сценариях не обнаружено.** F03/F04 также исправлены в исходниках native probe. Foundation/Swift и трёхпроцессный Mac gate остаются **не выполнены**.

Проверены `sdk-adapters-final.md`, `sdk-final-source-inventory.json`, `sdk-java-remediation.md`, `sdk-manager-authority-remediation.md`, actual adapters, registration/writer callsites и соответствующие fixtures. Начальный HEAD — `43c46497b961ee8a1ccdb9321bdcdae868747af4`, заключительный — `0ceafb7bc7c12774f40fcb9f4947e593c05aab0b`; основание verdict — pinned working-tree bytes, а не HEAD сам по себе. Implementation files не редактировались.

Сокращения:

- `P/` — `python/exteraless_runtime/`; `V/` — `python/virtualjava/`.
- `U/` — `telegram-ios/submodules/TelegramUI/Sources/`.
- `H/` — `swift/PluginHost/Sources/PluginHost/`.
- `T/` — `tools/compat/tests/`.

## Закрытие каждого контрпримера

### SDK-01 · CLOSED / source — отсутствовавшая регистрация 44 global overloads

`U/ExteralessClient/ExteralessClientRuntime.swift:54–61,81–84` теперь включает `ExteraConfigCompatibility.definitions` в **реальный** `Self.definitions`, передаваемый `ClientSettings.shared.register`. Generic UI исключает эти keys на `ExteralessSettingsController.swift:147–150`.

Прежний сценарий `getTabCounter()/setTabCounter(False)` больше не упирается в отсутствующую root definition. `T/test_sdk_config_binding.py:118–145` проверяет все 44 getter/setter overloads, global persistence между двумя SDK workers и отдельное per-plugin значение. Независимый прогон прошёл на обеих версиях Python.

**Fixture не скрывает отсутствующий root:** перед собственными recorder values вызывается `root_registration` (`:29–35`); отрицательный тест удаляет registration только из in-memory прочитанного root и получает отказ (`T/test_sdk_config_manifest.py:49–56`). Native driver строит registration expression из того же consumed root set (`tools/runtime/check_swift_plugin_embedding.py:357–369`). `python/runtime/smoke/swift_sdk_config_root_fixture.swift:26–35,42–45` регистрирует только этот набор, затем проверяет наличие 22 keys; отдельного добавления compatibility definitions нет. Выполнение этого настоящего Core/provider fixture на Mac ещё pending.

### SDK-02 · CLOSED / source — blind spot дочерних definitions и stale mapping

`tools/compat/sdk_config_manifest.py:28–62,97–175` читает участвующие Appearance/Tools/AI declarations и проверяет их registration references. Для дочерних файлов сканируются указанные подключённые initializers, а не все найденные массивы. Root membership проверяется на `:121–132`.

Прежние четыре exact IDs `getHideAllChats()/setHideAllChats(boolean)` и `getUseSystemIconShape()/setUseSystemIconShape(boolean)` теперь связаны с `appearance.hideAllTab` и `appearance.useSystemIconShape`. `--check` прошёл. Tests для disconnected child и дополнительного unregistered array прошли; проверки public read/write находятся в `T/test_sdk_config_binding.py:185–234`.

При этом новые bindings не получены слепым совпадением symbols:

- `front_rear_bool` читает native **Int** 0/1 как Bool, пишет обратно Int 0/1; **Ask=2** возвращает named unsupported, не меняя selection. Metadata default также проходит этот codec (`P/_config.py:149–181`). Проверены enum/Bool routes, native default и сохранение Ask после отказа getter.
- `disableCrashlyticsCollection` и `enhancedFileLoader` остаются **migration-only unsupported** (`sdk_config_manifest.py:63–69,387–390`). Legacy false не превращается в enable diagnostics/downgrade download profile; live control принадлежит `GeneralConfig`.
- `TelegramAiEditor`/`TelegramAiSummaries` сохраняют original inversions; Tools mode helpers передают Bool либо Int согласно actual native key type. Эти сценарии прошли в `domain_cohort`.

### SDK-03 · CLOSED / Python behavioral — false-cancel терял completion

`P/_controllers.py:24–31` закрывает lease только после strict Bool true. False, malformed reply и exception оставляют его живым. `P/_scheduling.py:64–79` возвращает actual cancellation success, не удаляет task заранее; completion/on-close используют identity-checked `forget` (`:30–47`). Terminal unload cleanup остаётся отдельным `CallbackLeases.end` path.

Прежний completion-before-cancel сценарий теперь доставляет callback **один раз** с исходным account, затем native FIFO release освобождает handle. Независимо прошли controller/task false, malformed, throwing и positive cancel; duplicate cancel; replacement-entry preservation; отсутствие transient leaks — `T/test_sdk_adapter_wave2.py:845–894`, case `cancellation_winners`.

### SDK-04 · CLOSED / Python behavioral — native notification union ломал старые события

`P/_notifications.py:16–48` содержит все **12** current native IDs; корректный неизвестный availability row фильтруется, неверное имя известного ID отвергается. Registry независимо сопоставлен с `H/NativeServiceOperations.swift:157–187` и совпал полностью. `Center.supported/addObserver` используют эту таблицу (`P/_controllers.py:123–149`).

Прежнее добавление `{id:3,name:"dialogsNeedReload"}` больше не ломает `contactsDidLoad`. Cases `notifications` и `notification_payloads` прошли на обоих Python: полный union, additive unknown ID, старые subscriptions, все 12 payload shapes, forged account/invalid shape, wrong name, missing publisher и files permission. Delegate по-прежнему получает explicit account без implicit hook scope. Новый HNS child сравнивает SDK discovery с настоящим `NativeServiceNotification.allCases` (`swift_sdk_hns_probe.swift:102–105`); его execution pending.

### SDK-05 · CLOSED / source — pin writes продолжались после revocation

Per-ID loop удалён. `U/Exteraless/ExteralessPluginRuntime.swift:648–653` передаёт **один** `.pinnedSet(wanted:installed:)` вместе с authority; `:899–903` переносит authority в detached writer.

`PluginConfigAuthority` хранит live `@Sendable` check, а не однажды вычисленный Bool (`U/ExteralessClient/PluginUI/PluginConfigBridgeExtension.swift:9–13,43–50`). `PluginManagerPreferences.swift:68–94` под writer lock готовит целый next state, сохраняет uninstalled entries, проверяет authority непосредственно перед **одной** atomic write и публикует memory state только после неё.

Таким образом, прежний сценарий «первый pin завершился → revoke → второй независимый write» отсутствует. Revocation до writer admission запрещает весь set; уже допущенный полный write может закончиться. SDK compact/developer используют ту же authority boundary. Self-disable/safe-mode сохраняют прежнюю admitted maintenance policy и асинхронное ожидание root caller (`ExteralessPluginRuntime.swift:632–647`).

Три `telegram-ios/Tests/Exteraless/PluginManagerAuthorityTests.swift:22–81` используют настоящий writer: revoked set сохраняет bytes, admitted set целиком меняет два IDs, async-hop revocation блокирует pin/compact/developer. **Прочитаны, не исполнены:** Swift здесь отсутствует. Для source-closure достаточна устранённая split-write причина; native execution этим не объявляется.

### SDK-06 · CLOSED / Python + C transport — byte[] превращался в vector

`V/arrays.py:143–146` распознаёт именно component descriptor `B` и преобразует signed bytes через `& 0xff`. `P/_tl.py:97–104` ставит bytes marker **перед** generic array branch; empty byte[] также обрабатывается, поскольку проверяется `is not None`.

Прежний `getBotCallbackAnswer.data=jarray(jbyte)([-1,0])` теперь имеет bytes representation. `byte_fields` и реальный C test проверили empty/signed-edge/plain-bytes/nested fields; int[]/long[] сохраняют array representation. Matching CPython 3.12 C transport действительно принял markers и вернул bytes; malformed base64/Int64 overflow отклонены, handles=0 (`T/test_java_value_regressions.py:46–79,82–122,245–253`).

Это **не** Foundation TL binary encode/decode pass: `fixtures/java_values/native_codec.swift` и его positive/negative normalization cases пока не запускались.

### SDK-07 · CLOSED / Python behavioral — jarray(T) терял class identity

Стабильные primitive converters имеют разные descriptors (`V/arrays.py:22–43`); array cache keyed по canonical component descriptor (`:103–140`). `V/finder.py:90–140` сводит primitive aliases, `jclass("[I")`, `int[]`, nested descriptors и casts к этому cache.

Прежние `isinstance(a,jarray(jint))` и `cast(jarray(jint),a)` проходят, cast сохраняет identity. Проверены повторные primitive imports, alias/nested class identity, null cast и отказ int[]→long[] (`primitive_identity`, `array_identity`). Статус относится к этим typed-array контрпримерам, не ко всей Java type system.

### SDK-08 · CLOSED / Python + C scalar transport — Integer/Long keys и Boolean.equals

`P/_java_types.py:235–267,382–405,514–545` отделяет Java boxed equality от Python arithmetic: `.equals` различает Integer/Long; Boolean сравнивается по value; non-string map keys используют `_JavaKey`.

Прежние `put(Integer(1),"integer")` и `put(Long(1),"long")` теперь сохраняют **две** entries, независимо созданные `Boolean(True)` сравниваются равными и перезаписывают ту же Boolean entry. `boxed_values`/`map_keys` проверили null keys/values, old-value returns и typed lookup. Python `Integer(1) == Long(1) == 1` намеренно сохраняет scalar arithmetic domain; это не используется как Java map-key equality.

Реальный C test подтвердил Int64 extrema, `9007199254740993`, Bool и null после explicit scalar extraction/unboxing; string-key HashMap transport сохранился. Это не утверждение, что произвольная mixed-key Java map стала lossless JSON object.

### SDK-09 · CLOSED / Python behavioral — detached HashMap views

`P/_java_types.py:319–369,438–442` возвращает backed key/entry views; `clear/remove/removeAll/retainAll` меняют исходную map. `Entry.setValue` возвращает прежнее значение и отклоняет удалённую entry (`:273–285`). Iterators отслеживают structural version (`:288–316`).

Прежний `keys=m.keySet(); keys.clear()` теперь оставляет `m.size()==0`; удержанный view видит последующие puts. `entrySet.clear`, value updates, integer-key removal, iterator.remove/invalidation и named refusal для view.add прошли в `map_views`/`map_iterators` (`T/test_java_value_regressions.py:303–356`).

## F03/F04 — source readiness native probe

- **F03 — исправлено:** `python/runtime/smoke/swift_sdk_hns_probe.swift:82` объявляет `grants: [PluginPermission]`; три uses `:83,156,195` согласованы с `PluginHost.setGrantedPermissions(... grants: [PluginPermission])` (`H/PluginHost.swift:1051–1055`). Grant set ui/messages.read/network/files сохранён.
- **F04 — исправлено:** `requireSecurityDenial` требует именно `{ok:false,error:{kind:"SecurityError"}}` (`swift_sdk_hns_probe.swift:131–135`). Destroyed-owner и old-token→replacement calls используют настоящий Host bridge и проверяют неизменность provider cleanup/release counts и replacement resources (`:211–244`). Это согласовано с owner rejection **до provider dispatch** в `H/BridgeServices.swift:208–232` и `.permission → SecurityError`.
- Idempotent cleanup проверяется отдельно во время actual retiring SDK unload, через production cleanup route и UI stored-token revoke (`swift_sdk_hns_fixture.swift:81–109`): ожидаются восемь duplicate no-ops и прежние 31 unique native retirements. Поздний SecurityError не подменён ложным success/no-op.
- Driver требует новые flags и прежние три reports/markers (`tools/runtime/check_swift_plugin_embedding.py:53–68`). Эти изменения source-correct; компиляция и выполнение всех трёх children ещё pending.

## Config receipt и оставшиеся четыре portable gaps

Current receipt и regeneration совпали: **272 implemented / 4 blocked / 32 unsupported = 308 уникальных exact overload IDs**, partition **220 / 44 / 44**. Среди reviewed source pins drift отсутствует.

Четыре blocked IDs независимо вызваны через production `ConfigStore.invoke`; все выдали named `UnsupportedSurfaceError` **без native calls**:

| IDs | Actual причина |
|---|---|
| `compat.ExteraConfig.getTabletMode()` / `setTabletMode(int)` | `NekoConfig.tabletMode`: нет native forced phone/tablet key/provider; automatic size-class layout не заменяет его. |
| `compat.ExteraConfig.getUseSystemFonts()` / `setUseSystemFonts(boolean)` | `NekoConfig.typeface`: нет native font-family selector/bundled-font assets; Dynamic Type и weight fallback — другие настройки. |

Это известные явные provider gaps, а не повтор SDK-02 scanner defect и не fictitious zero/false getters. 32 unsupported utilities также не переименованы в verified APIs.

## Независимо выполненная проверка

| Interpreter | Узкая выборка | Результат |
|---|---|---|
| CPython 3.12.10 | 19 Python/source cases + matching real C transport | **20 passed**, 7.92 s |
| CPython 3.14.8 | Те же 19 Python/source cases | **19 passed**, 7.80 s |

Exact selection:

- `T/test_sdk_config_manifest.py` — все четыре source/registration cases; включает `--check`.
- `T/test_sdk_config_binding.py` — все пять cases, включая двух SDK workers и exact native-root helper Python calls.
- `T/test_sdk_adapter_wave2.py::test_sdk_wave2` — `cancellation_winners`, `notifications`, `notification_payloads`.
- `T/test_java_value_regressions.py::test_java_value_regression` — `primitive_identity`, `array_identity`, `byte_fields`, `boxed_values`, `map_keys`, `map_views`, `map_iterators`.
- Только 3.12: `T/test_java_value_regressions.py::test_java_values_through_real_c`.

Каждый aggregate subprocess имел внешний **30 s** timeout; SDK workers — 20 s, Java workers — 30 s. Запуск: `python -X utf8 -B -m pytest <exact nodes above> -q -p no:cacheprovider`, `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1`, `PYTHONDONTWRITEBYTECODE=1`, отдельные approved-temp `--basetemp/--junitxml`. Первый runner attempt не создал parent basetemp: 4 source checks прошли, остальные fixtures не начали body. После создания собственного temp parent повторён тот же набор; implementation не менялась.

JUnit:

- `C:/Users/sasha/AppData/Local/Temp/opencode/sdk-source-closure-py312-268f7134/junit.xml`
- `C:/Users/sasha/AppData/Local/Temp/opencode/sdk-source-closure-py314-ac5f693e/junit.xml`

C artifact: `C:/Users/sasha/AppData/Local/Temp/opencode/exteraless-native-bulk-clear/_exteraless_bridge.cp312-win_amd64.pyd`, SHA-256 `0a95124fbae6b045992b700d60690445dc42d72e68413c62d4736460cfc35f0f`. Test проверяет ABI, binary hash и current C/header fingerprint из соседнего `remediation-report.json` **до загрузки**. C-owned echo service исполняет настоящий marshal/unmarshal; это transport fixture, не Swift/provider simulation, выдаваемая за native app pass. C219 numbering/baseline не менялись.

Дополнительно in-memory ≤20 s: все четыре blocked overloads; exact SDK/native notification registry equality; byte comparison 36 original SDK files. Полные owner runs **49/49**, Java **12/11** и **34 existing regressions each** прочитаны как owner evidence, но не объявлены повторно выполненными этим reviewer.

## Pins и предел verdict

`docs/wave-2/sdk-final-source-inventory.json` raw SHA-256:

`73e6abf1c5419daf36f88ebdca7616ebe24b38e429a982ac157f267468547ecf`

Проверены все его `sdk_source_sha256`, `integration_dependency_snapshot_sha256`, Java cohort pins, Config receipt hash и **56** `source_pins` из receipt: **84 уникальных файла, 0 несовпадений**. Config receipt SHA-256 — `63e97b1f4814cd7eacad9a4cebb859e3de26ac1390ac10024cd4409d9cd84b07`. Это актуальная цепочка pins; старые Runtime HNS hashes из исторического review не использованы как current equality.

Дополнительные/relevant raw pins:

```text
411b8e9eead79da90f45f3700005a1c62cc9acf1ea9fa265cdeedd81fc7efae5  docs/wave-2/sdk-adapters-final.md
55007047346fba8707841482a31bac2307a16885a47ab0b6f64c1533a811712a  docs/wave-2/sdk-java-remediation.md
27571b5a68da5a1f718ff310f96db4312e216723b39e6fbc719001bbdc6e7267  docs/wave-2/sdk-manager-authority-remediation.md
735bab1aa65253c9ce9ab3cb01576b14b951f3b1de0e8ae6ec04f872903599ec  docs/wave-2/reviews/sdk-config-adapters.md
1d44ca5414686ef791b4089b7566e6ceee32cb7f04cad59e8ca5b7de039a5cbf  U/ExteralessClient/ExteralessSettingsController.swift
e78665ba5d8c6a3ea47dae228ed69cd03b0586e9fdff8425265eb5faed9e4f44  U/ExteralessClient/PluginUI/PluginManagerPreferences.swift
7d10fffce395a25c8cd50e5da177009e486648e66ab3c2043b3120c093986e6d  U/ExteralessClient/PluginUI/PluginConfigBridgeExtension.swift
de2c753beed8dde39c48648df3fd8b1d6fb264338c81b926dfce461934d99d1d  telegram-ios/Tests/Exteraless/PluginManagerAuthorityTests.swift
c817d28bd8de0b7f942b790e7a7f060c27089d6a5352769dbcf9d0c1add0cb0a  H/BridgeServices.swift
695ff2cef7af8dcad96b28ff329574f0d09764676b5a94189b30d996a8ec3369  H/NativeServiceOperations.swift
70497a280c5ebc081e662fc72c656bb907df721981c19e2929f7c815e638c481  P/_callbacks.py
```

Все 36 `python/sdk/**/*.py` остались byte-identical original Android Python SDK. Общий digest по прежней формуле `SDK-relative path + NUL + raw SHA-256 + LF` — `9eff1a8c957fd2692f821b2ae787d5b5ffbe358f69de7ac9b4023736e8571ec7`.

**Итог ограничен SDK-01–09 и указанными probe joins.** Он не означает «925 public symbols verified», полный JVM port или закрытие четырёх native-provider gaps. Swift/swiftc отсутствуют; настоящие Core/root-provider и manager-writer tests, Foundation TL codec и три Mac children ещё должны выполниться на согласованном cohort. UIKit frames и production Telegram delivery этим verdict не подтверждаются. External plugins/accounts/network/CI не запускались.
