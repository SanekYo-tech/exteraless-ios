import Foundation

public struct ToolsBackupPluginSettings: Codable, Equatable, Sendable {
    public let path: String
    public let values: [String: ClientSettingValue]

    public init(path: String, values: [String: ClientSettingValue]) {
        self.path = path
        self.values = values
    }
}

public struct ToolsBackupPayload: Codable, Equatable, Sendable {
    public let createdAt: String
    public let appVersion: String
    public let clientSettings: [String: ClientSettingValue]
    /// Nil belongs to v1/legacy input, whose entries were all explicit values.
    public let clientStoredKeys: Set<String>?
    public let pluginSettings: [ToolsBackupPluginSettings]

    public init(createdAt: String, appVersion: String, clientSettings: [String: ClientSettingValue],
                pluginSettings: [ToolsBackupPluginSettings] = [], clientStoredKeys: Set<String>? = nil) {
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.clientSettings = clientSettings
        self.clientStoredKeys = clientStoredKeys
        self.pluginSettings = pluginSettings
    }
}

public struct ToolsBackupInspection: Sendable {
    public enum Origin: Equatable, Sendable { case native, legacyExtera }
    public let origin: Origin
    public let payload: ToolsBackupPayload
    public let settings: [String: ClientSettingValue]
    public let resetting: Set<String>
    public let ignoredKeys: [String]
    public var settingCount: Int { settings.count + resetting.count }
    public var pluginFileCount: Int { payload.pluginSettings.count }
}

/// The caller pins this location for an operation. Only already-known, non-secret
/// fields may be exported/restored. The allowlist comes from stored schema metadata,
/// never by executing a plugin's get_settings during inspection.
public struct ToolsBackupPluginLocation: Sendable {
    public let directory: URL
    public let exportableFields: [String: Set<String>]
    public let schemas: [String: ToolsPluginSettingsSchema]

    public init(directory: URL, exportableFields: [String: Set<String>], schemas: [String: ToolsPluginSettingsSchema] = [:]) {
        self.directory = directory
        self.exportableFields = exportableFields
        self.schemas = schemas
    }
}

public enum ToolsBackupPolicy {
    public static let maximumArchiveBytes = 24 * 1_024 * 1_024
    public static let maximumPayloadBytes = 16 * 1_024 * 1_024
    public static let maximumPluginFileBytes = 1_024 * 1_024
    public static let maximumPluginFiles = 256

    public static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isASCII && $0.isLetter }
        return ["password", "passwd", "secret", "apikey", "accesstoken", "refreshtoken", "authtoken",
                "privatekey", "credential", "authorization", "sessionstring", "bottoken", "githubtoken", "apitoken", "bearertoken"]
            .contains { normalized.contains($0) }
            || normalized == "token" || normalized == "cookie" || normalized == "authkey"
    }

    public static func safeValues(_ values: [String: ClientSettingValue]) -> [String: ClientSettingValue] {
        values.reduce(into: [:]) { result, entry in
            if !isSensitiveKey(entry.key), let value = safeValue(entry.value) { result[entry.key] = value }
        }
    }

    private static func safeValue(_ value: ClientSettingValue) -> ClientSettingValue? {
        switch value {
        case let .object(values): return .object(safeValues(values))
        // An array has no stable field identity for merging credentials back. Omit
        // the whole array rather than later replacing credential-bearing elements.
        case .array: return containsSensitiveField(value) ? nil : value
        default: return value
        }
    }

    private static func containsSensitiveField(_ value: ClientSettingValue) -> Bool {
        switch value {
        case let .object(values): return values.contains { isSensitiveKey($0.key) || containsSensitiveField($0.value) }
        case let .array(values): return values.contains(where: containsSensitiveField)
        default: return false
        }
    }

    public static func validatePluginPath(_ path: String) throws {
        guard ToolsFileSafety.isComponent(path), path.hasSuffix(".json"), path.count > 5,
              !path.contains("..") else { throw ToolsError.unsafePath }
    }

    public static func validateLocation(_ location: ToolsBackupPluginLocation) throws {
        // Deliberately refuse the service root (which also holds executable plugins),
        // account directories and a symlinked settings directory.
        let root = location.directory.standardizedFileURL
        guard root.isFileURL, root.lastPathComponent == "settings",
              root.resolvingSymlinksInPath().pathComponents == root.pathComponents else {
            throw ToolsError.unsafePath
        }
        var seen = Set<String>()
        guard location.exportableFields.count <= maximumPluginFiles else { throw ToolsError.sizeLimit }
        for (path, keys) in location.exportableFields {
            try validatePluginPath(path)
            guard seen.insert(path.lowercased()).inserted, keys.count <= 4_096,
                  keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") && !isSensitiveKey($0) }) else {
                throw ToolsError.invalidArchive("Invalid plugin settings allowlist.")
            }
        }
    }

    /// Overlay recursively so keys deliberately excluded from the backup, including
    /// existing plugin credentials, are retained in their original local store.
    public static func merging(_ patch: [String: ClientSettingValue], into current: [String: ClientSettingValue]) throws -> [String: ClientSettingValue] {
        var result = current
        for (key, value) in patch {
            if case let .object(incoming) = value, case let .object(existing)? = current[key] {
                result[key] = .object(try merging(incoming, into: existing))
            } else {
                if let existing = current[key], containsSensitiveField(existing) {
                    throw ToolsError.invalidArchive("A plugin field contains local credentials and cannot be replaced by backup data.")
                }
                result[key] = value
            }
        }
        return result
    }
}

