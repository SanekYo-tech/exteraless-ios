import Foundation
import XCTest
@testable import ExteralessCore

final class ClientSettingsSearchClosureTests: XCTestCase {
    private func definition(title: String = "A", section: String = "Appearance") -> ClientSettingDefinition {
        .init(key: "appearance.avatarCorners", title: title, section: section, defaultValue: .integer(28))
    }

    private func withStore(_ body: (ClientSettings, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-closure-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let store = try ClientSettings(storageURL: url, secretStore: SearchClosureSecrets(), durabilityRootURL: directory)
        try body(store, url)
    }

    private func refresh(_ index: inout ClientSettingsSearchIndex, from store: ClientSettings) throws {
        let snapshot = store.readSnapshot()
        try index.refresh(definitions: snapshot.definitions, secretKeys: snapshot.secretKeys, actions: [],
                          definitionVersions: snapshot.definitionVersions)
    }

    func testPublishedTitleAndVisibilityABAInvalidateWithoutIntermediateIndexRefresh() throws {
        try withStore { store, url in
            let a = definition()
            let other = ClientSettingDefinition(key: "search.unrelated", title: "Unrelated", section: "Fixture", defaultValue: .bool(false))
            try store.register([a, other])
            var index = ClientSettingsSearchIndex()
            try refresh(&index, from: store)
            let unrelated = try index.resolve(.canonical(.setting(other.key))).ticket
            let file = try Data(contentsOf: url)
            for b in [definition(title: "B"), definition(section: "AI state")] {
                let old = try index.resolve(.canonical(.setting(a.key))).ticket
                let before = store.readSnapshot()
                try store.register([b])
                try store.register([a])
                // No observer or index refresh was allowed to see B.
                let after = store.readSnapshot()
                XCTAssertEqual(after.definitions, before.definitions)
                XCTAssertNotEqual(after.definitionVersions[a.key], before.definitionVersions[a.key])
                XCTAssertEqual(after.definitionVersions[other.key], before.definitionVersions[other.key])
                XCTAssertEqual(after.values, before.values)
                XCTAssertEqual(after.storedKeys, before.storedKeys)
                try refresh(&index, from: store)
                XCTAssertThrowsError(try index.validate(old)) { XCTAssertEqual($0 as? ClientSettingsRouteError, .changed) }
                XCTAssertNoThrow(try index.validate(unrelated))
                XCTAssertNotEqual(try index.resolve(.canonical(.setting(a.key))).ticket, old)
            }
            XCTAssertEqual(try Data(contentsOf: url), file, "schema metadata must not rewrite settings data")
        }
    }

    func testValueOnlyPublicBatchesReloadAndIdenticalRegistrationKeepSchemaTickets() throws {
        try withStore { store, _ in
            let a = definition()
            let other = ClientSettingDefinition(key: "search.unrelated", title: "Unrelated", section: "Fixture", defaultValue: .bool(false))
            try store.register([a, other])
            var index = ClientSettingsSearchIndex()
            try refresh(&index, from: store)
            let old = try index.resolve(.canonical(.setting(a.key))).ticket
            let unrelated = try index.resolve(.canonical(.setting(other.key))).ticket
            let versions = store.readSnapshot().definitionVersions
            try store.set(.integer(30), for: a.key)
            try store.applyPublic([other.key: .bool(true)], expected: store.readSnapshot())
            try store.applyPublic([:], resetting: [other.key], expected: store.readSnapshot())
            try store.reset(a.key)
            try store.reload()
            try store.register([a, other])
            XCTAssertThrowsError(try store.set(.string("wrong type"), for: a.key))
            XCTAssertEqual(store.readSnapshot().definitionVersions, versions)
            try refresh(&index, from: store)
            XCTAssertNoThrow(try index.validate(old))
            XCTAssertNoThrow(try index.validate(unrelated))
        }
    }

    func testAcceptedSchemaOnLoadFailureStillPublishesNewIdentity() throws {
        try withStore { store, url in
            let a = definition()
            try store.register([a])
            var index = ClientSettingsSearchIndex()
            try refresh(&index, from: store)
            let old = try index.resolve(.canonical(.setting(a.key))).ticket
            let before = store.readSnapshot().definitionVersions
            let malformed = Data("{".utf8)
            try malformed.write(to: url)
            XCTAssertThrowsError(try store.register([definition(title: "B")])) {
                XCTAssertEqual($0 as? ClientSettingsError, .invalidJSON)
            }
            XCTAssertThrowsError(try store.register([a])) {
                XCTAssertEqual($0 as? ClientSettingsError, .invalidJSON)
            }
            XCTAssertNotEqual(store.readSnapshot().definitionVersions[a.key], before[a.key])
            try refresh(&index, from: store)
            XCTAssertThrowsError(try index.validate(old)) { XCTAssertEqual($0 as? ClientSettingsRouteError, .changed) }
            XCTAssertEqual(try Data(contentsOf: url), malformed)
        }
    }

    func testSnapshotConstructorRemainsCompatibleAndPrunesUnknownVersionKeys() throws {
        let a = definition()
        let reconstructed = ClientSettingsSnapshot(definitions: [a], values: [a.key: .integer(28)], storedKeys: [])
        XCTAssertTrue(reconstructed.definitionVersions.isEmpty)
        let version = UUID()
        let tagged = ClientSettingsSnapshot(definitions: [a], values: reconstructed.values, storedKeys: [],
            definitionVersions: [a.key: version, "unknown.private": UUID()])
        XCTAssertEqual(tagged.definitionVersions, [a.key: version])
        try withStore { store, _ in
            try store.register([a])
            let published = store.readSnapshot()
            XCTAssertEqual(Set(published.definitionVersions.keys), Set(published.definitions.map(\.key)))
            XCTAssertNotNil(published.definitionVersions[a.key])
        }
    }

    func testNagramRedirectIntersectsExplicitClassAndPreservesValidMovedRows() throws {
        let general = "app.exteraless.settings.OpenExteraGeneralActivity"
        let raw = "tg://settings/exteraless/source?page=nasettings/general&class=" + general + "&row=HideHelpSection"
        let url = try XCTUnwrap(URL(string: raw))
        let request = try XCTUnwrap(try ClientSettingsLink.parseURL(url))
        var index = ClientSettingsSearchIndex()
        try index.refresh(definitions: [.init(key: "appearance.hideHelpSection", title: "Hide help", section: "Hiding", defaultValue: .bool(false))], secretKeys: [], actions: [])
        XCTAssertThrowsError(try index.resolve(request)) { XCTAssertEqual($0 as? ClientSettingsRouteError, .notFound) }
        for row in ["HidePremiumSection", "HideHelpSection", "HideStoriesFromHeader", "DisableStories", "MainTabsHideTitles",
                    "MainTabsHideContacts", "MainTabsHideCallsSettings", "MainTabsHideProfile", "AlwaysShowDownloadIcon", "VideoPlayerDecoder"] {
            XCTAssertThrowsError(try ClientSettingsSourceRoutes.resolve(page: nil, className: general, row: row))
            XCTAssertThrowsError(try ClientSettingsSourceRoutes.resolve(page: "nasettings/general", className: general, row: row)) {
                XCTAssertEqual($0 as? ClientSettingsRouteError, .notFound)
            }
        }
        XCTAssertEqual(try index.resolve(.original(page: "nasettings/general", className: nil, row: "HideHelpSection")).route, .setting("appearance.hideHelpSection"))
        XCTAssertEqual(try ClientSettingsSourceRoutes.resolve(page: "appearance", className: nil, row: "HideHelpSection"), .setting("appearance.hideHelpSection"))
        XCTAssertEqual(try ClientSettingsSourceRoutes.resolve(page: "nasettings/chats", className: "app.exteraless.settings.OpenExteraChatsActivity", row: "HideHelpSection"), .setting("appearance.hideHelpSection"))
        XCTAssertEqual(try ClientSettingsSourceRoutes.resolve(page: "exteraless_chats", className: nil, row: "videoMessagesCamera"), .setting("tools.videoMessageCameraFacing"))
    }

    func testCredentialValueCanaryIsRejectedAsLocalTypedError() throws {
        let canary = "OWNED_CANARY"
        let url = try XCTUnwrap(URL(string: "tg://settings/exteraless/setting/clientAPI.customAppHash?value=" + canary))
        XCTAssertThrowsError(try ClientSettingsLink.parseURL(url)) {
            XCTAssertEqual($0 as? ClientSettingsRouteError, .invalidLink)
            XCTAssertFalse(($0 as? ClientSettingsRouteError)?.message.contains(canary) ?? true)
        }
    }
}

private final class SearchClosureSecrets: ClientSecretStore, Sendable {
    func data(for key: String) throws -> Data? { throw ClientSettingsError.secretStorageUnavailable }
    func set(_ data: Data?, for key: String) throws { throw ClientSettingsError.secretStorageUnavailable }
}
