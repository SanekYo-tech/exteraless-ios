import Foundation

/// Swift-реализация реестра `_exteraless_bridge`: сюда приходят вызовы
/// Python-прокси virtualjava, маршрутизируются в Swift-сервисы.
///
/// Контракт 1:1 с python/virtualjava/backend.py (Backend-протокол):
/// construct / call / call_instance / get / get_instance / set / set_instance
/// / member_kind / class_exists. Практика v1 — JSON-маршаллинг: Python-сторона
/// (C-мост этапа 2) сериализует вызов в JSON-строку, Swift отвечает JSON-строкой:
///
///     запрос:  {"op":"call","fqcn":"...","member":"...","args":[...],
///               "kwargs":{...},"instance":42,"value":...,"pluginId":"..."}
///     ответ:   {"ok":true,"value":...} | {"ok":false,"error":{"kind":...,"message":...}}
///
/// Прокси «разрешающий» (принцип 3): членов НЕ гейтим — ошибки решает бэкенд;
/// незнакомый класс/член = честный отказ JavaMemberError, на который SDK
/// exteraless рассчитывает (graceful-деградация).
///
/// ВАЖНО: точка входа синхронная — вызывается с потока интерпретатора Python
/// через C-колбэк этапа 2. Сервисы обязаны отвечать без долгих ожиданий;
/// UI-эффекты — через асинхронные хвосты (runOnUIThread ставит задачу в
/// основной очереди и возвращает сразу).
///
/// TODO(манифест): полная поверхность — build/compat/report.md: топ-классы
/// AndroidUtilities (10 плагинов), ApplicationLoader (9), Theme (8),
/// Browser (7), PluginsController (6), LocaleController (6), UserConfig (6),
/// TLRPC (6). Ниже — заглушки под топ вызовов; полная таблица — этап 5.

// MARK: - Операции моста

/// Операции Backend-протокола (имена — кандидатные, фиксирует этап 2 в C-мосте).
public enum BridgeOperation: String, Sendable {
    case construct
    case call
    case callInstance = "call_instance"
    case get
    case getInstance = "get_instance"
    case set
    case setInstance = "set_instance"
    case memberKind = "member_kind"
    case classExists = "class_exists"
}

/// Ошибка моста (JSON-ответ).
enum BridgeFailure: Error {
    case memberError(String)      // JavaMemberError-семантика: класса/члена нет
    case unimplemented(String)    // честный отказ: поверхности ещё нет
    case permission(String)       // гейт разрешений отказал
    case malformed(String)        // битый запрос

    var kind: String {
        switch self {
        case .memberError: return "JavaMemberError"
        case .unimplemented: return "Unimplemented"
        case .permission: return "SecurityError"
        case .malformed: return "MalformedRequest"
        }
    }
}

// MARK: - Swift-сервисы (заглушки-протоколы)

/// Поток сообщений: чтение/отправка (messages.read / messages.send).
/// Манифест: MessagesController (4 плагина), SendMessagesHelper (4),
/// MessageObject (2), TLRPC (6).
public protocol PluginMessagesService: AnyObject, Sendable {
    /// UserConfig#selectedAccount — 3 плагина.
    func selectedAccount() -> Int32
    /// MessagesController#getInstance(account) / прочие getInstance — 5 плагинов.
    /// Возвращает дескриптор инстанса для таблицы моста; v1: стабильный id.
    func instanceHandle(fqcn: String, account: Int32) -> Int64
}

/// Настройки/тема/локаль: Theme#getColor (6 плагинов), key_* поля (по 4–5),
/// LocaleController#getInstance (4), плагинные настройки (plugin_settings).
public protocol PluginSettingsService: AnyObject, Sendable {
    /// org.telegram.ui.ActionBar.Theme#getColor(key) — цвет ARGB по ключу.
    func themeColor(forKey key: String) -> Int32
    /// Статические поля key_*: v1 — вернуть само имя ключа (прокси поймёт).
    func themeKey(_ name: String) -> String
}

