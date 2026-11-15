import Display
import ExteralessCore
import Foundation
import TelegramUI
import UIKit

/// Three owned keys only. Reads/writes are the real ClientSettings backend calls;
/// the never-observed key fails from its first read. No system secret store exists here.
private final class ClientHarnessAvailabilitySecrets: ClientSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var failedKeys: Set<String> = [ClientHarnessSecretAvailability.unknown]
    private var reads = 0
    private var failedReads = 0
    private var writes = 0

    func data(for key: String) throws -> Data? {
        self.lock.lock(); defer { self.lock.unlock() }
        self.reads += 1
        if self.failedKeys.contains(key) {
            self.failedReads += 1
            throw ClientSettingsError.secretStorageUnavailable
        }
        return self.values[key]
    }
    func set(_ data: Data?, for key: String) throws {
        self.lock.lock(); defer { self.lock.unlock() }
        self.writes += 1
        self.values[key] = data
    }
    func makeKnownUnreadable() {
        self.lock.lock(); defer { self.lock.unlock() }
        self.failedKeys.insert(ClientHarnessSecretAvailability.known)
    }
    var keepsRawFalse: Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.values[ClientHarnessSecretAvailability.known] == Data("false".utf8)
    }
    var counts: [String: Int] {
        self.lock.lock(); defer { self.lock.unlock() }
        return ["reads": self.reads, "failedReads": self.failedReads, "writes": self.writes]
    }
}

private enum ClientHarnessSecretAvailability {
    static let absent = "harness.secretAvailability.absent"
    static let known = "harness.secretAvailability.known"
    static let unknown = "harness.secretAvailability.unknown"
    static let expectedDefault = ClientSettingValue.string("ExpectedLegacySecret")
    static let rows = [(absent, "Confirmed absent", "Not set"),
                       (known, "Known quarantined", "Stored value unavailable"),
                       (unknown, "Never observed", "Secure storage unavailable")]

    static func definition(_ key: String, title: String, secret: Bool = true) -> ClientSettingDefinition {
        .init(key: key, title: title, section: "Secret availability fixture", defaultValue: self.expectedDefault, isSecret: secret)
    }

    static func expect(_ error: ClientSettingsError, _ operation: () throws -> Void) throws {
        do {
            try operation()
            throw ClientHarnessFailure(description: "secret fixture operation unexpectedly succeeded")
        } catch let actual as ClientSettingsError {
            try clientHarnessRequire(actual == error, "secret fixture returned the wrong typed failure")
        }
    }

    static func prepare(directory: URL) throws -> (ClientSettings, ClientHarnessAvailabilitySecrets) {
        let url = directory.appendingPathComponent("secret-availability.json")
        try clientHarnessRequire(!FileManager.default.fileExists(atPath: url.path), "secret fixture file must be fresh")
        // Actual legacy bytes: native repair, not this adapter, must quarantine false.
        try JSONEncoder().encode([self.known: ClientSettingValue.bool(false)]).write(to: url, options: .atomic)
        let backend = ClientHarnessAvailabilitySecrets()
        let settings = try ClientSettings(storageURL: url, secretStore: backend, durabilityRootURL: directory)

        // Reuse the absence key for a real public CAS set/reset before its monotonic
        // secret promotion. No fourth field or synthetic expected snapshot is needed.
        try settings.register([self.definition(self.absent, title: self.rows[0].1, secret: false)])
        try settings.applyPublic([self.absent: self.expectedDefault], expected: settings.readSnapshot())
        try settings.reload()
        try clientHarnessRequire(settings.readSnapshot().storedKeys.contains(self.absent), "CAS set did not persist its override")
        try settings.applyPublic([:], resetting: [self.absent], expected: settings.readSnapshot())
        try clientHarnessRequire(!settings.readSnapshot().storedKeys.contains(self.absent) && settings.value(self.absent) == self.expectedDefault,
            "CAS reset did not restore confirmed absence with its typed String default")

        let invalid = ClientSettingsError.invalidValue(key: self.known, reason: .type)
        try self.expect(invalid) { try settings.register(self.rows.map { self.definition($0.0, title: $0.1) }) }
        // Native reset confirms A's absence and moves B's invalid legacy value into
        // the supplied backend, retaining B's presence/error. C has never been readable.
        try self.expect(invalid) { try settings.reset(self.absent) }
        try clientHarnessRequire(backend.keepsRawFalse, "native repair did not preserve quarantined raw false")
        try self.check(settings.readSnapshot())
        backend.makeKnownUnreadable()
        try self.expect(.secretStorageUnavailable) { try settings.reload() }
        try self.check(settings.readSnapshot())
        try clientHarnessRequire(settings.value(self.absent) == self.expectedDefault,
            "confirmed absence lost its nonempty typed String default")
        let counts = backend.counts
        try self.expect(.secretAccessDenied) {
            try settings.applyPublic([self.known: self.expectedDefault], expected: settings.readSnapshot())
        }
        try clientHarnessRequire(backend.counts == counts && backend.keepsRawFalse, "public CAS accessed the secret backend")
        try self.check(settings.readSnapshot())
        return (settings, backend)
    }

