import Foundation

/// One resolver per process launch. Drafts are frozen before account construction;
/// resolving after a settings edit cannot change this launch's effective identity.
public final class ClientAPILaunchResolver: @unchecked Sendable {
    private let builtin: ClientAPICredentials
    private let vault: ClientAPIVault
    private let settings: ClientSettings
    private let launchSelections: [ClientAPIEnvironment: Result<ClientAPISelection, ClientAPIError>]
    private let lock = NSLock()
    private var active: [ClientAPIAccountScope: ClientAPICredentials] = [:]

    public init(builtinApiId: Int32, builtinApiHash: String, configuration: ClientAPIConfigurationStore) throws {
        self.builtin = try ClientAPICredentials(apiId: builtinApiId, apiHash: builtinApiHash, mode: .builtIn)
        self.vault = configuration.vault
        self.settings = configuration.settings
        var selections: [ClientAPIEnvironment: Result<ClientAPISelection, ClientAPIError>] = [:]
        for environment in ClientAPIEnvironment.allCases {
            do { selections[environment] = .success(try configuration.selection(environment: environment)) }
            catch { selections[environment] = .failure((error as? ClientAPIError) ?? .settingsUnavailable) }
        }
        self.launchSelections = selections
    }

    /// existingAuthorization must come from the actual Postbox account state,
    /// before MTApiEnvironment/MTContext creation. A pre-feature authorized account
    /// with no pin is pinned to the supplied BuildConfig identity, never the draft.
    public func resolve(scope: ClientAPIAccountScope, existingAuthorization: Bool) throws -> ClientAPICredentials {
        lock.lock()
        let cached = active[scope]
        lock.unlock()
        if let cached { return cached }
        // Core settings observers run outside their own locks and may re-enter.
        // Never hold our cache lock across registration, Keychain I/O or CAS.
        let marker = try markerSnapshot(scope)
        if let credentials = try vault.pin(for: scope) {
            try confirmMarker(credentials, scope: scope, expected: marker)
            return cache(credentials, scope: scope)
        }
        // A missing item is not necessarily a legacy account: re-signing, an
        // access-group mismatch or Keychain loss can make an existing pin vanish.
        // The public marker contains no hash and prevents a silent built-in switch.
        guard !marker.storedKeys.contains(markerKey(scope)) else { throw ClientAPIError.invalidSecureRecord }
        let proposed: ClientAPICredentials
        if existingAuthorization { proposed = builtin }
        else {
            guard let selection = launchSelections[scope.environment] else { throw ClientAPIError.bootstrapRequired }
            switch try selection.get() {
            case .builtIn: proposed = builtin
            case let .custom(credentials): proposed = credentials
            }
        }
        // SecItemAdd wins atomically against an extension/another account loader.
        // Publish to memory only after the complete tuple is durably owned.
        let pinned = try vault.pin(proposed, for: scope)
        try confirmMarker(pinned, scope: scope, expected: marker)
        return cache(pinned, scope: scope)
    }

    public func makeEnvironment<Environment>(scope: ClientAPIAccountScope, existingAuthorization: Bool,
                                             factory: (Int32, String) throws -> Environment) throws -> Environment {
        try resolve(scope: scope, existingAuthorization: existingAuthorization).withAPITuple(factory)
    }

    private func markerKey(_ scope: ClientAPIAccountScope) -> String {
        "clientAPI.accountIdentity.\(scope.environment.rawValue).\(scope.recordId)"
    }

    private func cache(_ credentials: ClientAPICredentials, scope: ClientAPIAccountScope) -> ClientAPICredentials {
        lock.lock()
        defer { lock.unlock() }
        if let current = active[scope] { return current }
        active[scope] = credentials
        return credentials
    }

    private func markerSnapshot(_ scope: ClientAPIAccountScope) throws -> ClientSettingsSnapshot {
        do {
            try settings.register([.init(key: markerKey(scope), title: "Pinned account API generation", section: "Client API state",
                defaultValue: .object([:]), explanation: "Native account identity marker; contains no App hash.")])
            return settings.readSnapshot()
        } catch { throw ClientAPIError.settingsUnavailable }
    }

    private func confirmMarker(_ credentials: ClientAPICredentials, scope: ClientAPIAccountScope,
                               expected: ClientSettingsSnapshot) throws {
        let key = markerKey(scope)
        let value = ClientSettingValue.object(["apiId": .integer(Int64(credentials.apiId)),
            "mode": .integer(Int64(credentials.mode.rawValue)), "generation": .string(credentials.generation.uuidString)])
        if expected.storedKeys.contains(key) {
            guard expected.values[key] == value else { throw ClientAPIError.invalidSecureRecord }
            return
        }
        do { try settings.applyPublic([key: value], expected: expected) }
        catch {
            // Another account loader can publish the SAME atomically won pin.
            let current = settings.readSnapshot()
            guard current.storedKeys.contains(key), current.values[key] == value else { throw ClientAPIError.settingsUnavailable }
        }
    }
}
