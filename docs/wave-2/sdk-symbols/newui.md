# Exact UI SDK source reconciliation — 147 IDs

**Готова карта [newui.json](newui.json): ровно 147 исходных ID, без добавленных, пропущенных или дублированных символов.**

Это source-disposition по схеме `README.md`. Во всех 147 строках `ported=false`, `verified=false`, `native_execution_claimed=false`. `metadata` и `native-adapter` не являются оценкой функциональной/визуальной готовности.

## Scope и fingerprints

Начальный HEAD: `9bfce05f708fba472ca942bcfe355914847a347d`; рассмотрен actual working tree. `original.path/line/symbol` каждой строки сверены с исходным inventory, а actual override и provider указаны отдельно.

| Модуль | Exact IDs | SDK source SHA-256 |
|---|---:|---|
| `ui.settings` | 87 | `483154a1355c8476f8fff60dbf9975e5b4f7cb088d62d822071c6c7b0c5000e3` |
| `ui.alert` | 40 | `38446959aa3cf1c17df24967ca6cc319aa98a18be1cd4006dde27a416b2cffc0` |
| `ui.bulletin` | 20 | `8eec86cc8f684a2872cb889eaee633e71b692302d215010390a8212d137ea19d` |

- Input `docs/parity/sdk-surface.json`: `ce7b067fdcffc440ba3640ac194c2eef8a68192a80410cbcb3a593e0d9cf64d8`.
- Schema `docs/wave-2/sdk-symbols/README.md`: `732b61337c3acb19bba4ff5d111a9fdb63a8481210d7885e9bbd9dcf342038d7`.
- Scope hash: `afc4f5a40344273014e1fb694d4afb670c7b05f08da6371e4a891c492aa70eaf` — SHA-256 от UTF-8, sorted exact IDs, LF после каждого ID, включая последний.
- `newui.json`: `2d07544d4806b466d6d3969191ccb88148d4efc027c6cd07210d6a247d41e400`.
- В JSON закреплены **36 input hashes**, включая 25 различных source paths из ordered routes и общий transport/lease context.

## Dispositions

| Модуль | metadata | plugin-contract | pure-sdk | native-adapter | partial | unsupported |
|---|---:|---:|---:|---:|---:|---:|
| `ui.settings` | 63 | 18 | 3 | 3 | 0 | 0 |
| `ui.alert` | 9 | 4 | 2 | 16 | 4 | 5 |
| `ui.bulletin` | 8 | 0 | 0 | 0 | 12 | 0 |
| **Всего** | **80** | **22** | **5** | **19** | **16** | **5** |

`ui.settings` состоит преимущественно из реальных dataclass fields. Их metadata-статус не скрывает ограничения потребителей: например, `Custom` материализуется только на portable Widget route, а `EditText.mask` хранится в Python, но не передаётся renderer. Эти ограничения указаны в соответствующих exact-ID строках.

## Actual iOS dispatch

### Bootstrap и byte-identical SDK wrappers

`Platform.install` (`python/exteraless_runtime/_platform.py:308–325`) устанавливает `_settings`, `_logging`, затем `_ui`. `_ui.install` регистрирует точный `org.telegram.ui.ActionBar.AlertDialog$Builder` как локальный Python `Builder` (`_ui.py:306–392`). `java.jclass` проходит через `virtualjava/finder.py:114–118` → `proxy.get_class:204–209` → `registry.get_registered:45–52`; зарегистрированный класс выбирается раньше C fallback.

Поэтому неизменённый `AlertDialogBuilder.set_title` реально вызывает Python `Builder.setTitle` и `Builder._set`, а не неизвестный Android setter. `_run_sync` и `_post` заменены на owner-worker `ui_sync` (`_ui.py:424–428`), без Android Looper wait. `__init__`, `make_button_red`, `set_blurred_background`, `set_items` имеют отдельные actual replacements (`:431–454`).

Button/dismiss/cancel/back proxy wrappers из исходного `ui/alert.py` получают локальные interface classes из `_java_types.install:659–672`; `virtualjava.proxy.dynamic_proxy:92–112` создаёт Python implementation. `Builder.create.handler` вызывает эти Python listener methods, сохраняя SDK callback signatures. `alert.safe_call` — bound import; при штатном configure `_logging.install` уже установил actual `safe_call` до импорта alert в `_ui.install`.

### Presentation и callback ownership

Рабочая цепочка для alert/bulletin:

`SDK body / runtime replacement` → `_ui.Builder` либо `show_bulletin` → `Presentation.show` → `Runtime.uiPresent(kind, model, callbacks)` → `PluginUIBridgeExtension.call` → `PluginUIContentController`.