public enum ToolsBackupArchive {
    public static let fileExtension = "exteraless-backup"
    private struct Envelope: Codable {
        let format: String
        let version: Int
        let payload: Data
        let sha256: String
    }

    public static func export(snapshot: ClientSettingsSnapshot, appVersion: String,
                              plugins: ToolsBackupPluginLocation? = nil, date: Date = Date()) throws -> Data {
        let snapshot = try ToolsBackupSettingsSnapshot(snapshot)
        return try export(settings: snapshot.values, definitions: snapshot.definitions, appVersion: appVersion, plugins: plugins,
                          date: date, storedKeys: snapshot.storedKeys)
    }

    public static func export(settings: [String: ClientSettingValue], definitions: [ClientSettingDefinition],
                              appVersion: String, plugins: ToolsBackupPluginLocation? = nil, date: Date = Date(),
                              storedKeys: Set<String>? = nil) throws -> Data {
        var values: [String: ClientSettingValue] = [:]
        for definition in definitions where !definition.isSecret {
            if let value = settings[definition.key] {
                values[definition.key] = try definition.validatedValue(value)
            }
        }
        var files: [ToolsBackupPluginSettings] = []
        if let plugins {
            try ToolsBackupPolicy.validateLocation(plugins)
            for path in plugins.exportableFields.keys.sorted() {
                let url = try ToolsFileSafety.checkedChild(path, root: plugins.directory)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let data = try ToolsFileSafety.read(url, maximumBytes: ToolsBackupPolicy.maximumPluginFileBytes)
                let object = try decodeSettings(data)
                let keys = plugins.exportableFields[path] ?? []
                let safe = ToolsBackupPolicy.safeValues(object.filter { keys.contains($0.key) })
                try plugins.schemas[path]?.validate(safe)
                if !safe.isEmpty { files.append(.init(path: path, values: safe)) }
            }
        }
        let payload = ToolsBackupPayload(createdAt: ISO8601DateFormatter().string(from: date),
                                         appVersion: appVersion, clientSettings: values, pluginSettings: files,
                                         clientStoredKeys: (storedKeys ?? Set(values.keys)).intersection(Set(values.keys)))
        return try encode(payload)
    }

    public static func encode(_ payload: ToolsBackupPayload) throws -> Data {
        let payload = ToolsBackupPayload(createdAt: payload.createdAt, appVersion: payload.appVersion, clientSettings: payload.clientSettings,
                                         pluginSettings: payload.pluginSettings, clientStoredKeys: payload.clientStoredKeys ?? Set(payload.clientSettings.keys))
        try validatePayload(payload)
        let bytes = try ToolsFileSafety.encode(payload)
        guard bytes.count <= ToolsBackupPolicy.maximumPayloadBytes else { throw ToolsError.sizeLimit }
        try ToolsFileSafety.checkJSON(bytes, maximumBytes: ToolsBackupPolicy.maximumPayloadBytes)
        let envelope = Envelope(format: "exteraless.settings", version: 2, payload: bytes, sha256: ToolsSHA256.hex(bytes))
        let data = try ToolsFileSafety.encode(envelope)
        guard data.count <= ToolsBackupPolicy.maximumArchiveBytes else { throw ToolsError.sizeLimit }
        return data
    }

