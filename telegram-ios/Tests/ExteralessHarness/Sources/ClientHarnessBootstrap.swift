import ExteralessCore
import Foundation
import TelegramCore

/// Test-only private storage for SYNTHETIC API identities. No system Keychain
/// backend is constructed. The native resolver still owns pin/marker admission.
private final class ClientHarnessPrivateStore: ClientSecretStore, ClientAPISecureStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(for key: String) throws -> Data? { try self.read(key) }
    func set(_ data: Data?, for key: String) throws { try self.write(data, key: key) }
    func read(_ key: String) throws -> Data? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.values[key]
    }
    func write(_ data: Data?, key: String) throws {
        self.lock.lock(); defer { self.lock.unlock() }
        self.values[key] = data
    }
    func insertIfAbsent(_ data: Data, key: String) throws -> Data {
        self.lock.lock(); defer { self.lock.unlock() }
        if let current = self.values[key] { return current }
        self.values[key] = data
        return data
    }
}

enum ClientHarnessBootstrap {
    /// Must complete before HarnessAccount.make() opens either Postbox writer.
    /// .mainApplication is the actual process role; supplementary only controls
    /// Telegram synchronization. No retention readiness/maintenance is bypassed.
    static func prepare(directory: URL, domain: Bool, scenario: String? = nil) throws {
        let privateStore = ClientHarnessPrivateStore()
        let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        try ClientSettings.shared.configure(storageURL: directory.appendingPathComponent("native-client-settings.json"),
            secretStore: privateStore, durabilityRootURL: container)
        try ClientSettings.shared.register(RetentionFeatures.definitions)
        if domain {
            try ClientSettings.shared.register(ChatFeatures.definitions + FeedFeatures.definitions
                + PlayerFeatures.definitions + PillFeatures.definitions)
            // Native providers read this real, isolated store. No remote provider
            // or media playback is selected by any domain fixture.
            try ClientSettings.shared.applyPublic([
                "appearance.lrclibAllowed": .bool(false),
                "chats.activePillsRaw": .string(""), "chats.hiddenPillsRaw": .string("5"),
                "chats.lastActivePillId": .integer(-1), "chats.rateInstancesMigrated": .bool(true),
                "chats.weatherUseCurrentLocation": .bool(false)
            ], expected: ClientSettings.shared.readSnapshot())
        }
        if scenario == "avatar-render" {
            try ClientSettings.shared.register(AppearanceFeatures.definitions)
        } else if scenario == "composer-render" {
            try ClientSettings.shared.register(ChatFeatures.definitions)
            try ClientSettings.shared.applyPublic([
                "chats.showTextCreateDate": .bool(true),
                "chats.stripTrackingOnPaste": .bool(true),
                "chats.disableMarkdown": .bool(false)
            ], expected: ClientSettings.shared.readSnapshot())
        }
        let retention = try ExteralessRetentionProcessConfiguration(role: .mainApplication,
            snapshot: ClientSettings.shared.readSnapshot(), durabilityRootURL: container)
        try ExteralessAccountRetentionEnvironment.shared.configure(retention)
        let configuration = ClientAPIConfigurationStore(settings: .shared, settingsSecrets: privateStore,
            vault: ClientAPIVault(storage: privateStore))
        // Validly shaped but synthetic. It is never a user's API/account tuple.
        try ExteralessClientAPIEnvironment.shared.configure(builtinApiId: 1,
            builtinApiHash: "11111111111111111111111111111111", configuration: configuration)
    }
}
