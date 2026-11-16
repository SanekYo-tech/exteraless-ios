import Foundation

/// The on-disk container selects both the SDK reader and its ID grammar.
public enum PluginFileFormat: String, Codable, Hashable, Sendable {
    case source, elyx, eaf

    public init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "py", "plugin": self = .source
        case "elyx": self = .elyx
        case "eaf": self = .eaf
        default: return nil
        }
    }

    public var isArchive: Bool { self != .source }
    var installedExtension: String { self == .source ? "plugin" : rawValue }
}

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
    public var fileFormat: PluginFileFormat
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
                fileFormat: PluginFileFormat = .source,
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
        self.fileFormat = fileFormat
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
        case permissionsDeclared, path, fileFormat, enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decodeIfPresent(String.self, forKey: .path)
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
            requires: try container.decodeIfPresent([String: Dependency].self, forKey: .requires)?.mapValues(\.values) ?? [:],
            permissions: try container.decodeIfPresent([String].self, forKey: .permissions) ?? [],
            permissionsDeclared: try container.decodeIfPresent(Bool.self, forKey: .permissionsDeclared) ?? false,
            path: path,
            fileFormat: try container.decodeIfPresent(PluginFileFormat.self, forKey: .fileFormat)
                ?? path.flatMap { PluginFileFormat(pathExtension: URL(fileURLWithPath: $0).pathExtension) } ?? .source,
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true)
    }

    /// SDK Elyx emits objects; persisted native models use two nullable slots.
    private struct Dependency: Decodable {
        let values: [String?]
        private enum Keys: String, CodingKey { case minVersion, min_version, url }
        init(from decoder: Decoder) throws {
            if let array = try? decoder.singleValueContainer().decode([String?].self) {
                guard array.count <= 2 else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "requires needs [minVersion?, url?]"))
                }
                values = array
            } else {
                let object = try decoder.container(keyedBy: Keys.self)
                values = [try object.decodeIfPresent(String.self, forKey: .minVersion)
                    ?? object.decodeIfPresent(String.self, forKey: .min_version),
                    try object.decodeIfPresent(String.self, forKey: .url)]
            }
        }
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

    public static func isValidID(_ id: String, format: PluginFileFormat) -> Bool {
        if !format.isArchive { return isValidID(id) }
        return (2...32).contains(id.utf8.count)
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    static func isReservedID(_ id: String) -> Bool {
        id.lowercased() == "exteralessmetadatainspector"
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
    private let mutationLock = NSLock()
    private var records: [String: PluginPermissionRecord] = [:]
    private var revoked: [String: [PluginPermission: UUID]] = [:]
    private var revisions: [String: UUID] = [:]
    private let log: (@Sendable (String) -> Void)?

    /// unsafe-режим (PluginsConstants.KEY_UNSAFE_MODE): всё разрешено.
    private var storedUnsafeMode: Bool
    public var unsafeMode: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storedUnsafeMode }
        set {
            lock.lock()
            defer { lock.unlock() }
            if storedUnsafeMode != newValue {
                for id in Array(revisions.keys) { revisions[id] = UUID() }
            }
            if storedUnsafeMode && !newValue {
                for id in Set(records.keys).union(revoked.keys) {
                    let allowed = (records[id] ?? PluginPermissionRecord()).effective()
                    revokeLocked(id, permissions: Set(PluginPermission.allCases).subtracting(allowed))
                }
            }
            storedUnsafeMode = newValue
        }
    }

    public init(unsafeMode: Bool = false, log: (@Sendable (String) -> Void)? = nil) {
        self.storedUnsafeMode = unsafeMode
        self.log = log
    }

    // MARK: Выданное

    /// Startup migration is durable before publication; corruption never becomes
    /// an apparently empty consent store. A failed reload retains the old state.
    public func load(from store: PluginStore) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        publish(try store.loadPermissionRecords())
    }

    /// Installed legacy plugins with no grant entry had only UI. Pin their zero
    /// tier in one startup transaction without touching any existing raw consent.
    public func migrateInstalled(_ pluginIds: [String], to store: PluginStore) throws {
        try mutate(store, isCurrent: { true }) { records in
            for id in pluginIds where records[id] == nil { records[id] = PluginPermissionRecord() }
        }
    }

    /// LEGACY NATIVE consent contract: the explicitly supplied grants also consent
    /// to their minimum tier. Retain a higher existing tier. This is not used for
    /// metadata, new-install defaults, or the level-aware native UI, and is never
    /// exported as a Python setter. Existing native callers keep their semantics.
    public func setGranted(_ pluginId: String, _ permissions: [PluginPermission], to store: PluginStore,
                           isCurrent: @Sendable () -> Bool = { true }) throws {
        try mutate(store, isCurrent: isCurrent) { records in
            let old = records[pluginId]?.level ?? .default
            let required = PluginTrustLevel.migrating(rawGrants: permissions)
            let level = old.rawValue >= required.rawValue ? old : required
            records[pluginId] = PluginPermissionRecord(level: level, grants: permissions)
        }
    }

    /// Level-aware native UI/install consent. A ceiling never implies any grant.
    /// Disallowed input is an error, so the displayed selection cannot lie.
    public func setConsent(_ pluginId: String, level: PluginTrustLevel, permissions: [PluginPermission],
                           to store: PluginStore, isCurrent: @Sendable () -> Bool = { true }) throws {
        if let denied = permissions.first(where: { !level.allows($0) }) {
            throw PluginPermissionStoreError.disallowedGrant(level, denied)
        }
        try mutate(store, isCurrent: isCurrent) { records in
            records[pluginId] = PluginPermissionRecord(level: level, grants: permissions)
        }
    }

    /// A new installation always replaces orphan consent with DEFAULT (0), unless
    /// an explicit native install selection is supplied. Replacements preserve
    /// existing consent when `selection` is nil. Run before any plugin bootstrap.
    public func prepareInstall(_ pluginId: String, replacing: Bool, selection: PluginPermissionRecord? = nil,
                               to store: PluginStore, isCurrent: @Sendable () -> Bool = { true }) throws {
        if let selection, let denied = selection.grants.first(where: { !selection.level.allows($0) }) {
            throw PluginPermissionStoreError.disallowedGrant(selection.level, denied)
        }
        try mutate(store, isCurrent: isCurrent) { records in
            if let selection { records[pluginId] = selection }
            else if !replacing || records[pluginId] == nil { records[pluginId] = PluginPermissionRecord() }
        }
    }

    /// Commit level and pruning in one replacement, even while unsafe mode is on.
    public func setLevel(_ pluginId: String, _ level: PluginTrustLevel, to store: PluginStore,
                         isCurrent: @Sendable () -> Bool = { true }) throws {
        try mutate(store, isCurrent: isCurrent) { records in
            records[pluginId] = (records[pluginId] ?? PluginPermissionRecord()).changingLevel(to: level)
        }
    }

    /// Removal forgets both grants and level in the same durable operation.
    public func clear(_ pluginId: String, in store: PluginStore,
                      isCurrent: @Sendable () -> Bool = { true }) throws {
        try mutate(store, isCurrent: isCurrent) { $0[pluginId] = nil }
    }

    private func mutate(_ store: PluginStore, isCurrent: @Sendable () -> Bool,
                        _ change: (inout [String: PluginPermissionRecord]) throws -> Void) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        // No snapshot lock across disk or the authority predicate: predicates
        // may themselves consult this model. Publication has no failing step.
        publish(try store.updatePermissionRecords(isCurrent: isCurrent, change))
    }

    private func publish(_ next: [String: PluginPermissionRecord]) {
        lock.lock()
        defer { lock.unlock() }
        for id in Set(records.keys).union(next.keys) {
            if records[id] != next[id] { revisions[id] = UUID() }
            let before = (records[id] ?? PluginPermissionRecord()).effective(unsafeMode: storedUnsafeMode)
            let after = (next[id] ?? PluginPermissionRecord()).effective(unsafeMode: storedUnsafeMode)
            revokeLocked(id, permissions: before.subtracting(after))
        }
        records = next
    }

    private func revokeLocked(_ id: String, permissions: Set<PluginPermission>) {
        for permission in permissions { revoked[id, default: [:]][permission] = UUID() }
    }

    // MARK: Эффективные

    public func snapshot(_ pluginId: String) -> PluginPermissionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        if revisions[pluginId] == nil { revisions[pluginId] = UUID() }
        return PluginPermissionSnapshot(record: records[pluginId], unsafeMode: storedUnsafeMode, revision: revisions[pluginId])
    }

    public func level(_ pluginId: String) -> PluginTrustLevel { snapshot(pluginId).level }

    /// One snapshot of unsafe mode, level and raw grants. A missing record has
    /// only UI unless the explicit global unsafe override is active.
    public func effective(_ pluginId: String) -> Set<PluginPermission> {
        snapshot(pluginId).effective
    }

    /// Retained native work captures this BEFORE its queue hop. A revocation is
    /// permanent for that work, even if the permission is granted again before
    /// the callback reaches its captured owner. Owner/account admission is still
    /// required independently; this predicate does not grant an interpreter.
    public func futurePredicate(_ pluginId: String, requiring permissions: Set<PluginPermission>) -> @Sendable () -> Bool {
        lock.lock()
        let current = (records[pluginId] ?? PluginPermissionRecord()).effective(unsafeMode: storedUnsafeMode)
        if revoked[pluginId] == nil { revoked[pluginId] = [:] }
        let epochs = revoked[pluginId] ?? [:]
        lock.unlock()
        guard permissions.isSubset(of: current) else { return { false } }
        return { [weak self] in
            guard let self else { return false }
            self.lock.lock()
            defer { self.lock.unlock() }
            let current = (self.records[pluginId] ?? PluginPermissionRecord()).effective(unsafeMode: self.storedUnsafeMode)
            return permissions.isSubset(of: current)
                && permissions.allSatisfy { self.revoked[pluginId]?[$0] == epochs[$0] }
        }
    }

    /// Разрешения, о которых плагин просит при установке (объявленные минус ui).
    public static func requested(_ plugin: Plugin) -> [PluginPermission] {
        PluginPermission.sanitize(rawKeys: plugin.permissions).filter { $0 != .ui }
    }

    // MARK: Проверка

    /// Тихая проверка (для UI). unsafe-режим пропускает всё.
    public func has(_ pluginId: String, _ permission: PluginPermission) -> Bool {
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
    private let permissionStorage: PluginPermissionStorage

    public convenience init(directory: URL? = nil) throws {
        try self.init(directory: directory, beforePermissionCommit: nil)
    }

    init(directory: URL?, beforePermissionCommit: (@Sendable () throws -> Void)?) throws {
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("exteraless/plugins", isDirectory: true)
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("exteraless/plugins")
        self.directory = base ?? fallback
        pluginsFile = self.directory.appendingPathComponent("plugins.json")
        permissionStorage = PluginPermissionStorage(url: self.directory.appendingPathComponent("grants.json"),
                                                    beforeCommit: beforePermissionCommit)
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
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plugins)
        try atomicWrite(data, to: pluginsFile)
    }

    // MARK: Разрешения

    public func loadPermissionRecords() throws -> [String: PluginPermissionRecord] {
        try permissionStorage.load()
    }

    func updatePermissionRecords(isCurrent: @Sendable () -> Bool = { true },
                                 _ change: (inout [String: PluginPermissionRecord]) throws -> Void) throws -> [String: PluginPermissionRecord] {
        try permissionStorage.update(isCurrent: isCurrent, change)
    }

    /// Legacy raw-grant projection. Loading also durably migrates missing levels.
    public func loadGrants() throws -> [String: [PluginPermission]] {
        try loadPermissionRecords().mapValues(\.orderedGrants)
    }

    /// Legacy bulk save must not erase or re-infer an existing explicit level.
    /// Existing ceilings cap incoming grants; only new records infer their tier
    /// from this explicit native consent. Omitted records are removed as before.
    public func saveGrants(_ grants: [String: [PluginPermission]]) throws {
        _ = try permissionStorage.update { records in
            var next: [String: PluginPermissionRecord] = [:]
            for (id, values) in grants {
                let level = records[id]?.level ?? .migrating(rawGrants: values)
                next[id] = PluginPermissionRecord(level: level, grants: values.filter { level.allows($0) })
            }
            records = next
        }
    }

    // MARK: Вспомогательное

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
