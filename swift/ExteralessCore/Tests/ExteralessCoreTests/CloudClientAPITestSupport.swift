import Foundation
import XCTest
@testable import ExteralessCore

final class CloudFixtureSecrets: ClientSecretStore, CloudCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var reads: [String] = []
    private var readFailure = false
    private var insertFailure = false

    func data(for key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        reads.append(key)
        if readFailure { throw ClientSettingsError.secretStorageUnavailable }
        return values[key]
    }

    func set(_ data: Data?, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = data
    }

    func read(_ id: CloudCredentialID) throws -> String? {
        guard let bytes = try data(for: id.settingKey) else { return nil }
        guard case let .string(value) = try JSONDecoder().decode(ClientSettingValue.self, from: bytes) else { throw CloudError.invalidCredential }
        return value
    }

    func insertIfAbsent(_ entry: CloudCredentialEntry) throws -> CloudCredentialInsertResult {
        lock.lock(); defer { lock.unlock() }
        if insertFailure { throw CloudError.secureStorage }
        if values[entry.id.settingKey] != nil { return .alreadyPresent }
        values[entry.id.settingKey] = try entry.withValue { try JSONEncoder().encode(ClientSettingValue.string($0)) }
        return .inserted
    }

    func failReads(_ value: Bool) { lock.lock(); readFailure = value; lock.unlock() }
    func failInserts(_ value: Bool) { lock.lock(); insertFailure = value; lock.unlock() }
    func resetReads() { lock.lock(); reads = []; lock.unlock() }
    func readKeys() -> [String] { lock.lock(); defer { lock.unlock() }; return reads }
}

final class ClientAPIFixtureStorage: ClientAPISecureStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var unavailable = false

    func read(_ key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if unavailable { throw ClientAPIError.secureStorageUnavailable }
        return values[key]
    }

    func write(_ data: Data?, key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if unavailable { throw ClientAPIError.secureStorageUnavailable }
        values[key] = data
    }

    func insertIfAbsent(_ data: Data, key: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if unavailable { throw ClientAPIError.secureStorageUnavailable }
        if let previous = values[key] { return previous }
        values[key] = data
        return data
    }

    func setUnavailable(_ value: Bool) { lock.lock(); unavailable = value; lock.unlock() }
    func keys() -> Set<String> { lock.lock(); defer { lock.unlock() }; return Set(values.keys) }
}

final class CloudFixtureStateStorage: CloudSyncStateStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CloudAccountScope: CloudLocalState] = [:]
    private var fail = false

    func load(scope: CloudAccountScope) throws -> CloudLocalState {
        lock.lock(); defer { lock.unlock() }
        return values[scope] ?? CloudLocalState(scope: scope)
    }
    func save(_ state: CloudLocalState) throws {
        lock.lock(); defer { lock.unlock() }
        if fail { throw CloudError.localStorage }
        values[state.scope] = state
    }
    func failSaves(_ value: Bool) { lock.lock(); fail = value; lock.unlock() }
}

actor CloudFixtureTransport: CloudKeyValueTransport {
    private var values: [String: String] = [:]
    private var writeOrder: [String] = []
    private var keyCalls = 0
    private var writeAttempts = 0
    private var failWrite: Int?
    private var failKeys = false
    private var delayWrites: UInt64 = 0
    private var forkBarrier = false
    private struct Held {
        let key: String
        let value: String
        let continuation: CheckedContinuation<Void, Error>
    }
    private var held: [UUID: Held] = [:]

    func keys() async throws -> [String] {
        keyCalls += 1
        if failKeys { throw CloudError.network }
        return values.keys.sorted()
    }
    func get(_ keys: [String]) async throws -> [String: String] {
        values.filter { keys.contains($0.key) }
    }
    func set(key: String, value: String) async throws {
        writeAttempts += 1
        if writeAttempts == failWrite { throw CloudError.network }
        if delayWrites > 0 { try await Task.sleep(nanoseconds: delayWrites) }
        if forkBarrier && key.hasPrefix(CloudProtocol.nativePrefix + "r.") {
            let id = UUID()
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    held[id] = Held(key: key, value: value, continuation: continuation)
                    if held.count == 2 {
                        let ready = Array(held.values)
                        held.removeAll()
                        forkBarrier = false
                        for item in ready { values[item.key] = item.value; writeOrder.append(item.key) }
                        for item in ready { item.continuation.resume() }
                    }
                }
            }, onCancel: { Task { await self.cancelHeld(id) } })
            return
        }
        values[key] = value
        writeOrder.append(key)
    }
    func remove(_ keys: [String]) async throws { for key in keys { values.removeValue(forKey: key) } }
    func seed(_ values: [String: String]) { self.values = values }
    func replace(key: String, value: String?) { values[key] = value }
    func snapshot() -> [String: String] { values }
    func writes() -> [String] { writeOrder }
    func calls() -> (keys: Int, writes: Int) { (keyCalls, writeAttempts) }
    func failWrite(at ordinal: Int?) { failWrite = ordinal; writeAttempts = 0 }
    func failKeyRequests(_ value: Bool) { failKeys = value }
    func setWriteDelay(_ value: UInt64) { delayWrites = value }
    func holdTwoManifestWrites() { forkBarrier = true }
    private func cancelHeld(_ id: UUID) { held.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
}

