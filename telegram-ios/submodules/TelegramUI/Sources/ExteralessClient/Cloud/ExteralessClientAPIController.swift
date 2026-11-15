import AccountContext
import ExteralessCore
import Foundation
import TelegramCore
import UIKit

@MainActor final class ExteralessClientAPIController: ExteralessCloudListController {
    private struct Draft { var id = ""; var hash = "" }
    private let configuration: ClientAPIConfigurationStore
    private var environment: ClientAPIEnvironment
    private var summaries: [ClientAPIEnvironment: ClientAPIDraftSummary] = [:]
    private var drafts: [ClientAPIEnvironment: Draft] = [:]
    private var loaded = false

    init(context: AccountContext, configuration: ClientAPIConfigurationStore) {
        self.configuration = configuration
        self.environment = context.account.testingEnvironment ? .test : .production
        super.init(context: context)
        title = "Client API"
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        super.loadDisplayNode()
        reloadDrafts()
    }

    override func render() {
        var sections = operationSections()
        let available = contextAvailable && !isBusy && loaded
        sections.append(PluginListSection(title: "Server environment", rows: ClientAPIEnvironment.allCases.map { value in
            var row = exteralessCloudAction("api-" + value.rawValue, value == .production ? "Production" : "Test server", enabled: available) { [weak self] in
                self?.environment = value
                self?.render()
            }
            row.accessory = environment == value ? .checkmark : .none
            return row
        }))
        if let summary = summaries[environment] {
            var builtin = exteralessCloudAction("api-builtin", "Use built-in API after restart", enabled: available) { [weak self] in self?.saveBuiltIn() }
            builtin.accessory = summary.mode == .builtIn ? .checkmark : .none
            var custom = exteralessCloudAction("api-custom", "Edit custom API…", detail: summary.apiId > 0 ? "Saved draft App ID: \(summary.apiId) · hash \(summary.hashIsSet ? "set" : "not set")" : "Enter the credentials from your Telegram application", enabled: available) { [weak self] in self?.edit() }
            custom.accessory = summary.mode == .custom ? .checkmark : .none
            var rows = [builtin, custom]
            if summary.requiresRepair { rows.append(PluginListRow(id: "api-repair", title: "Incomplete save", detail: ClientAPIError.incompleteSave.errorDescription)) }
            sections.append(PluginListSection(title: "Draft for new logins", footer: "Changes take effect for new authorization flows after a full app restart. Existing accounts and an already-started login keep their pinned API ID/hash and generation. Disabling retains the draft. Production and test-server drafts are separate.", rows: rows))
        }
        sections.append(PluginListSection(title: "Current account", footer: "Saving this draft does not change this account's authorization, restart its network, sign out, publish a build, or export its hash.", rows: [
            PluginListRow(id: "api-effective", title: "Effective account App ID", detail: String(context.account.networkArguments.apiId)),
            exteralessCloudAction("api-refresh", "Reload saved draft", enabled: contextAvailable && !isBusy) { [weak self] in self?.reloadDrafts() }
        ]))
        setSections(sections)
    }

    private func reloadDrafts() {
        let configuration = self.configuration
        runWriter("Reading native API configuration…", writer: {
            try configuration.register()
            var result: [ClientAPIEnvironment: ClientAPIDraftSummary] = [:]
            for environment in ClientAPIEnvironment.allCases { result[environment] = try configuration.summary(environment: environment) }
            return result
        }, completion: { [weak self] summaries in
            guard let self else { return }
            self.summaries = summaries
            self.loaded = true
            for (environment, summary) in summaries where self.drafts[environment] == nil {
                self.drafts[environment] = Draft(id: summary.apiId == 0 ? "" : String(summary.apiId), hash: "")
            }
        })
    }

    private func edit() {
        let environment = self.environment
        let draft = drafts[environment] ?? Draft()
        let expected = configuration.settings.readSnapshot()
        let alert = UIAlertController(title: "Custom API · " + environment.rawValue,
            message: "Save both fields together. Leave the hash blank to retain the saved hash for the same App ID. Restart before beginning a new login.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "App ID"
            field.keyboardType = .numberPad
            field.text = draft.id
            field.accessibilityLabel = "Telegram App ID"
        }
        alert.addTextField { field in
            field.placeholder = "App hash (32 hex characters)"
            field.isSecureTextEntry = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.text = draft.hash // User's unsaved draft only, never a Keychain read.
            field.accessibilityLabel = "Telegram App hash"
        }
        let capture = { [weak self, weak alert] in
            self?.drafts[environment] = Draft(id: alert?.textFields?.first?.text ?? "", hash: alert?.textFields?.last?.text ?? "")
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in capture() })
        alert.addAction(UIAlertAction(title: "Save for next restart", style: .default) { [weak self] _ in
            capture()
            guard let self, self.contextAvailable, let draft = self.drafts[environment], let id = Int32(draft.id.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                self?.operationFailure = ClientAPIError.invalidAppId.errorDescription
                self?.render()
                return
            }
            self.save(mode: .custom, id: id, hash: draft.hash, environment: environment, expected: expected)
        })
        present(alert, animated: true)
    }

    private func saveBuiltIn() {
        guard let summary = summaries[environment] else { return }
        save(mode: .builtIn, id: summary.apiId, hash: nil, environment: environment, expected: configuration.settings.readSnapshot())
    }

    private func save(mode: ClientAPIMode, id: Int32, hash: String?, environment: ClientAPIEnvironment, expected: ClientSettingsSnapshot) {
        let configuration = self.configuration
        runWriter("Saving API draft in Keychain…", writer: {
            try configuration.save(mode: mode, apiId: id, replacementHash: hash, environment: environment, expected: expected)
            return try configuration.summary(environment: environment)
        }, completion: { [weak self] summary in
            self?.allowsCancellation = true
            self?.summaries[environment] = summary
            self?.drafts[environment] = Draft(id: id == 0 ? "" : String(id), hash: "")
            self?.operationMessage = "Saved. Fully close and reopen the app before starting a new login. Existing account identities are retained."
        })
    }
}
