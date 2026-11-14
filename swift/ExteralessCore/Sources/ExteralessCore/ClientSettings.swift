import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Errors contain schema keys and failure codes, never rejected values, JSON,
/// Keychain data, underlying error descriptions or account paths.
public enum ClientSettingsError: Error, Equatable, LocalizedError, Sendable {
    public enum ValidationReason: String, Sendable {
        case type, option, range, step
    }

    case invalidKey
    case unregisteredKey(String)
    case invalidDefinition(key: String)
    case conflictingDefinition(key: String)
    case invalidValue(key: String, reason: ValidationReason)
    case conflictingChanges
    case concurrentModification
    case nonFiniteNumber
    case invalidJSON
    case unsupportedVersion(Int64)
    case notConfigured
    case invalidStorageURL
    case storageFailure(operation: String, code: Int)
    case secretStorageUnavailable
    case secretAccessDenied
    case secretStorageFailure(status: Int32)
    case invalidSecret

    public var errorDescription: String? {
        switch self {
        case .invalidKey: return "The setting key is invalid."
        case let .unregisteredKey(key): return "The setting is not registered: \(key)."
        case let .invalidDefinition(key): return "The setting definition is invalid: \(key)."
        case let .conflictingDefinition(key): return "The setting is already registered with another definition: \(key)."
        case let .invalidValue(key, reason):
            switch reason {
            case .type: return "The value has the wrong type for \(key)."
            case .option: return "Choose one of the available options for \(key)."
            case .range: return "The value is outside the allowed range for \(key)."
            case .step: return "The value does not match the allowed step for \(key)."
            }
        case .conflictingChanges: return "A setting cannot be updated and reset in the same batch."
        case .concurrentModification: return "The affected settings have changed. Refresh the snapshot before trying again."
        case .nonFiniteNumber: return "Settings cannot contain NaN or infinite numbers."
        case .invalidJSON: return "The settings document is invalid. The existing file has been preserved."
        case let .unsupportedVersion(version): return "This settings document requires a newer client (version \(version))."
        case .notConfigured: return "The settings storage has not been configured."
        case .invalidStorageURL: return "Settings require a local file URL."
        case let .storageFailure(operation, code): return "Settings storage failed during \(operation) (code \(code))."
        case .secretStorageUnavailable: return "Persistent secret storage is unavailable on this platform."
        case .secretAccessDenied: return "This setting is managed by native credential services."
        case let .secretStorageFailure(status): return "Secure settings storage is unavailable (code \(status))."
        case .invalidSecret: return "A secure setting could not be read. Its stored value has been preserved."
        }
    }
}

/// A single cache generation for UI/rendering. Secret values are always .null;
/// unregistered values are retained on disk but never included in this view.
public struct ClientSettingsSnapshot: Sendable {
    public let definitions: [ClientSettingDefinition]
    public let values: [String: ClientSettingValue]
    public let storedKeys: Set<String>
    public let secretKeys: Set<String>
    public let lastError: ClientSettingsError?

    /// Also allows a journal to reconstruct an expected CAS state. Construction
    /// grants no write access: applyPublic rechecks the live schema and file.
    public init(definitions: [ClientSettingDefinition], values: [String: ClientSettingValue],
                storedKeys: Set<String>, secretKeys: Set<String> = [], lastError: ClientSettingsError? = nil) {
        let secretKeys = secretKeys.union(definitions.filter(\.isSecret).map(\.key))
        var values = values
        for key in secretKeys where values[key] != nil { values[key] = .null }
        self.definitions = definitions
        self.values = values
        self.storedKeys = storedKeys
        self.secretKeys = secretKeys
        self.lastError = lastError
    }
}

/// Synchronous, process-local read cache with serialized durable writes.
/// No getter performs file or Keychain I/O. Configure and register all domains
/// before starting consumers; extensions configure the same existing shared path
/// and explicitly reload when entering a lifecycle that needs fresh settings.
public final class ClientSettings: @unchecked Sendable {
    public static let shared = ClientSettings(defaultStorage: ())

