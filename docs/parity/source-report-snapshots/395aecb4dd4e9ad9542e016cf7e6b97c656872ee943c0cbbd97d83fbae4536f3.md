# Manager Custom + own setting aliases — focused source closure

2026-11-15. **PARTIAL: обе исходные точки входа соединены, но остаются два P2 в доставке событий. Полная source-closure этих контрактов пока не подтверждается.**

Scope: только `PLUGINS-P2-02` / `PLUGINS-P2-03` из
`docs/wave-2/module-routes/plugins.md:71–90` и их remediation из
`docs/wave-2/sdk-manager-custom-alias-remediation.md`. Основание — actual working-tree
source и ограниченные Python fixtures. Native XCTest, C-extension/Host integration
и UIKit/render execution в этой проверке не выполнялись.

Сокращения путей ниже:

- `P/` = `python/exteraless_runtime/`.
- `S/` = `python/sdk/`.
- `H/` = `swift/PluginHost/Sources/PluginHost/`.
- `U/` = `telegram-ios/submodules/TelegramUI/Sources/`.
- `UI/` = `U/ExteralessClient/PluginUI/`.

## Итог по двум исходным контрпримерам

| Контракт | Actual source | Остаток |
| --- | --- | --- |
| Manager `Custom(view/item/factory)` | Host read вызывает owner-worker materialization; decoder знает `.custom`; actual Manager cell создаёт shipping `PluginUIWidgetView`/container/resources. Прежний безусловный unsupported-row разрыв устранён. | **MCA-F02:** root Custom action обходит очередь ранее принятых inline mutations. |
| `openPluginSettings(ownId, target)` | Facade принимает target, resolver ищет точный исходный alias/key, native page/row focus подключён. Прежний отказ для любого non-null target устранён. | **MCA-F01:** portable refresh переключает callback snapshot до native model commit. |

Граница alias-контракта — own-id facade и native settings target. Новый внешний
обработчик `p`/`s` URL этим изменением и этой closure не заявляется.

## MCA-F01 · P2 · portable refresh публикует новые callbacks до native commit

**Остаётся воспроизводимый рассинхрон S1 UI → S2 callback.**

### Источник

1. `P/_ui.py:55–60` считает возврат `uiUpdate` завершением обновления своего model.
   `show_settings.refresh`, `P/_ui.py:840–848`, после этого немедленно делает
   `page = replacement` и `previous.close()`.
2. Общий `receive` замыкает эту изменяемую переменную `page`
   (`P/_ui.py:833–839`). Обычный change выбирает callback по key из **текущей**
   страницы; исходный native revision/page snapshot здесь не выбирается.
3. Actual `UI/PluginUIBridgeExtension.swift:189–214` возвращает null после
   `DispatchQueue.main.async`, **сохраняя прежние committed model/revision**.
   Commit выполняется позднее в `applyUpdate`, `:689–702`, через
   `UI/PluginUILifecycle.swift:339–366`.
4. `refresh(id:)` не меняет revision (`PluginUILifecycle.swift:437–443`), а
   `permitsCallback`, `:294–310`, допускает callback со всё ещё текущим старым
   `_uiRevision`. Уже захваченный old event потому может пройти actual worker gate
   до отложенного main commit. Owner/account и permission lease при этом остаются
   текущими; добавленный permission predicate не связывает snapshot с UI revision.

### Контрпример

- S1 содержит `Switch("known_key", ..., on_change=callback_v1,
  link_alias="known_alias")`; own-id API открыл содержащую его подстраницу.
- Пока owner выполняет refresh с `callback_v2`, native захватывает событие S1.
- `uiUpdate(S2)` проходит проверку assets/owner, но его main commit ещё не выполнен.
  Допустимый controlled schedule: задержать main **после asset readback**, перед
  `applyUpdate`; событие S1 уже стоит в owner FIFO за refresh.
