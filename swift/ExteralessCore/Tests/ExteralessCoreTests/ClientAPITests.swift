import Foundation
import XCTest
@testable import ExteralessCore

final class ClientAPITests: XCTestCase {
    // Deliberately synthetic; no real account or build credentials are loaded.
    private let builtinHash = String(repeating: "a", count: 32)
    private let customHash = String(repeating: "b", count: 32)
    private let changedHash = String(repeating: "c", count: 32)

    private func fixture() throws -> (ClientAPIConfigurationStore, CloudFixtureSecrets, ClientAPIFixtureStorage) {
        let secrets = CloudFixtureSecrets()
        let settings = try cloudSettings(secrets: secrets)
        let secure = ClientAPIFixtureStorage()
        return (ClientAPIConfigurationStore(settings: settings, settingsSecrets: secrets, vault: ClientAPIVault(storage: secure)), secrets, secure)
    }

    private func launch(_ configuration: ClientAPIConfigurationStore) throws -> ClientAPILaunchResolver {
        try ClientAPILaunchResolver(builtinApiId: 100_001, builtinApiHash: builtinHash, configuration: configuration)
    }

    func testOriginalSelectorDefaultsAndBuiltInLaunchSelectionSkipsCustomHash() throws {
        let (configuration, secrets, _) = try fixture()
        let defaults = configuration.settings.readSnapshot()
        XCTAssertEqual(defaults.values["clientAPI.customApi"], .integer(0))
        XCTAssertEqual(defaults.values["clientAPI.customAppId"], .integer(0))
        XCTAssertEqual(defaults.values["clientAPI.customAppHash"], .null)
        let definition = try XCTUnwrap(ClientAPIFeatures.definitions.first { $0.key == "clientAPI.customApi" })
        XCTAssertEqual(definition.options.map(\.value), [.integer(0), .integer(3)])
        secrets.resetReads()
        let resolver = try launch(configuration)
        XCTAssertTrue(secrets.readKeys().isEmpty)
        let matches = try resolver.makeEnvironment(scope: .init(recordId: 1, environment: .production), existingAuthorization: false) {
            $0 == 100_001 && $1 == self.builtinHash
        }
        XCTAssertTrue(matches)
    }

    func testFreshKeychainValueReachesInjectedNativeEnvironmentFactory() throws {
        let (configuration, secrets, _) = try fixture()
        try configuration.save(mode: .custom, apiId: 200_002, replacementHash: customHash, environment: .production)
        XCTAssertEqual(configuration.settings.snapshot()["clientAPI.customAppHash"], .null)
        secrets.resetReads()
        let resolver = try launch(configuration)
        XCTAssertEqual(secrets.readKeys(), ["clientAPI.customAppHash"])
        var called = false
        let matches = try resolver.makeEnvironment(scope: .init(recordId: 2, environment: .production), existingAuthorization: false) { id, hash in
            called = true
            return id == 200_002 && hash == self.customHash
        }
        XCTAssertTrue(called && matches)
    }

    func testExistingAuthorizationAndInProgressLoginKeepPinnedGenerationsAcrossRestart() throws {
        let (configuration, _, _) = try fixture()
        try configuration.save(mode: .custom, apiId: 200_002, replacementHash: customHash, environment: .production)
        let first = try launch(configuration)
        let existingScope = ClientAPIAccountScope(recordId: 1, environment: .production)
        let loginScope = ClientAPIAccountScope(recordId: 2, environment: .production)
        let existing = try first.resolve(scope: existingScope, existingAuthorization: true)
        let login = try first.resolve(scope: loginScope, existingAuthorization: false)
        XCTAssertEqual(existing.apiId, 100_001)
        XCTAssertEqual(login.apiId, 200_002)
        try configuration.save(mode: .custom, apiId: 300_003, replacementHash: changedHash, environment: .production)
        let sameLaunch = try first.resolve(scope: .init(recordId: 3, environment: .production), existingAuthorization: false)
        XCTAssertEqual(sameLaunch.apiId, 200_002)
        let restarted = try launch(configuration)
        XCTAssertEqual(try restarted.resolve(scope: existingScope, existingAuthorization: true).generation, existing.generation)
        XCTAssertEqual(try restarted.resolve(scope: loginScope, existingAuthorization: false).generation, login.generation)
        let next = try restarted.resolve(scope: .init(recordId: 4, environment: .production), existingAuthorization: false)
        XCTAssertTrue(next.withAPITuple { $0 == 300_003 && $1 == changedHash })
    }