    private struct Cache {
        var definitions: [ClientSettingDefinition] = []
        var values: [String: ClientSettingValue] = [:]
        var storedKeys: Set<String> = []
        var secretKeys: Set<String> = []
        var error: ClientSettingsError?
    }

    private struct Change {
        let keys: Set<String>
        let observers: [ClientSettingsObserver]

        func deliver() {
            for observer in self.observers { observer.notify(self.keys) }
        }
    }

    private enum Operation {
        case configure(URL, (any ClientSecretStore)?)
        case register([ClientSettingDefinition])
        case reload
        case set(String, ClientSettingValue)
        case setPublic(String, ClientSettingValue)
        case applyPublic([String: ClientSettingValue], Set<String>, ClientSettingsSnapshot?)
        case reset(String)
        case migrateKey(String, String)
    }

    private enum SecretMutation {
        case set(ClientSettingValue)
        case delete
    }

    // Lock order: writer -> cache. Cache readers never take writer. Filesystem
    // locks serialize read/modify/replace across instances and app processes.
    private let writerLock = NSLock()
    private let cacheLock = NSLock()
    private var cache = Cache()
    private var observers: [UUID: ClientSettingsObserver] = [:]
    private var storageURL: URL?
    private var secretStore: any ClientSecretStore
    private var registeredDefinitions: [ClientSettingDefinition] = []
    private let afterFileReplace: (@Sendable () throws -> Void)?

    /// The initial file read is completed before this initializer returns.
    /// Inject a fake secretStore in tests; no production in-memory fallback exists.
    public convenience init(storageURL: URL, secretStore: any ClientSecretStore = ClientSecrets.systemStore()) throws {
        try self.init(storageURL: storageURL, secretStore: secretStore, afterFileReplace: nil)
    }

    /// Internal fault injection at the real post-rename/pre-directory-sync seam.
    /// Production initializers never supply a hook; fixtures must not re-enter.
    init(storageURL: URL, secretStore: any ClientSecretStore, afterFileReplace: (@Sendable () throws -> Void)?) throws {
        self.secretStore = secretStore
        self.afterFileReplace = afterFileReplace
        try self.configure(storageURL: storageURL)
    }

    private init(defaultStorage: ()) {
        self.secretStore = ClientSecrets.systemStore()
        self.afterFileReplace = nil
        do {
            try self.configure(storageURL: Self.defaultStorageURL())
        } catch {
            // shared cannot throw. Expose the failure to UI and preserve the
            // document; a later configure/reload can recover without a reset.
            self.cache.error = Self.storageError(error, operation: "initial read")
        }
    }

