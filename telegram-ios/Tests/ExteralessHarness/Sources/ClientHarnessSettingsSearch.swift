import AccountContext
import Display
import Foundation

@MainActor
extension ClientHarnessSession {
    private func requireSearchChecks() throws -> SettingsSearchUIViewRouteChecks {
        guard let checks = self.settingsSearchChecks else { throw ClientHarnessFailure(description: "native settings search fixture missing") }
        return checks
    }

    func runSettingsSearchSegment() async throws {
        try clientHarnessRequire(["core-light", "core-dark"].contains(self.report.scenario), "search segment must use an existing core scenario")
        try self.loadDomainSourceEvidence()
        let required = [
            "swift/ExteralessCore/Sources/ExteralessCore/ClientSettings.swift",
            "swift/ExteralessCore/Sources/ExteralessCore/ClientSettingsSearchIndex.swift",
            "swift/ExteralessCore/Sources/ExteralessCore/ClientSettingsSourceRoutes.swift",
            "telegram-ios/submodules/AccountContext/Sources/ExteralessSettingsEntry.swift",
            "telegram-ios/submodules/AccountContext/Sources/ExteralessSettingsSearchEntry.swift",
            "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsSearch.swift",
            "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsController.swift",
            "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessSettingsUIHelpers.swift",
            "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/ExteralessClientRuntime.swift",
            "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Appearance/ExteralessMainMenu.swift",
            "telegram-ios/submodules/TelegramUI/Sources/ExteralessClient/Player/ExteralessPlayerActions.swift",
            "telegram-ios/submodules/SettingsUI/Sources/Search/ExteralessSettingsSearch.swift",
            "telegram-ios/submodules/SettingsUI/Sources/Search/SettingsSearchableItems.swift",
            "telegram-ios/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift",
            "telegram-ios/submodules/TelegramUI/Sources/AppDelegate.swift",
            "telegram-ios/submodules/TelegramUI/Sources/OpenUrl.swift",
            "telegram-ios/Tests/Exteraless/SettingsSearchUIViewRouteChecks.swift",
            "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessSettingsSearch.swift",
            "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessApplication.swift",
            "telegram-ios/Tests/ExteralessHarness/Sources/ClientHarnessScenarios.swift",
            "telegram-ios/Tests/ExteralessHarness/BUILD", "telegram-ios/Tests/ExteralessHarness/Info.plist"
        ]
        let manifest = self.report.facts["domainSources"] as? [String: Any]
        let files = manifest?["files"] as? [String: String] ?? [:]
        try clientHarnessRequire(required.allSatisfy { files[$0]?.count == 64 }, "settings search source/config fingerprints missing")
        self.report.facts["settingsSearchSources"] = Dictionary(uniqueKeysWithValues: required.map { ($0, files[$0]!) })
        try await self.requireSearchChecks().exerciseSearch { name, fields in try self.probe(name, extra: fields) }
    }

    func assertSettingsSearchSelector(_ key: String) throws { try self.requireSearchChecks().assertSelector(key) }
    func assertSettingsSearchEditor(_ key: String) throws { try self.requireSearchChecks().assertEditor(key) }

    func finishSettingsSearchChecks() async throws {
        guard let home = self.navigation.topViewController as? ViewController else { throw ClientHarnessFailure(description: "search cleanup home missing") }
        self.report.facts["settingsSearchClosure"] = try await self.requireSearchChecks().exerciseClosureChecks(from: home)
        ExteralessSettingsSearchEntry.install(nil)
    }
}
