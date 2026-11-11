import Foundation

/// Модель плагина — поля 1:1 из Plugin.java (модель эталона Android).
/// Метаданные читает Python-сторона (AST/SDK), сюда приезжают готовыми.
public struct Plugin: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var description: String?
    public var author: String?
    /// «1.0» по умолчанию (Plugin.java).
    public var version: String
    /// Иконка-стикер «pack/index», например "exteraPlugins/1".
    public var icon: String?
    /// «python» по умолчанию (PluginsConstants.PYTHON).
    public var engine: String
    public var appVersion: String?
    public var sdkVersion: String?
    public var beta: Bool
    /// Python-требования (pip).
    public var requirements: [String]
    /// Elyx requires: id → [минимальная версия?, ссылка?].
    public var requires: [String: [String?]]
    /// Объявленные __permissions__ ключи (проверенные).
    public var permissions: [String]
    /// Было ли объявление __permissions__ вообще («объявил пусто» ≠ «не объявлял»).
    public var permissionsDeclared: Bool
    /// Абсолютный путь файла в каталоге плагинов.
    public var path: String?
    /// Включён ли пользователем (персистентно).
    public var enabled: Bool

    // --- transient (не персистятся, вычисляются на лету) ---
    /// Загружен ли сейчас в интерпретатор.
    public var loaded: Bool
    /// Есть ли create_settings (показывать ли экран настроек).
    public var hasSettings: Bool
    /// Текст последней ошибки загрузки/валидации.
    public var loadError: String?
    /// Полный отчёт об ошибке (traceback, кнопка «копировать»).
    public var loadDebug: String?
    /// Отметка сторожа: плагин завис в текущем вызове.
    public var notResponding: Bool
    /// handles*-флаги (Plugin.java): какие хуки плагин вообще берёт.
    public var handlesAppEvent: Bool
    public var handlesPreRequest: Bool
    public var handlesPostRequest: Bool
    public var handlesUpdate: Bool
    public var handlesUpdates: Bool
    public var handlesSendMessage: Bool

    public init(id: String,
                name: String? = nil,
                description: String? = nil,
                author: String? = nil,
                version: String = "1.0",
                icon: String? = nil,
                engine: String = "python",
                appVersion: String? = nil,
                sdkVersion: String? = nil,
                beta: Bool = false,
                requirements: [String] = [],
                requires: [String: [String?]] = [:],
                permissions: [String] = [],
                permissionsDeclared: Bool = false,
                path: String? = nil,
                enabled: Bool = true,
                loaded: Bool = false,
                hasSettings: Bool = false,
                loadError: String? = nil,
                loadDebug: String? = nil,
                notResponding: Bool = false,
                handlesAppEvent: Bool = true,
                handlesPreRequest: Bool = true,
                handlesPostRequest: Bool = true,
                handlesUpdate: Bool = true,
                handlesUpdates: Bool = true,
                handlesSendMessage: Bool = true) {
        self.id = id
        self.name = name
        self.description = description
        self.author = author
        self.version = version
        self.icon = icon
        self.engine = engine
        self.appVersion = appVersion
        self.sdkVersion = sdkVersion
        self.beta = beta
        self.requirements = requirements
        self.requires = requires
        self.permissions = permissions
        self.permissionsDeclared = permissionsDeclared
        self.path = path
        self.enabled = enabled
        self.loaded = loaded
        self.hasSettings = hasSettings
        self.loadError = loadError
        self.loadDebug = loadDebug
        self.notResponding = notResponding
        self.handlesAppEvent = handlesAppEvent
        self.handlesPreRequest = handlesPreRequest
        self.handlesPostRequest = handlesPostRequest
        self.handlesUpdate = handlesUpdate
        self.handlesUpdates = handlesUpdates
        self.handlesSendMessage = handlesSendMessage
    }

    // MARK: - Codable (устойчивость к отсутствующим ключам персистентности)

    private enum CodingKeys: String, CodingKey {
        case id, name, description, author, version, icon, engine, appVersion
        case sdkVersion, beta, requirements, requires, permissions
        case permissionsDeclared, path, enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            author: try container.decodeIfPresent(String.self, forKey: .author),
            version: try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0",
            icon: try container.decodeIfPresent(String.self, forKey: .icon),
            engine: try container.decodeIfPresent(String.self, forKey: .engine) ?? "python",
            appVersion: try container.decodeIfPresent(String.self, forKey: .appVersion),
            sdkVersion: try container.decodeIfPresent(String.self, forKey: .sdkVersion),
            beta: try container.decodeIfPresent(Bool.self, forKey: .beta) ?? false,
            requirements: try container.decodeIfPresent([String].self, forKey: .requirements) ?? [],
            requires: try container.decodeIfPresent([String: [String?]].self, forKey: .requires) ?? [:],
            permissions: try container.decodeIfPresent([String].self, forKey: .permissions) ?? [],
            permissionsDeclared: try container.decodeIfPresent(Bool.self, forKey: .permissionsDeclared) ?? false,
            path: try container.decodeIfPresent(String.self, forKey: .path),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true)
    }

    // MARK: - Вычисляемые (семантика Plugin.java)

    /// Включён И без ошибок загрузки (Plugin.java isEnabled()).
    public var isEnabled: Bool { enabled && loadError == nil }
    /// name ?? id (getDisplayName).
    public var displayName: String { name ?? id }
    /// «v1.0 • author • error» (getSubtitle).
    public var subtitle: String {
        var text = "v\(version.isEmpty ? "1.0" : version)"
        if let author, !author.isEmpty { text += " • \(author)" }
        if loadError != nil { text += " • error" }
        return text
    }
    /// Часть icon до слэша (getPack).
    public var iconPack: String? {
        guard let icon else { return nil }
        guard let slash = icon.firstIndex(of: "/") else { return icon }
        return String(icon[..<slash])
    }
    /// Номер стикера в паке (getIndex).
    public var iconIndex: Int {
        guard let icon, let slash = icon.firstIndex(of: "/") else { return 0 }
        let tail = icon.index(after: slash)
        guard tail < icon.endIndex else { return 0 }
        return Int(icon[tail...]) ?? 0
    }

    /// Валидация __id__ (PluginsController.PLUGIN_ID: 2–32, [A-Za-z][A-Za-z0-9_-]).
    public static func isValidID(_ id: String) -> Bool {
        guard id.count >= 2, id.count <= 32,
              let first = id.first, first.isASCII, first.isLetter else { return false }
        return id.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}