    func testDisableRetainsDraftAndOnlyFutureFlowsUseBuiltIn() throws {
        let (configuration, secrets, _) = try fixture()
        try configuration.save(mode: .custom, apiId: 200_002, replacementHash: customHash, environment: .production)
        let scope = ClientAPIAccountScope(recordId: 3, environment: .production)
        let pinned = try launch(configuration).resolve(scope: scope, existingAuthorization: false)
        try configuration.save(mode: .builtIn, apiId: 200_002, replacementHash: nil, environment: .production)
        let summary = try configuration.summary(environment: .production)
        XCTAssertEqual(summary.mode, .builtIn)
        XCTAssertEqual(summary.apiId, 200_002)
        XCTAssertTrue(summary.hashIsSet)
        let hash = try secrets.data(for: "clientAPI.customAppHash")
        XCTAssertNotNil(hash)
        let restarted = try launch(configuration)
        XCTAssertEqual(try restarted.resolve(scope: scope, existingAuthorization: true).generation, pinned.generation)
        XCTAssertEqual(try restarted.resolve(scope: .init(recordId: 4, environment: .production), existingAuthorization: false).apiId, 100_001)
    }

    func testProductionAndTestDraftsAndAccountPinsAreDifferentNamespaces() throws {
        let (configuration, _, secure) = try fixture()
        try configuration.save(mode: .custom, apiId: 200_002, replacementHash: customHash, environment: .production)
        try configuration.save(mode: .custom, apiId: 300_003, replacementHash: changedHash, environment: .test)
        let resolver = try launch(configuration)
        let production = try resolver.resolve(scope: .init(recordId: 9, environment: .production), existingAuthorization: false)
        let test = try resolver.resolve(scope: .init(recordId: 9, environment: .test), existingAuthorization: false)
        XCTAssertTrue(production.withAPITuple { $0 == 200_002 && $1 == customHash })
        XCTAssertTrue(test.withAPITuple { $0 == 300_003 && $1 == changedHash })
        XCTAssertNotEqual(production.generation, test.generation)
        XCTAssertTrue(secure.keys().contains("pin.v1.production.9"))
        XCTAssertTrue(secure.keys().contains("pin.v1.test.9"))
    }

    func testLockedKeychainNeverSilentlySelectsBuiltInForACustomLogin() throws {
        let (configuration, secrets, secure) = try fixture()
        try configuration.save(mode: .custom, apiId: 200_002, replacementHash: customHash, environment: .production)
        let existing = ClientAPIAccountScope(recordId: 10, environment: .production)
        _ = try launch(configuration).resolve(scope: existing, existingAuthorization: true)
        secrets.failReads(true) // Cache still contains a value: bootstrap must not use it.
        let resolver = try launch(configuration)
        XCTAssertThrowsError(try resolver.resolve(scope: .init(recordId: 11, environment: .production), existingAuthorization: false)) {
            XCTAssertTrue([ClientAPIError.secureStorageUnavailable, .settingsUnavailable].contains($0 as? ClientAPIError ?? .bootstrapRequired))
        }
        secrets.failReads(false)
        XCTAssertEqual(try resolver.resolve(scope: existing, existingAuthorization: true).apiId, 100_001)
        secure.setUnavailable(true)
        // An already admitted account can keep its in-memory pinned identity.
        XCTAssertEqual(try resolver.resolve(scope: existing, existingAuthorization: true).apiId, 100_001)
        XCTAssertThrowsError(try resolver.resolve(scope: .init(recordId: 12, environment: .production), existingAuthorization: true))
    }

