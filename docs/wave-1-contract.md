# Волна 1 — интеграционные контракты

База: `b0324c44`. Runtime проверен в 43615992774 (CPython 3.12.16 / iOS,
Swift adapter / macOS). Цель волны: runtime в клиенте, настоящий загрузчик,
нативные callbacks/services, менеджер плагинов и первые event hooks.

## Владение файлами

1. Build-agent: Bazel/MODULE/BUILD, runtime staging, ios-build workflow.
2. Bridge-agent: C transport/public C headers и новый NativeBridgeBinding.swift.
3. Loader-agent: `python/exteraless_runtime/`, связанные маленькие tests/fixtures.
4. Services-agent: BridgeServices.swift, TelegramPluginServices.swift, сервисные tests.
5. UI-agent: PluginManagerController.swift, PluginSettingsController.swift,
   PeerInfoSettingsItems.swift и новый AccountContext/ExteralessPluginEntry.swift.
6. Hooks-agent: отдельный lightweight PluginHooks module + TelegramCore hook sites.
7. Coordinator: PluginHost.swift, PythonRuntime.swift, lifecycle/bootstrap приложения,
   новый ExteralessPluginRuntime.swift, интеграционные проверки и handoff.

Агенты не коммитят и не dispatch-ят CI. Все правки через patch. Не запускать
корпус плагинов или локальные тяжёлые/неограниченные симуляции. Полная IPA —
после объединения волны. Не заявлять проверку UIKit без кадров/записи.

## Python entry point — `exteraless_runtime`

Вызовы на выделенном worker одного плагина:

- `configure(plugin_id, plugins_dir, settings_dir) -> None`
- `metadata_json(path) -> str` (AST, без исполнения файла)
- `load_json(path) -> str` — JSON `{metadata: {...}, handles: {...}, has_settings: bool}`;
  ключи handles: app_event, pre_request, post_request, update, updates, send_message.
- `unload() -> None`
- `dispatch_json(hook, payload_json) -> str` — hook совпадает с SDK protocolName.
  Ответ send_message: `{strategy: "DEFAULT|CANCEL|MODIFY|MODIFY_FINAL", params: ...}`.
  create_settings: JSON-массив элементов SDK ui.settings.
- `settings_json() -> str`
- `setting_changed_json(key, value_json) -> str`
- `setting_click_json(callback_id) -> str`
- `invoke_handle_json(handle, method, args_json) -> str`

SDK сохраняет исходники: iOS-адаптация живёт снаружи. Не устанавливать permissive
mock автоматически. Неподдержанные API дают явную ошибку. Тесты — маленькие
собственные BasePlugin fixtures, без сетевой отправки и внешнего корпуса.

## Native transport

`_exteraless_bridge.xt_set_plugin_id(str)` связывает ID с состоянием
интерпретатора. `xt_call_host(request: dict) -> Any` вызывает тот же native
dispatcher, что и семь операций BridgeBackend. pluginId определяется native
state, а не принимается из недоверенного request.

Swift factory: `NativeBridgeBinding(services: BridgeServices)`, `install() throws`.
Binding удерживается координатором до конца процесса/безопасного shutdown.
Dispatcher использует существующий request envelope BridgeServices и превращает
`{ok,value}` / `{ok:false,error}` в значение / Python-ошибку по контракту C-моста.

NativeBridgeBinding компилируется только при наличии CExteralessPythonBridge.
Новые Python callbacks выполняются через очередь владельца по pluginId/handle;
не вызывать PyGILState_Ensure из чужого потока.

## Services / application

`TelegramPluginServices` реализует PluginMessagesService, PluginSettingsService,
PluginUIService и новый optional PluginPlatformService. `update(context: AccountContext)`
публикует snapshot аккаунта/темы; UIKit эффекты отправляются в main queue.
Расширенные операции попадают в `PluginPlatformService` через объект ui в
BridgeServices. Нативные объекты используют отрицательные handles и владельца.

Системный fqcn `exteraless.ios.Runtime` предоставляет getSetting/setSetting,
removeSetting, getFilesDir/getPluginsDir, log и getVersion. Аргументы — список,
pluginId берётся из native context. Settings persist на Swift-стороне.

В TelegramUI координатор создаёт `ExteralessPluginRuntime.shared`:
- `host: PluginHost?` — готовый хост;
- `start()` / `update(context:)`;
- UI использует `host.pluginList`, install/remove/enable/settings API после готовности.
Согласованные дополнительные UI методы координатор добавит при стыковке.

UI factory `exteralessPluginManagerController(context: AccountContext) -> ViewController`
регистрируется через `ExteralessPluginEntry` в AccountContext (UI-agent), чтобы
PeerInfoScreen не зависел циклически от TelegramUI. Менеджер принимает host через
параметр фабрики или ExteralessPluginRuntime в TelegramUI.

## Lightweight hooks

TelegramCore не получает зависимость на CPython/TelegramUI. Hooks-agent создаёт
`swift/PluginHooks` с чистым Foundation API и инъекцией обработчиков. Нулевой
гейт до сериализации. Coordinator связывает этот API с PluginHost.events.
Account identity передаётся как Int64 record ID, mapping в Int32 index — у host.
Сигналы MTProto/Postbox не блокируются и обязательно доставляют terminal event.

## Build / resource layout

Основной bundle: Frameworks/Python.framework + native extension frameworks,
python-stdlib/lib/python3.12, python/virtualjava, python/sdk,
python/exteraless_runtime, python/compat-manifest.json.
Вторая подволна добавляет `python/vendor` с pinned pure-Python wheels
(dependency-lock.json / vendor_dependencies.py); этот путь уже включён в
PythonRuntimeConfiguration. Provider build добавит каталог при стыковке.
CPython и сервисы инициализируются только в основном приложении. Сохранить все
шесть extensions; проверить их rpaths к shared frameworks. Инициализация при
загрузке библиотеки запрещена — только явный вызов из app lifecycle.