// MARK: - Разрешения (PluginPermissions.java)

/// Ключи разрешений — порядок спецификации (ALL), первый — ui.
public enum PluginPermission: String, Codable, CaseIterable, Sendable, Hashable {
    /// Меню/диалоги/бюллетени/настройки плагина. Выдаётся всегда, не спрашивается.
    case ui
    /// Чтение апдейтов/диалогов/сообщений, post-request хуки.
    case messagesRead = "messages.read"
    /// Отправка/редактирование/удаление, отмена исходящих.
    case messagesSend = "messages.send"
    /// Сеть из кода плагина.
    case network
    /// Чтение/запись вне своего каталога.
    case files
    /// Перехват ссылок и интентов.
    case intents
    /// Чтение/запись настроек приложения вне своих.
    case settings
    /// Xposed-хуки, Class Proxy — корневое.
    case hooks
    /// ctypes/нативные библиотеки — корневое.
    case native

    /// Запрашиваемые у пользователя (всё кроме ui).
    public static var requestable: [PluginPermission] { Array(allCases.dropFirst()) }

    /// hooks/native — «обладая, может всё остальное» (особое предупреждение).
    public var isDangerous: Bool { self == .hooks || self == .native }

    /// Короткий английский текст (describe).
    public var describe: String {
        switch self {
        case .ui: return "user interface"
        case .messagesRead: return "read messages and updates"
        case .messagesSend: return "send, edit and delete messages"
        case .network: return "network access"
        case .files: return "files outside its own directory"
        case .intents: return "intercept links and intents"
        case .settings: return "app settings"
        case .hooks: return "Java hooks (full control)"
        case .native: return "load native libraries (full control)"
        }
    }
}

/// Модель разрешений с персистентным хранилищем выданного (JSON в
/// Application Support) и режимом совместимости.
///
/// Честная граница (как в PluginPermissions.java): плагины исполняются в том
/// же процессе, модель делает намерения видимыми и ограничивает случайный
/// вред — не границу против атакующего.
public final class PermissionsModel: @unchecked Sendable {
    private let lock = NSLock()
    private var granted: [String: Set<PluginPermission>] = [:]
    private let log: (@Sendable (String) -> Void)?

    /// unsafe-режим (PluginsConstants.KEY_UNSAFE_MODE): всё разрешено.
    public var unsafeMode: Bool

    public init(unsafeMode: Bool = false, log: (@Sendable (String) -> Void)? = nil) {
        self.unsafeMode = unsafeMode
        self.log = log
    }

    // MARK: Выданное

    /// Загрузить хранилище согласий (старт приложения).
    public func load(from store: PluginStore) {
        let raw = store.loadGrants()
        lock.lock()
        granted = raw.mapValues { Set($0) }
        lock.unlock()
    }

