# PluginHost — этап 4: нативная сторона плагин-системы (Swift)

Swift-модуль плагин-хоста для iOS-порта exteraless. Управляет CPython
(суб-интерпретаторы PEP 684 — по одному на плагин), доставкой событий,
изоляцией зависаний, разрешениями и мостом `_exteraless_bridge`.
Семантика портирована с эталона Android
(`third_party/exteraless-android/.../app/exteraless/plugins/`), горячие пути
написаны заново на Swift под правила telegram-ios.

```
swift/PluginHost/
├── Package.swift                     # SPM-упаковка (для Linux-CI/локальной разработки)
├── Sources/CPluginHostShims/         # C11-атомики (lock-free счётчики, без внешних зависимостей)
├── Sources/PluginHost/
│   ├── PluginHost.swift              # фасад: старт/стоп, install/uninstall/enable, делегат UI
│   ├── PythonRuntime.swift           # CPython: PyConfig-инициализация, движок-контракт CPythonEngine
│   ├── SubinterpreterManager.swift   # PEP 684: интерпретатор на плагин, политика abandon, лимит
│   ├── BridgeServices.swift          # _exteraless_bridge: реестр, JSON v1, сервисы-заглушки
│   ├── ExtensionPoints.swift         # типизированная шина + atomic-гейт «есть ли подписчики»
│   ├── PluginEventQueue.swift        # ОДНА очередь: коалесценг, приоритеты, дроп, таймауты
│   ├── PluginWatchdog.swift          # notResponding, RSS-лимит, маркер .watchdog, страйки
│   ├── PluginModel.swift             # Plugin 1:1 с Plugin.java, PermissionsModel, PluginStore
│   └── SecurityGates.swift           # reflection-политика (java.chaquopy), гейт разрешений
└── Tests/PluginHostTests/            # тесты без CPython (fake-движок) — Linux-CI
```

## Статус

Код написан на Windows-машине **без компиляции** (Swift здесь не собирается —
по плану сборка на macOS/CI). Синтаксис/сендабельность выверены вручную;
рискованные места помечены `TODO(мак)` и `TODO(этап 5)`. Все обращения к
CPython идут через протокол `CPythonEngine` — модуль собирается и тестируется
**вообще без Python** (это же даёт Linux-CI «на каждый пуш» по принципу 5
архитектуры).

## Разработка и тесты (бесплатно, без macOS)

```bash
cd swift/PluginHost
swift test          # Linux/macOS: гейт, коалесценг, приоритеты, сторож, модель
swift build         # проверка типов Swift 6
```

`UnboundCPythonEngine` — движок-заглушка по умолчанию (все операции честно
бросают `pythonNotLinked`). В тестах — `FakeEngine` (см. Tests).

## Как это врезается в telegram-ios (Bazel)

### 1. Таргеты

telegram-ios собирается Bazel (MODULE.bazel + rules_apple/rules_swift).
Два способа:

**A. Bzlmod local override (рекомендую, без копирования):** добавить в
`telegram-ios/MODULE.bazel`:

```python
bazel_dep(name = "pluginhost", version = "0.4.0")
local_path_override(
    module_name = "pluginhost",
    path = "../swift/PluginHost",     # путь от корня telegram-ios к репо exteraless-ios
)
```

и положить в `swift/PluginHost/MODULE.bazel` + `BUILD.bazel`:

```python
# swift/PluginHost/BUILD.bazel
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

package(default_visibility = ["//visibility:public"])

cc_library(
    name = "CPluginHostShims",
    srcs = ["Sources/CPluginHostShims/ph_atomic.c"],
    hdrs = ["Sources/CPluginHostShims/include/ph_atomic.h"],
    includes = ["Sources/CPluginHostShims/include"],
)

swift_library(
    name = "PluginHost",
    srcs = glob(["Sources/PluginHost/*.swift"]),
    deps = [":CPluginHostShims"],
    visibility = ["//visibility:public"],
)
```

**B. Вендоринг:** скопировать каталог в `telegram-ios/third-party/pluginhost/`
и подключить те же таргеты оттуда (как сделано для прочих third-party).
TODO(мак): выбрать вариант по тому, как telegram-ios в 13.1.1 подключает
локальные модули (у него есть и WORKSPACE, и MODULE.bazel — сверить).

### 2. CPython (этап 1: Python.xcframework) и движок

