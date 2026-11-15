# Utilities: 267 exact SDK source routes

**Сопоставлены 267/267 исходных ID; пропусков, дубликатов и неизвестных ID — 0.**
Машинная карта: [`utilities.json`](utilities.json), схема: [`README.md`](README.md).
Для каждого ID записаны исходный символ/строка, фактический маршрут, контракт,
ограничения и именованные source references. Все `ported`, `verified` и
`native_execution_claimed` равны **false**.

Это количество **сопоставленных записей**, включая декларации и явные пробелы,
а не количество работающих функций. Исходные параметры, defaults, annotations
и return annotations сохраняются в [`sdk-surface.json`](../../parity/sdk-surface.json)
и адресуются точным ID; строки `original` указывают на его byte-identical SDK copy.

## Граница и метод

- Проверка 2026-11-15, исходный HEAD `9bfce05f708fba472ca942bcfe355914847a347d`.
- Чтение тел SDK, поздних runtime override/registration, C transport, Swift Host
  и конкретных native providers; локальные JSON/AST/hash-проверки через
  `python -B`, каждая команда с лимитом 30 секунд.
- SDK и внешние плагины не импортировались/исполнялись. Сеть, CI, приложение и
  UIKit не запускались; pending e16 не опрашивался.
- **15/15** выбранных SDK-файлов побайтно равны соответствующим файлам
  `third_party/exteraless-android/TMessagesProj/src/main/python/` и совпадают
  с SHA-256 inventory. Совпадение исходников не доказывает поведение.
- `source_sha256` содержит **76** raw-file SHA-256: все source anchors карты,
  исходные Android counterparts, схема и scoped acceptance reference.
  Переводы строк при хэшировании не нормализовались.

| Модуль | ID |
|---|---:|
| `dev_server` | 13 |
| `extera_utils` | 3 |
| `extera_utils.audit_gate` | 4 |
| `extera_utils.capability_scan` | 20 |
| `extera_utils.class_aliases` | 11 |
| `extera_utils.classes` | 35 |
| `extera_utils.hook_profile` | 11 |
| `extera_utils.metadata_parser` | 16 |
| `extera_utils.plugin_loader` | 42 |
| `extera_utils.text_formatting` | 30 |
| `extera_utils.thread_state` | 4 |
| `file_utils` | 43 |
| `markdown_utils` | 7 |
| `pip_controller` | 20 |
| `plugin_settings` | 8 |
| **Всего** | **267** |

Типы inventory: **97 functions, 17 methods, 15 classes, 73 constants/aliases,
65 imports**. Все **114 function/method signatures** сверены с AST:
имена/виды параметров, optional/defaults, annotations и return annotations.
Декларации типов, enum members, dataclass fields и package exports имеют
собственные строки, а не заменены одной строкой на модуль.

| Disposition | Сопоставлено |
|---|---:|
| `metadata` | 163 |
| `pure-sdk` | 57 |
| `native-adapter` | 21 |
| `plugin-contract` | 15 |
| `partial` | 11 |
| `unsupported` | 0 |

## Фактические границы реализации

- **Настройки.** Поздний `python/exteraless_runtime/_settings.py:9-102`
  заменяет ранние placeholders из `_platform.py`. Module getters читают lazy
  mirror через `Runtime.getSettings() -> opaque JSON String`; setter вызывает
  `updateSettings(json:String)`, remove — `removeSetting(key:String) -> Bool`.
  Терминальные методы `PluginServiceStorage`: `settingsJSON`, `updateSettings`,
  `removeSetting`, включая `readSettings` и `Data.write(options: .atomic)`
  (`swift/PluginHost/Sources/PluginHost/PluginServiceStorage.swift:96-238`).
  Optional refresh доходит до `PluginUISettingsRefresh.invalidate(pluginId:)`
  через `uiRefreshSettings()`; это source route, не визуальная приёмка.
