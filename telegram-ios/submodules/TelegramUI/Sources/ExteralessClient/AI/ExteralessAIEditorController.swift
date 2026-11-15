import AccountContext
import Display
import ExteralessCore
import Foundation
import TelegramCore
import UIKit

@MainActor
final class ExteralessAIEditorController: PluginListController {
    private let integration: ExteralessAIIntegration
    private var draft = ""
    private var image: AIImageAttachment?
    private var imagePicker: ExteralessAIImagePicker?

    init(context: AccountContext, integration: ExteralessAIIntegration) {
        self.integration = integration
        super.init(context: context)
        allowsRefresh = false
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func render() {
        title = "AI Text Editor"
        let row = exteralessAIInputRow(id: "text", title: "Text to process", text: draft, multiline: true, updated: { [weak self] text in self?.draft = text })
        var actions = PluginListRow(id: "actions", title: "Text actions", detail: "Ask, summarize, proofread, change tone or translate")
        actions.style = .accent
        actions.action = { [weak self] in
            guard let self, !self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.image != nil else { return }
            self.view.endEditing(true)
            let before = self.draft
            let beforeImage = self.image?.id
            let input = ExteralessAITextInput(text: before, image: self.image, applyResult: { [weak self] result in
                guard let self, self.draft == before, self.image?.id == beforeImage else { return false }
                self.draft = result.text
                self.render()
                return true
            })
            self.integration.presentActions(context: self.context, from: self, input: input)
        }
        var attachment = PluginListRow(id: "image", title: image == nil ? "Attach an image" : "Replace image", detail: image.map { "JPEG · \($0.data.count / 1024) KiB · included only in AI text-action requests" })
        attachment.action = { [weak self] in
            guard let self else { return }
            self.view.endEditing(true)
            let picker = ExteralessAIImagePicker { [weak self] result in
                guard let self else { return }
                self.imagePicker = nil
                switch result {
                case let .success(image): self.image = image
                case let .failure(error): self.errorText = error == .cancelled ? nil : error.description
                }
                self.render()
            }
            self.imagePicker = picker
            picker.present(from: self)
        }
        if image != nil { attachment.remove = { [weak self] in self?.image = nil; self?.render() } }
        var clear = PluginListRow(id: "clearHistory", title: "Clear assistant history for this account")
        clear.style = .destructive
        clear.action = { [weak self] in
            guard let self else { return }
            let settings = self.integration.settings
            let account = self.integration.accountId(self.context)
            self.perform(title: "Clearing history…", operation: { try await ExteralessAIPersistence.run { try settings.clearHistory(accountId: account) } }, completion: { _ in })
        }
        setSections(operationSections() + [PluginListSection(footer: "Text and the selected image are sent only when an AI action is chosen. Images are downsampled to 2048 px, encoded as JPEG up to 4 MiB, and are not stored in assistant history. The provider/model must support image input.", rows: [row, attachment, actions]), PluginListSection(footer: "Only Ask AI uses the saved conversation. Summaries, proofreading and translations start independent requests.", rows: [clear])])
    }
}

@MainActor
final class ExteralessAIActionController: PluginListController {
    private let integration: ExteralessAIIntegration
    private let input: ExteralessAITextInput