    public static func inspect(_ data: Data, definitions: [ClientSettingDefinition], secretKeys: Set<String> = []) throws -> ToolsBackupInspection {
        guard data.count <= ToolsBackupPolicy.maximumArchiveBytes else { throw ToolsError.sizeLimit }
        if let string = String(data: data, encoding: .utf8), string.hasPrefix(ToolsInvisibleUnicode.prefix) {
            return try ToolsLegacyBackup.inspect(ToolsInvisibleUnicode.decode(string), definitions: definitions.filter { !secretKeys.contains($0.key) })
        }
        try ToolsFileSafety.checkJSON(data, maximumBytes: ToolsBackupPolicy.maximumArchiveBytes)
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ToolsError.invalidArchive("Expected a JSON object.")
            }
            root = object
        } catch { throw ToolsError.invalidArchive("The file is not valid JSON.") }
        if root["format"] == nil && (root["exteraconfig"] != nil || root["pillstackconfig"] != nil) {
            return try ToolsLegacyBackup.inspect(data, definitions: definitions.filter { !secretKeys.contains($0.key) })
        }
        guard Set(root.keys) == ["format", "version", "payload", "sha256"] else {
            throw ToolsError.invalidArchive("Unrecognized archive schema.")
        }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw ToolsError.invalidArchive("Invalid archive envelope.") }
        guard envelope.format == "exteraless.settings", envelope.version == 1 || envelope.version == 2 else {
            throw ToolsError.invalidArchive("Unsupported archive version.")
        }
        guard envelope.payload.count <= ToolsBackupPolicy.maximumPayloadBytes else { throw ToolsError.sizeLimit }
        guard envelope.sha256 == ToolsSHA256.hex(envelope.payload) else { throw ToolsError.checksumMismatch }
        try ToolsFileSafety.checkJSON(envelope.payload, maximumBytes: ToolsBackupPolicy.maximumPayloadBytes)
        var payload: ToolsBackupPayload
        do { payload = try JSONDecoder().decode(ToolsBackupPayload.self, from: envelope.payload) }
        catch { throw ToolsError.invalidArchive("Invalid settings payload.") }
        if envelope.version == 1 {
            payload = ToolsBackupPayload(createdAt: payload.createdAt, appVersion: payload.appVersion, clientSettings: payload.clientSettings,
                                         pluginSettings: payload.pluginSettings, clientStoredKeys: nil)
        } else if payload.clientStoredKeys == nil {
            throw ToolsError.invalidArchive("Version 2 requires settings presence metadata.")
        }
        try validatePayload(payload)
        return try inspection(payload, origin: .native, definitions: definitions, secretKeys: secretKeys)
    }

    static func inspection(_ payload: ToolsBackupPayload, origin: ToolsBackupInspection.Origin,
                           definitions: [ClientSettingDefinition], secretKeys: Set<String> = []) throws -> ToolsBackupInspection {
        var known: [String: ClientSettingDefinition] = [:]
        for definition in definitions { known[definition.key] = definition }
        var supported: [String: ClientSettingValue] = [:]
        var resetting = Set<String>()
        var ignored: [String] = []
        for (key, value) in payload.clientSettings {
            guard !secretKeys.contains(key) else { throw ToolsError.invalidArchive("Secret settings cannot be restored from a configuration backup.") }
            guard let definition = known[key] else { ignored.append(key); continue }
            guard !definition.isSecret else {
                throw ToolsError.invalidArchive("Secret settings cannot be restored from a configuration backup.")
            }
            if let storedKeys = payload.clientStoredKeys, !storedKeys.contains(key) {
                resetting.insert(key)
            } else {
                supported[key] = try definition.validatedValue(value)
            }
        }
        return ToolsBackupInspection(origin: origin, payload: payload, settings: supported, resetting: resetting, ignoredKeys: ignored.sorted())
    }

    static func validatePayload(_ payload: ToolsBackupPayload) throws {
        guard payload.appVersion.utf8.count <= 128, payload.createdAt.utf8.count <= 64,
              ISO8601DateFormatter().date(from: payload.createdAt) != nil,
              payload.clientSettings.count <= 4_096,
              payload.pluginSettings.count <= ToolsBackupPolicy.maximumPluginFiles else {
            throw ToolsError.invalidArchive("Invalid metadata or too many settings.")
        }
        guard payload.clientSettings.keys.allSatisfy({ ClientSettingDefinition.isValidKey($0) }) else {
            throw ToolsError.invalidArchive("Invalid client settings key.")
        }
        if let stored = payload.clientStoredKeys, !stored.isSubset(of: Set(payload.clientSettings.keys)) {
            throw ToolsError.invalidArchive("Stored-key metadata names an absent setting.")
        }
        var paths = Set<String>()
        for file in payload.pluginSettings {
            try ToolsBackupPolicy.validatePluginPath(file.path)
            guard paths.insert(file.path.lowercased()).inserted else {
                throw ToolsError.invalidArchive("Duplicate plugin settings path.")
            }
            guard file.values.count <= 4_096,
                  file.values.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }),
                  ToolsBackupPolicy.safeValues(file.values) == file.values else {
                throw ToolsError.invalidArchive("Invalid or secret plugin settings.")
            }
            guard try ToolsFileSafety.encode(file.values).count <= ToolsBackupPolicy.maximumPluginFileBytes else {
                throw ToolsError.sizeLimit
            }
        }
    }

    static func decodeSettings(_ data: Data) throws -> [String: ClientSettingValue] {
        try ToolsFileSafety.checkJSON(data, maximumBytes: ToolsBackupPolicy.maximumPluginFileBytes)
        do { return try JSONDecoder().decode([String: ClientSettingValue].self, from: data) }
        catch { throw ToolsError.invalidArchive("A plugin settings file is not a JSON object.") }
    }
}

