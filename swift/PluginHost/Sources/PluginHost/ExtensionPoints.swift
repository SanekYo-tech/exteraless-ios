import Foundation
import CPluginHostShims

/// Типизированная шина extension points и счётчик подписчиков хот-пата.
///
/// Ключевое свойство (принцип 1 архитектуры): ВЫКЛЮЧЕННЫЕ плагины = ноль
/// накладных. Каждая точка входа telegram-ios перед постановкой события
/// проверяет `SubscriberGate.hasSubscribers(_:)` — один lock-free atomic-load
/// (единицы наносекунд). Проверка не аллоцирует, не берёт локи, не входит в
/// актор. Все события уходят в интерпретаторы ТОЛЬКО через `PluginEventQueue`.
///
/// Имена хуков — 1:1 с python/sdk/base_plugin.py (on_app_event,
/// pre_request_hook, post_request_hook, on_send_message_hook, on_update_hook,
/// on_updates_hook, create_settings). Приоритеты — от частот манифеста
/// (build/compat/report.md): create_settings (14 плагинов) >
/// send_message (9) > update/updates (2).

// MARK: - Atomic

/// Lock-free счётчик Int32 поверх C11-атомиков (хранилище не двигается).
final class AtomicInt32: @unchecked Sendable {
    private let storage: UnsafeMutableRawPointer

    init(_ initial: Int32 = 0) {
        storage = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<Int32>.size,
            alignment: MemoryLayout<Int32>.alignment)
        ph_atomic_init_i32(storage, initial)
    }

    deinit { storage.deallocate() }

    var value: Int32 { ph_atomic_load_i32(storage) }

    @discardableResult
    func add(_ delta: Int32) -> Int32 { ph_atomic_fetch_add_i32(storage, delta) }

    func store(_ value: Int32) { ph_atomic_store_i32(storage, value) }
}

// MARK: - Точки входа

/// Точка входа (тип события). Индексы — позиция в allCases, порядок фиксирован.
public enum ExtensionPointKind: Int, CaseIterable, Codable, Hashable, Sendable {
    case appEvent = 0
    case preRequest = 1
    case postRequest = 2
    case update = 3
    case updates = 4
    case sendMessage = 5
    case createSettings = 6

    /// Имя протокольного хука SDK (base_plugin.py), `create_settings`
    /// соответствует PluginsConstants.CREATE_SETTINGS.
    public var protocolName: String {
        switch self {
        case .appEvent: return "on_app_event"
        case .preRequest: return "pre_request_hook"
        case .postRequest: return "post_request_hook"
        case .update: return "on_update_hook"
        case .updates: return "on_updates_hook"
        case .sendMessage: return "on_send_message_hook"
        case .createSettings: return "create_settings"
        }
    }

    var index: Int {
        assert(rawValue == ExtensionPointKind.allCases.firstIndex(of: self) ?? -1,
               "rawValue должен совпадать с позицией в allCases")
        return rawValue
    }
}

/// Атомарные счётчики подписчиков по каждой точке входа.
///
/// Горячий путь telegram-ios читает `hasSubscribers` — один atomic-load.
/// Счётчики инкрементируются при загрузке плагина (по его handles*-флагам,
/// см. Plugin.java) и декрементируются при выгрузке/выключении/зависании.
public final class SubscriberGate: @unchecked Sendable {
    private let counters: [AtomicInt32]

    public init() {
        counters = ExtensionPointKind.allCases.map { _ in AtomicInt32(0) }
    }

    /// Есть ли хоть один живой подписчик (atomic-load, наносекунды).
    public func hasSubscribers(_ kind: ExtensionPointKind) -> Bool {
        counters[kind.index].value > 0
    }

    /// Число подписчиков (для UI-отладки).
    public func subscriberCount(_ kind: ExtensionPointKind) -> Int32 {
        counters[kind.index].value
    }

    /// Все ли точки без подписчиков (плагинов нет вообще).
    public var isIdle: Bool { counters.allSatisfy { $0.value == 0 } }

    func add(_ kind: ExtensionPointKind, _ delta: Int32) {
        counters[kind.index].add(delta)
    }