    static func check(_ snapshot: ClientSettingsSnapshot) throws {
        try clientHarnessRequire(snapshot.definitions.count == 3 && snapshot.definitions.allSatisfy {
            $0.isSecret && $0.defaultValue == self.expectedDefault
        }, "secret fixture schema changed")
        try clientHarnessRequire(snapshot.values[self.absent] == .null && !snapshot.storedKeys.contains(self.absent),
            "confirmed absence must be available/redacted, not unavailable")
        try clientHarnessRequire(snapshot.values[self.known] == nil && snapshot.storedKeys.contains(self.known),
            "quarantined secret lost known presence or became a typed default")
        try clientHarnessRequire(snapshot.values[self.unknown] == nil && !snapshot.storedKeys.contains(self.unknown),
            "unreadable never-observed secret became a confirmed absence")
    }
}

@MainActor
extension ClientHarnessSession {
    func runSecretAvailabilitySegment() async throws {
        try clientHarnessRequire(["core-light", "core-dark"].contains(self.report.scenario), "secret labels belong to the existing core scenarios")
        let directory = self.report.directory
        let (settings, backend) = try await Task.detached(priority: .userInitiated) {
            try ClientHarnessSecretAvailability.prepare(directory: directory)
        }.value
        // The existing resource pins the helper, coordinator-owned renderer and
        // frozen app configuration. No source hash is invented from a revision label.
        try self.loadDomainSourceEvidence()
        let required = ["telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessSecretAvailability.swift",
            "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessScenarios.swift",
            "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessScenario.swift",
            "telegram-ios/Tests/ExteralessHarness/BUILD", "telegram-ios/Tests/ExteralessHarness/Info.plist",
            "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsController.swift",
            "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsUIHelpers.swift",
            "swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift",
            "swift/ExteralessCore/Sources/ExteralessCore/ClientSettingDefinition.swift",
            "swift/ExteralessCore/Sources/ExteralessCore/ClientSettingValue.swift",
            "swift/ExteralessCore/Sources/ExteralessCore/ClientSecrets.swift"]
        let manifest = self.report.facts["domainSources"] as? [String: Any]
        let files = manifest?["files"] as? [String: String] ?? [:]
        try clientHarnessRequire(required.allSatisfy { files[$0]?.count == 64 }, "secret-label source/config fingerprint inputs missing")

        let controller = exteralessSettingsController(context: self.context, settings: settings)
        self.report.journal.record("secret-availability-open", ["factory": "exteralessSettingsController(context:settings:)"])
        self.navigation.pushViewController(controller)
        try await self.driver.settle()
        guard let table = self.driver.views(in: controller.view).compactMap({ $0 as? UITableView }).first else {
            throw ClientHarnessFailure(description: "generic Settings controller did not create its real table")
        }
        func detail(_ key: String, text: String) -> UILabel? {
            guard let cell = table.visibleCells.first(where: { $0.accessibilityIdentifier == "setting:" + key }) else { return nil }
            return self.driver.views(in: cell).compactMap { $0 as? UILabel }.first {
                self.driver.visible($0) && $0.text == text
            }
        }
        try await self.driver.until("three settled native secret status labels") {
            self.navigation.topViewController === controller && !self.driver.hasText("operation")
                && ClientHarnessSecretAvailability.rows.allSatisfy { detail($0.0, text: $0.2) != nil }
        }
        try await self.driver.settle(0.15)
        let snapshot = settings.readSnapshot()
        try ClientHarnessSecretAvailability.check(snapshot)
        let rows = try ClientHarnessSecretAvailability.rows.map { key, _, status -> [String: Any] in
            guard let label = detail(key, text: status) else { throw ClientHarnessFailure(description: "native secret detail label disappeared") }
            let frame = label.convert(label.bounds, to: self.window)
            return ["id": "setting:" + key, "actualDetail": label.text ?? "", "labelClass": NSStringFromClass(type(of: label)),
                "frame": [frame.minX, frame.minY, frame.width, frame.height], "rgba": clientHarnessRGBA(label.textColor, traits: label.traitCollection),
                "typedAvailable": snapshot.values[key] != nil, "redactedNull": snapshot.values[key] == .null,
                "knownStored": snapshot.storedKeys.contains(key)]
        }
        try clientHarnessRequire(!self.driver.hasText("ExpectedLegacySecret"), "secret default leaked into the generic settings labels")
        try self.probe("secret-availability", extra: ["rows": rows, "backend": backend.counts, "publicCASSetReset": true,
            "publicSecretCASRejected": true, "sources": Dictionary(uniqueKeysWithValues: required.map { ($0, files[$0]!) })])
        try self.driver.back()
        try await self.driver.settle()
        try clientHarnessRequire(self.navigation.viewControllers.count == 1 && controller.view.window == nil
            && self.window.findFirstResponder() == nil, "secret Settings segment did not return to home")
    }
}