- **Файлы.** `getFilesDir()/getCacheDir()/getPluginsDir()` доходят до
  `BridgeServices.callRuntime` и конкретных `PluginServiceStorage` directories.
  Media getters сохраняют документированный fallback в `images`, `videos`,
  `audios`, `documents` внутри owner files directory: зарегистрированный `FileLoader`
  (`_controllers.py:108-116,192-197`) не имеет `getDirectory/MEDIA_DIR_*`.
  Для обычного Python I/O указаны точные `open` modes, `os.remove`,
  `os.makedirs`, `os.walk/listdir` и установленные audit/permission boundaries.
  Внешняя реализация CPython `_io/posix` не выдается за прочитанный Swift provider.
- **Файловый перехват.** `fileRegister(model,callbackHandle) -> {id:String}`
  проходит `_registrations.py:102-122` →
  `PluginNativeServicesBridgeExtension.swift:160-180` →
  `NativeServiceInterceptions.registerFile` → реальный
  `OpenChatMessage.swift:283-287`. Путь файла предоставляет
  `NativeServiceMedia.swift:104-108` через `MediaBox.resourceData` без fetch.
  `fileRemove(id)` использует stored cleanup identity. Custom icons отсутствуют,
  `activity/parent_fragment` равны null; whitelist/blacklist проверяют
  **подстроки имени файла**, как и original Java `passesFilters:258-277`.
- **Форматирование.** `parse_raw/parse_markdown/parse_html` — реальные Python
  parser bodies с UTF-16 offsets. `to_tlrpc_object/parse_text` в configured iOS
  материализуют **Python TLObject DTO** через `_tl.Schema` и десять точных
  TLRPC aliases; все десять definitions/fields проверены в `tl-schema.json`.
  Создание DTO не является native send/render. Реальный Markdown body использует
  `__` для underline, `_` для italic и не раскрывает вложенную inline-разметку.
- **Java DSL.** `Base`, `J/ClassHelper`, `jfield`, decorators и class namespace
  имеют конкретные Python constructor/descriptor/metadata contracts. Генерация
  Java-класса отмечена отдельно как `partial`. Поздний override
  `_java_types.py:673-683` действительно реализует `JIgnoreResult`; исходная
  установка флага без этого override не использована как итоговый verdict.
- **Loader/audit.** Hook/settings callbacks остаются plugin override contracts;
  iOS entrypoints добавляют owner/account scope и registration matching.
  Permission queries доходят до `Runtime.hasPermission(permission)` /
  `isUnsafeMode()` и `PermissionsModel`. Engine-only import restrictions
  отражены отдельно от наличия символов в inventory.
- **Зависимости.** После установки `_platform.py:238-249` используется
  `ProvidedDependencies`, проверяющий версии, markers, extras и transitive
  requirements по app vendor metadata. Метаданные пакета не равны успешному
  iOS import, а runtime download/install отсутствуют.

Общий transport прочитан до тела:
`Platform.call` (`_platform.py:89`) → `py_xt_call_host` /
`native_dispatch_request` (`_exteraless_bridge.c:3252,2005`) →
`NativeBridgeBinding.nativeBridgeDispatch` (`NativeBridgeBinding.swift:73`) →
`BridgeServices.dispatchJSON` (`BridgeServices.swift:200`). В индивидуальных
native rows дополнительно названы точные операции и предметные providers;
сам transport не принят за доказательство реализации операции.

## 11 явных partial ID

