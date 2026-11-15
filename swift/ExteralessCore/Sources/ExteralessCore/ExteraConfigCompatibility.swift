import Foundation

/// The original ExteraConfig.java compatibility-only preference file, projected
/// into one installation-wide native store. These entries are storage contracts,
/// not independent client features and must be excluded from generic settings UI.
public enum ExteraConfigCompatibility {
    public static let prefix = "compat.exteraconfig."
    public static let section = "Compatibility state"
    public static let maximumStringBytes = 65_536
    public static let maximumBatchBytes = 262_144
    public static let maximumBatchKeys = 128

    public static let definitions: [ClientSettingDefinition] = [
        enumeration("translationFormality", 0, ["NONE", "INFORMAL", "FORMAL"]),
        boolean("useYandexMaps", false),
        enumeration("tabIcons", 1, ["ICONS_AND_TITLES", "TITLES_ONLY", "ICONS_ONLY"]),
        boolean("tabCounter", true),
        boolean("newSliderStyle", true),
        boolean("newSwitchStyle", true),
        boolean("springAnimations", true),
        boolean("forceBlur", false),
        ClientSettingDefinition(key: "compat.exteraconfig.eventType", title: "eventType", section: section,
            defaultValue: .integer(0), minimum: -2_147_483_648, maximum: 2_147_483_647,
            androidSymbols: ["ExteraConfig.getEventType", "ExteraConfig.setEventType"], valueShape: .integer),
        boolean("unlimitedRecentStickers", false),
        boolean("quickTransitionForChannels", true),
        boolean("quickTransitionForTopics", true),
        boolean("showClearButton", true),
        boolean("showGenerateButton", true),
        ClientSettingDefinition(key: "compat.exteraconfig.recognitionLanguage", title: "recognitionLanguage", section: section,
            defaultValue: .string("none"), androidSymbols: ["ExteraConfig.getRecognitionLanguage", "ExteraConfig.setRecognitionLanguage"], valueShape: .string),
        boolean("postprocessingWithAi", false),
        boolean("useGoogleAnalytics", false),
        boolean("enableAdBlock", true),
        ClientSettingDefinition(key: "compat.exteraconfig.updateScheduleTimestamp", title: "updateScheduleTimestamp", section: section,
            defaultValue: .integer(0), androidSymbols: ["ExteraConfig.getUpdateScheduleTimestamp", "ExteraConfig.setUpdateScheduleTimestamp"], valueShape: .integer),
        ClientSettingDefinition(key: "compat.exteraconfig.sdkUpdateScheduleTimestamp", title: "sdkUpdateScheduleTimestamp", section: section,
            defaultValue: .integer(0), androidSymbols: ["ExteraConfig.getSdkUpdateScheduleTimestamp", "ExteraConfig.setSdkUpdateScheduleTimestamp"], valueShape: .integer),
        boolean("pluginsPySdkAutoUpdate", true),
        boolean("pluginsPySdkBetaVersions", false)
    ]

    public static let keys = Set(definitions.map(\.key))

    private static func boolean(_ name: String, _ value: Bool) -> ClientSettingDefinition {
        let method = name.prefix(1).uppercased() + String(name.dropFirst())
        return ClientSettingDefinition(key: prefix + name, title: name, section: section, defaultValue: .bool(value),
            androidSymbols: ["ExteraConfig.get" + method, "ExteraConfig.set" + method], valueShape: .bool)
    }

    private static func enumeration(_ name: String, _ value: Int64, _ labels: [String]) -> ClientSettingDefinition {
        let method = name.prefix(1).uppercased() + String(name.dropFirst())
        return ClientSettingDefinition(key: prefix + name, title: name, section: section, defaultValue: .integer(value),
            options: labels.enumerated().map { ClientSettingOption(value: .integer(Int64($0.offset)), title: $0.element) },
            androidSymbols: ["ExteraConfig.get" + method, "ExteraConfig.set" + method], valueShape: .integer)
    }

    /// The bridge never accepts an arbitrary key under this reserved namespace.
    /// The store still independently requires actual registration and public access.
    public static func validatePublicValue(_ value: ClientSettingValue, for key: String) throws {
        guard key.hasPrefix(prefix) else { return }
        guard let definition = definitions.first(where: { $0.key == key }) else {
            throw ClientSettingsError.unregisteredKey(key)
        }
        try definition.validate(value)
        if case let .string(text) = value, text.utf8.count > maximumStringBytes {
            throw ClientSettingsError.invalidValue(key: key, reason: .shape)
        }
    }

