import Foundation

/// Native editor + bootstrap access. An interrupted multi-store save leaves a
/// Keychain marker; a fresh login must not use an old ID with a newly written hash.
public final class ClientAPIConfigurationStore: @unchecked Sendable {
    public let settings: ClientSettings
    public let vault: ClientAPIVault
    private let settingsSecrets: any ClientSecretStore
    // The main-process native editor is the only writer. Multiple editor
    // instances serialize the Keychain-marker + public-file sequence.
    private static let configurationLock = NSRecursiveLock()
    private var lock: NSRecursiveLock { Self.configurationLock }

    public init(settings: ClientSettings = .shared,
                settingsSecrets: any ClientSecretStore = ClientSecrets.systemStore(),
                vault: ClientAPIVault = ClientAPIVault()) {
        self.settings = settings
        self.settingsSecrets = settingsSecrets
        self.vault = vault
    }

    public func register() throws { try settings.register(ClientAPIFeatures.definitions) }

    /// Explicit, destination-wins migration of the three original preference
    /// aliases already present in the selected settings file; no Android file scan.
    public func migrateAndroidAliases() throws {
        try register()
        for (old, new) in [("custom_api", "customApi"), ("custom_app_id", "customAppId"), ("custom_app_hash", "customAppHash")] {
            try settings.migrateKey(from: old, to: ClientAPIEnvironment.production.settingPrefix + new)
        }
    }

    public func summary(environment: ClientAPIEnvironment) throws -> ClientAPIDraftSummary {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = settings.readSnapshot()
        let pending = try vault.pending(environment)
        let prefix = environment.settingPrefix
        let mode = pending?.mode ?? Self.mode(snapshot, prefix: prefix)
        let id = pending?.apiId ?? Self.id(snapshot, prefix: prefix)
        return ClientAPIDraftSummary(mode: mode, apiId: id,
            hashIsSet: pending?.replacementHash != nil || snapshot.storedKeys.contains(prefix + "customAppHash"),
            requiresRepair: pending != nil)
    }

    func selection(environment: ClientAPIEnvironment) throws -> ClientAPISelection {
        lock.lock()
        defer { lock.unlock() }
        guard try vault.pending(environment) == nil else { throw ClientAPIError.incompleteSave }
        let before = settings.readSnapshot()
        guard before.lastError == nil else { throw ClientAPIError.settingsUnavailable }
        let prefix = environment.settingPrefix
        guard before.values[prefix + "customApi"] != nil else { throw ClientAPIError.bootstrapRequired }
        if Self.mode(before, prefix: prefix) == .builtIn { return .builtIn }
        let id = Self.id(before, prefix: prefix)
        let hash = try readHash(prefix: prefix)
        let after = settings.readSnapshot()
        guard before.values[prefix + "customApi"] == after.values[prefix + "customApi"],
              before.values[prefix + "customAppId"] == after.values[prefix + "customAppId"] else {
            throw ClientAPIError.concurrentEdit
        }
        return .custom(try ClientAPICredentials(apiId: id, apiHash: hash, mode: .custom))
    }

    /// Empty replacementHash retains the existing hash only for the same ID.
    /// Built-in mode retains the draft, and never rebinds an account or network.
    public func save(mode: ClientAPIMode, apiId: Int32, replacementHash: String?,
                     environment: ClientAPIEnvironment, expected: ClientSettingsSnapshot? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        let before = settings.readSnapshot()
        let prefix = environment.settingPrefix
        let pending = try vault.pending(environment)
        var replacement = replacementHash?.trimmingCharacters(in: .whitespacesAndNewlines)
        if replacement?.isEmpty == true { replacement = nil }
        if replacement == nil, pending?.apiId == apiId { replacement = pending?.replacementHash }
        if let replacement, !ClientAPICredentials.validHash(replacement) { throw ClientAPIError.invalidAppHash }
        if mode == .custom {
            guard apiId > 0 else { throw ClientAPIError.invalidAppId }
            if replacement == nil {
                guard Self.id(before, prefix: prefix) == apiId else { throw ClientAPIError.missingAppHash }
                _ = try ClientAPICredentials(apiId: apiId, apiHash: readHash(prefix: prefix), mode: .custom)
            }
        } else if apiId < 0 { throw ClientAPIError.invalidAppId }
        let draft = ClientAPIPendingDraft(version: 1, mode: mode, apiId: apiId, replacementHash: replacement)
        try vault.setPending(draft, environment: environment)
        do {
            if let replacement { try settings.set(.string(replacement), for: prefix + "customAppHash") }
            try settings.applyPublic([prefix + "customApi": .integer(Int64(mode.rawValue)),
                                      prefix + "customAppId": .integer(Int64(apiId))], expected: expected ?? before)
            try vault.setPending(nil, environment: environment)
        } catch {
            // Keep the recoverable draft. In particular, a public write may have
            // renamed its file before reporting a durability failure.
            throw ClientAPIError.incompleteSave
        }
    }

    private func readHash(prefix: String) throws -> String {
        let bytes: Data?
        do { bytes = try settingsSecrets.data(for: prefix + "customAppHash") }
        catch { throw ClientAPIError.secureStorageUnavailable }
        guard let bytes else { throw ClientAPIError.missingAppHash }
        guard bytes.count <= 256, let value = try? JSONDecoder().decode(ClientSettingValue.self, from: bytes),
              case let .string(hash) = value, ClientAPICredentials.validHash(hash) else {
            throw ClientAPIError.invalidAppHash
        }
        return hash
    }

    private static func mode(_ snapshot: ClientSettingsSnapshot, prefix: String) -> ClientAPIMode {
        snapshot.values[prefix + "customApi"] == .integer(3) ? .custom : .builtIn
    }

    private static func id(_ snapshot: ClientSettingsSnapshot, prefix: String) -> Int32 {
        guard case let .integer(value)? = snapshot.values[prefix + "customAppId"], let id = Int32(exactly: value) else { return 0 }
        return id
    }
}