    /// Записать согласие (ui подразумевается и не хранится).
    public func setGranted(_ pluginId: String, _ permissions: [PluginPermission], to store: PluginStore) {
        let clean = PluginPermission.sanitize(permissions).filter { $0 != .ui }
        lock.lock()
        granted[pluginId] = Set(clean)
        lock.unlock()
        store.saveGrants(rawGrants())
    }

    /// Стереть запись (удаление плагина).
    public func clear(_ pluginId: String, in store: PluginStore) {
        lock.lock()
        granted[pluginId] = nil
        lock.unlock()
        store.saveGrants(rawGrants())
    }

    private func rawGrants() -> [String: [PluginPermission]] {
        lock.lock()
        defer { lock.unlock() }
        return granted.mapValues { Array($0) }
    }

    // MARK: Эффективные

    /// Что плагин имеет на самом деле. Режим совместимости: НЕТ записи о
    /// согласии (плагин попал в каталог мимо листа установки) — только ui,
    /// пока пользователь не выдаст сам.
    public func effective(_ pluginId: String) -> Set<PluginPermission> {
        if unsafeMode { return Set(PluginPermission.allCases) }
        lock.lock()
        let stored = granted[pluginId]
        lock.unlock()
        guard let stored else { return [.ui] }
        return stored.union([.ui])
    }

    /// Разрешения, о которых плагин просит при установке (объявленные минус ui).
    public static func requested(_ plugin: Plugin) -> [PluginPermission] {
        PluginPermission.sanitize(rawKeys: plugin.permissions).filter { $0 != .ui }
    }

    // MARK: Проверка

    /// Тихая проверка (для UI). unsafe-режим пропускает всё.
    public func has(_ pluginId: String, _ permission: PluginPermission) -> Bool {
        if permission == .ui || unsafeMode { return true }
        return effective(pluginId).contains(permission)
    }

    /// Проверка в точке вызова: отказ не роняет плагин, лог — один раз на пару.
    public func check(_ pluginId: String, _ permission: PluginPermission, what: String? = nil) -> Bool {
        if has(pluginId, permission) { return true }
        log?("PluginPermissions: denied \(what ?? permission.rawValue) to plugin \(pluginId) — missing '\(permission.rawValue)' (\(permission.describe))")
        return false
    }
}

extension PluginPermission {
    /// Отбросить неизвестные ключи и дубли, порядок — как в ALL (sanitize).
    public static func sanitize(_ permissions: [PluginPermission]) -> [PluginPermission] {
        allCases.filter { permissions.contains($0) }
    }

    /// Из сырых строк __permissions__ (неизвестные отбрасываются).
    public static func sanitize(rawKeys: [String]) -> [PluginPermission] {
        let known = Set(rawKeys.compactMap(PluginPermission.init(rawValue:)))
        return allCases.filter { known.contains($0) }
    }
}

// MARK: - Персистентное хранилище (JSON в Application Support)

/// Хранилище: каталог Application Support/exteraless/plugins,
/// файлы plugins.json (модель) и grants.json (выданные разрешения).
/// Запись атомарная (tmp + rename) — аналог SharedPreferences-сторов эталона.
public final class PluginStore: @unchecked Sendable {
    private let lock = NSLock()
    public let directory: URL
    private let pluginsFile: URL
    private let grantsFile: URL

    public init(directory: URL? = nil) throws {
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("exteraless/plugins", isDirectory: true)
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("exteraless/plugins")
        self.directory = base ?? fallback
        pluginsFile = self.directory.appendingPathComponent("plugins.json")
        grantsFile = self.directory.appendingPathComponent("grants.json")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Маркер сторожа: plugins/.watchdog (PluginsWatchdog.MARKER_FILE).
    public var watchdogMarkerURL: URL { directory.appendingPathComponent(".watchdog") }

    // MARK: Плагины

    public func loadPlugins() -> [Plugin] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: pluginsFile) else { return [] }
        return (try? JSONDecoder().decode([Plugin].self, from: data)) ?? []
    }

    public func savePlugins(_ plugins: [Plugin]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plugins)
        try atomicWrite(data, to: pluginsFile)
    }

    // MARK: Разрешения

    public func loadGrants() -> [String: [PluginPermission]] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: grantsFile),
              let raw = (try? JSONDecoder().decode([String: [String]].self, from: data)) else { return [:] }
        return raw.mapValues { $0.compactMap(PluginPermission.init(rawValue:)) }
    }

    public func saveGrants(_ grants: [String: [PluginPermission]]) {
        let raw = grants.mapValues { $0.map(\.rawValue) }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? atomicWrite(data, to: grantsFile)
    }

    // MARK: Вспомогательное

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}