- Python refresh возвращается и закрывает S1 snapshot. Native revision всё ещё S1,
  поэтому старое событие проходит gate, но `receive` вызывает `callback_v2`.

Ожидаемый контракт: событие S1 либо исполняет S1 callback, либо отклоняется; оно не
должно исполнять S2 callback до отображения/commit S2.

**Независимый bounded Python control воспроизвёл именно Python-половину этого
стыка:** в существующем owned fixture `uiUpdate` только сохранял pending model и
возвращал None, повторяя разделение admission/commit из actual Swift source.
Production Python и исходный SDK исполнялись без изменений. Результат:

```json
{"visible_snapshot_version":1,"callback_snapshot_version":2,"native_model_still_old":true,"persisted_value":true,"native_execution":false}
```

Это не native execution receipt. Достижимость промежутка и сохранение native gate
подтверждаются указанными Swift bodies; fixture показывает, что SDK действительно
выбирает S2. Имеющийся `test_sdk_manager_custom_alias.py:48–51` обновляет recorder
model синхронно, поэтому его green `portable_refresh` этот промежуток не проверяет.

Необходимый контракт исправления: смена callback snapshot должна быть связана с
actual native revision/commit либо старые events должны терять admission на той
же границе. Одного успешного возврата из queued `uiUpdate` недостаточно.

## MCA-F02 · P2 · Manager root Custom click обгоняет pending inline changes

**Есть два независимых пути в один owner mailbox без общего порядка событий
пользователя.**

### Источник

- Nested widget changes/clicks проходят через `UI/PluginUIManagerWidgetEvents.swift:27–60`.
  Только одно событие отправляется в `actions.click`; последующие остаются в
  `pending`, пока `await actions.click(...)` не завершится (`:41–50`).
- Root `Custom.on_click` создаётся отдельно в
  `U/Exteraless/PluginSettingsController.swift:435–443` и вызывает
  `click(...)`, `:500–513`, напрямую через `PluginListController.perform`.
  Root long callback использует тот же прямой путь (`:382–384`).
- `PluginListController.tableView(didSelectRowAt:)`,
  `U/Exteraless/PluginUIHelpers.swift:339–344`, исполняет этот `row.action`.
  Он не ждёт `widgetEvents.pending` и не передаёт текущий draft nested widgets.
- `H/PluginHost.swift`, `clickSetting` в scoped region `:1270–1319`, кодирует root
  событие как `{kind:"click", callbackId}`. `P/_ui.py:548–551` передаёт root callback
  сохранённый Widget. Его значения обновляются только при исполнении widget change
  (`:552–563`).
- Actual `InterpreterMailbox` сохраняет **порядок постановки jobs**, а не более
  ранний порядок UIKit events: `H/SubinterpreterManager.swift:186–211,429–438`.

### Детерминированный source schedule

1. В Manager Custom row есть вложенный input и root callback, читающий
   `root.children[0].getText()` — ровно форма owned fixture
   `tools/compat/tests/fixtures/ios_runtime/manager_custom_alias.plugin:68–71`.
2. Принять input change **E1 = "a"**; удержать его callback на owner worker после
   записи `view.model["value"]`. Native input остаётся интерактивным.
3. Принять **E2 = "ab"**. UIKit уже показывает `ab`, но E2 находится только в
   `PluginUIManagerWidgetEvents.pending`: worker Task ещё ждёт E1.
4. Вызвать actual root row action **R**, пока E1 удерживается. Прямой click path
   успевает поставить R в Host mailbox; E2 туда ещё не отправлен.
5. Освободить E1. Mailbox исполняет **E1 → R → E2**. Root callback получает `a`,
   хотя последнее уже принятое input value — `ab`.

Owner, account и page lease во всём сценарии остаются текущими; текущие stale
guards эту перестановку не запрещают. Даже если последующий refresh закроет E2,
R уже наблюдал неправильное значение.