Python.xcframework (BeeWare+патч, CPython 3.12, собран этапом 1) кладём в
`telegram-ios/third-party/python/`:

```python
# third-party/python/BUILD.bazel
apple_static_framework_import(
    name = "PythonFramework",
    framework_imports = glob(["Python.xcframework/ios-arm64/Python.framework/**"]),
)
```

Движок — ОДИН файл на macOS (этап 5, ~150 строк), реализующий `CPythonEngine`:

```swift
// CPythonXCFrameworkEngine.swift
import Python   // modulemap на Python.xcframework/Headers/Python.h
import PluginHost

public struct CPythonXCFrameworkEngine: CPythonEngine { ... }
```

(modulemap: `module Python { header "Python.h" export * }` + `cc_import`/`objc_library`
к `libpython3.12.a` из фреймворка; TODO(мак): сверить с артефактом этапа 1.)
Все настоящие C-вызовы перечислены в doc-комментариях `CPythonEngine`
(PyConfig_InitPythonConfig/Py_InitializeFromConfig, Py_NewInterpreterFromConfig
с PyInterpreterConfig(gil: OWN_GIL), PyRun_String/PyObject_Repr, Py_EndInterpreter,
Py_FinalizeEx) — реализация механическая.

### 3. Ресурсы Python и мост этапа 2

В app-таргет добавить resource-bundle `PluginHostResources` со структурой
(кладут её сборочные скрипты этапов 1–2):

```
PluginHostResources.bundle/
├── Python.framework/…               # этап 1
├── python-stdlib/lib/python3.12/…   # stdlib (без test-suite, ~10 МБ)
├── python/virtualjava/…             # копия python/virtualjava из этого репо
└── python/sdk/…                     # копия python/sdk из этого репо
```

`PythonRuntimeConfiguration.standard(bundle:)` читает ровно эту структуру.
Плагины живут в `Application Support/exteraless/plugins` (туда же пишет стор
`plugins.json`/`grants.json`/`.watchdog`).

C-мост этапа 2 (`_exteraless_bridge`) получает Swift-колбэк так:

```swift
let host = try PluginHost(
    engine: CPythonXCFrameworkEngine(),
    configuration: .standard(bundle: pluginResourcesBundle))
try await host.start()
// C-слой зовёт host.bridge.dispatchJSON(json, pluginId:) синхронно
// с потока интерпретатора — это и есть Backend-протокол (python/virtualjava/backend.py).
```

### 4. Где физически ставить extension points

Приоритеты — от частот манифеста `build/compat/report.md`
(create_settings: 14 → send_message: 9 → on_send_message: 8 → on_updates: 2).

| приоритет | хук | файл telegram-ios 13.1.1 | что вставить |
|---|---|---|---|
| 1 | `create_settings` (14 плагинов) | `submodules/SettingsUI` — новый экран `PluginSettingsScreen` (аналог PluginSettingsActivity) | экран вызывает `host.events.requestCreateSettings(pluginId:)` → JSON-массив (PluginsConstants.Settings: type/key/text/subtext/…) и рисует UItem-подобные строки; пункт-список плагинов — в главный список настроек |
| 2 | `add_on_send_message_hook` (9) | `submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift:730` `enqueueMessages(account:peerId:messages:)` | перед построением `EnqueueMessage` — `host.events.preSendMessage(SendMessagePayload(account:…, paramsJSON:…))`; стратегия `CANCEL` — не ставить, `MODIFY` — подменить параметры; TODO(этап 5): словарь соответствий params |
| 3 | `on_updates_hook` (2) + `on_update_hook` | `submodules/TelegramCore/Sources/State/AccountStateManager.swift` (точка входа апдейтов; см. `UpdateMessageService.swift`, `UpdateGroup.swift`) | `host.events.emitUpdate(name:account:updateJSON:)` / `emitUpdates(...)` — очередь сама коалесцирует N апдейтов в один вход |
| 4 | `pre/post_request_hook` | `submodules/TelegramCore/Sources/Network/Network.swift` (конвейер запросов) | `emitPreRequest` до отправки, `emitPostRequest` после ответа (fire-and-forget, не на критическом пути) |
| 5 | `on_app_event` | AppDelegate приложения (didFinishLaunching / willResignActive и т.п.) | `host.events.emitAppEvent("app_start" / "app_pause" / …)` |

