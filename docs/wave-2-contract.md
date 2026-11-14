# Полная реализационная волна и последующее независимое ревью

База: `68bb1adf`. Пользователь прямо запросил масштабное делегирование до
закрытия плана с последующей сверкой независимыми reviewers с Android-оригиналом.
Runtime/SDK gate `43633853229` полностью пройден на `38d335fa`; full IPA
`43635233046` уже собирается, watcher принадлежит coordinator. Не опрашивать его.

## Общие правила

- Реализация и доказательства: живой callsite, реальные значения/эффекты,
  meaningful bounded tests. Пустой handler или сохранённая неиспользуемая настройка
  не считается переносом функциональной настройки.
- Оригинал: `third_party/exteraless-android/TMessagesProj/src/main/java` **и**
  `src/main/kotlin`. ExteraConfig.java — частично compatibility-storage shim;
  первоначальные «159 тумблеров» нельзя считать полным/точным списком функций.
- SDK сохраняется в `python/sdk`; адаптация снаружи. CPython engine/ABI уже
  проверен, не переписывать его. Swift/C — для native, Python — для совместимости.
- Нет commit/push/dispatch от агентов. Только patch для исходников. CI запускает
  coordinator после стыковки. Не исполнять внешний корпус и не создавать
  неограниченные тесты/процессы. Собственные fixtures — 20–30 секунд максимум.
- В `telegram-ios` читать AGENTS.md/CLAUDE.md. UIKit/анимации требуют кадров;
  без XcodeBuildMCP/устройства не заявлять visual pass.
- Различать native/stock-equivalent/adapted/compat-storage/platform-prerequisite/
  pending. Непроверенную или отсутствующую функцию не записывать как completed.

## Владельцы