Это source counterexample; native schedule здесь не исполнялся. Подготовленный
native cell test (`ManagerCustomAliasNativeTests.swift:58–105`) вызывает recorder
closure непосредственно и не соединяет `PluginUIManagerWidgetEvents` с отдельным
root `PluginSettingsController.click` path.

Необходимый контракт исправления: root Custom click/long-click должен соблюдать
тот же порядок ранее допущенных inline events либо получать согласованный snapshot
их значений перед вызовом Python.

## Что подтверждено в остальных проверенных стыках

### Manager materialization, данные и ownership

- `U/Exteraless/PluginSettingsController.swift:46–71` создаёт
  `PluginSettingsPageLease` из **captured read.owner/account**, помещает его в
  `PluginSettingsPageExecution.current` и проверяет `wasRead` перед decode.
  Read error/cancellation закрывают непереданный lease через defer.
- Actual Runtime forwarding — `ExteralessPluginRuntime.settings`, scoped
  `:432–467`; Host `settingsJSON`/release — `H/PluginHost.swift:1216–1255`.
  `CreateSettingsPayload.settingsPage` сохраняется при `pinned`
  (`H/ExtensionPoints.swift:189–213`). Actual dispatch и script builder используют
  `_ui.read_settings_page_json` (`H/PluginHost.swift:1596–1610,2046–2050`).
- `P/_ui.py:358–419` делает `copy.copy(PluginRecord)` с новыми click/change/custom
  dictionaries и сохраняет **тот же instance**. `scope`, `:387–399`, подставляет
  snapshot только на owned worker и восстанавливает исходный record в finally.
  `dispatch_json(create_settings)` вызывает original serializer.
- `P/_ui.py:432–445` вызывает original `S/extera_utils/plugin_loader.py:3532–3577`
  builder, в порядке `view → item → factory`; `SimpleSettingFactory.build_view`
  находится в `S/ui/settings.py:150–160`. Factory исполняется до Foundation/UIKit
  decode. Android View/UItem/Java subclass facets сохраняют явный unavailable scope.
- `prepare_widget`, `P/_ui.py:481–537`, извлекает callbacks перед существующим
  `Widget.to_model()` deepcopy и восстанавливает **те же объекты** в finally.
  Bound method не копирует plugin instance. Snapshot хранит точные
  `(row, widget, event, callback)` tuples, а `event`, `:539–564`, проверяет их;
  input callbacks получают value, click callbacks — Widget, zero-argument callable
  использует original optional-argument helper. Изолированный Manager page UUID
  не выбирает callbacks из следующего read.
- Snapshot резервирует SDK lease без `.wrap`/`xt_register_handle`
  (`P/_ui.py:362–367`). Это source-путь с нулём **собственных** C callback handles;
  recorder отдельно подтвердил zero handles. Arbitrary plugin factory effects и
  реальный C runtime этим утверждением не измерялись.
- Decoder `UI/PluginUIManagerSettingsDocument.swift:25–65` использует existing
  `PluginUIWidget.parse` и resource checks. Actual cell construction находится в
  `PluginSettingsController.swift:339–370` и
  `UI/PluginUIManagerCustomCell.swift:16–51`: shipping WidgetView, container,
  constraints, fonts/images. Это source wiring настоящего renderer.

### Stale/cancelled reads, действия и release

- Native page `close` атомарно снимает open и забирает cleanup один раз
  (`H/PluginSettingsPageLease.swift:23–47`). Host cleanup несёт captured owner,
  проходит `settingsTarget(expectedOwner:)` и ставит release на тот же mailbox.
  Close до build запрещает build через guard; close после worker entry ставит
  release после него. Unload дополнительно закрывает zero-handle SDK lease.
- Host page actions проверяют page/owner/account и передают page/permit/UI guard
  как **worker predicate и retained-effect guard**; actual `invokePlugin`
  устанавливает его на worker (`H/PluginHost.swift:1810–1862`).