/// Compatibility with InvisibleEncryptor's base-11 alphabet. The original name
/// describes obfuscation, not encryption; no secret is made safe by this wrapper.
public enum ToolsInvisibleUnicode {
    public static let prefix = "\u{2001}\u{2002}"
    private static let alphabet: [Unicode.Scalar] = ["\u{200a}", "\u{200b}", "\u{200c}", "\u{200f}", "\u{202f}",
                                                       "\u{206a}", "\u{206b}", "\u{206c}", "\u{206d}", "\u{206e}", "\u{206f}"]

    public static func encode(_ data: Data) throws -> String {
        guard data.count <= 1_024 * 1_024 else { throw ToolsError.sizeLimit }
        var parts: [String] = []
        parts.reserveCapacity(data.count)
        for byte in data {
            var value = Int(byte)
            var digits = ""
            while value > 0 {
                digits = String(alphabet[value % 11]) + digits
                value /= 11
            }
            parts.append(digits)
        }
        return prefix + parts.joined(separator: "\u{2000}")
    }

    public static func decode(_ string: String) throws -> Data {
        guard string.hasPrefix(prefix), string.utf8.count <= ToolsBackupPolicy.maximumArchiveBytes else {
            throw ToolsError.invalidArchive("Invalid Unicode backup wrapper.")
        }
        let body = string.dropFirst(prefix.count).filter { $0 != "\r" && $0 != "\n" }
        if body.isEmpty { return Data() }
        var result = Data()
        for token in body.split(separator: "\u{2000}", omittingEmptySubsequences: false) {
            guard token.unicodeScalars.count <= 3, result.count < ToolsBackupPolicy.maximumPayloadBytes else { throw ToolsError.sizeLimit }
            var number = 0
            for scalar in token.unicodeScalars {
                guard let digit = alphabet.firstIndex(of: scalar) else { throw ToolsError.invalidArchive("Invalid Unicode digit.") }
                number = number * 11 + digit
            }
            guard number <= 255 else { throw ToolsError.invalidArchive("Unicode byte is out of range.") }
            result.append(UInt8(number))
        }
        return result
    }
}

public enum ToolsLegacyBackup {
    // Identity mappings are supplemented by the explicit unit/inversion/enum rules
    // below. Composite Android storage shims are not guessed from their names.
    private static let identityFields: Set<String> = [
        "disableNumberRounding", "relativeLastSeen", "singleCornerRadius", "hideActionBarStatus", "senderMiniAvatars",
        "hideStories", "hidePhoneNumber", "hideArchiveFolder", "archiveOnPull", "disableUnarchiveSwipe", "squareFab",
        "newLoadingStyle", "newChatHeaderStyle", "newNavigationBarStyle", "iosNavigationBarStyle", "iosChatHeader",
        "profileMusicCard", "gooeyAvatarAnimation", "customThemes", "glassMessageMenu", "navigationDrawer",
        "immersiveDrawerAnimation", "showFeedTab", "stickerTimeMode", "replyColors", "replyEmoji", "replyBackground",
        "addCommaAfterMention", "inlineMathResult", "removeMessageTail", "wideChannelPosts", "wideFeedPosts",
        "showResultsBeforeVoting", "cameraStabilization", "cameraMirrorMode", "rememberLastUsedCamera",
        "startWithWideAngleCamera", "staticZoom", "extendedFramesPerSecond", "alwaysSendInHD", "hideCameraTile",
        "preferOriginalQuality", "swipeToPip", "unmuteWithVolumeButtons", "pauseOnMinimizeVoice", "pauseOnMinimizeRound",
        "titleText", "downloadSpeedBoost", "glassOutlineStyle", "stickerShape", "doubleTapSeekDuration",
        "avatarCorners", "sectionRadius", "stickerSize", "hideReactionsInChannels", "hideReactionsInGroups",
        "bottomButton", "dividerStyle", "infiniteScrolling"
    ]