    func testInterruptedSaveCannotPairOldIdWithNewHashAndRepairRetainsDraft() throws {
        let (configuration, _, _) = try fixture()
        try configuration.save(mode: .custom, apiId: 200_002, replacementHash: customHash, environment: .production)
        let scope = ClientAPIAccountScope(recordId: 15, environment: .production)
        let pinned = try launch(configuration).resolve(scope: scope, existingAuthorization: false)
        let stale = configuration.settings.readSnapshot()
        try configuration.settings.applyPublic(["clientAPI.customAppId": .integer(222_222)])
        XCTAssertThrowsError(try configuration.save(mode: .custom, apiId: 300_003, replacementHash: changedHash, environment: .production, expected: stale)) {
            XCTAssertEqual($0 as? ClientAPIError, .incompleteSave)
        }
        XCTAssertTrue(try configuration.summary(environment: .production).requiresRepair)
        let blocked = try launch(configuration)
        XCTAssertThrowsError(try blocked.resolve(scope: .init(recordId: 16, environment: .production), existingAuthorization: false)) {
            XCTAssertEqual($0 as? ClientAPIError, .incompleteSave)
        }
        XCTAssertEqual(try blocked.resolve(scope: scope, existingAuthorization: true).generation, pinned.generation)
        // Blank input recovers the typed pending draft, not an unrelated cached key.
        try configuration.save(mode: .custom, apiId: 300_003, replacementHash: nil, environment: .production)
        XCTAssertFalse(try configuration.summary(environment: .production).requiresRepair)
        XCTAssertTrue(try launch(configuration).resolve(scope: .init(recordId: 17, environment: .production), existingAuthorization: false)
            .withAPITuple { $0 == 300_003 && $1 == changedHash })
    }

    func testInvalidDraftsDoNotCreatePendingRecordsAndDescriptionsHideHash() throws {
        let (configuration, _, secure) = try fixture()
        XCTAssertThrowsError(try configuration.save(mode: .custom, apiId: 0, replacementHash: customHash, environment: .production))
        XCTAssertThrowsError(try configuration.save(mode: .custom, apiId: 123, replacementHash: "not-a-hash", environment: .production))
        XCTAssertThrowsError(try configuration.save(mode: .custom, apiId: 123, replacementHash: nil, environment: .production))
        XCTAssertTrue(secure.keys().isEmpty)
        let credentials = try ClientAPICredentials(apiId: 123, apiHash: customHash, mode: .custom)
        XCTAssertFalse(String(describing: credentials).contains(customHash))
        XCTAssertFalse(String(reflecting: credentials).contains(customHash))
        XCTAssertFalse(Mirror(reflecting: credentials).children.contains { String(describing: $0.value).contains(customHash) })
        XCTAssertThrowsError(try ClientAPILaunchResolver(builtinApiId: 0, builtinApiHash: "", configuration: configuration)) {
            XCTAssertEqual($0 as? ClientAPIError, .builtInUnavailable)
        }
    }

    func testOriginalPreferenceAliasesMigrateWithoutExportingHash() throws {
        let root = try cloudTemporaryDirectory()
        let file = root.appendingPathComponent("settings.json")
        try JSONEncoder().encode(["custom_api": ClientSettingValue.integer(3), "custom_app_id": .integer(234_567),
                                  "custom_app_hash": .string(customHash)]).write(to: file)
        let secrets = CloudFixtureSecrets()
        let settings = try ClientSettings(storageURL: file, secretStore: secrets)
        let configuration = ClientAPIConfigurationStore(settings: settings, settingsSecrets: secrets,
                                                       vault: ClientAPIVault(storage: ClientAPIFixtureStorage()))
        try configuration.migrateAndroidAliases()
        XCTAssertTrue(try launch(configuration).resolve(scope: .init(recordId: 20, environment: .production), existingAuthorization: false)
            .withAPITuple { $0 == 234_567 && $1 == customHash })
        let exported = try settings.exportJSON()
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains(customHash))
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(customHash))
    }

    func testMissingPreviouslyPinnedKeychainItemCannotAdoptBuiltInIdentity() throws {
        let (configuration, _, secure) = try fixture()
        try configuration.save(mode: .custom, apiId: 200_002, replacementHash: customHash, environment: .production)
        let scope = ClientAPIAccountScope(recordId: 31, environment: .production)
        _ = try launch(configuration).resolve(scope: scope, existingAuthorization: false)
        try secure.write(nil, key: "pin.v1.production.31")
        XCTAssertThrowsError(try launch(configuration).resolve(scope: scope, existingAuthorization: true)) {
            XCTAssertEqual($0 as? ClientAPIError, .invalidSecureRecord)
        }
    }
}
