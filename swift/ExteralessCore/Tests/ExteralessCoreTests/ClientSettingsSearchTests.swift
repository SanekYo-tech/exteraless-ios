import Foundation
import XCTest
@testable import ExteralessCore

final class ClientSettingsSearchTests: XCTestCase {
    private func definition(_ key: String = "appearance.avatarCorners", title: String = "Avatar corners", secret: Bool = false) -> ClientSettingDefinition {
        .init(key: key, title: title, section: "Appearance", defaultValue: secret ? .string("") : .integer(28),
              isSecret: secret, explanation: "Controls rounded profile pictures")
    }

    private func action(_ id: String = "clientAPI.edit", registration: UUID = UUID()) -> ClientSettingsSearchAction {
        .init(id: id, title: "Client API", section: "API", registration: registration)
    }

    func testLocalizedLabelsExplanationsAndOriginalNamesAreSearchable() throws {
        var index = ClientSettingsSearchIndex()
        try index.refresh(definitions: [definition()], secretKeys: [], actions: [], localize: { key, fallback in
            key == "Setting.appearance.avatarCorners.Title" ? "Café аватары" : fallback
        })
        XCTAssertEqual(index.search("CAFE аватары").first?.route, .setting("appearance.avatarCorners"))
        XCTAssertEqual(index.search("Search Exteraless").first?.route, .search)
        XCTAssertEqual(index.search("profile pictures").first?.route, .setting("appearance.avatarCorners"))
        XCTAssertEqual(index.search("avatarCornersPreviewRow").first?.route, .setting("appearance.avatarCorners"))
        XCTAssertTrue(index.search("profile absentword").isEmpty)
    }

    func testSourceClassRedirectAndMovedRowsUseExactCanonicalKeys() throws {
        XCTAssertEqual(try ClientSettingsSourceRoutes.resolve(page: nil,
            className: "com.exteragram.messenger.preferences.appearance.AppearancePreferencesActivity", row: "avatarCorners"), .setting("appearance.avatarCorners"))
        XCTAssertEqual(try ClientSettingsSourceRoutes.resolve(page: "exteraless_chats", className: nil, row: "videoMessagesCamera"), .setting("tools.videoMessageCameraFacing"))
        XCTAssertEqual(try ClientSettingsSourceRoutes.resolve(page: "appearance", className: nil, row: "HideHelpSection"), .setting("appearance.hideHelpSection"))
        XCTAssertEqual(try ClientSettingsSourceRoutes.resolve(page: "navigation", className: nil, row: "-101"), .setting("appearance.tabletMode"))
        XCTAssertEqual(try ClientSettingsSourceRoutes.resolve(page: "menus", className: nil, row: "actionBarButtons"), .row("chats.ActionBarButtonReply"))
    }

    func testConflictingQualifiersAndUnknownClassesNeverPickFirstMatch() {
        XCTAssertThrowsError(try ClientSettingsSourceRoutes.resolve(page: "general",
            className: "app.exteraless.settings.OpenExteraAppearanceActivity", row: "avatarCorners")) {
            XCTAssertEqual($0 as? ClientSettingsRouteError, .ambiguous)
        }
        for name in ["SomeAppearancePreferencesActivity", "app.exteraless.settings.OpenExteraAppearanceActivity$ListAdapter", "private.AccountPreferences"] {
            XCTAssertThrowsError(try ClientSettingsSourceRoutes.resolve(page: nil, className: name, row: "avatarCorners"))
        }
        XCTAssertThrowsError(try ClientSettingsSourceRoutes.resolve(page: "appearance", className: nil, row: "AVATARCORNERS"))
        XCTAssertThrowsError(try ClientSettingsSourceRoutes.resolve(page: "navigation", className: nil, row: "123456"))
    }

    func testUnchangedRefreshRetainsTicketButDefinitionChangeInvalidatesIt() throws {
        var index = ClientSettingsSearchIndex()
        try index.refresh(definitions: [definition()], secretKeys: [], actions: [])
        let old = try index.resolve(.canonical(.setting("appearance.avatarCorners"))).ticket
        try index.refresh(definitions: [definition()], secretKeys: [], actions: [])
        XCTAssertNoThrow(try index.validate(old))
        try index.refresh(definitions: [definition(title: "Changed label")], secretKeys: [], actions: [])
        XCTAssertThrowsError(try index.validate(old)) { XCTAssertEqual($0 as? ClientSettingsRouteError, .changed) }
    }