- `create()` создаёт локальный `NativeDialog`; native admission происходит при `show()`.
- `Presentation.show` (`_ui.py:25–47`) создаёт уникальный `CallbackLeases.Lease`, обёртки пользовательских callbacks и reserved `closed`; `native_owned` выставляется после успешного ответа с id. Failure rollback закрывает SDK wrappers.
- `PluginUILeaseStore` удерживает original CallbackOwner, account scope, revision и уникальные callback handles. Последующие `uiUpdate`, `uiDismiss`, `uiState` работают по id этого lifetime.
- Native callbacks идут через Runtime worker predicate и `PluginCallbackDispatcher` owner FIFO; terminal callbacks предшествуют release. Quota удерживается до FIFO admission release.
- Button/item listener получает `(builder, which)`, dismiss/cancel/back — `(builder)`. Bulletin action/undo callbacks вызываются без аргументов. Ignored returns нормализуются в `None`; это не result-bearing intent barrier.

Это существующий retained-owner contract; закрытые HNS-F01–04 данным reconciliation не переоткрываются.

### Два settings consumers

**Plugin Manager:** `Host.settingsJSON` → `_exteraless_runtime.dispatch_json('create_settings', …)` → `plugin_loader.get_settings_json` → `_serialize_setting_data` → `PluginSettingsDocument` / `PluginUISettingsPageDocument` → `PluginSettingsController`.

`on_change` сохраняется в `PluginRecord.change_callbacks[key]`; click/long-click — в `click_callbacks[cb_/lc_]` (`plugin_loader.py:3131–3152`). Эти строки-ID **не являются C handle numbers**. Native Manager action использует captured settings/read/action authority, Host `setting_changed_json` / `setting_click_json`, SDK account scope. `notify_setting_changed:3484–3499` сначала вызывает actual `_settings.set_value` → `Runtime.updateSettings`, затем пользовательский callback. Сигнатура — `fn(value)`/`fn()`; click — `fn(None)`/`fn()` по optional-argument helper.

**Portable settings:** `_facades.Controller.openPluginSettings` → `_ui.show_settings` → SDK serializer → `prepare` → `Presentation(kind='settings', rows=…)` → `Runtime.uiPresent` с четырьмя generic change/action/longAction/refresh callbacks и внутренним closed. `prepare` удаляет `integral`/backup annotations, преобразует link alias в `id`, материализует Custom в Widget и рекурсивно готовит subpages (`_ui.py:498–534`).

Read/write storage — actual `_settings.install.get_value/set_value`, `BridgeServices.callRuntime(getSettings/updateSettings)` и `PluginServiceStorage`. Отдельные dataclass fields не получают выдуманного native member или lease. Динамический `create_settings` остаётся display metadata, не immutable backup proof.

## Конкретные unavailable/partial routes

### Пять unsupported alert methods

| Exact suffix под `sdk.ui.alert.AlertDialogBuilder` | Отсутствующий actual selector / provider |
|---|---|
| `set_top_animation` | `Builder.setTopAnimation`; отсутствует top-animation DTO/resource renderer |
| `set_top_animation_is_new` | `Builder.setTopAnimationIsNew`; отсутствует animation lifecycle field |
| `set_top_image` | `Builder.setTopImage`; отсутствует Android integer-resource/background tuple adapter |
| `set_top_drawable` | Тот же отсутствующий `setTopImage`; нет Android Drawable → UIKit converter |
| `set_dialog_button_color_key` | `Builder.setDialogButtonColorKey`; нет Android numeric theme-key → button-color adapter |

Сейчас вызов этих wrapper bodies доходит до отсутствующего Python selector и поднимает `AttributeError`. Наличие отдельного native `icon`, `color`, spinner либо `destructive` field не считается реализацией этих exact IDs.

### Поддержанные subsets

- **Alert constructor:** styles 0/2/3; настоящий Android ResourcesProvider не поддерживается. Wrapper сохраняет explicit context для `get_context`, но native presenter/account выбирается retained native scope. Не заявляется произвольная переадресация context в UIKit.
- **`set_items`:** items ≤256, строки ≤4096 UTF-16, icons count совпадает с items. Поддержаны named aliases / `sf:` / `bundle:` и отсутствие icon (`None`/0); nonzero Android integer icon не имеет resolver.
- **`set_view`:** только `_ui.Widget` ports; height `-1`, `-2` либо 0…8192 native points. SDK `height=None` выбирает overload без height, то есть wrap. Нет произвольного Android View adapter.
- **`set_progress`:** 0…100 на созданном dialog; до create — no-op. Loading отображает процент; spinner остаётся indeterminate, message style не рисует progress.
- **Все 11 bulletin helpers:** реальные staticmethod overrides (`_ui.py:469–488`). `fragment` принимается, но не переносится в `Runtime.uiPresent.sourceId`; default current presenter route — единственный соединённый. Поэтому все их строки `partial`.
- Bulletin helpers с `icon_res_id` используют `icon_value`: нет nonzero integer drawable resolver. `show_file_saved_to_downloads` не использует `file_type`; отсутствует `BulletinFactory.FileType/createDownloadBulletin` specialization, показывается `Saved to downloads (N)`.
- `show_copied_to_clipboard`, `show_link_copied`, `show_file_saved_*` показывают notification; они не копируют данные, не сохраняют файлы/Photos и не доказывают результат отдельного действия.