| Роль | Основные файлы |
|---|---|
| parity | tools/compat/feature_inventory.py, docs/parity/**, inventory tests |
| core-settings | swift/ExteralessCore core store/models/Package; ExteralessSettingsController/Entry |
| appearance | Core AppearanceDefinitions/Policy; ExteralessClient/Appearance/**, appearance/icon resources |
| chat | Core ChatDefinitions/Policy; ExteralessClient/Chats/**; уникальные chat/player/feed sites |
| privacy | Core PrivacyDefinitions/Policy; ExteralessClient/Privacy/**; unique read/presence/notification sites |
| AI/speech | Core AI definitions/client/models; ExteralessClient/AI/** and Speech/** |
| tools/backup | Core Tools definitions/backup/updater; ExteralessClient/Tools/** |
| SDK | python/exteraless_runtime/**, virtualjava registry support, SDK adapter tests |
| native UI | ExteralessClient/PluginUI/**, PluginUIBridgeExtension.swift, bounded UI DTO tests |
| TL/services | Core-facing ExteralessTLCodec/Service files, generated TL metadata, codec tests |
| dependencies/build | dependency locks/vendor builders/native dependency tooling; all BUILD/MODULE/workflows |
| coordinator | PluginHost common APIs/BridgeServices; AppDelegate; shared insertion sites; integration/handoff |

**Общие места принадлежат coordinator:** AppDelegate.swift, Network.swift,
PeerInfoSettingsItems.swift, ChatController.swift, ChatControllerInteraction.swift,
ChatControllerContextMenu*.swift, ExteralessPluginRuntime.swift, BridgeServices.swift,
PluginHost.swift. Для них возвращать точные insertion hunks/функции и необходимые
imports в своём handoff, coordinator применит после объединения. Остальные
существующие файлы менять только внутри своей тематической области; пересечения
отмечать сразу. Все BUILD/MODULE правит build-agent по итогам списка dependencies.

Каждая роль оставляет `docs/wave-2/<role>.md`: original symbols/defaults,
изменённые файлы и callsites, проверки, ограничения и незакрытые пункты.
Основной parity JSON редактирует только parity-agent/coordinator.

## Foundation модуль `ExteralessCore`

Чистый Swift 6, без Telegram/UIKit/CPython dependencies; iOS 15+, macOS 12+.
Модуль доступен TelegramCore и TelegramUI через `//third-party/exteraless:ExteralessCore`.
Core-settings agent реализует следующий стабильный API:

```swift
public enum ClientSettingValue: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([ClientSettingValue]), object([String: ClientSettingValue])
}
public struct ClientSettingOption: Sendable {
    public init(value: ClientSettingValue, title: String)
}
public struct ClientSettingDefinition: Sendable {
    public init(key: String, title: String, section: String,
                defaultValue: ClientSettingValue,
                options: [ClientSettingOption] = [],
                minimum: Double? = nil, maximum: Double? = nil,
                step: Double? = nil, isSecret: Bool = false,
                explanation: String? = nil, androidSymbols: [String] = [])
}
public final class ClientSettings: @unchecked Sendable {
    public static let shared: ClientSettings
    public func configure(storageURL: URL) throws
    public func register(_ definitions: [ClientSettingDefinition]) throws
    public func bool(_ key: String, default fallback: Bool = false) -> Bool
    public func integer(_ key: String, default fallback: Int = 0) -> Int
    public func double(_ key: String, default fallback: Double = 0) -> Double
    public func string(_ key: String, default fallback: String = "") -> String
    public func value(_ key: String) -> ClientSettingValue?
    public func set(_ value: ClientSettingValue, for key: String) throws
    public func snapshot() -> [String: ClientSettingValue]
    public func definitions() -> [ClientSettingDefinition]
    public func reload() throws
    public func observe(_ callback: @escaping @Sendable (Set<String>) -> Void) -> ClientSettingsObservation
}
// observation.cancel(), deinit also removes observation
```

Domain definitions/policies (new files in ExteralessCore, owned by each domain):
`AppearanceFeatures.definitions`, `ChatFeatures.definitions`,
`PrivacyFeatures.definitions`, `AIFeatures.definitions`, `ToolsFeatures.definitions`.
Ключи `appearance.<originalField>`, `chats.<originalField>`, `privacy.<originalField>`,
`ai.<field>`, `tools.<field>`; предпочтительно имя исходного field, не shim getter.
Default совпадает с оригиналом либо явно документирован как iOS adaptation.
В UI регистрируются только определения с подключённым поведением.

Domain iOS composition: `ExteralessAppearanceIntegration`, `ExteralessChatIntegration`,
`ExteralessPrivacyIntegration`, `ExteralessAIIntegration`, `ExteralessToolsIntegration`
с `init()`, `update(context: AccountContext)` на main и `clearContext()`.
Coordinator удерживает их в application composition root. При необходимости
другой API сообщить явно, не придумывать существующий context singleton.

Settings UI-agent предоставляет TelegramUI-level registry для нестандартных экранов:
`ExteralessSettingsAction(id:title:section:action:)`, где action —
`@MainActor (AccountContext, ViewController) -> Void`;
`ExteralessSettingsUI.registerActions([ExteralessSettingsAction])`.
Domain integrations регистрируют свои actions с уникальными id; basic toggles/
selectors/input/sliders строятся из ClientSettingDefinition. Общая factory:
`exteralessSettingsController(context: AccountContext) -> ViewController`.

Secret definitions хранятся через Keychain на Apple, без секретов в JSON/logs/export.
При отсутствии Apple Security tests inject secret store; нельзя выдавать memory
fallback за persistent secure storage. Main/extension shared path coordinator
возьмёт из существующего app-group/account base path, не нового entitlement.

## Дополнительные plugin services

Coordinator добавит расширяемую границу в PluginHost:

```swift
public protocol PluginBridgeExtension: AnyObject, Sendable {
    // nil = this provider does not own this operation; result is full
    // {ok:true,value:...}/{ok:false,error:{kind,message}} JSON envelope.
    func dispatch(requestJSON: String, pluginId: String) throws -> String?
    func releaseInstances(pluginId: String)
}
// BridgeServices.extensionProvider: PluginBridgeExtension?
```

Request envelope остаётся `op/fqcn/member/args/kwargs/instance/value`; pluginId
приходит из C state. Extra provider вызывается до builtin для своих операций,
unknown возвращает nil. Composite provider пишет coordinator. Каждый provider
валидирует операцию/аргументы и permissions; не эмулировать Unknown как success.

SDK новые native calls через `exteraless.ios.Runtime`:

- UI: `uiPresent(kind, model, callbacks) -> {id: String}`, `uiUpdate(id, model)`,
  `uiDismiss(id)`, `uiState(id)`; kind = alert/bulletin/bottomSheet/menu и т.п.
- TL/services: `tlRequest(requestModel, callback) -> {requestId: String}`,
  `tlCancel(requestId)`, `getPeer(peerModel, callback)` и `sendMedia(model, callback)`.
- Settings: `getClientSetting(key, default)`, `setClientSetting(key,value)`.

Builtin per-plugin bulk storage уже реализован coordinator:
`Runtime.getSettings() -> JSON object as STRING`,
`setSettings(json_string)` (replace), `updateSettings(json_string)` (merge),
`clearSettings()`; mutations return None. JSON text важен: ключи пользовательских
настроек `__handle__`/`__bytes__` не должны превращаться в transport tags.
Размер 1 MiB, keys validated, owner из native context, atomic full write.

Callbacks — положительные C handles, **не Swift/Python pointers**. Coordinator
предоставит `PluginCallbackDispatcher` с sync token capture и owner-queue invoke;
providers могут принимать closures init-параметрами:
`captureOwner(pluginId) -> PluginHost.CallbackOwner?`,
`callback(owner, handle, method, argsJSON)`, `release(owner, handles)`.
Реализован `PluginHost.PluginCallbackDispatcher`: init(host:log:),
captureOwner, hasPermission, callback (Bool admission result), release.
Callbacks и release одного owner идут FIFO; разные owner могут исполняться
параллельно. Provider должен учитывать false при перегрузке/retired owner.
Не запускать Python на main или через PyGILState_Ensure. Native provider хранит
owner при принятии операции; после reload старый owner не входит в новый Python.
UI SDK создаёт отдельные wrapper-callables на каждый presentation lease; reuse
одного C handle разными UI leases без refcount запрещён. Dismiss освобождает lease
на owner worker; unload закрывает native presentations/requests без reverse calls.

`uiPresent`/native widgets реализованы Swift/UIKit; Python builders/DTO нужны для
совместимости Android API. TL моделям допускается pure-Python data representation,
но сериализация/отправка/Telegram engine — native Swift. DTO schema фиксирует
TL/services-agent в docs/wave-2/tl-schema.md, SDK-agent согласует его до dispatch.
Для native-backed Python class aliases добавить явный class registry virtualjava;
сохранять фактический C BridgeBackend, не заменять его MockBackend/Universal.

## Результат и ревью

После implementer-волны coordinator собирает связный граф, целевые tests/native
probes, проверяет runtime/IPA. Затем **новые независимые reviewers** проверяют:
1) client parity и отсутствующие callsites/фиктивные настройки;
2) SDK/API parity, lifecycle/GIL/ownership;
3) UIKit/main-thread/layout и integration;
4) media/network/privacy/APNs semantics;
5) packaging/CI/resources/secret handling.

Ревьюеры сначала read-only, findings с file:line и воспроизводимым сценарием;
исправления принимаются coordinator и implementers отдельной подволной. Завершение
пункта требует конкретного evidence. External prerequisites (подпись/физический
iPhone/APNs credentials/визуальные кадры) остаются явно обозначенными до проверки.