    func testRemovedAndReaddedDefinitionDoesNotReviveOldIdentifier() throws {
        var index = ClientSettingsSearchIndex()
        try index.refresh(definitions: [definition()], secretKeys: [], actions: [])
        let old = try index.resolve(.canonical(.setting("appearance.avatarCorners"))).ticket
        try index.refresh(definitions: [], secretKeys: [], actions: [])
        try index.refresh(definitions: [definition()], secretKeys: [], actions: [])
        XCTAssertThrowsError(try index.validate(old))
        XCTAssertNotEqual(old, try index.resolve(.canonical(.setting("appearance.avatarCorners"))).ticket)
    }

    func testActionReplacementAndABAInvalidateSelectedResult() throws {
        var index = ClientSettingsSearchIndex()
        let first = action()
        try index.refresh(definitions: [], secretKeys: [], actions: [first])
        let old = try index.resolve(.canonical(.action(first.id))).ticket
        try index.refresh(definitions: [], secretKeys: [], actions: [action()])
        XCTAssertThrowsError(try index.validate(old))
        let replacement = try index.resolve(.canonical(.action(first.id))).ticket
        try index.refresh(definitions: [], secretKeys: [], actions: [])
        try index.refresh(definitions: [], secretKeys: [], actions: [first])
        XCTAssertThrowsError(try index.validate(old))
        XCTAssertThrowsError(try index.validate(replacement))
    }

    func testContextRetirementAndDifferentScopeRejectRetainedTickets() throws {
        var first = ClientSettingsSearchIndex(), second = ClientSettingsSearchIndex()
        try first.refresh(definitions: [definition()], secretKeys: [], actions: [])
        try second.refresh(definitions: [definition()], secretKeys: [], actions: [])
        let ticket = try first.resolve(.canonical(.setting("appearance.avatarCorners"))).ticket
        XCTAssertThrowsError(try second.validate(ticket)) { XCTAssertEqual($0 as? ClientSettingsRouteError, .retired) }
        first.retire()
        XCTAssertTrue(first.items.isEmpty)
        XCTAssertTrue(first.search("Avatar").isEmpty)
        XCTAssertThrowsError(try first.validate(ticket))
        XCTAssertThrowsError(try first.refresh(definitions: [definition()], secretKeys: [], actions: []))
    }

    func testAllCompatibilityFieldsAndAIStateStayOutOfIndexAndResolution() throws {
        var index = ClientSettingsSearchIndex()
        let state = ClientSettingDefinition(key: "ai.internalJournal", title: "Never publish this field", section: "AI state", defaultValue: .null)
        let privateAPI = ClientSettingDefinition(key: "clientAPI.privateJournal", title: "Private journal title", section: "Client API", defaultValue: .string(""), isSecret: true)
        try index.refresh(definitions: ExteraConfigCompatibility.definitions + [state, privateAPI, definition()], secretKeys: [], actions: [action()])
        for item in ExteraConfigCompatibility.definitions {
            XCTAssertFalse(index.items.contains { $0.ticket.identifier == "setting:" + item.key })
            XCTAssertThrowsError(try index.resolve(.canonical(.setting(item.key))))
        }
        XCTAssertThrowsError(try index.resolve(.canonical(.setting(state.key))))
        XCTAssertTrue(index.search("Never publish this field").isEmpty)
        XCTAssertTrue(index.search("Private journal title").isEmpty)
        XCTAssertThrowsError(try index.resolve(.canonical(.setting(privateAPI.key))))
        XCTAssertThrowsError(try index.resolve(.canonical(.setting("unregistered.private"))))
    }