    /// Снять все счётчики (стоп движка).
    func reset() {
        for counter in counters { counter.store(0) }
    }
}

// MARK: - Payload-ы

/// app_start / app_stop / app_pause / app_resume (PluginsConstants.EVENT_*).
public struct AppEventPayload: Hashable, Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}

/// Входящий TL-запрос (pre_request_hook: requestName, account, request).
public struct RequestPayload: Hashable, Sendable {
    public let requestName: String
    public let account: Int32
    public let requestJSON: String
    public init(requestName: String, account: Int32, requestJSON: String) {
        self.requestName = requestName
        self.account = account
        self.requestJSON = requestJSON
    }
}

/// Ответ на TL-запрос (post_request_hook: response либо error).
public struct RequestResponsePayload: Hashable, Sendable {
    public let requestName: String
    public let account: Int32
    public let responseJSON: String?
    public let errorMessage: String?
    public init(requestName: String, account: Int32,
                responseJSON: String?, errorMessage: String?) {
        self.requestName = requestName
        self.account = account
        self.responseJSON = responseJSON
        self.errorMessage = errorMessage
    }
}

/// Один входящий апдейт (on_update_hook: updateName, account, update).
public struct UpdatePayload: Hashable, Sendable {
    public let updateName: String
    public let account: Int32
    public let updateJSON: String
    public init(updateName: String, account: Int32, updateJSON: String) {
        self.updateName = updateName
        self.account = account
        self.updateJSON = updateJSON
    }
}

/// Контейнер апдейтов (on_updates_hook: containerName, account, updates).
public struct UpdatesPayload: Hashable, Sendable {
    public let containerName: String
    public let account: Int32
    public let updatesJSON: [String]
    public init(containerName: String, account: Int32, updatesJSON: [String]) {
        self.containerName = containerName
        self.account = account
        self.updatesJSON = updatesJSON
    }
}

/// Исходящее сообщение (on_send_message_hook: account, params).
public struct SendMessagePayload: Hashable, Sendable {
    public let account: Int32
    public let paramsJSON: String
    public init(account: Int32, paramsJSON: String) {
        self.account = account
        self.paramsJSON = paramsJSON
    }
}

/// Запрос экрана настроек плагина (create_settings у конкретного плагина).
public struct CreateSettingsPayload: Hashable, Sendable {
    public let pluginId: String
    public let account: Int32
    public init(pluginId: String, account: Int32) {
        self.pluginId = pluginId
        self.account = account
    }
}

// MARK: - Событие

/// Стратегия хука (PluginsConstants.Strategy, сравнивается строкой в Java/Python).
public enum HookStrategy: String, Codable, CaseIterable, Sendable {
    case `default` = "DEFAULT"
    case cancel = "CANCEL"
    case modify = "MODIFY"
    case modifyFinal = "MODIFY_FINAL"
}

/// Результат обработки события (возвращается ожидающими вызывающими).
public enum PluginEventResult: Equatable, Sendable {
    case none
    case strategy(HookStrategy)
    case settingsJSON(String)
    case string(String)
}

/// Ключ коалесценга апдейтов (аккаунт + имя контейнера/апдейта).
public struct CoalesceKey: Hashable, Sendable {
    public let account: Int32
    public let container: String
    public init(account: Int32, container: String) {
        self.account = account
        self.container = container
    }
}

/// Типизированное событие плагин-шины. `coalescedUpdates` — форма на выходе из
/// очереди: N апдейтов одним входом в интерпретатор.
public enum PluginEvent: Equatable, Sendable {
    case appEvent(AppEventPayload)
    case preRequest(RequestPayload)
    case postRequest(RequestResponsePayload)
    case update(UpdatePayload)
    case updates(UpdatesPayload)
    case sendMessage(SendMessagePayload)
    case createSettings(CreateSettingsPayload)
    case coalescedUpdates(CoalesceKey, [PluginEvent])
}

extension PluginEvent {
    /// Точка входа, обрабатывающая событие (для coalescedUpdates — .update/.updates).
    public var kind: ExtensionPointKind {
        switch self {
        case .appEvent: return .appEvent
        case .preRequest: return .preRequest
        case .postRequest: return .postRequest
        case .update: return .update
        case .updates: return .updates
        case .sendMessage: return .sendMessage
        case .createSettings: return .createSettings
        case .coalescedUpdates: return .updates
        }
    }