| Exact original ID | Точный пробел / сужение |
|---|---|
| `sdk.dev_server.dispatch` | Нет manager facade providers `getPluginsSnapshot`, `setPluginEnabled`, `reloadPlugin`, `installPlugin(File,InstallCallback)`, `uninstallPlugin`; debugpy listener subprocess/stop API также не предоставлены. |
| `sdk.dev_server.start` | `daemon=True` несовместим с configured `allowDaemonThreads=false`; требуется совместимый listener lifecycle. |
| `sdk.extera_utils.classes.Base.java_class` | Нет `generateProxyClass(owner,spec_json)` и `getProxyClass(key)->java.lang.Class`. |
| `sdk.extera_utils.classes.Base.new_instance` | Нет `generateProxyClass` и `newProxyInstance(owner,key,ctorSig,Object[],peer)` с pre-super dispatch. |
| `sdk.extera_utils.classes.Base.new_java_instance` | Делегирует тому же отсутствующему native constructor, затем выбирает `.java`. |
| `sdk.extera_utils.classes.super` | Нет `invokeSuper(classKey,rawProxy,pyKey,Object[])->Any`. |
| `sdk.extera_utils.plugin_loader.load_plugin` | iOS entry принимает только `.py/.plugin`, provided dependencies и одного owner; `.elyx/.eaf`, runtime pip и cross-owner neighbour load не покрыты. |
| `sdk.extera_utils.plugin_loader.set_unsafe_mode` | Меняет только старый SDK cache; effective native unsafeMode читает другой provider, setter operation не экспортируется. |
| `sdk.extera_utils.plugin_loader.start_dev_server` | Тот же несовместимый daemon listener; once-флаг выставляется до попытки и исключает повтор. |
| `sdk.extera_utils.thread_state.pin` | Нет owner-interpreter-aware foreign-thread pin/release adapter; исходный путь использует `PyGILState_Ensure` и `.so` fallback. |
| `sdk.pip_controller.ensure_requirements` | Есть только проверка approved provided distributions, нет PyPI/wheel installation; например, отсутствуют lxml/Pillow/PySocks. |

## Конкретный P2

**`utilities-P2-001`: dev-server start и native daemon policy расходятся.**
`python/sdk/dev_server.py:338-340` создает `Thread(..., daemon=True)` после
завершения bind-error `try/except`. Default policy задаёт
`allowDaemonThreads=false` в
`swift/PluginHost/Sources/PluginHost/SubinterpreterManager.swift:33`, передаётся
через `CPythonXCFrameworkEngine.swift:43` в
`python/runtime/engine.c:270`.

Контрпример по исходникам: при доступном loopback bind первая engine-вызванная
попытка `start_dev_server()` доходит до запрещённого daemon thread; отказ не
превращается в `False` внутри `dev_server.start`. Внешний wrapper ловит его уже
после `_dev_server_started=True` (`plugin_loader.py:3643-3648`), поэтому вторая
попытка сразу возвращается. Этот путь **не исполнялся**; finding не является
native failure receipt.

## Проверки и hashes

- Exact set equality: **267/267**, duplicate/missing/unknown = **0/0/0**.
- Original path/line/symbol и AST signatures согласованы с inventory.
- Все route/evidence paths существуют, указанные строки попадают в файлы,
  **76/76** raw SHA-256 совпадают; selected Android/SDK pairs — **15/15**.
- Все три promotion flags у всех 267 строк остаются false.

| Объект | SHA-256 |
|---|---|
| `utilities.json` (285821 bytes) | `2ac21bccf6e5ca7046bd7a6060c15b1bcebcc44fe4403dd1d39a75af018f16a0` |
| Exact ID set: sorted UTF-8, LF + final LF | `c0e431103998b21fa2211bacf28a94ab1efe1542bdb692e9e6e21278fe261743` |
| `source_sha256`: sorted-key compact JSON, UTF-8 | `330936914bb106e4a4652dace4338e77d1559a9fd859f9953b6247b322a8d4aa` |
| `docs/parity/sdk-surface.json` | `ce7b067fdcffc440ba3640ac194c2eef8a68192a80410cbcb3a593e0d9cf64d8` |

[`runtime-native-acceptance.md`](../runtime-native-acceptance.md), строки 90–120,
сохраняет независимый GREEN всех трёх macOS SDK child processes для
`136c946f87194221342a83b2b06743fe4cc3fc7c`, run `43738810843`.
Его CPython/Foundation component scope исключает реальный Telegram network
и UIKit; этот receipt не превращён в 267 индивидуальных execution claims.