- Controller refresh, external invalidation, replacement, disappearance/deinit
  закрывают/отзывают соответствующие page/actions; closures проверяют захваченный
  lease через `matches` (`PluginSettingsController.swift:149–177,194–216,243–283,477–534`).
  Native selector захватывает permit **до** показа action sheet (`:541–561`).
- Runtime `closeAll` стоит до account replacement/clear и в terminate;
  `UI/PluginUIManagerSettingsLifetimes.swift:12–20` держит weak leases и закрывает
  захваченные экземпляры. Здесь нет reacquire нового owner по plugin id.
- Ordinary setting change сохраняет порядок persist → original on_change;
  callback failure не отменяет выполненную запись. Post-action reread имеет свой
  read permit, а stale/cancelled action выходит до нового create_settings
  (`PluginSettingsController.swift:82–114`).

### Own alias/key target и focus

- `P/_facades.py:53–55` проверяет own id до `show_settings(target=...)`.
  Последний сначала получает current fragment/account, затем строит snapshot
  (`P/_ui.py:813–831`). `None` задаёт обычный root без targetRowId.
- Python resolver (`:310–341`) и native resolver
  (`PluginSettingsModel.swift:192–211`) ищут точный `link_alias OR key`, один match
  на row, включая sub_page. Native сравнивает UTF-8 bytes, сохраняя различие
  `é` / `e\u0301`. Пустой/NUL/невалидный target, >256 UTF-8 bytes, unknown и
  duplicate имеют отдельные ошибки; строка не trim/case-fold/normalize.
- Navigation использует original serializer `row_id`, а alias остаётся lookup
  key (`P/_ui.py:471–474`; `S/extera_utils/plugin_loader.py:3248–3266`).
  `UI/PluginUIModel.swift:486–526` валидирует pagePath/targetRowId и запрещает
  retarget sourceId при update.
- Manager focus (`PluginSettingsController.swift:251–255,571–581`) и portable
  `UI/PluginUISettingsTargetFocus.swift:9–18` прокручивают существующую строку
  после проверок visibility/scope. Portable helper подключён на appearance и
  layout (`UI/PluginUIContentController.swift:122–143,230–264`). Focus не вызывает
  callback строки.
- Synchronous rejected update или unknown refreshed target закрывает candidate
  snapshot и сохраняет прежний (`P/_ui.py:822–848`). **Асинхронная граница successful
  admission → commit остаётся MCA-F01.**

### Проверенные ограничения

Manager JSON: 1 MiB, 1,000 rows, 16 subpage levels. Custom trees: 512 nodes,
8 levels, cycle/duplicate-ID rejection. Page callback ledger: 128 entries и
existing SDK lease-generation/count budget. Inline native FIFO: 128 events /
512 KiB, включая in-flight event. Portable presentation дополнительно проходит
existing `PluginUIModel`/Widget bounds. Resource failure закрывает rejected page;
Python factory failure даёт видимый `custom_error` и удаляет references этой строки.

## Applied joins и выполненная проверка

Bounded static check подтвердил **11/11 actual shared joins**:

- Runtime: page forwarding и три closeAll lifecycle sites — 4.
- PluginUIModel: target field admission и target validation — 2.
- ContentController: focus instance, appearance call, layout/helper call — 3.
- ClientHarnessRuntime: тот же page forwarding — 1.
- TelegramUI BUILD: actual filegroup из 11 существующих sources — 1.

Новые sources входят в production `Sources/**/*.swift`; native test target
`telegram-ios/Tests/ManagerCustomAlias/BUILD` использует этот filegroup и PluginHost.
Наличие BUILD entries не является compilation/execution receipt.

Локально выполнено:

```text
python -B -m pytest -p no:cacheprovider -q tools/compat/tests/test_sdk_manager_custom_alias.py --basetemp <fresh approved opencode temp>
8 passed in 4.73s
```