    init(context: AccountContext, integration: ExteralessAIIntegration, input: ExteralessAITextInput) {
        self.integration = integration
        self.input = input
        super.init(context: context)
        allowsRefresh = false
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func render() {
        title = "AI Text Actions"
        let selected = (try? exteralessAIFormattedInput(input))?.text ?? ""
        let service = integration.settings.selectedService
        var source = PluginListRow(id: "source", title: "Selected text", detail: String(selected.prefix(500)) + (selected.count > 500 ? "…" : ""))
        source.enabled = false
        var settingsRow = PluginListRow(id: "settings", title: service.displayName + " · " + service.model, detail: integration.settings.apiKey(for: service).isEmpty ? "Configure your API key" : "Change provider or model")
        settingsRow.accessory = .disclosure
        settingsRow.action = { [weak self] in
            guard let self else { return }
            self.push(ExteralessAIProvidersController(context: self.context, integration: self.integration))
        }
        var sections = operationSections() + [PluginListSection(footer: input.image == nil ? nil : "An image is attached to this AI request.", rows: [source, settingsRow])]
        let actions: [AITextAction] = [.assistant, .summarize, .proofread, .emojify]
        sections.append(PluginListSection(title: "Actions", rows: actions.map { action in actionRow(action) }))
        var toneRows = AITextAction.tones.map { tone -> PluginListRow in
            var row = actionRow(.rewrite(tone.prompt), id: tone.id)
            row.title = tone.title
            return row
        }
        var custom = PluginListRow(id: "tone.custom", title: "Custom style…")
        custom.action = { [weak self] in
            guard let self else { return }
            let alert = UIAlertController(title: "Rewrite style", message: "Describe how the selected text should be rewritten.", preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "Style instructions" }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Rewrite", style: .default, handler: { [weak self, weak alert] _ in
                guard let self, let text = alert?.textFields?.first?.text, !text.isEmpty else { return }
                self.integration.run(.rewrite("following this style: " + text), context: self.context, from: self, input: self.input)
            }))
            self.present(alert, animated: true)
        }
        toneRows.append(custom)
        sections.append(PluginListSection(title: "Rewrite tone", rows: toneRows))
        let provider = AITranslationProvider(rawValue: integration.settings.store.integer("ai.translationProvider", default: 1)) ?? .google
        var translate = PluginListRow(id: "translate", title: "Translate message", detail: provider.title)
        translate.action = { [weak self] in
            guard let self else { return }
            self.integration.presentTranslation(context: self.context, from: self, input: self.input)
        }
        let chatId = input.chatId.map { String($0.toInt64()) }
        let target: String
        var languageAvailable = true
        do { target = try integration.settings.inputLanguage(chatId: chatId) }
        catch {
            target = "unavailable"
            languageAvailable = false
            sections.append(PluginListSection(rows: [PluginListRow(id: "language-error", title: "Translation settings unavailable", detail: "Go back and retry after secure storage is available.")]))
        }
        var translateDraft = PluginListRow(id: "translateDraft", title: "Translate draft to " + target)
        translateDraft.enabled = languageAvailable
        translateDraft.action = { [weak self] in
            guard let self else { return }
            self.integration.presentTranslation(context: self.context, from: self, input: self.input, targetLanguage: target, purpose: .input)
        }
        var language = PluginListRow(id: "language", title: "Draft target language", detail: target)
        language.enabled = languageAvailable
        language.accessory = .disclosure
        language.action = { [weak self] in
            guard let self else { return }
            let settings = self.integration.settings
            self.push(ExteralessAILanguagePicker(context: self.context, integration: self.integration, current: target, defaultLanguage: "en", selected: { value in
                _ = try AITranslationLanguage.normalize(value, provider: provider)
                try await ExteralessAIPersistence.run {
                    if let chatId { try settings.setInputLanguage(value, chatId: chatId) }
                    else { try settings.store.set(.string(value), for: "ai.translateInputLang") }
                }
            }))
        }
        sections.append(PluginListSection(title: "Translation", footer: provider.prerequisite, rows: [translate, translateDraft, language]))
        var speak = PluginListRow(id: "speak", title: "Read selected text aloud", detail: "Apple speech synthesis")
        speak.action = { [weak self] in
            guard let self else { return }
            ExteralessAIEntry.speak?(self.context, self, self.input)
        }
        sections.append(PluginListSection(rows: [speak]))
        setSections(sections)
    }

    private func actionRow(_ action: AITextAction, id: String? = nil) -> PluginListRow {
        var row = PluginListRow(id: "action." + (id ?? action.title), title: action.title)
        row.style = .accent
        row.action = { [weak self] in
            guard let self else { return }
            self.integration.run(action, context: self.context, from: self, input: self.input)
        }
        return row
    }
}