    /// Приоритет: настройки/UI > поток сообщений > запросы > жизненный цикл > апдейты.
    public var priority: PluginEventPriority {
        switch self {
        case .createSettings: return .uiSettings
        case .appEvent: return .uiSettings
        case .sendMessage: return .sendMessage
        case .preRequest, .postRequest: return .request
        case .update, .updates, .coalescedUpdates: return .updates
        }
    }

    /// Ключ коалесценга (только апдейты; остальное не коалесцируется).
    var coalesceKey: CoalesceKey? {
        switch self {
        case .update(let p): return CoalesceKey(account: p.account, container: "u:\(p.updateName)")
        case .updates(let p): return CoalesceKey(account: p.account, container: "c:\(p.containerName)")
        default: return nil
        }
    }
}

/// Приоритеты очереди (меньше — раньше).
public enum PluginEventPriority: Int, Comparable, Sendable {
    case uiSettings = 0
    case sendMessage = 1
    case request = 2
    case lifecycle = 3
    case updates = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Шина

/// Публичный фасад шины для точек входа telegram-ios.
///
/// Синхронные emit* (fire-and-forget) возвращаются сразу: проверка гейта —
/// atomic-load, постановка — Task. Ждущие методы (send-message, настройки)
/// возвращают результат через очередь.
public final class PluginEventBus: @unchecked Sendable {
    /// Гейт подписчиков хот-пата (проверка «есть ли подписчики»).
    public let subscribers: SubscriberGate
    private let queue: PluginEventQueue

    init(subscribers: SubscriberGate, queue: PluginEventQueue) {
        self.subscribers = subscribers
        self.queue = queue
    }

    /// app_start / app_stop / app_pause / app_resume.
    public func emitAppEvent(_ name: String) {
        guard subscribers.hasSubscribers(.appEvent) else { return }
        queue.submitAsync(.appEvent(AppEventPayload(name: name)))
    }

    /// Входящий TL-запрос (pre_request_hook). Вызов возвращается сразу.
    public func emitPreRequest(_ payload: RequestPayload) {
        guard subscribers.hasSubscribers(.preRequest) else { return }
        queue.submitAsync(.preRequest(payload))
    }

    /// Ответ на TL-запрос (post_request_hook).
    public func emitPostRequest(_ payload: RequestResponsePayload) {
        guard subscribers.hasSubscribers(.postRequest) else { return }
        queue.submitAsync(.postRequest(payload))
    }

    /// Один входящий апдейт. Очередь коалесцирует N апдейтов в один вход.
    public func emitUpdate(name: String, account: Int32, updateJSON: String) {
        guard subscribers.hasSubscribers(.update) else { return }
        queue.submitAsync(.update(UpdatePayload(
            updateName: name, account: account, updateJSON: updateJSON)))
    }

    /// Контейнер апдейтов (TL_updates и т.п.).
    public func emitUpdates(container: String, account: Int32, updatesJSON: [String]) {
        guard subscribers.hasSubscribers(.updates) else { return }
        queue.submitAsync(.updates(UpdatesPayload(
            containerName: container, account: account, updatesJSON: updatesJSON)))
    }

    /// Исходящее сообщение: ждёт стратегию хуков (DEFAULT/CANCEL/MODIFY/...).
    public func preSendMessage(_ payload: SendMessagePayload) async throws -> HookStrategy {
        guard subscribers.hasSubscribers(.sendMessage) else { return .default }
        switch try await queue.submitAwaiting(.sendMessage(payload)) {
        case .strategy(let strategy): return strategy
        case .none: return .default
        default: return .default
        }
    }

    /// create_settings: JSON-массив настроек плагина (PluginsConstants.Settings).
    public func requestCreateSettings(_ payload: CreateSettingsPayload) async throws -> String {
        guard subscribers.hasSubscribers(.createSettings) else { return "[]" }
        switch try await queue.submitAwaiting(.createSettings(payload)) {
        case .settingsJSON(let json): return json
        case .string(let json): return json
        default: return "[]"
        }
    }
}