Каждый existing case — fresh `-I -S -B` child с 20-second timeout, общий command cap
30 seconds. Дополнительный deferred-refresh control — отдельный `python -I -S -B`
process под 30-second cap; только owned fixture, native wire recorder и временные
данные в approved opencode temp. Его изменённая **fixture** логика исполнялась из
памяти; production/test source files не переписывались.

Provided 10 Python passes из handoff остаются evidence автора; новые результаты
reviewer — 8 cases и один counterexample выше. Прочитаны 4 Host tests
(`PluginSettingsPageLeaseTests.swift`) и 5 native tests
(`ManagerCustomAliasNativeTests.swift`); они здесь **не запускались**. Host tests
используют canned engine, а Python tests — wire recorder. Полный Host+C+SDK+UIKit
стык и recorded frames для нового кода остаются отдельной execution границей.

## Source checkpoint

Для shared Runtime/Host/facade/composition и UI bridge/lifecycle фиксируются **scoped LF regions**.
Несвязанные добавления, включая новый source-root/developer entry, не требуют
совпадения старого whole-file hash. Диапазоны строк ниже относятся к этому
checkpoint; SHA привязан к указанному region text.

| Region | Lines | SHA-256, UTF-8/LF |
| --- | --- | --- |
| `U/Exteraless/ExteralessPluginRuntime.swift`, `settings(id:)` до `updateSetting` | 432–467 | `c1f9bbeefed8af6d8df6c6b4ef1b7b7934a1a8ccf25e258de42cb602459be0b2` |
| `H/PluginHost.swift`, `settingsJSON` + `releaseSettingsPage`, до `resolveSettingsReadOwner` | 1216–1255 | `fe2ec2b1b513eb20c37cafc6d3426e0b9547a9003119e4dc839a56235d08b728` |
| `H/PluginHost.swift`, `updateSetting` + `clickSetting`, до `settingsTarget` | 1270–1319 | `fb89f07c6d55242cbf44eb2403ecc51897c8b2e34bf72ba6a93cfcf5b9c93e97` |
| `H/PluginHost.swift`, handleEvent createSettings case, до sendMessage case | 1596–1610 | `9fda04a53918174dea2d62e3dc59c0176ab5b4de004065d536fb86e103bb9909` |
| `H/PluginHost.swift`, script-builder createSettings case | 2046–2050 | `748da6fd40daf7dfed7e4088989a8a4e0b52c7042dfbe192c6c1c038fcdefa0f` |
| `H/PluginHost.swift`, `invokePlugin`, до `recordExecutionFailure` | 1810–1862 | `9082f451f9b7ec53143478d707284ad248ee4b9c2c0b698818cfad92073a38f0` |
| `P/_facades.py`, `Controller.openPluginSettings`, до следующего class | 53–55 | `d72f79d2ca923f324f9bca2a84ed6a6c93125584d27ed4d24a2782af7edce608` |
| `UI/PluginUIModel.swift`, targetRowId validation block | 501–511 | `3b6140605187199998c66f1cad3b807ecec0efa0550e7da2ecd156cd07fa0ffa` |
| `UI/PluginUIContentController.swift`, `revealSettingsTarget`, до `page()` | 261–265 | `c2a1f0f3b36e47b54e0f770253743d15d00937b10a09f1e394953aaa08be2ba5` |
| `telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessRuntime.swift`, settings closure | 143–150 | `3a02a7405c9cd3a156b02162277b24276c6ea234a1cff5dd2dc3149d7232be2f` |
| `telegram-ios/submodules/TelegramUI/BUILD`, ExteralessManagerCustomAliasSources filegroup | 126–142 | `210f50ef5ca19d87a05001ee47776f3d56dcc3b260dd151c3e4c57023bde581f` |
| `UI/PluginUIBridgeExtension.swift`, uiUpdate case, до uiState case | 189–214 | `1c9c5d59904b5985ba9b5f8b21f72b35bf368a7d6b5c94c82e9ce3767ac3e527` |
| `UI/PluginUIBridgeExtension.swift`, applyUpdate, до canAct | 689–709 | `1891e33717291f4d6f695ab1a0a1732c6e9d0cfd9d354e4a0ab43e0da42ae9e2` |
| `UI/PluginUILifecycle.swift`, permitsCallback, до beginPresentation | 294–311 | `811ef932e95df8956ad82c6ec69aedc935d787693e5750213f2896919a0bb127` |
| `UI/PluginUILifecycle.swift`, update, до комментария Claim before scheduling | 339–367 | `c2f0a63acd7376d5b004a010f6365512cc4f24d95d161bfaa5a5839ca2c6789e` |
| `UI/PluginUILifecycle.swift`, refresh, до release(pluginId:) | 437–444 | `9b139b872907b81eca0a792ba832a64f1c94bab97bb7132befc6b908eec51fbf` |

