import Foundation

public struct ToolsPluginSettingsSchema: Sendable {
    public struct Field: Sendable {
        public enum Kind: Sendable { case bool, integer, number, string }
        public let kind: Kind
        public let minimum: Double?
        public let maximum: Double?
        public let maximumLength: Int
        public init(kind: Kind, minimum: Double? = nil, maximum: Double? = nil, maximumLength: Int = 65_536) {
            self.kind = kind; self.minimum = minimum; self.maximum = maximum; self.maximumLength = maximumLength
        }
        func validate(_ value: ClientSettingValue) throws {
            let numeric: Double?
            switch (kind, value) {
            case (.bool, .bool): numeric = nil
            case let (.integer, .integer(value)): numeric = Double(value)
            case let (.number, .integer(value)): numeric = Double(value)
            case let (.number, .number(value)): numeric = value
            case let (.string, .string(value)):
                guard value.utf8.count <= maximumLength else { throw ToolsError.sizeLimit }
                numeric = nil
            default: throw ToolsError.invalidArchive("A plugin value does not match its cached native schema.")
            }
            if let numeric {
                guard numeric.isFinite, minimum.map({ numeric >= $0 }) ?? true,
                      maximum.map({ numeric <= $0 }) ?? true else { throw ToolsError.invalidArchive("A plugin numeric value is outside its schema range.") }
            }
        }
    }
    public let publicFields: [String: Field]
    public let unclassifiedCount: Int
    public let renderedJSONSHA256: String?
    public init(publicFields: [String: Field], unclassifiedCount: Int = 0, renderedJSONSHA256: String? = nil) {
        self.publicFields = publicFields; self.unclassifiedCount = unclassifiedCount
        self.renderedJSONSHA256 = renderedJSONSHA256
    }

    public func validate(_ values: [String: ClientSettingValue]) throws {
        for (key, value) in values {
            guard let field = publicFields[key] else { throw ToolsError.invalidArchive("The cached plugin schema does not permit this field.") }
            try field.validate(value)
        }
    }
}

/// Receives JSON which the native settings UI already obtained for its normal
/// operation. This cache never requests get_settings, loads Python, retains secret
/// values, or infers exportability for unknown widget types.
public final class ToolsPluginSchemaCache: @unchecked Sendable {
    private struct Entry {
        let owner: String
        let schema: ToolsPluginSettingsSchema
        let evidence: ToolsPluginSchemaEvidence?
        let generation: UUID
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    public init() {}

    /// Matches PluginServiceStorage's validated id + UTF-8 hex component. This is
    /// a filename, never a plugin display name or a path supplied by an archive.
    public static func settingsFileName(pluginId: String) throws -> String {
        guard (2...32).contains(pluginId.utf8.count), let first = pluginId.utf8.first,
              (65...90).contains(first) || (97...122).contains(first),
              pluginId.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }) else {
            throw ToolsError.unsafePath
        }
        return pluginId + "-" + pluginId.utf8.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    public func record(fileName: String, owner: String, cachedNativeSettingsJSON: Data,
                       evidence: ToolsPluginSchemaEvidence? = nil) throws {
        try ToolsBackupPolicy.validatePluginPath(fileName)
        guard !owner.isEmpty, owner.utf8.count <= 512 else { throw ToolsError.invalidArchive("Invalid cached-schema owner.") }
        do {
            let schema = try Self.decode(cachedNativeSettingsJSON)
            if let evidence {
                try evidence.validate()
                guard evidence.owner == owner, evidence.schemaSHA256 == schema.renderedJSONSHA256 else { throw ToolsError.invalidArchive("Schema evidence does not match the native response/owner.") }
            }
            lock.lock()
            defer { lock.unlock() }
            guard entries[fileName] != nil || entries.count < ToolsBackupPolicy.maximumPluginFiles else { throw ToolsError.sizeLimit }
            entries[fileName] = Entry(owner: owner, schema: schema, evidence: evidence, generation: UUID())
        } catch {
            invalidate(fileName: fileName)
            throw error
        }
    }

    public func invalidate(fileName: String) { lock.lock(); entries.removeValue(forKey: fileName); lock.unlock() }
    public func clear() { lock.lock(); entries.removeAll(); lock.unlock() }

    public func location(directory: URL, activeOwners: [String: String],
                         validity: (any ToolsPluginSchemaValidity)? = nil) throws -> ToolsBackupPluginLocation {
        lock.lock()
        let eligible = entries.filter {
            activeOwners[$0.key] == $0.value.owner && $0.value.evidence?.guarantee == .nativeImmutable && validity != nil
        }
        lock.unlock()
        let schemas = eligible.mapValues(\.schema)
        let guardValue = validity.map { CacheValidity(cache: self, generations: eligible.mapValues(\.generation), base: $0) }
        let location = ToolsBackupPluginLocation(directory: directory,
            exportableFields: schemas.mapValues { Set($0.publicFields.keys) }, schemas: schemas,
            evidence: eligible.compactMapValues(\.evidence), validity: guardValue)
        try ToolsBackupPolicy.validateLocation(location)
        return location
    }