    func testOwnedAPIAndCloudFieldsCanOnlyResolveToOwningActions() throws {
        var index = ClientSettingsSearchIndex()
        let cloud = ClientSettingDefinition(key: "cloud.includeApiKeys", title: "Include service API keys", section: "Cloud", defaultValue: .bool(false))
        let apiAction = action(), cloudAction = action("cloud.settings")
        try index.refresh(definitions: ClientAPIFeatures.definitions + [cloud], secretKeys: [], actions: [apiAction, cloudAction])
        for definition in ClientAPIFeatures.definitions {
            let item = try index.resolve(.canonical(.row(definition.key)))
            XCTAssertEqual(item.route, .action("clientAPI.edit"))
            XCTAssertEqual(item.link?.absoluteString, "tg://settings/exteraless/action/clientAPI.edit")
        }
        XCTAssertEqual(try index.resolve(.canonical(.setting(cloud.key))).route, .action("cloud.settings"))
        let old = try index.resolve(.canonical(.setting("clientAPI.customAppId"))).ticket
        try index.refresh(definitions: ClientAPIFeatures.definitions, secretKeys: [], actions: [action()])
        XCTAssertThrowsError(try index.validate(old))
        try index.refresh(definitions: ClientAPIFeatures.definitions, secretKeys: [], actions: [])
        XCTAssertThrowsError(try index.resolve(.canonical(.setting("clientAPI.customAppHash")))) {
            guard case .unavailable? = $0 as? ClientSettingsRouteError else { return XCTFail("missing owning editor was not explicit") }
        }
    }

    func testLearnedSecretClassificationDisablesPublicEditorButKeepsNativeRepair() throws {
        var index = ClientSettingsSearchIndex()
        let key = "network.customDoH"
        try index.refresh(definitions: [definition(key, secret: false)], secretKeys: [key], actions: [])
        XCTAssertThrowsError(try index.resolve(.canonical(.setting(key))))
        try index.refresh(definitions: [definition(key, secret: true)], secretKeys: [key], actions: [])
        XCTAssertEqual(try index.resolve(.canonical(.setting(key))).route, .setting(key))
    }

