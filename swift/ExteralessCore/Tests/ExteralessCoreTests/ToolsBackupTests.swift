import Foundation
import XCTest
@testable import ExteralessCore

final class ToolsBackupTests: XCTestCase {
    private let definitions: [ClientSettingDefinition] = [
        .init(key: "tools.cameraStabilization", title: "Stabilization", section: "Camera", defaultValue: .bool(false)),
        .init(key: "tools.flashIntensity", title: "Intensity", section: "Camera", defaultValue: .integer(100), minimum: 0, maximum: 100, step: 1),
        .init(key: "ai.services", title: "Credentials", section: "AI", defaultValue: .string(""), isSecret: true)
    ]

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tools-backup-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func payload(settings: [String: ClientSettingValue] = ["tools.cameraStabilization": .bool(true)],
                         files: [ToolsBackupPluginSettings] = []) -> ToolsBackupPayload {
        .init(createdAt: "2026-11-14T12:00:00Z", appVersion: "13.1.1", clientSettings: settings, pluginSettings: files)
    }

    func testSelfContainedExportExcludesSecretDefinitionsAndUnregisteredValues() throws {
        let bytes = try ToolsBackupArchive.export(settings: ["tools.cameraStabilization": .bool(true), "tools.flashIntensity": .integer(75),
                                                            "ai.services": .string("fixture-credential"), "unregistered": .string("private")],
                                                 definitions: definitions, appVersion: "13.1.1")
        let result = try ToolsBackupArchive.inspect(bytes, definitions: definitions)
        XCTAssertEqual(result.settingCount, 2)
        XCTAssertEqual(result.settings["tools.flashIntensity"], .integer(75))
        XCTAssertNil(result.payload.clientSettings["ai.services"])
        XCTAssertNil(result.payload.clientSettings["unregistered"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let embedded = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["payload"] as? String)))
        XCTAssertFalse(String(decoding: embedded, as: UTF8.self).contains("fixture-credential"))
    }

    func testIntegrityCoversTheExactPayloadBytes() throws {
        let data = try ToolsBackupArchive.encode(payload())
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        envelope["payload"] = try ToolsFileSafety.encode(payload(settings: ["tools.cameraStabilization": .bool(false)])).base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertThrowsError(try ToolsBackupArchive.inspect(tampered, definitions: definitions)) { XCTAssertEqual($0 as? ToolsError, .checksumMismatch) }
    }

    func testUnknownVersionMalformedSchemaAndExcessiveNesting() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ToolsBackupArchive.encode(payload())) as? [String: Any])
        object["version"] = 99
        XCTAssertThrowsError(try ToolsBackupArchive.inspect(JSONSerialization.data(withJSONObject: object), definitions: definitions))
        XCTAssertThrowsError(try ToolsBackupArchive.inspect(Data("{\"config\": {}}".utf8), definitions: definitions))
        let nested = Data((String(repeating: "[", count: 100) + "0" + String(repeating: "]", count: 100)).utf8)
        XCTAssertThrowsError(try ToolsBackupArchive.inspect(nested, definitions: definitions)) { XCTAssertEqual($0 as? ToolsError, .sizeLimit) }
    }

    func testMalformedPathsAndCaseAliasesCannotBecomeRestoreDestinations() throws {
        for path in ["../outside.json", "/tmp/outside.json", "C:\\outside.json", "a/b.json", "a\\b.json", "%2e%2e.json", "bad\0.json", "plugin.py", ".hidden.json", "а.json"] {
            XCTAssertThrowsError(try ToolsBackupArchive.encode(payload(files: [.init(path: path, values: ["style": .bool(true)])])), path)
        }
        XCTAssertThrowsError(try ToolsBackupArchive.encode(payload(files: [.init(path: "Plugin.json", values: [:]), .init(path: "plugin.json", values: [:])])))
    }

    func testMalformedValuesAndSecretDefinitionCannotBeApplied() throws {
        let cases: [[String: ClientSettingValue]] = [
            ["tools.cameraStabilization": .integer(1)], ["tools.flashIntensity": .number(2.5)],
            ["tools.flashIntensity": .integer(101)], ["ai.services": .string("fixture")]
        ]
        for values in cases {
            XCTAssertThrowsError(try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload(settings: values)), definitions: definitions))
        }
    }

    func testPluginArrayAndTypeChangesCannotEraseLocalCredentials() throws {
        let providers: ClientSettingValue = .array([.object(["name": .string("fixture"), "api_key": .string("local-only")])])
        XCTAssertTrue(ToolsBackupPolicy.safeValues(["providers": providers]).isEmpty)
        XCTAssertThrowsError(try ToolsBackupPolicy.merging(["providers": .array([])], into: ["providers": providers]))
        XCTAssertThrowsError(try ToolsBackupPolicy.merging(["config": .bool(false)], into: ["config": .object(["token": .string("local-only")])]))
        let merged = try ToolsBackupPolicy.merging(["config": .object(["color": .string("blue")])], into: ["config": .object(["token": .string("local-only")])])
        XCTAssertEqual(merged["config"], .object(["color": .string("blue"), "token": .string("local-only")]))
    }

    func testPluginExportUsesExplicitAllowlistAndRedactsNestedCredentials() throws {
        let root = try temporaryDirectory().appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let values: [String: ClientSettingValue] = ["style": .string("blue"), "preferences": .object(["density": .integer(2), "api_key": .string("fixture-secret")]), "unknown": .string("private")]
        try ToolsFileSafety.encode(values).write(to: root.appendingPathComponent("fixture.json"))
        let location = ToolsBackupPluginLocation(directory: root, exportableFields: ["fixture.json": ["style", "preferences"]])
        let data = try ToolsBackupArchive.export(settings: [:], definitions: definitions, appVersion: "13.1.1", plugins: location)
        let result = try ToolsBackupArchive.inspect(data, definitions: definitions)
        XCTAssertEqual(result.pluginFileCount, 1)
        XCTAssertEqual(result.payload.pluginSettings[0].values, ["style": .string("blue"), "preferences": .object(["density": .integer(2)])])
    }

    func testFileReadBoundsAndSymlinkContainment() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("outside.json")
        try Data(repeating: 65, count: 32).write(to: file)
        XCTAssertThrowsError(try ToolsFileSafety.read(file, maximumBytes: 16))
        let settings = root.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: settings.appendingPathComponent("fixture.json"), withDestinationURL: file)
        XCTAssertThrowsError(try ToolsFileSafety.checkedChild("fixture.json", root: settings))
        XCTAssertThrowsError(try ToolsBackupPolicy.validateLocation(.init(directory: root, exportableFields: [:])))
    }

    func testLegacyUnicodeFormatMatchesOriginalDigitsAndRoundTripsUTF8() throws {
        XCTAssertEqual(try ToolsInvisibleUnicode.encode(Data([65])), "\u{2001}\u{2002}\u{206a}\u{206f}")
        let text = Data("{\"exteraconfig\":{\"cameraStabilization\":true},\"unknown\":{\"text\":\"Привет\"}}".utf8)
        let wrapped = try ToolsInvisibleUnicode.encode(text)
        XCTAssertEqual(try ToolsInvisibleUnicode.decode(wrapped), text)
        let inspected = try ToolsBackupArchive.inspect(Data(wrapped.utf8), definitions: definitions)
        XCTAssertEqual(inspected.settings, ["tools.cameraStabilization": .bool(true)])
        XCTAssertThrowsError(try ToolsInvisibleUnicode.decode(ToolsInvisibleUnicode.prefix + "A"))
        XCTAssertThrowsError(try ToolsInvisibleUnicode.decode(ToolsInvisibleUnicode.prefix + "\u{206f}\u{206f}\u{206f}"))
    }

    func testLegacyUnitsInversionsAndEnumMappingsMatchEtgBackup() throws {
        let definitions = self.definitions + [
            .init(key: "appearance.disableVibration", title: "Haptics", section: "Appearance", defaultValue: .bool(false)),
            .init(key: "appearance.tabsTitleType", title: "Tabs", section: "Appearance", defaultValue: .integer(0), minimum: 0, maximum: 2, step: 1)
        ]
        let bytes = Data("{\"exteraconfig\":{\"flashIntensity\":0.75,\"inAppVibration\":false,\"tabIcons\":0}}".utf8)
        let imported = try ToolsBackupArchive.inspect(bytes, definitions: definitions)
        XCTAssertEqual(imported.settings["tools.flashIntensity"], .integer(75))
        XCTAssertEqual(imported.settings["appearance.disableVibration"], .bool(true))
        XCTAssertEqual(imported.settings["appearance.tabsTitleType"], .integer(2))
        let exported = try ToolsLegacyBackup.export(settings: imported.settings, definitions: definitions)
        let decoded = try ToolsInvisibleUnicode.decode(String(decoding: exported, as: UTF8.self))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: [String: Any]])
        XCTAssertEqual(object["exteraconfig"]?["flashIntensity"] as? Double, 0.75)
        XCTAssertEqual(object["exteraconfig"]?["inAppVibration"] as? Bool, false)
        XCTAssertEqual(object["exteraconfig"]?["tabIcons"] as? Int, 0)
    }

    func testUnknownFieldsAreReportedWithoutBeingApplied() throws {
        let result = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload(settings: ["unknown.field": .bool(true)])), definitions: definitions)
        XCTAssertTrue(result.settings.isEmpty)
        XCTAssertEqual(result.ignoredKeys, ["unknown.field"])
    }

    func testLearnedSecretClassificationOverridesPublicDefinition() throws {
        let snapshot = ToolsBackupSettingsSnapshot(definitions: definitions, values: ["tools.cameraStabilization": .bool(true)],
                                                  storedKeys: ["tools.cameraStabilization"],
                                                  secretKeys: ["tools.cameraStabilization"])
        XCTAssertNil(snapshot.values["tools.cameraStabilization"])
        XCTAssertThrowsError(try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload()), definitions: definitions,
                                                            secretKeys: ["tools.cameraStabilization"]))
    }

    func testNonSecretFlagsAreNotDiscardedByCredentialNameGuessing() throws {
        let definitions = [ClientSettingDefinition(key: "privacy.secretChatPreview", title: "Preview flag", section: "Privacy", defaultValue: .bool(false))]
        let bytes = try ToolsBackupArchive.export(settings: ["privacy.secretChatPreview": .bool(true)], definitions: definitions, appVersion: "13.1.1")
        XCTAssertEqual(try ToolsBackupArchive.inspect(bytes, definitions: definitions).settings["privacy.secretChatPreview"], .bool(true))
    }

    func testDurabilityFailureRetainsJournalUntilCASRecovery() throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("settings")
        let settings = TestSettings(definitions: definitions, values: ["tools.cameraStabilization": .bool(false)])
        settings.failAfterNextApply()
        let inspected = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload()), definitions: definitions)
        XCTAssertThrowsError(try ToolsBackupRestorer().restore(inspected, settings: settings.access,
                                                              plugins: .init(directory: directory, exportableFields: [:])))
        XCTAssertEqual(try settings.access.snapshot().values["tools.cameraStabilization"], .bool(true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("tools-settings-restore.json").path))
        try ToolsBackupRestorer().recover(settings: settings.access, plugins: .init(directory: directory, exportableFields: [:]))
        XCTAssertEqual(try settings.access.snapshot().values["tools.cameraStabilization"], .bool(false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tools-settings-restore.json").path))
    }

    func testClientOnlyJournalRecoveryDoesNotRequirePluginBackup() throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("settings")
        let journal: [String: Any] = ["version": 2, "transactionId": UUID().uuidString,
            "before": ["values": ["tools.cameraStabilization": false], "storedKeys": []],
            "target": ["values": ["tools.cameraStabilization": true], "storedKeys": ["tools.cameraStabilization"]],
            "phase": "clientPending", "clientWrite": "uncertain"]
        try JSONSerialization.data(withJSONObject: journal).write(to: root.appendingPathComponent("tools-settings-restore.json"))
        let settings = TestSettings(definitions: definitions, values: ["tools.cameraStabilization": .bool(true)])
        try ToolsBackupRestorer().recover(settings: settings.access, plugins: .init(directory: directory, exportableFields: [:]))
        XCTAssertEqual(try settings.access.snapshot().values["tools.cameraStabilization"], .bool(false))
        XCTAssertFalse(try settings.access.snapshot().storedKeys.contains("tools.cameraStabilization"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    #if canImport(Darwin)
    func testInterruptedRestoreJournalRecoversBeforeRuntimeResumes() throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("settings")
        let id = UUID()
        let backup = root.appendingPathComponent("tools-settings-original-" + id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        try ToolsFileSafety.encode(["style": ClientSettingValue.string("new")]).write(to: directory.appendingPathComponent("fixture.json"))
        let original = try ToolsFileSafety.encode(["style": ClientSettingValue.string("old"), "token": .string("local-only")])
        try original.write(to: backup.appendingPathComponent("fixture.json"))
        let changed = try Data(contentsOf: directory.appendingPathComponent("fixture.json"))
        let journal: [String: Any] = ["version": 2, "transactionId": id.uuidString,
            "before": ["values": ["tools.cameraStabilization": false], "storedKeys": []],
            "target": ["values": ["tools.cameraStabilization": true], "storedKeys": ["tools.cameraStabilization"]],
            "originalFiles": ["fixture.json": ToolsSHA256.hex(original)], "targetFiles": ["fixture.json": ToolsSHA256.hex(changed)],
            "phase": "clientPending", "clientWrite": "uncertain"]
        try JSONSerialization.data(withJSONObject: journal).write(to: root.appendingPathComponent("tools-settings-restore.json"))
        let settings = TestSettings(definitions: definitions, values: ["tools.cameraStabilization": .bool(true)])
        try ToolsBackupRestorer().recover(settings: settings.access, plugins: .init(directory: directory, exportableFields: ["fixture.json": ["style"]]))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("fixture.json")), original)
        XCTAssertEqual(try settings.access.snapshot().values["tools.cameraStabilization"], .bool(false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testPluginSwapFailureRollsBackEntireConfigurationAndPreservesOtherFiles() throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let original = try ToolsFileSafety.encode(["style": ClientSettingValue.string("old"), "token": .string("local-only")])
        try original.write(to: directory.appendingPathComponent("fixture.json"))
        let settings = TestSettings(definitions: definitions, values: ["tools.cameraStabilization": .bool(false)])
        let archive = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload(files: [.init(path: "fixture.json", values: ["style": .string("new")])])), definitions: definitions)
        let restorer = ToolsBackupRestorer(beforeSettingsCommit: { throw ToolsError.unavailable("injected write failure") })
        XCTAssertThrowsError(try restorer.restore(archive, settings: settings.access, plugins: .init(directory: directory, exportableFields: ["fixture.json": ["style"]])))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("fixture.json")), original)
        XCTAssertEqual(try settings.access.snapshot().values["tools.cameraStabilization"], .bool(false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tools-settings-restore.json").path))
    }

    func testSuccessfulPluginRestoreMergesNonSecretFieldsAndKeepsCredentials() throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try ToolsFileSafety.encode(["style": ClientSettingValue.string("old"), "token": .string("local-only")]).write(to: directory.appendingPathComponent("fixture.json"))
        let settings = TestSettings(definitions: definitions, values: ["tools.cameraStabilization": .bool(false)])
        let archive = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload(files: [.init(path: "fixture.json", values: ["style": .string("new")])])), definitions: definitions)
        let result = try ToolsBackupRestorer().restore(archive, settings: settings.access, plugins: .init(directory: directory, exportableFields: ["fixture.json": ["style"]]))
        let values = try ToolsBackupArchive.decodeSettings(Data(contentsOf: directory.appendingPathComponent("fixture.json")))
        XCTAssertEqual(values["style"], .string("new"))
        XCTAssertEqual(values["token"], .string("local-only"))
        XCTAssertEqual(result.pluginFiles, 1)
        XCTAssertEqual(try settings.access.snapshot().values["tools.cameraStabilization"], .bool(true))
    }
    #endif

    func testVersion2PreservesAbsentVersusStoredDefault() throws {
        let bytes = try ToolsBackupArchive.export(settings: ["tools.cameraStabilization": .bool(false), "tools.flashIntensity": .integer(100)],
            definitions: definitions, appVersion: "fixture", storedKeys: ["tools.flashIntensity"])
        let inspected = try ToolsBackupArchive.inspect(bytes, definitions: definitions)
        XCTAssertEqual(inspected.resetting, ["tools.cameraStabilization"])
        XCTAssertEqual(inspected.settings, ["tools.flashIntensity": .integer(100)])
        let store = TestSettings(definitions: definitions, values: ["tools.cameraStabilization": .bool(true), "tools.flashIntensity": .integer(50)])
        let root = try temporaryDirectory().appendingPathComponent("settings")
        _ = try ToolsBackupRestorer().restore(inspected, settings: store.access, plugins: .init(directory: root, exportableFields: [:]))
        let state = try store.access.snapshot()
        XCTAssertEqual(state.values["tools.cameraStabilization"], .bool(false))
        XCTAssertFalse(state.storedKeys.contains("tools.cameraStabilization"))
        XCTAssertTrue(state.storedKeys.contains("tools.flashIntensity"))
    }

    func testV1ArchivesMigrateAsExplicitValuesWithoutGuessingPresence() throws {
        let payload = try ToolsFileSafety.encode(self.payload(settings: ["tools.cameraStabilization": .bool(false)]))
        let envelope: [String: Any] = ["format": "exteraless.settings", "version": 1,
                                      "payload": payload.base64EncodedString(), "sha256": ToolsSHA256.hex(payload)]
        let inspected = try ToolsBackupArchive.inspect(JSONSerialization.data(withJSONObject: envelope), definitions: definitions)
        XCTAssertTrue(inspected.resetting.isEmpty)
        XCTAssertEqual(inspected.settings["tools.cameraStabilization"], .bool(false))
    }

    func testRealCoreBatchRollbackKeepsAbsentOverrideAbsentOnDisk() throws {
        let root = try temporaryDirectory()
        let store = try ClientSettings(storageURL: root.appendingPathComponent("client.json"), secretStore: ToolsNoSecrets())
        try store.register(definitions.filter { !$0.isSecret })
        let imported = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload()), definitions: store.definitions())
        let restorer = ToolsBackupRestorer(fault: { point in
            if case .afterClientCommit = point { throw ToolsError.unavailable("fixture after real rename") }
        })
        XCTAssertThrowsError(try restorer.restore(imported, settings: .clientSettings(store), plugins: .init(directory: root.appendingPathComponent("settings"), exportableFields: [:])))
        try store.reload()
        XCTAssertFalse(store.readSnapshot().storedKeys.contains("tools.cameraStabilization"))
        XCTAssertFalse(store.bool("tools.cameraStabilization"))
    }

    func testRealCoreNativeWriterWinsOverRollbackCAS() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("client.json")
        let store = try ClientSettings(storageURL: url, secretStore: ToolsNoSecrets())
        let writer = try ClientSettings(storageURL: url, secretStore: ToolsNoSecrets())
        try store.register(definitions.filter { !$0.isSecret })
        try writer.register(definitions.filter { !$0.isSecret })
        let imported = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload()), definitions: store.definitions())
        let restorer = ToolsBackupRestorer(fault: { point in
            if case .afterClientCommit = point {
                try writer.applyPublic(["tools.cameraStabilization": .bool(false)])
                throw ToolsError.unavailable("fixture after independent native writer")
            }
        })
        XCTAssertThrowsError(try restorer.restore(imported, settings: .clientSettings(store), plugins: .init(directory: root.appendingPathComponent("settings"), exportableFields: [:]))) { XCTAssertEqual($0 as? ToolsError, .rollbackFailed) }
        try store.reload()
        XCTAssertFalse(store.bool("tools.cameraStabilization"))
        XCTAssertTrue(store.readSnapshot().storedKeys.contains("tools.cameraStabilization"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("tools-settings-restore.json").path))
    }

    func testRollbackRestoresAbsenceAndKeepsAnExplicitDefault() throws {
        let root = try temporaryDirectory().appendingPathComponent("settings")
        let store = TestSettings(definitions: definitions, values: ["tools.flashIntensity": .integer(100)])
        let imported = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload(settings: ["tools.cameraStabilization": .bool(true), "tools.flashIntensity": .integer(50)])), definitions: definitions)
        let restorer = ToolsBackupRestorer(fault: { if case .afterClientCommit = $0 { throw ToolsError.unavailable("fixture after commit") } })
        XCTAssertThrowsError(try restorer.restore(imported, settings: store.access, plugins: .init(directory: root, exportableFields: [:])))
        let state = try store.access.snapshot()
        XCTAssertFalse(state.storedKeys.contains("tools.cameraStabilization"))
        XCTAssertTrue(state.storedKeys.contains("tools.flashIntensity"))
        XCTAssertEqual(state.values["tools.flashIntensity"], .integer(100))
    }

    func testRollbackCASPreservesConcurrentNativeEditIncludingPresence() throws {
        let parent = try temporaryDirectory()
        let root = parent.appendingPathComponent("settings")
        let store = TestSettings(definitions: definitions, values: [:])
        let imported = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload()), definitions: definitions)
        let restorer = ToolsBackupRestorer(fault: { point in
            if case .afterClientCommit = point {
                store.nativeEdit("tools.cameraStabilization", value: .bool(false))
                throw ToolsError.unavailable("fixture later failure")
            }
        })
        XCTAssertThrowsError(try restorer.restore(imported, settings: store.access, plugins: .init(directory: root, exportableFields: [:]))) { XCTAssertEqual($0 as? ToolsError, .rollbackFailed) }
        XCTAssertEqual(try store.access.snapshot().values["tools.cameraStabilization"], .bool(false))
        XCTAssertTrue(try store.access.snapshot().storedKeys.contains("tools.cameraStabilization"), "a new explicit default is a native edit")
        let journal = parent.appendingPathComponent("tools-settings-restore.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertThrowsError(try restorer.recover(settings: store.access, plugins: .init(directory: root, exportableFields: [:])))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }

    func testConcurrentUnrelatedEditSurvivesRollback() throws {
        let root = try temporaryDirectory().appendingPathComponent("settings")
        let store = TestSettings(definitions: definitions, values: [:])
        let imported = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload()), definitions: definitions)
        let restorer = ToolsBackupRestorer(fault: { point in
            if case .afterClientCommit = point {
                store.nativeEdit("tools.flashIntensity", value: .integer(88))
                throw ToolsError.unavailable("fixture later failure")
            }
        })
        XCTAssertThrowsError(try restorer.restore(imported, settings: store.access, plugins: .init(directory: root, exportableFields: [:])))
        XCTAssertEqual(try store.access.snapshot().values["tools.flashIntensity"], .integer(88))
        XCTAssertFalse(try store.access.snapshot().storedKeys.contains("tools.cameraStabilization"))
    }

    func testRejectedCommitDoesNotUndoNativeEditEqualToImportTarget() throws {
        let root = try temporaryDirectory().appendingPathComponent("settings")
        let store = TestSettings(definitions: definitions, values: [:])
        let imported = try ToolsBackupArchive.inspect(ToolsBackupArchive.encode(payload()), definitions: definitions)
        let restorer = ToolsBackupRestorer(fault: { point in
            if case .beforeClientCommit = point { store.nativeEdit("tools.cameraStabilization", value: .bool(true)) }
        })
        XCTAssertThrowsError(try restorer.restore(imported, settings: store.access, plugins: .init(directory: root, exportableFields: [:])))
        XCTAssertEqual(try store.access.snapshot().values["tools.cameraStabilization"], .bool(true))
        XCTAssertTrue(try store.access.snapshot().storedKeys.contains("tools.cameraStabilization"))
    }

    func testUncommittedV1JournalCannotGuessPresenceOrCASState() throws {
        let parent = try temporaryDirectory()
        let root = parent.appendingPathComponent("settings")
        let legacy: [String: Any] = ["version": 1, "transactionId": UUID().uuidString,
            "previousSettings": ["tools.cameraStabilization": false], "includesPluginSettings": false, "committed": false]
        let bytes = try JSONSerialization.data(withJSONObject: legacy)
        let file = parent.appendingPathComponent("tools-settings-restore.json")
        try bytes.write(to: file)
        let store = TestSettings(definitions: definitions, values: ["tools.cameraStabilization": .bool(true)])
        XCTAssertThrowsError(try ToolsBackupRestorer().recover(settings: store.access, plugins: .init(directory: root, exportableFields: [:])))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try store.access.snapshot().values["tools.cameraStabilization"], .bool(true))
    }
}