    private enum Conversion: Sendable {
        case identity, inverted, percent, counter, pills, folderName
        case integerMap([Int64: Int64])

        func importing(_ value: ClientSettingValue) throws -> ClientSettingValue? {
            switch self {
            case .identity: return value
            case .folderName:
                guard case let .string(value) = value else { throw ToolsError.invalidArchive("Expected a legacy folder name.") }
                return .string(try ToolsSavePathPolicy.customFolder(value))
            case .pills:
                guard case let .string(value) = value, value.utf8.count <= 4_096 else { throw ToolsError.invalidArchive("Invalid pill layout.") }
                if value.isEmpty { return .string(value) }
                let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                let ids = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard ids.count == parts.count, ids.count <= 100, Set(ids).count == ids.count,
                      ids.allSatisfy({ (1...100_000).contains($0) }) else { throw ToolsError.invalidArchive("Invalid pill layout.") }
                return .string(value)
            case .inverted:
                guard case let .bool(value) = value else { throw ToolsError.invalidArchive("Expected a legacy boolean.") }
                return .bool(!value)
            case .counter:
                guard case let .bool(value) = value else { throw ToolsError.invalidArchive("Expected a legacy counter boolean.") }
                return .integer(value ? 0 : 2)
            case .percent:
                let number: Double
                switch value {
                case let .number(value): number = value
                case let .integer(value): number = Double(value)
                default: throw ToolsError.invalidArchive("Expected a legacy fraction.")
                }
                guard number.isFinite, (0...1).contains(number) else { throw ToolsError.invalidArchive("Legacy flash fraction is outside 0…1.") }
                return .integer(Int64((number * 100).rounded()))
            case let .integerMap(mapping):
                let integer: Int64?
                switch value {
                case let .integer(value): integer = value
                case let .number(value): integer = Int64(exactly: value)
                default: integer = nil
                }
                guard let integer else { throw ToolsError.invalidArchive("Expected a legacy integer option.") }
                return mapping[integer].map(ClientSettingValue.integer)
            }
        }

        func exporting(_ value: ClientSettingValue) -> ClientSettingValue? {
            switch self {
            case .identity: return value
            case .folderName:
                guard case let .string(value) = value, !value.isEmpty else { return nil }
                return try? importing(.string(value))
            case .pills: return try? importing(value)
            case .inverted:
                guard case let .bool(value) = value else { return nil }
                return .bool(!value)
            case .counter:
                guard case let .integer(value) = value else { return nil }
                return .bool(value != 2)
            case .percent:
                guard case let .integer(value) = value else { return nil }
                return .number(Double(value) / 100)
            case let .integerMap(mapping):
                guard case let .integer(value) = value else { return nil }
                return mapping.first(where: { $0.value == value }).map { .integer($0.key) }
            }
        }
    }

    private struct Rule: Sendable {
        var section = "exteraconfig"
        let field: String
        let key: String
        var conversion: Conversion = .identity
        var displayKey: String { section == "exteraconfig" ? field : section + "." + field }
    }