/// UI: AndroidUtilities#dp (6 плагинов) / runOnUIThread (3) / typeface (3),
/// BottomSheet (4), PluginSettingsActivity (4), LayoutHelper (4), UItem (4).
public protocol PluginUIService: AnyObject, Sendable {
    /// org.telegram.messenger.AndroidUtilities#dp(value).
    func dp(_ value: Double) -> Double
    /// AndroidUtilities#runOnUIThread(runnable[, delay]) — постановка и выход.
    func runOnUIThread(delayMs: Int, work: @escaping @Sendable () -> Void)
    /// Конструкторы UI (PluginSettingsActivity#<init>, BottomSheet#<init>, ...):
    /// создать объект-обёртку; v1 — регистрирует заглушку в таблице инстансов.
    func constructUI(fqcn: String, arguments: [Any]) -> Int64
}

// MARK: - Реестр и диспетчер

/// Реестр колбэков моста: точка входа C-моста этапа 2.
public final class BridgeServices: @unchecked Sendable {

    private let lock = NSLock()
    private let messages: (any PluginMessagesService)?
    private let settings: (any PluginSettingsService)?
    private let ui: (any PluginUIService)?
    private let permissions: PermissionsModel?
    private let reflection: SecurityGates?
    private var instances: [Int64: InstanceRecord] = [:]
    private var nextInstanceId: Int64 = 1

    /// Инстанс моста: fqcn + владелец-плагин (для гейтов и атрибуции).
    struct InstanceRecord: Sendable {
        let fqcn: String
        let pluginId: String?
    }

    public init(messages: (any PluginMessagesService)? = nil,
                settings: (any PluginSettingsService)? = nil,
                ui: (any PluginUIService)? = nil,
                permissions: PermissionsModel? = nil,
                reflection: SecurityGates? = nil) {
        self.messages = messages
        self.settings = settings
        self.ui = ui
        self.permissions = permissions
        self.reflection = reflection
    }