actor CloudFixtureBotRPC {
    struct Call: Sendable { let method: String; let params: Data }
    private var values: [String: String] = [:]
    private var calls: [Call] = []

    func invoke(_ method: String, _ params: Data) throws -> Data {
        calls.append(Call(method: method, params: params))
        let object = try JSONDecoder().decode([String: ClientSettingValue].self, from: params)
        switch method {
        case "getStorageKeys": return try JSONEncoder().encode(values.keys.sorted())
        case "saveStorageValue":
            guard case let .string(key)? = object["key"], case let .string(value)? = object["value"] else { throw CloudError.malformedRemote }
            values[key] = value
            return Data("true".utf8)
        case "getStorageValues", "deleteStorageValues":
            guard case let .array(items)? = object["keys"] else { throw CloudError.malformedRemote }
            var result: [String: ClientSettingValue] = [:]
            for item in items {
                guard case let .string(key) = item else { throw CloudError.malformedRemote }
                result[key] = values[key].map(ClientSettingValue.string) ?? .null
                if method == "deleteStorageValues" { values.removeValue(forKey: key) }
            }
            return method == "getStorageValues" ? try JSONEncoder().encode(result) : Data("true".utf8)
        default: throw CloudError.malformedRemote
        }
    }
    func transcript() -> [Call] { calls }
}

enum CloudFixture {
    static let owner = CloudRemoteOwner(userId: 4001, environment: .production)
    static let scope = CloudAccountScope(recordId: 42, userId: 4001, environment: .production)
    static let date = Date(timeIntervalSince1970: 1_800_000_000)
    // Protocol/state fixtures inject an identity compression codec; this does not
    // claim to test gzip. CloudTransportTests exercises the real native MTGzip.
    static let compression = CloudCompression(compress: { $0 }, decompress: { bytes, maximum in
        guard bytes.count <= maximum else { throw CloudError.sizeLimit }
        return bytes
    })
    static let definitions: [ClientSettingDefinition] = [
        .init(key: "appearance.fixtureFlag", title: "Flag", section: "Appearance", defaultValue: .bool(false), androidSymbols: ["Fixture.flag"]),
        .init(key: "appearance.fixtureCount", title: "Count", section: "Appearance", defaultValue: .integer(2), androidSymbols: ["Fixture.count"]),
        .init(key: "ai.services", title: "Services", section: "AI", defaultValue: .array([]), androidSymbols: ["AiConfig.KEY_SERVICES"]),
        .init(key: "ai.serviceKey.default", title: "Service key", section: "AI credentials", defaultValue: .string(""), isSecret: true),
        .init(key: "ai.deepLTranslateKey", title: "Translation key", section: "Translation", defaultValue: .string(""), isSecret: true),
        .init(key: "ai.roles", title: "Roles", section: "AI", defaultValue: .string(""), isSecret: true),
        .init(key: "ai.history.fixture", title: "History", section: "AI private data", defaultValue: .string(""), isSecret: true)
    ] + CloudFeatures.definitions + ClientAPIFeatures.definitions

    static func installBoundAssistantKey(_ key: String, settings: ClientSettings) throws {
        let destination = try AICredentialDestination(settingKey: AIService.default.keySetting,
            baseURL: AIService.default.url, wireProtocol: AIService.default.wireProtocol)
        let value = try AICredentialBinding.updated(.replace(key), previous: "", destination: destination,
            authorizeDestinationChange: false)
        try settings.set(.string(value ?? ""), for: AIService.default.keySetting)
    }
}

extension XCTestCase {
    func cloudTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-api-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func cloudSettings(secrets: CloudFixtureSecrets = CloudFixtureSecrets()) throws -> ClientSettings {
        let settings = try ClientSettings(storageURL: cloudTemporaryDirectory().appendingPathComponent("settings.json"), secretStore: secrets)
        try settings.register(CloudFixture.definitions)
        return settings
    }
}