Raw-file SHA-256 для owned inputs/consumers, составляющих рассмотренные маршруты:

```text
6cd1ff47408cade40aa6a99b19c0319bdde291990182bf245aad21708ebbf57f  python/exteraless_runtime/_ui.py
483154a1355c8476f8fff60dbf9975e5b4f7cb088d62d822071c6c7b0c5000e3  python/sdk/ui/settings.py
c90134bde58559d675ffeff313eecd4223f39d60edbe0992137b41461b6547f5  python/sdk/extera_utils/plugin_loader.py
d607bf036b27d3af74de54a0fce1f1614f7bdd73ab940d443feb074df0d5e19c  swift/PluginHost/Sources/PluginHost/PluginSettingsPageLease.swift
a7f5ce2b5fd5495a505a548504a40c9cf8f83fbbfcbd95d22d727da5360dec5b  swift/PluginHost/Sources/PluginHost/ExtensionPoints.swift
083f795b3e8f246b7d517ef82e57eb09a8cce8f409c0ba0e133b11ac1b853269  swift/PluginHost/Tests/PluginHostTests/PluginSettingsPageLeaseTests.swift
18c11359debb3c72176bf4a939b158532a60cca4dcfe3529a4e6ed9b66cd1285  telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginSettingsController.swift
1561d1dd79fa407818f2c23ea9f2fdb8ed6781d86c49c283be348ce41c47cfd7  telegram-ios/submodules/TelegramUI/Sources/Exteraless/PluginSettingsModel.swift
1cd3f90853801580581cf49497082541112a0e8a6419d50a266fa87a6b02b143  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIManagerSettingsDocument.swift
da8e69a506ffa0aec8dbe29d641dc7a9fb5e049e3f3877b6d23840899ab3e610  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIManagerCustomCell.swift
30a0411f84065f65bbf28ae7352756cbf19716394221fdf14179e78f02e8b2b4  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIManagerSettingsLifetimes.swift
731ef03db3afef8345b9c563a2cc9bfd8ad2de61f3cc26ef959d8e892b1ef899  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUIManagerWidgetEvents.swift
23a0fef3a408fb003e33f3b172a791b08a0225eaaec3775d430ab52eb1d36fba  telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/PluginUI/PluginUISettingsTargetFocus.swift
964ab285a50df1a2efd7d76fa22a8376976a61cf4718ca88a68b964fc2999792  tools/compat/tests/test_sdk_manager_custom_alias.py
77b935dc760fd01b328bfdf519afe334905ac4aca5d29d818199f040346eedd4  tools/compat/tests/fixtures/ios_runtime/manager_custom_alias.plugin
fa3169d01778edc0e189f73b6fff3d192f3ee9ba1f81f125fe8e0c470a7758bb  telegram-ios/Tests/ManagerCustomAlias/ManagerCustomAliasNativeTests.swift
```

**Остаток в заданном scope: MCA-F01 и MCA-F02 (P2).** Отсутствие исходных
materialization/alias entry gaps и green Python cases не устраняют эти два
межочередных контрпримера.