    private static func rules(_ definitions: [ClientSettingDefinition]) -> [Rule] {
        var result = definitions.compactMap { definition -> Rule? in
            guard !definition.isSecret, let field = definition.key.split(separator: ".").last.map(String.init), identityFields.contains(field) else { return nil }
            return Rule(field: field, key: definition.key)
        }
        result += [
            Rule(field: "formatTimeWithSeconds", key: "appearance.showSeconds"),
            Rule(field: "customSavePath", key: "tools.customSavePath", conversion: .folderName),
            Rule(field: "hidePhoneNumber", key: "privacy.hidePhone"),
            Rule(field: "sectionsSeparatedHeaders", key: "appearance.separateHeaders"),
            Rule(field: "hideSendAsPeer", key: "chats.hideSendAsChannel"),
            Rule(field: "hideKeyboardOnScroll", key: "chats.hideKeyboardOnChatScroll"),
            Rule(field: "hideReactionsInPrivateChats", key: "chats.hideReactionsInPrivate"),
            Rule(field: "showDetailsButton", key: "chats.showMessageDetails"),
            Rule(field: "showSaveMessageButton", key: "chats.showAddToSavedMessages"),
            Rule(field: "showRepeatMessageButton", key: "chats.showRepeat"),
            Rule(field: "inAppVibration", key: "appearance.disableVibration", conversion: .inverted),
            Rule(field: "tabCounter", key: "appearance.ignoreUnreadCount", conversion: .counter),
            Rule(field: "tabIcons", key: "appearance.tabsTitleType", conversion: .integerMap([0: 2, 1: 0, 2: 1])),
            Rule(field: "doNotUseProxy", key: "privacy.proxyDisableConditions", conversion: .integerMap([0: 0, 2: 2, 4: 4, 6: 6])),
            Rule(field: "flashWarmth", key: "tools.flashWarmth", conversion: .percent),
            Rule(field: "flashIntensity", key: "tools.flashIntensity", conversion: .percent),
            Rule(field: "doubleTapAction", key: "chats.doubleTapAction", conversion: .integerMap([0: 0, 1: 1, 2: 4])),
            Rule(field: "doubleTapActionOutOwner", key: "chats.doubleTapActionOut", conversion: .integerMap([0: 0, 1: 1, 2: 4])),
            Rule(section: "pillstackconfig", field: "activePills", key: "chats.activePillsRaw", conversion: .pills),
            Rule(section: "pillstackconfig", field: "hiddenPills", key: "chats.hiddenPillsRaw", conversion: .pills)
        ]
        return result
    }

    static func inspect(_ data: Data, definitions: [ClientSettingDefinition]) throws -> ToolsBackupInspection {
        try ToolsFileSafety.checkJSON(data, maximumBytes: ToolsBackupPolicy.maximumPayloadBytes)
        let root: [String: [String: ClientSettingValue]]
        do { root = try JSONDecoder().decode([String: [String: ClientSettingValue]].self, from: data) }
        catch { throw ToolsError.invalidArchive("Invalid legacy .extera settings.") }
        guard root["exteraconfig"] != nil || root["pillstackconfig"] != nil,
              root.values.reduce(0, { $0 + $1.count }) <= 4_096 else {
            throw ToolsError.invalidArchive("No supported exteraconfig section.")
        }
        var settings: [String: ClientSettingValue] = [:]
        var ignored = Set(root.flatMap { section, fields in fields.keys.map { section == "exteraconfig" ? $0 : section + "." + $0 } })
        var known: [String: ClientSettingDefinition] = [:]
        for definition in definitions where !definition.isSecret { known[definition.key] = definition }
        for rule in rules(definitions) {
            guard let definition = known[rule.key], let value = root[rule.section]?[rule.field],
                  let converted = try rule.conversion.importing(value) else { continue }
            settings[rule.key] = try definition.validatedValue(converted)
            ignored.remove(rule.displayKey)
        }
        guard !settings.isEmpty else { throw ToolsError.invalidArchive("No settings in this .extera file have a supported iOS equivalent.") }
        let payload = ToolsBackupPayload(createdAt: ISO8601DateFormatter().string(from: Date()), appVersion: "legacy .extera", clientSettings: settings)
        return ToolsBackupInspection(origin: .legacyExtera, payload: payload, settings: settings, resetting: [], ignoredKeys: ignored.sorted())
    }

    public static func export(settings: [String: ClientSettingValue], definitions: [ClientSettingDefinition]) throws -> Data {
        var legacy: [String: [String: ClientSettingValue]] = ["exteraconfig": [:]]
        var known: [String: ClientSettingDefinition] = [:]
        for definition in definitions where !definition.isSecret { known[definition.key] = definition }
        for rule in rules(definitions) {
            guard let definition = known[rule.key], let value = settings[rule.key],
                  let converted = rule.conversion.exporting(try definition.validatedValue(value)) else { continue }
            legacy[rule.section, default: [:]][rule.field] = converted
        }
        let bytes = try ToolsFileSafety.encode(legacy)
        return Data(try ToolsInvisibleUnicode.encode(bytes).utf8)
    }
}
