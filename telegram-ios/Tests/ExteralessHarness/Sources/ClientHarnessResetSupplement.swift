import Display
import Foundation
import UIKit

@MainActor
extension ClientHarnessSession {
    func runResetSupplement() async throws {
        guard let scenario = SettingsResetNavigationChecks.Scenario(rawValue: self.report.scenario),
              let layout = self.navigation.validLayout else {
            throw ClientHarnessFailure(description: "Missing explicit reset case/layout")
        }
        let darkCases: Set<String> = ["reset-prepare-before-return", "reset-reply-before-return",
            "reset-prepare-actual-pop", "reset-retired-ready", "reset-retired-reply"]
        let dark = darkCases.contains(scenario.rawValue)
        self.setDark(dark)
        try self.loadDomainSourceEvidence()
        guard let manifest = self.report.facts["domainSources"] as? [String: Any],
              let files = manifest["files"] as? [String: String] else {
            throw ClientHarnessFailure(description: "Missing verified reset source manifest")
        }
        self.report.facts["buildSelection"] = ["bundle": "org.exteraless.ClientUIHarness",
            "target": "//Telegram:ClientUIHarness", "host": "same-client-ui-app"]
        try await SettingsResetNavigationChecks.run(scenario, context: self.context,
            hostView: self.navigation.view, layout: layout, sourceHashes: files,
            probe: { name, payload in try self.visualProbe(name, view: self.navigation.view, extra: payload) })
        self.report.facts["resetSupplement"] = ["scenario": scenario.rawValue, "completed": true,
            "palette": dark ? "dark" : "light", "fixture": "SettingsResetNavigationChecks",
            "interactionDeadlineSeconds": 18, "replyGateSeconds": 6]
        try self.visualProbe("reset-cleanup", view: self.navigation.view,
            extra: ["nativeFixtureReturned": true, "firstResponder": self.window.findFirstResponder() != nil])
    }
}