    func testIndexNeverReadsOrIndexesCredentialsOrUnknownStoredFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let token = "OWNED_SECRET_MUST_NOT_BE_INDEXED", unknown = "OWNED_PRIVATE_FIELD_VALUE"
        try JSONSerialization.data(withJSONObject: ["search.token": token, "unregistered.private": unknown]).write(to: url)
        let backend = SearchTestSecrets()
        let store = try ClientSettings(storageURL: url, secretStore: backend, durabilityRootURL: directory)
        try store.register([definition("search.token", title: "Service credential", secret: true)])
        let snapshot = store.readSnapshot(), before = backend.counts
        var index = ClientSettingsSearchIndex()
        try index.refresh(definitions: snapshot.definitions, secretKeys: snapshot.secretKeys, actions: [])
        XCTAssertEqual(backend.counts, before)
        XCTAssertTrue(index.search(token).isEmpty)
        XCTAssertTrue(index.search(unknown).isEmpty)
        XCTAssertTrue(index.search("unregistered.private").isEmpty)
        XCTAssertEqual(index.search("Service credential").count, 1)
        XCTAssertFalse(index.items.map { $0.title + $0.explanation + $0.terms.joined() }.joined().contains(token))
    }

    func testTypedLinksRoundTripWithoutAnAssignedValue() throws {
        let routes: [ClientSettingsRoute] = [.root, .search, .setting("appearance.avatarCorners"), .row("harness.enabled"), .action("cloud.settings")]
        for route in routes {
            let url = try XCTUnwrap(ClientSettingsLink.url(for: route))
            XCTAssertEqual(try ClientSettingsLink.parseURL(url), .canonical(route))
        }
        XCTAssertEqual(try ClientSettingsLink.parseURL(try XCTUnwrap(URL(string: "https://t.me/exteraless/appearance?r=avatarCorners"))),
                       .original(page: "appearance", className: nil, row: "avatarCorners"))
        XCTAssertEqual(try ClientSettingsLink.parsePath("exteraless/source?class=app.exteraless.settings.OpenExteraAppearanceActivity&row=avatarCorners"),
                       .original(page: nil, className: "app.exteraless.settings.OpenExteraAppearanceActivity", row: "avatarCorners"))
    }

    func testValueImportsDuplicateParametersAndMalformedPathsAreRejected() throws {
        for raw in [
            "tg://settings/exteraless/setting/harness.enabled?v=true",
            "https://t.me/exteraless/general?r=IPv6&value=true",
            "https://t.me/exteraless/appearance?r=avatarCorners&r=other",
            "https://t.me/exteraless/appearance?r=avatarCorners&row=avatarCorners",
            "tg://settings/exteraless/source?class=A&class=B",
            "tg://settings/exteraless/setting/private%2Ffield",
            "tg://settings/exteraless/setting/private%252Efield",
            "tg://settings/exteraless//search",
            "tg://settings/exteraless/setting/harness.enabled#value",
            "https://user:password@t.me/exteraless/general?r=IPv6"
        ] {
            XCTAssertThrowsError(try ClientSettingsLink.parseURL(try XCTUnwrap(URL(string: raw))), raw)
        }
        XCTAssertNil(try ClientSettingsLink.parseURL(try XCTUnwrap(URL(string: "https://example.invalid/exteraless/settings"))))
        XCTAssertNil(try ClientSettingsLink.parsePath("privacy/active-websites"))
    }

    func testUnavailableOriginalRowsStayExplicitAndHaveNoLink() throws {
        var index = ClientSettingsSearchIndex()
        try index.refresh(definitions: [], secretKeys: [], actions: [])
        let results = index.search("Nothing Glyph")
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { !$0.isAvailable && $0.link == nil })
        XCTAssertThrowsError(try index.resolve(.original(page: "glyph", className: nil, row: "glyphPreview")))
        XCTAssertThrowsError(try index.resolve(.original(page: "other", className: nil, row: "resetSettings")))
        XCTAssertThrowsError(try index.resolve(.original(page: "appearance", className: nil, row: "avatarCorners"))) {
            guard case .unavailable? = $0 as? ClientSettingsRouteError else { return XCTFail("known row without provider was not explicit") }
        }
    }

    func testQueryResultAndCatalogBoundsFailClosed() throws {
        var index = ClientSettingsSearchIndex()
        let definitions = (0..<100).map { definition("fixture.key\($0)", title: "Bounded result \($0)") }
        try index.refresh(definitions: definitions, secretKeys: [], actions: [])
        XCTAssertEqual(index.search("Bounded result", limit: 1000).count, ClientSettingsSearchIndex.maximumResults)
        XCTAssertTrue(index.search(String(repeating: "x", count: 257)).isEmpty)
        XCTAssertTrue(index.search(Array(repeating: "x", count: 17).joined(separator: " ")).isEmpty)
        let old = try index.resolve(.canonical(.setting("fixture.key0"))).ticket
        XCTAssertThrowsError(try index.refresh(definitions: (0...ClientSettingsSearchIndex.maximumEntries).map { definition("overflow.\($0)") }, secretKeys: [], actions: []))
        XCTAssertTrue(index.items.isEmpty)
        XCTAssertThrowsError(try index.validate(old))
        XCTAssertThrowsError(try index.refresh(definitions: [definition(title: String(repeating: "x", count: 2049))], secretKeys: [], actions: []))
    }

    func testDuplicateNativeIdentitiesRejectInsteadOfChoosingAnAction() throws {
        var index = ClientSettingsSearchIndex()
        XCTAssertThrowsError(try index.refresh(definitions: [], secretKeys: [], actions: [action(), action()])) {
            XCTAssertEqual($0 as? ClientSettingsRouteError, .ambiguous)
        }
        XCTAssertTrue(index.items.isEmpty)
        XCTAssertThrowsError(try index.refresh(definitions: [definition(), definition(title: "Other meaning")], secretKeys: [], actions: []))
    }
}

private final class SearchTestSecrets: ClientSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var reads = 0, writes = 0
    var counts: [Int] { lock.lock(); defer { lock.unlock() }; return [reads, writes] }
    func data(for key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; reads += 1; return values[key] }
    func set(_ data: Data?, for key: String) throws { lock.lock(); defer { lock.unlock() }; writes += 1; values[key] = data }
}
