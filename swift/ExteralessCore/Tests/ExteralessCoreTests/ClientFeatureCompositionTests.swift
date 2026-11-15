import Foundation
import XCTest
@testable import ExteralessCore

private final class CompositionSecrets: ClientSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func data(for key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }; return values[key]
    }
    func set(_ data: Data?, for key: String) throws {
        lock.lock(); defer { lock.unlock() }; values[key] = data
    }
}

/// Exercises the joint schema consumed by application composition, including
/// domains that intentionally share declarations rather than owning duplicates.
final class ClientFeatureCompositionTests: XCTestCase {
    func testPublishedDomainsCanRegisterAndReopenTogether() throws {
        let definitions = AppearanceFeatures.definitions + ChatFeatures.definitions
            + FeedFeatures.definitions + PlayerFeatures.definitions + PlayerFeatures.galleryDefinitions
            + PillFeatures.definitions + PrivacyFeatures.definitions + PrivacyExtrasFeatures.definitions
            + AIFeatures.definitions + ToolsFeatures.definitions
            + NewNetworkFeatures.definitions + MapFeatures.definitions + DialogFeatures.definitions
            + IdentityFeatures.definitions + StickerFeatures.definitions
        let keys = Set(definitions.map(\.key))
        XCTAssertEqual(keys.count, definitions.count, "Two domain providers must not claim the same setting key")
        XCTAssertTrue(keys.isDisjoint(with: Set(PrivacyExtrasFeatures.privateDefinitions.map(\.key))),
                      "App-lock credentials must never join the generic client settings schema")
        XCTAssertTrue(keys.isDisjoint(with: Set(IdentityFeatures.accountDefinitions.map(\.key))),
                      "Account-local identity data must not become app-global editable preferences")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("feature-composition-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("client-settings.json")
        let secrets = CompositionSecrets()
        let first = try ClientSettings(storageURL: url, secretStore: secrets)
        try first.register(definitions)
        try first.applyPublic(["chats.activePillsRaw": .string("5,6,7"), "chats.includeArchived": .object(["fixture-account": .bool(true)])])
        let reopened = try ClientSettings(storageURL: url, secretStore: secrets)
        try reopened.register(definitions)
        XCTAssertEqual(reopened.string("chats.activePillsRaw"), "5,6,7")
        XCTAssertEqual(reopened.value("chats.includeArchived"), .object(["fixture-account": .bool(true)]))

        for key in ["chats.wideFeedPosts", "chats.includeArchived", "chats.addNewChannels",
                    "chats.excludedChannels", "chats.knownChannels", "chats.musicPlaybackSpeed",
                    "chats.pauseOnMinimizeVoice", "chats.pauseOnMinimizeRound", "chats.doubleTapSeekDuration",
                    "chats.activePillsRaw", "chats.hiddenPillsRaw", "chats.lastActivePillId", "chats.infiniteScrolling"] {
            XCTAssertNotNil(reopened.value(key), "Native consumer lost its shared definition: \(key)")
        }
    }
}