    private func requireCurrent(_ generations: [String: UUID]) throws {
        lock.lock(); defer { lock.unlock() }
        guard generations.allSatisfy({ entries[$0.key]?.generation == $0.value }) else { throw ToolsError.invalidArchive("Captured plugin schema was replaced or invalidated.") }
    }

    private final class CacheValidity: ToolsPluginSchemaValidity, @unchecked Sendable {
        private weak var cache: ToolsPluginSchemaCache?
        private let generations: [String: UUID]
        private let base: any ToolsPluginSchemaValidity
        init(cache: ToolsPluginSchemaCache, generations: [String: UUID], base: any ToolsPluginSchemaValidity) {
            self.cache = cache; self.generations = generations; self.base = base
        }
        func withCurrent<T>(evidence: [String: ToolsPluginSchemaEvidence], use: ToolsPluginSchemaUse,
                            _ body: () throws -> T) throws -> T {
            try base.withCurrent(evidence: evidence, use: use) {
                guard let cache else { throw ToolsError.invalidArchive("Schema cache is no longer available.") }
                let selected = generations.filter { evidence[$0.key] != nil }
                try cache.requireCurrent(selected)
                let result = try body()
                // Own restore writes invalidate later permissions. The native pin
                // still excludes other writers; do not mistake our own invalidation
                // for a missing atomic write receipt (TB-01/02 retain those separately).
                if case .export = use { try cache.requireCurrent(selected) }
                return result
            }
        }
    }

    private struct Row: Decodable {
        let type: String
        let key: String?
        let items: [String]?
        let min: Double?
        let max: Double?
        let max_length: Int?
        let is_secret: Bool?
        let sensitive: Bool?
        let backup_exportable: Bool?
        let sub_page: [Row]?
    }

    public static func decode(_ data: Data) throws -> ToolsPluginSettingsSchema {
        try ToolsFileSafety.checkJSON(data, maximumBytes: 1_024 * 1_024, maximumDepth: 20)
        let rows: [Row]
        do { rows = try JSONDecoder().decode([Row].self, from: data) }
        catch { throw ToolsError.invalidArchive("Invalid cached native plugin settings JSON.") }
        var fields: [String: ToolsPluginSettingsSchema.Field] = [:]
        var seen = Set<String>(), count = 0, unknown = 0
        func visit(_ rows: [Row], depth: Int) throws {
            guard depth <= 16 else { throw ToolsError.sizeLimit }
            for row in rows {
                count += 1
                guard count <= 1_000 else { throw ToolsError.sizeLimit }
                if let key = row.key {
                    guard !key.isEmpty, key.utf8.count <= 256, !key.contains("\0"), seen.insert(key).inserted else {
                        throw ToolsError.invalidArchive("Duplicate or invalid cached plugin setting key.")
                    }
                    let protected = row.is_secret == true || row.sensitive == true || row.backup_exportable == false || ToolsBackupPolicy.isSensitiveKey(key)
                    if !protected {
                        switch row.type {
                        case "switch": fields[key] = .init(kind: .bool)
                        case "selector":
                            guard let items = row.items, !items.isEmpty, items.count <= 1_000 else { throw ToolsError.invalidArchive("Invalid cached selector.") }
                            fields[key] = .init(kind: .integer, minimum: 0, maximum: Double(items.count - 1))
                        case "slider":
                            let minimum = row.min ?? 0, maximum = row.max ?? 100
                            guard minimum.isFinite, maximum.isFinite, minimum < maximum else { throw ToolsError.invalidArchive("Invalid cached slider.") }
                            fields[key] = .init(kind: .number, minimum: minimum, maximum: maximum)
                        case "input", "edittext", "edit_text":
                            // Original text inputs do not classify credentials. They
                            // need an explicit native public-export annotation.
                            if row.backup_exportable == true {
                                fields[key] = .init(kind: .string, maximumLength: min(65_536, max(1, row.max_length ?? 65_536)))
                            } else { unknown += 1 }
                        default: unknown += 1
                        }
                    }
                }
                if let children = row.sub_page { try visit(children, depth: depth + 1) }
            }
        }
        try visit(rows, depth: 0)
        return ToolsPluginSettingsSchema(publicFields: fields, unclassifiedCount: unknown, renderedJSONSHA256: ToolsSHA256.hex(data))
    }
}
