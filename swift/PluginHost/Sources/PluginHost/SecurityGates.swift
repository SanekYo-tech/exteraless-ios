import Foundation

/// Гейты безопасности моста: reflection-политика (какой fqcn разрешён плагину)
/// и гейт разрешений в точках вызова.
///
/// Семантика из java.chaquopy контракта форка (python/virtualjava/finder.py,
/// `_chaquopy_module`):
/// - `set_reflection_policy(fn)` — политика, решающая, пускать ли обращение
///   к классу; ПОСЛЕ `seal_reflection_policy()` смена политики запрещена;
/// - `set_call_fallback(fn)` — фолбэк на ненайденный класс;
/// - политика задаётся ХОСТОМ (этап 5), вызовы из плагина в гейты-мутаторы
///   отклоняются (PluginSinkGate-семантика: плагин не меняет свою политику).
///
/// Данные — манифест совместимости build/compat/manifest.json (принцип 2:
/// манифест = единственный источник правды). Класс, который есть в манифесте
/// (реально используется корпусом), разрешён; политика режимов:
/// - `.permissive` (по умолчанию, принцип 3): незнакомый класс пропускается
///   к сервисам, ошибки решает бэкенд — SDK рассчитан на graceful-деградацию;
/// - `.manifestOnly`: незнакомый класс — честный отказ (строгий режим).

// MARK: - Решения

/// Решение гейта по fqcn.
public enum ReflectionDecision: Equatable, Sendable {
    case allowed
    /// Отказ с причиной (ошибка плагину/в лог).
    case denied(String)
}

/// Режим reflection-политики.
public enum ReflectionPolicyMode: Equatable, Sendable, Codable {
    case permissive
    case manifestOnly
}

// MARK: - Политика

/// Статическая политика: корни Java-пакетов, запрещённые модули, поверхность
/// классов из манифеста, per-plugin allowlist (классы, которые ДАННЫЙ плагин
/// использует — из поля manifest.classes[].examples).
public struct ReflectionPolicy: Sendable {
    /// Java-корни virtualjava (finder.JAVA_ROOTS).
    public static let javaRoots: Set<String> = [
        "java", "javax", "android", "androidx", "org", "com", "kotlin", "dalvik",
    ]
    /// Модули, которых на iOS-мосте нет — честный ImportError (finder.DENY_MODULES).
    public static let deniedModules: Set<String> = ["java.android"]

    /// Известные классы (манифест совместимости, ключ classes).
    public let knownClasses: Set<String>
    /// Per-plugin: fqcn, которые плагин реально использует (манифест examples).
    public let pluginClasses: [String: Set<String>]
    public let mode: ReflectionPolicyMode

    public init(knownClasses: Set<String> = [],
                pluginClasses: [String: Set<String>] = [:],
                mode: ReflectionPolicyMode = .permissive) {
        self.knownClasses = knownClasses
        self.pluginClasses = pluginClasses
        self.mode = mode
    }

    /// Собрать политику из манифеста совместимости (build/compat/manifest.json).
    /// Структура: {"classes": {fqcn: {plugins: N, examples: [pluginId]}}}.
    public static func fromManifestJSON(_ data: Data) -> ReflectionPolicy {
        var known: Set<String> = []
        var perPlugin: [String: Set<String>] = [:]
        if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let classes = root["classes"] as? [String: Any] {
            for (fqcn, rawEntry) in classes {
                known.insert(fqcn)
                if let entry = rawEntry as? [String: Any],
                   let examples = entry["examples"] as? [String] {
                    for pluginId in examples {
                        perPlugin[pluginId, default: []].insert(fqcn)
                    }
                }
            }
        }
        return ReflectionPolicy(knownClasses: known, pluginClasses: perPlugin, mode: .permissive)
    }

    // MARK: Проверки

    /// Существует ли класс по данным манифеста (class_exists моста).
    public func classExists(_ fqcn: String) -> Bool {
        guard let root = fqcn.split(separator: ".", maxSplits: 1).first.map(String.init) else {
            return false
        }
        guard ReflectionPolicy.javaRoots.contains(root) else { return false }
        if ReflectionPolicy.deniedModules.contains(fqcn) { return false }
        return mode == .permissive || knownClasses.contains(fqcn) || pluginClasses.values.contains { $0.contains(fqcn) }
    }

    /// Поле или метод по манифесту (member_kind моста; unknown — permissive).
    public func memberKind(fqcn: String, member: String) -> String {
        // TODO(манифест): parsed-поля Java-классов из manifest.classes[].declared.fields
        // (как MockBackend на десктопе); v1 — "unknown", разбор на вызове.
        _ = fqcn
        _ = member
        return "unknown"
    }