    /// Original JSON bytes enter the strict Core codec. No NSNumber round-trip,
    /// permissive key registration, secret binding, or partially committed loop.
    public static func applyPublicJSON(_ json: String, to settings: ClientSettings) throws {
        guard json.utf8.count <= maximumBatchBytes,
              case let .object(values) = try ClientSettingValue.decodeJSON(json),
              values.count <= maximumBatchKeys else { throw ClientSettingsError.invalidJSON }
        for (key, value) in values { try validatePublicValue(value, for: key) }
        try settings.applyPublic(values)
    }

    /// Individual metadata queries return only an actually registered public
    /// definition. Learned secret aliases are denied, including failed migrations.
    public static func publicMetadata(for key: String, in settings: ClientSettings) throws -> ClientSettingValue {
        let snapshot = settings.readSnapshot()
        guard !snapshot.secretKeys.contains(key) else { throw ClientSettingsError.secretAccessDenied }
        guard let definition = snapshot.definitions.first(where: { $0.key == key }) else { return .null }
        guard !definition.isSecret else { throw ClientSettingsError.secretAccessDenied }
        try validatePublicValue(definition.defaultValue, for: key)
        var value: [String: ClientSettingValue] = [
            "key": .string(key), "type": .string(typeName(definition.defaultValue)),
            "default": definition.defaultValue, "scope": .string("global"),
            "options": .array(definition.options.map { .object(["value": $0.value, "title": .string($0.title)]) })
        ]
        if let minimum = definition.minimum { value["minimum"] = .number(minimum) }
        if let maximum = definition.maximum { value["maximum"] = .number(maximum) }
        if let step = definition.step { value["step"] = .number(step) }
        return .object(value)
    }

    private static func typeName(_ value: ClientSettingValue) -> String {
        switch value {
        case .null: return "nullable"
        case .bool: return "bool"
        case .integer: return "int"
        case .number: return "float"
        case .string: return "text"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

/// Native-only global-manager commands. UI Runtime binds their actual effects.
public enum ExteraConfigManagerMutation: Sendable {
    case engine(Bool), safeMode(Bool), developer(Bool), compact(Bool), pinned(Set<String>)

    public var field: String {
        switch self {
        case .engine: return "engineEnabled"
        case .safeMode: return "safeMode"
        case .developer: return "developerMode"
        case .compact: return "compactView"
        case .pinned: return "pinned"
        }
    }
}

public enum ExteraConfigCommandError: Error, Sendable {
    case queueFull, callerRetired
}

/// Synchronous bounded admission; one asynchronous effect at a time. Retirement
/// removes only pending work so self-disable can finish its own Host maintenance.
public final class ExteraConfigCommandQueue<Owner: Hashable & Sendable>: @unchecked Sendable {
    private struct Entry: Sendable {
        let id: String
        let owner: Owner
        let mutation: ExteraConfigManagerMutation
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var draining = false
    private var executing: Owner?
    private let apply: @Sendable (Owner, ExteraConfigManagerMutation) async throws -> Void
    private let failed: @Sendable (Owner, String, Error) -> Void
    private let maximumPending: Int
    private let maximumPerOwner: Int

    public init(maximumPending: Int = 128, maximumPerOwner: Int = 32,
                apply: @escaping @Sendable (Owner, ExteraConfigManagerMutation) async throws -> Void,
                failed: @escaping @Sendable (Owner, String, Error) -> Void) {
        self.maximumPending = maximumPending
        self.maximumPerOwner = maximumPerOwner
        self.apply = apply
        self.failed = failed
    }

    public func enqueue(owner: Owner, mutation: ExteraConfigManagerMutation) throws -> String {
        let id = UUID().uuidString
        lock.lock()
        let ownerCount = entries.filter { $0.owner == owner }.count + (executing == owner ? 1 : 0)
        guard entries.count + (executing == nil ? 0 : 1) < maximumPending, ownerCount < maximumPerOwner else {
            lock.unlock()
            throw ExteraConfigCommandError.queueFull
        }
        entries.append(Entry(id: id, owner: owner, mutation: mutation))
        let start = !draining
        draining = true
        lock.unlock()
        if start { Task { await self.drain() } }
        return id
    }

    public func retire(where matches: (Owner) -> Bool) {
        lock.lock()
        let retired = entries.filter { matches($0.owner) }
        entries.removeAll { matches($0.owner) }
        lock.unlock()
        for entry in retired { failed(entry.owner, entry.mutation.field, ExteraConfigCommandError.callerRetired) }
    }

    private func next() -> Entry? {
        lock.lock(); defer { lock.unlock() }
        executing = nil
        guard !entries.isEmpty else { draining = false; return nil }
        let entry = entries.removeFirst()
        executing = entry.owner
        return entry
    }

    private func drain() async {
        while let entry = next() {
            do { try await apply(entry.owner, entry.mutation) }
            catch { failed(entry.owner, entry.mutation.field, error) }
        }
    }
}