    /// Синхронная точка входа C-моста (поток интерпретатора Python).
    /// TODO(этап 2): C-обёртка передаёт JSON и получает владение строкой.
    public func dispatchJSON(_ json: String, pluginId: String?) -> String {
        guard let data = json.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return reply(error: .malformed("не JSON-объект"))
        }
        let op = (request["op"] as? String).flatMap(BridgeOperation.init(rawValue:))
            ?? .call
        do {
            let value = try dispatch(request: request, operation: op, pluginId: pluginId)
            return reply(value: value)
        } catch let failure as BridgeFailure {
            return reply(error: failure)
        } catch {
            return reply(error: .unimplemented(String(describing: error)))
        }
    }

    // MARK: Маршрутизация

    private func dispatch(request: [String: Any], operation: BridgeOperation,
                          pluginId: String?) throws -> Any {
        let fqcn = request["fqcn"] as? String ?? ""
        let member = request["member"] as? String ?? ""

        // Гейт reflection: java.chaquopy-семантика (finder.py: set_reflection_policy).
        if let reflection, !fqcn.isEmpty {
            let decision = reflection.checkClass(fqcn: fqcn, pluginId: pluginId)
            if case .denied(let reason) = decision {
                throw BridgeFailure.permission(reason)
            }
        }

        switch operation {
        case .classExists:
            // Поверхность классов — из манифеста совместимости (или сервисов).
            if let reflection {
                return reflection.classExists(fqcn)
            }
            return !fqcn.isEmpty

        case .memberKind:
            // member_kind: "field" | "method" | "unknown" (permissive, backend.py).
            if let reflection {
                return reflection.memberKind(fqcn: fqcn, member: member)
            }
            return "unknown"

        case .construct:
            return try construct(fqcn: fqcn, arguments: request["args"] as? [Any] ?? [],
                                 pluginId: pluginId)

        case .call, .callInstance, .get, .getInstance, .set, .setInstance:
            return try route(fqcn: fqcn, member: member, operation: operation,
                             request: request, pluginId: pluginId)
        }
    }

    private func construct(fqcn: String, arguments: [Any], pluginId: String?) throws -> Int64 {
        // Конструкторы UI идут в UI-сервис (манифест: PluginSettingsActivity,
        // BottomSheet, GiftSheet, BackupImageView, StarParticlesView).
        if let ui, fqcn.hasPrefix("org.telegram.ui.") {
            let handle = ui.constructUI(fqcn: fqcn, arguments: arguments)
            registerInstance(handle: handle, fqcn: fqcn, pluginId: pluginId)
            return handle
        }
        if let messages, fqcn.contains("BadgesController") || fqcn.contains("MessagesController") {
            let handle = messages.instanceHandle(fqcn: fqcn, account: 0)
            registerInstance(handle: handle, fqcn: fqcn, pluginId: pluginId)
            return handle
        }
        throw BridgeFailure.unimplemented("конструктор \(fqcn) в v1 не реализован")
    }

    private func route(fqcn: String, member: String, operation: BridgeOperation,
                       request: [String: Any], pluginId: String?) throws -> Any {
        let key = "\(fqcn)#\(member)"
        let arguments = request["args"] as? [Any] ?? []
        let instanceHandle = request["instance"] as? Int64

        switch key {
        // --- AndroidUtilities (манифест: 10 плагинов) ---
        case "org.telegram.messenger.AndroidUtilities#dp":
            return NSNumber(value: ui?.dp(number(arguments, at: 0)) ?? 0)
        case "org.telegram.messenger.AndroidUtilities#runOnUIThread":
            // Аргументы: (Runnable) / (Runnable, delay). Runnable — прокси-инстанс:
            // v1 — исполнить невозможно, ставим no-op (graceful-деградация SDK).
            ui?.runOnUIThread(delayMs: int(arguments, at: 1)) {}
            return NSNull()

        // --- Theme (8 плагинов; поля key_* читаются геттером) ---
        case "org.telegram.ui.ActionBar.Theme#getColor":
            return NSNumber(value: themeColorToARGB(string(arguments, at: 0)))

        // --- UserConfig (6 плагинов) ---
        case "org.telegram.messenger.UserConfig#selectedAccount":
            return Int(messages?.selectedAccount() ?? 0)

        default:
            // Поля key_*: Theme#key_dialogTextBlack и сотни других.
            if member.hasPrefix("key_"), fqcn.hasSuffix(".Theme") {
                return settings?.themeKey(member) ?? member
            }
            // getInstance(...): MessagesController/LocaleController/FileLoader и др.
            if member == "getInstance", let messages {
                let handle = messages.instanceHandle(fqcn: fqcn, account: int(arguments, at: 0))
                registerInstance(handle: handle, fqcn: fqcn, pluginId: pluginId)
                return handle
            }
            _ = instanceHandle
            throw BridgeFailure.memberError("нет члена \(key) на стороне iOS (v1)")
        }
    }

    // MARK: Инстансы

    private func registerInstance(handle: Int64, fqcn: String, pluginId: String?) {
        lock.lock()
        defer { lock.unlock() }
        instances[handle] = InstanceRecord(fqcn: fqcn, pluginId: pluginId)
    }

    /// Число живых инстансов (диагностика/тесты).
    public var liveInstanceCount: Int {
        lock.lock(); defer { lock.unlock() }
        return instances.count
    }

    // MARK: Кодирование ответа

    private func reply(value: Any) -> String {
        encode(["ok": true, "value": value] as [String: Any])
    }

    private func reply(error: BridgeFailure) -> String {
        encode(["ok": false, "error": ["kind": error.kind, "message": describe(error)]] as [String: Any])
    }

    private func describe(_ failure: BridgeFailure) -> String {
        switch failure {
        case .memberError(let message), .unimplemented(let message),
             .permission(let message), .malformed(let message):
            return message
        }
    }

    private func encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return "{\"ok\":false,\"error\":{\"kind\":\"MalformedRequest\",\"message\":\"encode\"}}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: Аргументы

    private func number(_ arguments: [Any], at index: Int) -> Double {
        guard index < arguments.count, let number = arguments[index] as? NSNumber else { return 0 }
        return number.doubleValue
    }

    private func int(_ arguments: [Any], at index: Int) -> Int {
        guard index < arguments.count, let number = arguments[index] as? NSNumber else { return 0 }
        return number.intValue
    }

    private func string(_ arguments: [Any], at index: Int) -> String {
        guard index < arguments.count, let string = arguments[index] as? String else { return "" }
        return string
    }

    /// ARGB-цвет темы в 0xAARRGGBB-double (v1: чёрный; сервис этапа 5).
    private func themeColorToARGB(_ key: String) -> Double {
        Double(UInt32(bitPattern: settings?.themeColor(forKey: key) ?? 0xFF000000))
    }
}
