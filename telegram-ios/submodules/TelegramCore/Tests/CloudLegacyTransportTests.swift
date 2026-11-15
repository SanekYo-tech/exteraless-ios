import ExteralessCore
import Foundation
import XCTest
@testable import TelegramCore

private actor CloudLegacyOfflineTransport: CloudKeyValueTransport {
    private var values: [String: String]
    private var replacement: String?
    private(set) var writes = 0

    init(payload: String, replacement: String? = nil) {
        self.values = ["neko_settings": "1", "neko_settings_encoding": "gzip_base64_v1", "neko_settings_updated_at": "7", "neko_settings_0": payload]
        self.replacement = replacement
    }
    func keys() async throws -> [String] { Array(values.keys) }
    func get(_ keys: [String]) async throws -> [String: String] {
        let result = values.filter { keys.contains($0.key) }
        if keys.contains("neko_settings_0"), let replacement {
            values["neko_settings_0"] = replacement
            self.replacement = nil
        }
        return result
    }
    func set(key: String, value: String) async throws { writes += 1; throw CloudError.network }
    func remove(_ keys: [String]) async throws { writes += 1; throw CloudError.network }
}

private struct CloudLegacyNoSecrets: ClientSecretStore {
    func data(for key: String) throws -> Data? { nil }
    func set(_ data: Data?, for key: String) throws { throw CloudError.secureStorage }
}

final class CloudLegacyTransportTests: XCTestCase, @unchecked Sendable {
    func testTinyOriginalGzipBase64SharedPrefsPreviewUsesNoAccountOrNetwork() async throws {
        let bytes = Data(#"{"nkmrcfg":{"showSeconds":true,"OEChatsFlashIntensity":50}}"#.utf8)
        let compressed = try ExteralessCloudTransport.compression.compress(bytes)
        let transport = CloudLegacyOfflineTransport(payload: compressed.base64EncodedString())
        let owner = CloudRemoteOwner(userId: 4001, environment: .production)
        let remote = CloudRemoteStore(owner: owner, transport: transport, compression: ExteralessCloudTransport.compression)
        let legacy = try await remote.readAndroidSnapshot()
        let definitions = (AppearanceFeatures.definitions + ToolsFeatures.definitions).filter {
            ["appearance.showSeconds", "tools.flashIntensity"].contains($0.key)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-cloud-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = try ClientSettings(storageURL: root.appendingPathComponent("settings.json"), secretStore: CloudLegacyNoSecrets())
        try settings.register(definitions)
        let plan = try CloudLegacySettingsArchive.inspect(legacy, snapshot: settings.readSnapshot(), includeApiKeys: false)
        XCTAssertEqual(plan.settingCount, 2)
        XCTAssertEqual(plan.publicInspection.settings["tools.flashIntensity"], .integer(50))
        XCTAssertEqual(plan.reportedUpdatedAtMilliseconds, 7)
        let writes = await transport.writes
        XCTAssertEqual(writes, 0)
    }

    func testSameMetadataDifferentChunksRejectsTheLegacyPreview() async throws {
        let first = try ExteralessCloudTransport.compression.compress(Data(#"{"nkmrcfg":{"showSeconds":true}}"#.utf8))
        let second = try ExteralessCloudTransport.compression.compress(Data(#"{"nkmrcfg":{"showSeconds":false}}"#.utf8))
        let transport = CloudLegacyOfflineTransport(payload: first.base64EncodedString(), replacement: second.base64EncodedString())
        let remote = CloudRemoteStore(owner: .init(userId: 4001, environment: .production), transport: transport,
                                      compression: ExteralessCloudTransport.compression)
        do { _ = try await remote.readAndroidSnapshot(); XCTFail("Mixed legacy generations must not produce a preview") }
        catch { XCTAssertEqual(error as? CloudError, .conflict) }
        let writes = await transport.writes
        XCTAssertEqual(writes, 0)
    }
}