    /// Решение по классу для конкретного плагина.
    public func decision(fqcn: String, pluginId: String?) -> ReflectionDecision {
        guard let root = fqcn.split(separator: ".", maxSplits: 1).first.map(String.init) else {
            return .denied("не похоже на Java-класс: \(fqcn)")
        }
        guard ReflectionPolicy.javaRoots.contains(root) else {
            return .denied("корень \(root) вне Java-корней моста")
        }
        for denied in ReflectionPolicy.deniedModules where fqcn == denied || fqcn.hasPrefix(denied + ".") {
            return .denied("\(fqcn): на iOS-мосте нет (честный ImportError)")
        }
        if mode == .manifestOnly {
            let allowedByPlugin = pluginId.flatMap { pluginClasses[$0]?.contains(fqcn) } ?? false
            if !knownClasses.contains(fqcn) && !allowedByPlugin {
                return .denied("\(fqcn) вне манифеста совместимости (строгий режим)")
            }
        }
        return .allowed
    }
}

// MARK: - Гейты

/// Гейты моста: reflection-политика (sealed), фолбэк вызовов, гейт разрешений.
/// Потокобезопасен: вызывается с потока интерпретатора синхронно.
public final class SecurityGates: @unchecked Sendable {

    private let lock = NSLock()
    private var policy: ReflectionPolicy
    private var sealed = false
    private var callFallback: (@Sendable (String) -> Bool)?
    private let permissions: PermissionsModel?
    private let log: (@Sendable (String) -> Void)?

    public init(policy: ReflectionPolicy = ReflectionPolicy(),
                permissions: PermissionsModel? = nil,
                log: (@Sendable (String) -> Void)? = nil) {
        self.policy = policy
        self.permissions = permissions
        self.log = log
    }

    // MARK: java.chaquopy-семантика

    /// set_reflection_policy: ХОСТ задаёт политику. Отказ после seal
    /// («reflection policy sealed»); вызовы из плагина отклоняются на уровне
    /// моста (этап 2 передаёт pluginId — с ним мутатор не работает).
    public func setReflectionPolicy(_ newPolicy: ReflectionPolicy, fromPlugin pluginId: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard pluginId == nil else {
            log?("SecurityGates: плагин \(pluginId!) пытался сменить reflection-политику — отказ")
            return
        }
        guard !sealed else {
            log?("SecurityGates: reflection policy sealed — отказ")
            return
        }
        policy = newPolicy
    }

    /// seal_reflection_policy: политика зафиксирована до конца сессии.
    public func sealReflectionPolicy() {
        lock.lock()
        sealed = true
        lock.unlock()
    }

    public var isSealed: Bool {
        lock.lock(); defer { lock.unlock() }
        return sealed
    }

    /// set_call_fallback: фолбэк на ненайденный класс (возврат False = ошибка).
    public func setCallFallback(_ fallback: (@Sendable (String) -> Bool)?) {
        lock.lock()
        callFallback = fallback
        lock.unlock()
    }

    // MARK: Точки вызова моста

    /// Проверка класса (гейт каждого вызова моста).
    public func checkClass(fqcn: String, pluginId: String?) -> ReflectionDecision {
        lock.lock()
        let current = policy
        let fallback = callFallback
        lock.unlock()
        let decision = current.decision(fqcn: fqcn, pluginId: pluginId)
        if case .denied = decision, let fallback, fallback(fqcn) {
            return .allowed
        }
        return decision
    }

    /// class_exists моста (манифест/фолбэк).
    public func classExists(_ fqcn: String) -> Bool {
        lock.lock()
        let current = policy
        let fallback = callFallback
        lock.unlock()
        if current.classExists(fqcn) { return true }
        return fallback?(fqcn) ?? false
    }

    /// member_kind моста.
    public func memberKind(fqcn: String, member: String) -> String {
        lock.lock()
        let current = policy
        lock.unlock()
        return current.memberKind(fqcn: fqcn, member: member)
    }

    // MARK: Гейт разрешений в точках вызова

    /// Таблица: точка моста → разрешение. Отказ НЕ роняет плагин: вызывающий
    /// отдаёт безопасное значение, сюда пишется отказ (PluginPermissions.check).
    /// TODO(манифест/этап 5): расширить по использованию классов корпусом
    /// (Browser#openUrl — intents; FileLoader/files — files; сеть — network).
    public func permissionFor(fqcn: String, member: String) -> PluginPermission? {
        switch (fqcn, member) {
        case ("org.telegram.messenger.browser.Browser", "openUrl"):
            return .intents
        case ("org.telegram.messenger.SendMessagesHelper", _) where member != "getClass":
            return .messagesSend
        default:
            if fqcn.hasPrefix("org.telegram.tgnet.") { return .network }
            if fqcn.hasPrefix("org.telegram.messenger.FileLoader") { return .files }
            return nil
        }
    }

    /// Проверить разрешение для вызова моста (одна точка входа).
    public func checkPermission(pluginId: String?, fqcn: String, member: String) -> Bool {
        guard let permissions else { return true }
        guard let permission = permissionFor(fqcn: fqcn, member: member) else { return true }
        guard let pluginId else { return false }
        return permissions.check(pluginId, permission, what: "\(fqcn)#\(member)")
    }
}