### Реальные data fields и factory aliases

- `Custom.view`, затем `item`, затем `factory` — фактический порядок `_build_custom_view:3532–3577`. Portable route требует `_ui.Widget`; Manager `PluginSetting.Kind` не имеет `custom`, `PluginSettingsController.makeRow:346–349` показывает unsupported row.
- `factory_args` реально хранится и участвует в SDK identity. Python `build_view(context, False)` его не получает; Java CustomSetting.Factory branch имеет forwarding, но не даёт универсального iOS factory renderer.
- `EditText.mask` — реальное поле, отсутствующее в SDK JSON projection и native input fields; metadata-строка прямо фиксирует этот пробел.
- `SimpleSettingFactory` хранит constructor delegates. `build_view` использует create_view/create_item/bind_view и prefix binding; is_clickable/is_shadow/attached_view/equality и factory-level click facets не передаются native provider. Это plugin contract с указанными ограничениями, не набор абстрактных native полей.
- SDK `PluginItemFactory` — alias `SimpleSettingFactory` (`settings.py:189`). `instance.java` возвращает исходный Python factory через `_FactoryPeer`; `.java` и `getInstance()` разрешают **другой** FQCN-registered Python port, который возвращает новый facade. `to_item()` вызывает его реальный `create(factory,args)` и получает Custom. Java singleton identity не предполагается.
- `link_alias` имеет реальную identity/id-проекцию; key имеет приоритет в `_item_ident`. Manager не получает external alias resolver, а `_facades.Controller.openPluginSettings(target!=None)` явно отказывает. Portable prepare делает alias → `id`, с native uniqueness/length checks.

## Native bounds

- UI JSON ≤512 KiB, depth ≤24; ≤128 callback entries; default presentation quota 16/plugin, 128 total. Это admission bounds, не promise UI appearance.
- Alert: title ≤4096 UTF-16, message/text ≤65536, subtitle ≤16384; ≤3 unique button IDs `-1/-2/-3`, nonempty button text ≤1024.
- Bulletin: integer duration 250…60000 ms, buttonText nonempty ≤1024; basic helpers default 1500, button/undo 5000. Native visible timing может продлеваться accessibility policy.
- Images: known aliases, `sf:` или безопасный относительный `bundle:` path, ≤256 UTF-8; actual missing image → `ResourceUnavailable`.
- Manager settings: document ≤1 MiB, ≤1000 rows, depth ≤16, selector ≤1000 options. Portable settings: ≤512 widgets, depth ≤8, selector ≤256 options; input max_length 0…65536, default 16384. Unicode scalar limits не объявляются Android UTF-16 LengthFilter parity.
- Slider SDK/Manager: finite values, max>min, step>0, ceil(span/step)≤Int32.max; portable additionally ограничивает min/max ±1e12, step 1e-12…1e12.
- Native per-plugin storage: key 1…256 UTF-8 без NUL, settings JSON ≤1 MiB. Callback failure после записи не означает rollback.

## Evidence и validation

В каждой строке `evidence` ссылается на конкретный source body/declaration. Никакой generic importability check не используется как evidence поведения exact ID.

Предоставленные внешние к этой source-карте receipts сохранены в исходной интерпретации: Mac `43738810843/136` (три SDK/C children, C219, 671 Core, 23 HNS), более поздний Ghost `1af9` (670 Core + 363 Pytest), harness cohort 36 targets / 410 tests / 8 frames. Здесь эти runs/frames не запрашивались и не переразмечались как execution всех 147 symbols. В частности, Foundation/manual-main/DTO recorder не становится production UIKit renderer. Статус нового app/CoreGate не запрашивался.

Проверка самой карты, read-only и bounded:

- exact set equality с тремя модулями inventory; **147/147**, unknown/missing/duplicate = **0/0/0**;
- все `original` совпадают с inventory path/line/name;
- все schema-required поля, SDK signatures, nonempty routes/evidence присутствуют;
- dispositions принадлежат разрешённому enum; все три claim flags строго `false`;
- source hashes совпадают; route paths существуют, line ranges валидны; основные body/field anchors дополнительно прочитаны;
- scope hash воспроизводится указанным LF-алгоритмом.

Новых доказанных P1/P2 behavior findings в этой задаче не выделено: `findings: []`. Конкретные недостающие selectors/adapters и ограничения полей перечислены в exact rows. Старые HNS reports и receipts не изменялись.

## Diff handoff

Изменения этой задачи — только два новых файла:

- `docs/wave-2/sdk-symbols/newui.json`
- `docs/wave-2/sdk-symbols/newui.md`

Карта готова к exact-ID join; native-adapter/partial dispositions и source tests не меняют исходные `ported/verified/native_execution_claimed` flags. Implementation, inventory/scanner, CI и другие author maps остаются отдельными read-only inputs.
