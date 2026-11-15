import AccountContext
import Display
import ExteralessCore
import Foundation
import UIKit

@MainActor
final class ExteralessAILanguagePicker: PluginListController {
    private let integration: ExteralessAIIntegration
    private let current: String
    private let defaultLanguage: String
    private let selected: (String) async throws -> Void
    private var filter = ""

    init(context: AccountContext, integration: ExteralessAIIntegration, current: String, defaultLanguage: String, selected: @escaping (String) async throws -> Void) {
        self.integration = integration; self.current = current; self.defaultLanguage = defaultLanguage; self.selected = selected
        super.init(context: context)
        allowsRefresh = false
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func render() {
        title = "Translation Language"
        let policy = AITranslationPolicy(store: integration.settings.store)
        var sections = operationSections()
        var search = exteralessAIInputRow(id: "filter", title: "Find language", text: filter, multiline: false, updated: { [weak self] in self?.filter = $0 })
        search.input = PluginListInput(text: filter, placeholder: "Name or language code", multiline: false, maxLength: 100, updated: { [weak self] in self?.filter = $0 }, submitted: { [weak self] in self?.render() })
        var apply = PluginListRow(id: "apply", title: "Apply filter")
        apply.action = { [weak self] in self?.view.endEditing(true); self?.render() }
        var preferences = PluginListRow(id: "preferences", title: "Edit preferred languages", detail: policy.preferredLanguages.joined(separator: ", "))
        preferences.action = { [weak self] in
            guard let self else { return }
            let store = self.integration.settings.store
            self.push(ExteralessAITextSettingController(context: self.context, title: "Preferred language codes", text: store.string("ai.preferredTranslateTargetLang"), multiline: false, save: { text in
                let codes = AITranslationPolicy.parsePreferredLanguages(text)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && codes.isEmpty { throw AIError.unsupportedLanguage }
                try await ExteralessAIPersistence.run { try store.set(.string(codes.joined(separator: ",")), for: "ai.preferredTranslateTargetLang") }
            }))
        }
        sections.append(PluginListSection(rows: [search, apply, preferences]))
        let locale = Locale(identifier: presentationData.strings.baseLanguageCode)
        let available = Locale.availableIdentifiers.sorted()
        let languages = policy.languages(defaultLanguage: defaultLanguage, available: available)
        let rows = languages.enumerated().compactMap { index, code -> PluginListRow? in
            let name = locale.localizedString(forIdentifier: code) ?? code
            guard filter.isEmpty || name.localizedCaseInsensitiveContains(filter) || code.localizedCaseInsensitiveContains(filter) else { return nil }
            let preferred = policy.preferredLanguages.contains { $0.caseInsensitiveCompare(code) == .orderedSame }
            let title = index == 0 ? "Default (\(name))" : (preferred ? "★ " : "") + name
            var row = PluginListRow(id: code, title: title, detail: code)
            row.accessory = current.caseInsensitiveCompare(code) == .orderedSame ? .checkmark : .none
            row.action = { [weak self] in
                guard let self else { return }
                let selected = self.selected
                self.perform(title: "Selecting language…", operation: { try await selected(code) }, completion: { [weak self] _ in self?.dismiss(animated: true) })
            }
            return row
        }
        sections.append(PluginListSection(footer: "The provider validates supported target languages. Preferred codes stay in your specified order after the default language.", rows: rows))
        setSections(sections)
    }
}