    public static func defaultStorageURL() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ClientSettingsError.notConfigured
        }
        return support.appendingPathComponent("exteraless", isDirectory: true)
            .appendingPathComponent("client-settings.json", isDirectory: false)
    }

    /// Selects a file, not a copy/move operation. A failed read keeps the last
    /// good cache, but subsequent writes target and revalidate the selected file.
    /// A corrupt new file can never cause a write to the previous/default path.
    public func configure(storageURL: URL) throws {
        try self.perform(.configure(storageURL, nil))
    }

    public func configure(storageURL: URL, secretStore: any ClientSecretStore) throws {
        try self.perform(.configure(storageURL, secretStore))
    }

    /// Identical registrations are idempotent. Labels, options and defaults may
    /// update if existing values still validate; type changes/secret downgrades
    /// fail as a batch. Defaults are never written as user preferences.
    public func register(_ definitions: [ClientSettingDefinition]) throws {
        try self.perform(.register(definitions))
    }

    public func bool(_ key: String, default fallback: Bool = false) -> Bool {
        guard case let .bool(value) = self.cachedValue(key) else { return fallback }
        return value
    }

    public func integer(_ key: String, default fallback: Int = 0) -> Int {
        guard case let .integer(value) = self.cachedValue(key), let result = Int(exactly: value) else { return fallback }
        return result
    }

    public func double(_ key: String, default fallback: Double = 0.0) -> Double {
        switch self.cachedValue(key) {
        case let .number(value): return value
        case let .integer(value): return Double(exactly: value) ?? fallback
        default: return fallback
        }
    }

    /// Native consumers can read a registered secret through this typed getter.
    /// Never interpolate the result into diagnostics, UI summaries or exports.
    public func string(_ key: String, default fallback: String = "") -> String {
        guard case let .string(value) = self.cachedValue(key) else { return fallback }
        return value
    }

    /// Native typed-value access, including secrets. Generic plugin services and
    /// backups must use snapshot()/exportJSON(), which redact secret values.
    public func value(_ key: String) -> ClientSettingValue? {
        return self.cachedValue(key)
    }

    public func set(_ value: ClientSettingValue, for key: String) throws {
        try self.perform(.set(key, value))
    }

    /// Generic plugin/API writes cannot race schema publication into a Keychain
    /// field. The public/secret check is performed under the same writer lock as
    /// schema resolution and persistence, including learned secret classifications.
    public func setPublic(_ value: ClientSettingValue, for key: String) throws {
        try self.perform(.setPublic(key, value))
    }

    /// One atomic public-settings patch, including removal of overrides. All
    /// affected keys must be registered and public; update/reset overlap fails.
    /// When expected is provided, compare affected effective JSON values AND
    /// override presence against disk under flock before writing. Unaffected
    /// keys are merged from that file. Credentials are neither read nor mutated.
    /// A post-rename error can still mean the entire batch committed; the cache
    /// then reflects the committed state. Build rollback's expected state from
    /// the intended patch, not a later snapshot that may include another edit.
    public func applyPublic(_ values: [String: ClientSettingValue], resetting: Set<String> = [],
                            expected: ClientSettingsSnapshot? = nil) throws {
        guard !values.isEmpty || !resetting.isEmpty else { return }
        try self.perform(.applyPublic(values, resetting, expected))
    }

    /// Removes an override (or Keychain item), so future defaults also take effect.
    public func reset(_ key: String) throws {
        try self.perform(.reset(key))
    }

    /// Idempotently migrates a legacy JSON key into a registered destination.
    /// An existing destination wins; unrelated/unknown keys survive. Secret
    /// destinations are moved into Keychain before the plaintext is removed.
    public func migrateKey(from oldKey: String, to key: String) throws {
        try self.perform(.migrateKey(oldKey, key))
    }

    public func snapshot() -> [String: ClientSettingValue] {
        return self.readSnapshot().values
    }

    public func definitions() -> [ClientSettingDefinition] {
        self.cacheLock.lock()
        defer { self.cacheLock.unlock() }
        return self.cache.definitions
    }

    public var lastError: ClientSettingsError? {
        self.cacheLock.lock()
        defer { self.cacheLock.unlock() }
        return self.cache.error
    }

    public func readSnapshot() -> ClientSettingsSnapshot {
        self.cacheLock.lock()
        defer { self.cacheLock.unlock() }
        return ClientSettingsSnapshot(definitions: self.cache.definitions, values: self.cache.values,
                                      storedKeys: self.cache.storedKeys, secretKeys: self.cache.secretKeys,
                                      lastError: self.cache.error)
    }

    /// Portable, registered settings only. Secret keys are omitted entirely.
    public func exportJSON() throws -> Data {
        let snapshot = self.readSnapshot()
        var values = snapshot.values
        for key in snapshot.secretKeys { values.removeValue(forKey: key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(values)
        } catch {
            throw ClientSettingsError.invalidJSON
        }
    }

    public func reload() throws {
        try self.perform(.reload)
    }

    /// Subscribe before taking the initial snapshot to avoid a lost update.
    /// Invalidations run synchronously outside every store/file/observer lock,
    /// on the mutating thread, and may overlap. Re-read the cache in the callback.
    /// An empty key set invalidates storage/error state. No initial callback.
    public func observe(_ callback: @escaping @Sendable (Set<String>) -> Void) -> ClientSettingsObservation {
        let id = UUID()
        let observer = ClientSettingsObserver(callback)
        self.cacheLock.lock()
        self.observers[id] = observer
        self.cacheLock.unlock()
        return ClientSettingsObservation { [weak self, observer] in
            observer.cancel()
            guard let self else { return }
            self.cacheLock.lock()
            self.observers.removeValue(forKey: id)
            self.cacheLock.unlock()
        }
    }

    private func cachedValue(_ key: String) -> ClientSettingValue? {
        self.cacheLock.lock()
        defer { self.cacheLock.unlock() }
        return self.cache.values[key]
    }

    private func perform(_ operation: Operation) throws {
        self.writerLock.lock()
        let change: Change
        var failure: ClientSettingsError?
        do {
            if case let .applyPublic(values, resetting, expected) = operation {
                let result = try self.runPublicBatchLocked(values, resetting: resetting, expected: expected)
                failure = result.failure
                change = result.change
            } else {
                let result = try self.runLocked(operation)
                failure = result.error
                change = self.publish(result)
            }
        } catch {
            let safeError = Self.storageError(error, operation: "read or write")
            failure = safeError
            var learnedSecretKeys: Set<String> = []
            if case let .register(definitions) = operation {
                learnedSecretKeys.formUnion(definitions.filter { $0.isSecret && ClientSettingDefinition.isValidKey($0.key) }.map(\.key))
            }
            // Keychain and rename can commit before a later I/O failure. Re-read
            // on failure too, rather than reporting a fictitious rollback.
            var recovered: Cache?
            if let url = self.storageURL {
                recovered = try? ClientSettingsFile.withLock(at: url) {
                    let document = try ClientSettingsFile.read(at: url)
                    learnedSecretKeys.formUnion(document.secretKeys)
                    if case .applyPublic = operation {
                        self.cacheLock.lock()
                        let cached = self.cache
                        self.cacheLock.unlock()
                        return try self.resolvePublic(document, definitions: self.registeredDefinitions, cached: cached)
                    }
                    return try self.resolve(document, definitions: self.registeredDefinitions)
                }
            }
            self.cacheLock.lock()
            var next = recovered ?? self.cache
            next.secretKeys.formUnion(self.cache.secretKeys)
            self.cacheLock.unlock()
            // Even a failed plaintext->secret migration must immediately stop
            // exposing that value through snapshots/export or later plain writes.
            next.secretKeys.formUnion(learnedSecretKeys)
            next.error = safeError
            change = self.publish(next)
        }
        self.writerLock.unlock()
        change.deliver()
        if let failure { throw failure }
    }

    /// The caller holds writerLock. CAS, the single file replacement and cache
    /// publication share the same flock; delivery happens in perform after both
    /// locks have been released. This path cannot enter secret migration logic.
    private func runPublicBatchLocked(_ values: [String: ClientSettingValue], resetting: Set<String>,
                                      expected: ClientSettingsSnapshot?) throws -> (change: Change, failure: ClientSettingsError?) {
        guard let url = self.storageURL else { throw ClientSettingsError.notConfigured }
        let definitions = self.registeredDefinitions
        self.cacheLock.lock()
        let cached = self.cache
        self.cacheLock.unlock()
        return try ClientSettingsFile.withLock(at: url) {
            let original = try ClientSettingsFile.read(at: url)
            var document = original
            document.secretKeys.formUnion(cached.secretKeys)
            document.secretKeys.formUnion(definitions.filter(\.isSecret).map(\.key))
            let affected = Set(values.keys).union(resetting)
            // A formerly public key becoming secret wins over stale expected
            // values, including a key whose owning domain is not registered here.
            guard affected.isDisjoint(with: document.secretKeys),
                  affected.isDisjoint(with: expected?.secretKeys ?? []) else {
                throw ClientSettingsError.secretAccessDenied
            }
            guard resetting.isDisjoint(with: values.keys) else { throw ClientSettingsError.conflictingChanges }

            var validated: [String: ClientSettingValue] = [:]
            var affectedDefinitions: [String: ClientSettingDefinition] = [:]
            for key in affected.sorted() {
                let definition = try Self.definition(key, in: definitions)
                affectedDefinitions[key] = definition
                validated[key] = try definition.validatedValue(values[key] ?? definition.defaultValue)
            }
            if let expected {
                for key in affected.sorted() {
                    guard let definition = affectedDefinitions[key], let anticipated = expected.values[key],
                          expected.storedKeys.contains(key) == (document.values[key] != nil) else {
                        throw ClientSettingsError.concurrentModification
                    }
                    do { try anticipated.validateJSON() }
                    catch { throw ClientSettingsError.concurrentModification }
                    let current = document.values[key] ?? definition.defaultValue
                    guard current.isSameJSONValue(as: anticipated) else {
                        throw ClientSettingsError.concurrentModification
                    }
                }
            }
            for (key, value) in validated {
                if resetting.contains(key) { document.values.removeValue(forKey: key) }
                else { document.values[key] = value }
            }
            // A public batch must not copy/migrate even an unrelated known
            // plaintext credential. Native registration must finish that first.
            guard document.secretKeys.isDisjoint(with: document.values.keys) else {
                throw ClientSettingsError.secretAccessDenied
            }
            var committed = try self.resolvePublic(document, definitions: definitions, cached: cached, validated: validated)
            if document != original || (document.legacy && !definitions.isEmpty) {
                committed.error = try ClientSettingsFile.write(document, at: url, afterReplace: self.afterFileReplace)
            }
            return (self.publish(committed), committed.error)
        }
    }

    /// Refresh public values from the candidate/file, retaining the last native
    /// credential cache. Used for public batch recovery too: no Keychain I/O.
    private func resolvePublic(_ document: ClientSettingsFile.Document, definitions: [ClientSettingDefinition],
                               cached: Cache, validated: [String: ClientSettingValue] = [:]) throws -> Cache {
        var result = Cache()
        result.definitions = definitions
        result.secretKeys = document.secretKeys.union(cached.secretKeys).union(definitions.filter(\.isSecret).map(\.key))
        for definition in definitions {
            let key = definition.key
            if result.secretKeys.contains(key) {
                result.values[key] = cached.values[key] ?? definition.defaultValue
                if cached.storedKeys.contains(key) { result.storedKeys.insert(key) }
            } else {
                if let value = validated[key] {
                    result.values[key] = value
                } else {
                    result.values[key] = try definition.validatedValue(document.values[key] ?? definition.defaultValue)
                }
                if document.values[key] != nil { result.storedKeys.insert(key) }
            }
        }
        return result
    }

    private func runLocked(_ operation: Operation) throws -> Cache {
        var definitions = self.registeredDefinitions
        if case let .configure(url, secretStore) = operation {
            // Clear the previous target even for an invalid URL.
            self.storageURL = nil
            guard url.isFileURL, !url.hasDirectoryPath, !url.lastPathComponent.isEmpty else {
                throw ClientSettingsError.invalidStorageURL
            }
            self.storageURL = url.standardizedFileURL
            if let secretStore { self.secretStore = secretStore }
        }
        if case let .register(additions) = operation {
            for definition in additions {
                try definition.validateDefinition()
                if let index = definitions.firstIndex(where: { $0.key == definition.key }) {
                    guard definition.canReplace(definitions[index]) else { throw ClientSettingsError.conflictingDefinition(key: definition.key) }
                    definitions[index] = definition
                } else {
                    definitions.append(definition)
                }
            }
        }
        guard let url = self.storageURL else { throw ClientSettingsError.notConfigured }
        self.cacheLock.lock()
        let protectedSecretKeys = self.cache.secretKeys
        self.cacheLock.unlock()
        let result: Cache = try ClientSettingsFile.withLock(at: url) {
            var document = try ClientSettingsFile.read(at: url)
            let original = document
            document.secretKeys.formUnion(protectedSecretKeys)
            var requestedSecrets: [String: SecretMutation] = [:]
            switch operation {
            case let .set(key, value), let .setPublic(key, value):
                let definition = try Self.definition(key, in: definitions)
                if case .setPublic = operation, definition.isSecret || document.secretKeys.contains(key) {
                    throw ClientSettingsError.secretAccessDenied
                }
                let validated = try definition.validatedValue(value)
                if definition.isSecret {
                    requestedSecrets[key] = validated == definition.defaultValue ? .delete : .set(validated)
                } else {
                    document.values[key] = validated
                }
            case let .reset(key):
                let definition = try Self.definition(key, in: definitions)
                document.values.removeValue(forKey: key)
                if definition.isSecret { requestedSecrets[key] = .delete }
            case let .migrateKey(oldKey, key):
                guard ClientSettingDefinition.isValidKey(oldKey), oldKey != key,
                      !document.secretKeys.contains(oldKey),
                      !definitions.contains(where: { $0.key == oldKey && $0.isSecret }) else {
                    throw ClientSettingsError.invalidKey
                }
                let definition = try Self.definition(key, in: definitions)
                if let old = document.values.removeValue(forKey: oldKey), document.values[key] == nil {
                    document.values[key] = try definition.validatedValue(old)
                }
            default:
                break
            }

            // Validate every candidate before either backend is modified.
            var next = Cache()
            next.definitions = definitions
            var secretWrites: [(String, Data?)] = []
            for definition in definitions {
                let key = definition.key
                if !definition.isSecret {
                    guard !document.secretKeys.contains(key) else {
                        // A build must not downgrade an older secret to plaintext.
                        throw ClientSettingsError.conflictingDefinition(key: key)
                    }
                    next.values[key] = try definition.validatedValue(document.values[key] ?? definition.defaultValue)
                    if document.values[key] != nil { next.storedKeys.insert(key) }
                    continue
                }
                document.secretKeys.insert(key)
                let previous: ClientSettingValue?
                do { previous = try self.readSecret(key, definition: definition) }
                catch ClientSettingsError.invalidSecret where requestedSecrets[key] != nil {
                    // An explicit replacement/reset can repair a corrupt secure
                    // item; ordinary reads never discard it or invent a default.
                    previous = nil
                }
                let plaintext = document.values.removeValue(forKey: key)
                let desired: ClientSettingValue?
                switch requestedSecrets[key] {
                case let .set(value): desired = value
                case .delete: desired = nil
                case nil:
                    if let previous {
                        desired = previous
                    } else if let plaintext {
                        let validated = try definition.validatedValue(plaintext)
                        desired = validated == definition.defaultValue ? nil : validated
                    } else {
                        desired = nil
                    }
                }
                if desired != previous || requestedSecrets[key] != nil {
                    let data: Data?
                    if let desired {
                        do { data = try JSONEncoder().encode(desired) }
                        catch { throw ClientSettingsError.invalidSecret }
                    } else {
                        data = nil
                    }
                    secretWrites.append((key, data))
                }
                next.values[key] = desired ?? definition.defaultValue
                if desired != nil { next.storedKeys.insert(key) }
            }
            next.secretKeys = document.secretKeys

            for (key, data) in secretWrites {
                do { try self.secretStore.set(data, for: key) }
                catch { throw Self.secretError(error) }
            }
            // Loading without a schema never copies a legacy plaintext document.
            // Structural v0 -> v1 migration happens with registration/mutation.
            let upgrade = document.legacy && !definitions.isEmpty
            if document != original || upgrade {
                next.error = try ClientSettingsFile.write(document, at: url, afterReplace: self.afterFileReplace)
            }
            return next
        }
        self.registeredDefinitions = definitions
        return result
    }

    /// Read-only error recovery: no migrations, deletion or writes.
    private func resolve(_ document: ClientSettingsFile.Document, definitions: [ClientSettingDefinition]) throws -> Cache {
        var result = Cache()
        result.definitions = definitions
        result.secretKeys = document.secretKeys.union(definitions.filter(\.isSecret).map(\.key))
        for definition in definitions {
            if definition.isSecret {
                let secret = try self.readSecret(definition.key, definition: definition)
                result.values[definition.key] = secret ?? definition.defaultValue
                if secret != nil { result.storedKeys.insert(definition.key) }
            } else {
                guard !document.secretKeys.contains(definition.key) else {
                    throw ClientSettingsError.conflictingDefinition(key: definition.key)
                }
                result.values[definition.key] = try definition.validatedValue(document.values[definition.key] ?? definition.defaultValue)
                if document.values[definition.key] != nil { result.storedKeys.insert(definition.key) }
            }
        }
        return result
    }

    private func readSecret(_ key: String, definition: ClientSettingDefinition) throws -> ClientSettingValue? {
        let data: Data?
        do { data = try self.secretStore.data(for: key) }
        catch { throw Self.secretError(error) }
        guard let data else { return nil }
        do {
            return try definition.validatedValue(JSONDecoder().decode(ClientSettingValue.self, from: data))
        } catch {
            throw ClientSettingsError.invalidSecret
        }
    }

    private static func definition(_ key: String, in definitions: [ClientSettingDefinition]) throws -> ClientSettingDefinition {
        guard ClientSettingDefinition.isValidKey(key) else { throw ClientSettingsError.invalidKey }
        guard let definition = definitions.first(where: { $0.key == key }) else {
            throw ClientSettingsError.unregisteredKey(key)
        }
        return definition
    }

    private func publish(_ next: Cache) -> Change {
        self.cacheLock.lock()
        let old = self.cache
        var keys = Set(old.values.keys).union(next.values.keys).filter { old.values[$0] != next.values[$0] }
        for definition in next.definitions where !old.definitions.contains(definition) { keys.insert(definition.key) }
        keys.formUnion(old.storedKeys.symmetricDifference(next.storedKeys))
        keys.formUnion(old.secretKeys.symmetricDifference(next.secretKeys))
        self.cache = next
        let callbacks = keys.isEmpty && old.error == next.error ? [] : Array(self.observers.values)
        self.cacheLock.unlock()
        return Change(keys: keys, observers: callbacks)
    }

    private static func storageError(_ error: Error, operation: String) -> ClientSettingsError {
        if let error = error as? ClientSettingsError { return error }
        return .storageFailure(operation: operation, code: (error as NSError).code)
    }

    private static func secretError(_ error: Error) -> ClientSettingsError {
        if let error = error as? ClientSettingsError {
            switch error {
            case .secretStorageFailure, .secretStorageUnavailable, .invalidSecret: return error
            default: break
            }
        }
        // Never surface a custom backend's localizedDescription/userInfo.
        return .secretStorageFailure(status: -1)
    }
}