private struct ToolsNoSecrets: ClientSecretStore {
    func data(for key: String) throws -> Data? { XCTFail("Public backup test must not read Keychain"); return nil }
    func set(_ data: Data?, for key: String) throws { XCTFail("Public backup test must not write Keychain") }
}

private final class TestSettings: @unchecked Sendable {
    let definitions: [ClientSettingDefinition]
    private let lock = NSLock()
    private var values: [String: ClientSettingValue]
    private var failNext = false
    init(definitions: [ClientSettingDefinition], values: [String: ClientSettingValue]) { self.definitions = definitions; self.values = values }
    func failAfterNextApply() { lock.lock(); failNext = true; lock.unlock() }
    func nativeEdit(_ key: String, value: ClientSettingValue?) { lock.lock(); values[key] = value; lock.unlock() }
    var access: ToolsBackupSettingsAccess {
        .init(snapshot: {
            self.lock.lock(); defer { self.lock.unlock() }
            return ToolsBackupSettingsSnapshot(definitions: self.definitions, values: self.values, storedKeys: Set(self.values.keys))
        }, applyAtomically: { values, resetting, expected in
            for (key, value) in values { try self.definitions.first(where: { $0.key == key })?.validate(value) }
            self.lock.lock(); defer { self.lock.unlock() }
            for key in Set(values.keys).union(resetting) {
                let actual = self.values[key] ?? self.definitions.first(where: { $0.key == key })?.defaultValue
                guard actual == expected.values[key], (self.values[key] != nil) == expected.storedKeys.contains(key) else {
                    throw ToolsBackupWriteFailure.rejected("fixture CAS conflict")
                }
            }
            self.values.merge(values) { _, new in new }
            for key in resetting { self.values.removeValue(forKey: key) }
            if self.failNext { self.failNext = false; throw ToolsBackupWriteFailure.durability("injected post-commit error") }
        })
    }
}