### 5. Нулевые накладные без плагинов

Каждая точка входа обязана начинаться с atomic-гейта (один lock-free load,
никаких локов/аллокаций/акторов):

```swift
// в точке входа telegram-ios:
guard host.events.subscribers.hasSubscribers(.updates) else { return }
host.events.emitUpdate(name: updateName, account: account, updateJSON: json)
```

Счётчики пересчитываются при загрузке/выгрузке/зависании плагина
(`Plugin.handles*` — 1:1 с Plugin.java; `.createSettings` → `hasSettings`).

## Политика зависаний (кратко)

- вызов не вернулся за таймаут (5 c, как FREEZE_TIMEOUT_SECONDS) →
  интерпретатор **бросается** (abandon): поток и память утекают до конца
  процесса — осознанно, безопасного убийства потока CPython нет;
  плагин помечается `notResponding`, в гейт не входит;
- два страйка маркера `plugins/.watchdog` при смертях процесса → плагин
  выключается на старте (`PluginWatchdog.recoverAfterCrash`);
- RSS-лимит на плагин — по приближённому footprint (TODO(мак): per-interpreter
  RSS в CPython 3.12 нет, меряем дельтой RSS процесса);
- если есть брошенные интерпретаторы — при остановке движка НЕ вызываем
  `Py_FinalizeEx` (зависнет на вечных GIL).

## Что осталось этапу 5 (macOS)

1. `CPythonXCFrameworkEngine` (см. выше) + проверка всех `TODO(мак)` в
   doc-комментариях `CPythonEngine`.
2. C-мост этапа 2: модуль `_exteraless_bridge` (Backend-протокол) +
   JSON-обёртка `host.bridge.dispatchJSON` + регистрация инстанс-таблицы.
3. Реальные Swift-сервисы моста (`PluginMessagesService`/`PluginSettingsService`/
   `PluginUIService`) по поверхности манифеста — сейчас заглушки
   (Theme#getColor, AndroidUtilities#dp, UserConfig#selectedAccount, getInstance...).
4. Диспатч загрузки плагина через `python/sdk/extera_utils/plugin_loader.py`,
   фиксация контракта `__exteraless_dispatch__` (сейчас стаб в
   `PluginScriptBuilder`), снятие handles*-флагов по факту регистрации хуков.
5. Экран настроек плагина в SettingsUI + экран списка/установки (PermissionsModel
   для диалога согласия).

## Эталонная семантика (что портировано откуда)

| файл модуля | эталон |
|---|---|
| PluginModel.swift | `Plugin.java` (поля 1:1), `PluginPermissions.java` (ключи/ALL/REQUESTABLE/describe/sanitize/effective/compat), `PluginGrantStore.java`, `PluginsConstants.java` (SDK_VERSION/SETTINGS-константы здесь не нужны — они в Python SDK) |
| PluginWatchdog.swift | `PluginsWatchdog.java`: FREEZE_TIMEOUT=5c, маркер `plugins/.watchdog` (write-on-change, без fsync, отложенная очистка 2 с), CRASH_STRIKES=2, recoverAfterCrash, noteHealthy/onAppBackgrounded |
| SecurityGates.swift | контракт `java.chaquopy` из `python/virtualjava/finder.py` (`set_reflection_policy`/`seal`/`set_call_fallback`), принцип «разрешающий прокси, честный отказ» (архитектура, принцип 3) |
| BridgeServices.swift | `python/virtualjava/backend.py` (construct/call/call_instance/get/set/member_kind/class_exists, JavaMemberError) |
| ExtensionPoints.swift | имена хуков `python/sdk/base_plugin.py`; приоритеты — `build/compat/report.md` |
| PluginHost.swift | модель жизненного цикла `PluginsController.java` (rescan/load/unload/setEnabled/согласия; safe mode/developer mode) |

## Границы честности

- Мост v1 — JSON-строки: медленнее бинарного маршаллинга, но просто и
  отлаживаемо; манифест показывает, что плагины почти не гоняют данные через
  мост (топ — getColor/dp/settings). Оптимизация — этап 5+.
- Враждебный плагин в том же процессе обойдёт гейты (как в эталоне); модель
  разрешений делает намерения видимыми и ограничивает случайный вред.
- App Store закрыт (2.5.2) — сидлоад, сборка только на macOS.
