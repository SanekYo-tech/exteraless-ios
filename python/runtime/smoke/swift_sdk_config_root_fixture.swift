import ExteralessCore
import Foundation

/// Disposable secret storage for the fixture's whole registered client schema.
/// No production Keychain item or account directory is accessed.
private final class SDKConfigFixtureSecrets: ClientSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func data(for key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func set(_ data: Data?, for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = data }
}

/// Uses ONLY the actual root expression staged by the driver. There is no
/// ExteraConfigCompatibility-only registration which could hide SDK-01.
final class SDKConfigRootFixture {
    private let url: URL
    private let secrets: SDKConfigFixtureSecrets
    private var settings: ClientSettings

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("client-settings.json")
        let secrets = SDKConfigFixtureSecrets()
        self.url = url
        self.secrets = secrets
        settings = try ClientSettings(storageURL: url, secretStore: secrets)
        try settings.register(SDKConfigRootRegistration.definitions)
        try requireRegisteredCompatibility()
    }

    private func requireRegisteredCompatibility() throws {
        let keys = Set(settings.definitions().map(\.key))
        guard ExteraConfigCompatibility.keys.count == 22, ExteraConfigCompatibility.keys.isSubset(of: keys) else {
            throw BridgeFailure.unavailable("Actual root registration omitted the 22 global Config definitions")
        }
    }

    func provider(callbacks: PluginCallbackDispatcher) -> ClientSettingsBridgeExtension {
        ClientSettingsBridgeExtension(settings: settings, permits: { callbacks.hasPermission($0, $1) })
    }

    func reopen() throws {
        settings = try ClientSettings(storageURL: url, secretStore: secrets)
        try settings.register(SDKConfigRootRegistration.definitions)
        try requireRegisteredCompatibility()
    }
}