private enum ClientSettingsFile {
    private static let format = "exteraless.client-settings"
    private static let maximumBytes = 8 * 1024 * 1024

    struct Document: Equatable {
        var values: [String: ClientSettingValue] = [:]
        var secretKeys: Set<String> = []
        var extra: [String: ClientSettingValue] = [:]
        var legacy = false
    }

    static func read(at url: URL) throws -> Document {
        let data: Data
        do {
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > self.maximumBytes {
                throw ClientSettingsError.invalidJSON
            }
            data = try Data(contentsOf: url)
        } catch {
            let nsError = error as NSError
            if (nsError.domain == NSCocoaErrorDomain && (nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError))
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == 2) {
                return Document()
            }
            if let error = error as? ClientSettingsError { throw error }
            throw ClientSettingsError.storageFailure(operation: "read", code: nsError.code)
        }
        guard data.count <= self.maximumBytes else { throw ClientSettingsError.invalidJSON }
        let root: [String: ClientSettingValue]
        do { root = try JSONDecoder().decode([String: ClientSettingValue].self, from: data) }
        catch { throw ClientSettingsError.invalidJSON }
        guard root["$format"] != nil else {
            return Document(values: root, legacy: true)
        }
        guard root["$format"] == .string(self.format),
              case let .integer(version) = root["version"] else {
            throw ClientSettingsError.invalidJSON
        }
        guard version == 0 || version == 1 else { throw ClientSettingsError.unsupportedVersion(version) }
        guard case let .object(values) = root["values"] else { throw ClientSettingsError.invalidJSON }
        var secretKeys: Set<String> = []
        if let encoded = root["secretKeys"] {
            guard case let .array(keys) = encoded else { throw ClientSettingsError.invalidJSON }
            for key in keys {
                guard case let .string(key) = key, ClientSettingDefinition.isValidKey(key) else {
                    throw ClientSettingsError.invalidJSON
                }
                secretKeys.insert(key)
            }
        }
        // In a versioned file, marked secrets must never be in values, even when
        // this process has not registered the owning domain.
        guard secretKeys.isDisjoint(with: values.keys) else { throw ClientSettingsError.invalidJSON }
        var extra = root
        for key in ["$format", "version", "values", "secretKeys"] { extra.removeValue(forKey: key) }
        return Document(values: values, secretKeys: secretKeys, extra: extra, legacy: version == 0)
    }

    /// Returns a post-commit durability error separately so the caller still
    /// publishes the committed generation. Pre-rename failures throw normally.
    static func write(_ document: Document, at url: URL, afterReplace: (@Sendable () throws -> Void)? = nil) throws -> ClientSettingsError? {
        guard document.secretKeys.isDisjoint(with: document.values.keys) else { throw ClientSettingsError.invalidJSON }
        var root = document.extra
        root["$format"] = .string(self.format)
        root["version"] = .integer(1)
        root["values"] = .object(document.values)
        root["secretKeys"] = .array(document.secretKeys.sorted().map { .string($0) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do { data = try encoder.encode(root) }
        catch { throw ClientSettingsError.invalidJSON }
        guard data.count <= self.maximumBytes else { throw ClientSettingsError.invalidJSON }

        #if canImport(Darwin) || canImport(Glibc)
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".client-settings-\(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600)) }
        guard descriptor >= 0 else { throw self.posixError("create temporary file") }
        defer {
            _ = close(descriptor)
            _ = temporary.path.withCString { unlink($0) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                #if canImport(Darwin)
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                #else
                let count = Glibc.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw self.posixError("write") }
                offset += count
            }
        }
        try self.sync(descriptor, operation: "sync file")
        let renamed = temporary.path.withCString { source in
            url.path.withCString { destination in rename(source, destination) }
        }
        guard renamed == 0 else { throw self.posixError("replace") }
        do { try afterReplace?() }
        catch { return .storageFailure(operation: "sync directory", code: (error as NSError).code) }
        let directoryDescriptor = directory.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
        guard directoryDescriptor >= 0 else { return self.posixError("open directory after replace") }
        defer { _ = close(directoryDescriptor) }
        do { try self.sync(directoryDescriptor, operation: "sync directory") }
        catch { return error as? ClientSettingsError ?? .storageFailure(operation: "sync directory", code: -1) }
        return nil
        #else
        throw ClientSettingsError.storageFailure(operation: "unsupported durable filesystem", code: -1)
        #endif
    }

    static func withLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        var missingDirectories: [URL] = []
        var ancestor = directory
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            missingDirectories.append(ancestor)
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw ClientSettingsError.storageFailure(operation: "create directory", code: (error as NSError).code)
        }
        #if canImport(Darwin) || canImport(Glibc)
        // Sync newly created directory links too, not only the eventual file's
        // immediate parent. Otherwise a first-ever save can lose its new folder.
        for created in missingDirectories.reversed() {
            let descriptor = created.deletingLastPathComponent().path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
            guard descriptor >= 0 else { throw self.posixError("open new directory parent") }
            defer { _ = close(descriptor) }
            try self.sync(descriptor, operation: "sync new directory parent")
        }
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = lockURL.path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600)) }
        guard descriptor >= 0 else { throw self.posixError("open lock") }
        defer { _ = close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw self.posixError("lock")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
        #else
        throw ClientSettingsError.storageFailure(operation: "unsupported filesystem lock", code: -1)
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    private static func posixError(_ operation: String) -> ClientSettingsError {
        return .storageFailure(operation: operation, code: Int(errno))
    }

    private static func sync(_ descriptor: Int32, operation: String) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw self.posixError(operation)
        }
    }
    #endif
}
