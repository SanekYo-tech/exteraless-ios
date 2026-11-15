import AccountContext
import Display
import ExteralessCore
import Foundation
import TelegramCore
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ExteralessAIProvidersController: PluginListController, UIDocumentPickerDelegate {
    private let integration: ExteralessAIIntegration
    private var prepared = false

    init(context: AccountContext, integration: ExteralessAIIntegration) {
        self.integration = integration
        super.init(context: context)
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func refresh() {
        guard !isBusy else { return }
        prepared = false
        let integration = self.integration
        let context = self.context
        perform(title: "Opening secure settings…", operation: { try await integration.prepare(context: context) }, completion: { [weak self] _ in self?.prepared = true })
    }

    override func render() {
        title = "AI Providers and Models"
        guard prepared else { setSections(exteralessAIProviderPreparationSections(self)); return }
        let settings = integration.settings
        let services = settings.services.isEmpty ? [AIService.default] : settings.services
        let selected = settings.selectedService.id
        var sections = operationSections()
        let rows = services.map { service -> PluginListRow in
            var row = PluginListRow(id: service.id, title: service.displayName, detail: service.model + (settings.apiKey(for: service).isEmpty ? "\nAPI key required" : "\nAPI key is stored securely"))
            row.accessory = selected == service.id ? .checkmark : .disclosure
            row.action = { [weak self] in
                guard let self else { return }
                self.push(ExteralessAIServiceController(context: self.context, integration: self.integration, service: service))
            }
            if service.id != "default" {
                row.remove = { [weak self] in
                    self?.perform(title: "Removing provider…", operation: { try await ExteralessAIPersistence.run { try settings.remove(service: service) } }, completion: { _ in })
                }
            }
            return row
        }
        sections.append(PluginListSection(title: "Your services", footer: "Each service has its own endpoint, model and Keychain-backed key. Choosing a preset does not send a request.", rows: rows))
        var presets = AIProviderPreset.assistant.map { preset -> PluginListRow in
            var row = PluginListRow(id: "preset." + preset.id, title: "Add " + preset.title, detail: preset.baseURL)
            row.style = .accent
            row.action = { [weak self] in
                guard let self else { return }
                self.push(ExteralessAIServiceController(context: self.context, integration: self.integration, service: AIService(preset: preset)))
            }
            return row
        }
        var custom = PluginListRow(id: "custom", title: "Add custom provider", detail: "OpenAI-compatible /chat/completions and /models")
        custom.style = .accent
        custom.action = { [weak self] in
            guard let self else { return }
            self.push(ExteralessAIServiceController(context: self.context, integration: self.integration, service: AIService(url: "", model: "")))
        }
        presets.append(custom)
        var importServices = PluginListRow(id: "importAndroid", title: "Import Android AI services", detail: "Service JSON only; included API keys are moved to Keychain. Legacy service selection hashes are migrated to stable IDs.")
        importServices.action = { [weak self] in
            guard let self else { return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
            picker.delegate = self
            self.present(picker, animated: true)
        }
        presets.append(importServices)
        sections.append(PluginListSection(title: "Presets from the Android source", rows: presets))
        setSections(sections)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let settings = integration.settings
        perform(title: "Importing service configuration…", operation: {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try await ExteralessAIPersistence.run {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                guard let data = try handle.read(upToCount: 2 * 1024 * 1024 + 1) else { throw AIError.configuration }
                try settings.importAndroidServices(data)
            }
        }, completion: { _ in })
    }
}

@MainActor
private final class ExteralessAIServiceController: PluginListController {
    private let integration: ExteralessAIIntegration
    private var service: AIService
    private var keyDraft: String?
    private var authorizeDestinationChange = false
    private var prepared = false

    init(context: AccountContext, integration: ExteralessAIIntegration, service: AIService) {
        self.integration = integration
        self.service = service
        super.init(context: context)
        allowsRefresh = false
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func refresh() {
        guard !isBusy else { return }
        prepared = false
        let integration = self.integration
        let context = self.context
        perform(title: "Opening secure settings…", operation: { try await integration.prepare(context: context) }, completion: { [weak self] _ in self?.prepared = true })
    }

    override func render() {
        title = service.name.isEmpty ? "Custom provider" : service.name
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Save", style: .done, target: self, action: #selector(savePressed))
        navigationItem.rightBarButtonItem?.isEnabled = prepared && !isBusy
        guard prepared else { setSections(exteralessAIProviderPreparationSections(self)); return }
        var sections = operationSections()
        var rows: [PluginListRow] = [
            exteralessAIInputRow(id: "name", title: "Name", text: service.name, multiline: false, updated: { [weak self] in self?.service.name = $0 }),
            exteralessAIInputRow(id: "url", title: "Base URL", text: service.url, multiline: false, updated: { [weak self] value in
                guard let self else { return }
                if self.service.url != value { self.authorizeDestinationChange = true }
                self.service.url = value
            }),
            exteralessAIInputRow(id: "model", title: "Model ID", text: service.model, multiline: false, updated: { [weak self] in self?.service.model = $0 })
        ]
        let hasKey = !(keyDraft ?? integration.settings.apiKey(for: service)).isEmpty
        var key = PluginListRow(id: "key", title: "API key", detail: hasKey ? "Stored securely · tap to replace" : "Required · tap to add")
        key.accessory = .disclosure
        key.action = { [weak self] in
            guard let self else { return }
            exteralessAIEditSecret(from: self, title: "API key", save: { [weak self] value in self?.keyDraft = value; self?.render() })
        }
        rows.append(key)
        if keyDraft == nil, !hasKey, integration.settings.store.readSnapshot().storedKeys.contains(service.keySetting) {
            var rebind = PluginListRow(id: "bindKey", title: "Use stored key for this endpoint", detail: authorizeDestinationChange ? "Will bind when you tap Save" : service.url)
            rebind.action = { [weak self] in self?.authorizeDestinationChange = true; self?.render() }
            rows.append(rebind)
        }
        var models = PluginListRow(id: "models", title: "Choose from provider's models", detail: "GET /models, only when you tap Load")
        models.accessory = .disclosure
        models.action = { [weak self] in
            guard let self else { return }
            let key = self.keyDraft ?? self.integration.settings.apiKey(for: self.service)
            self.push(ExteralessAIModelsController(context: self.context, integration: self.integration, service: self.service, apiKey: key, selected: { [weak self] model in self?.service.model = model; self?.render() }))
        }
        rows.append(models)
        sections.append(PluginListSection(footer: "HTTPS endpoints use the provider's OpenAI-compatible API. The URL must not contain a key or user/password. Save also selects this service.", rows: rows))
        let effortRows = ["Off", "Low", "Medium", "High"].enumerated().map { index, title -> PluginListRow in
            var row = PluginListRow(id: "reasoning.\(index)", title: title)
            row.accessory = service.reasoningEffort == index ? .checkmark : .none
            row.action = { [weak self] in self?.service.reasoningEffort = index; self?.render() }
            return row
        }
        sections.append(PluginListSection(title: "Reasoning effort", footer: "Only providers/models supporting reasoning_effort accept this parameter. A rejected optional-parameter request is retried once without it.", rows: effortRows))
        if integration.settings.services.contains(where: { $0.id == service.id }) {
            var duplicate = PluginListRow(id: "duplicate", title: "Duplicate service")
            duplicate.action = { [weak self] in
                guard let self else { return }
                self.service.id = UUID().uuidString
                self.service.name += " Copy"
                self.keyDraft = ""
                self.authorizeDestinationChange = false
                self.render()
            }
            sections.append(PluginListSection(footer: "A duplicate starts with an empty key.", rows: [duplicate]))
        }
        setSections(sections)
    }

    @objc private func savePressed() {
        guard prepared, !isBusy else { return }
        view.endEditing(true)
        let settings = integration.settings
        let service = self.service
        let credential: AICredentialUpdate = keyDraft.map { $0.isEmpty ? .remove : .replace($0) } ?? .unchanged
        let authorizeDestinationChange = self.authorizeDestinationChange
        perform(title: "Saving service…", operation: {
            try await ExteralessAIPersistence.run { try settings.save(service: service, credential: credential, authorizeDestinationChange: authorizeDestinationChange) }
        }, completion: { [weak self] _ in self?.dismiss(animated: true) })
    }
}

@MainActor
final class ExteralessAIModelsController: PluginListController {
    private let integration: ExteralessAIIntegration
    private let service: AIService
    private let apiKey: String
    private let selected: (String) -> Void
    private var models: [String] = []
    private var search = ""

    init(context: AccountContext, integration: ExteralessAIIntegration, service: AIService, apiKey: String, selected: @escaping (String) -> Void) {
        self.integration = integration
        self.service = service
        self.apiKey = apiKey
        self.selected = selected
        if service.wireProtocol == .vertex { models = AILLMPreset.vertexModels }
        super.init(context: context)
        allowsRefresh = false
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func render() {
        title = "Models · " + service.displayName
        var sections = operationSections()
        var load = PluginListRow(id: "load", title: "Load model list", detail: service.wireProtocol == .vertex ? "Built-in list from VertexGeminiClient.MODELS" : "Fetch /models from this service")
        load.style = .accent
        load.enabled = !isBusy
        load.action = { [weak self] in self?.loadModels() }
        var catalog = PluginListRow(id: "catalog", title: "Load model metadata", detail: "models.dev · reasoning support and context window")
        catalog.enabled = !isBusy
        catalog.action = { [weak self] in
            guard let self else { return }
            let client = self.integration.client
            self.perform(title: "Loading metadata…", operation: { try await client.loadCatalog() }, completion: { [weak self] catalog in self?.integration.catalog = catalog })
        }
        sections.append(PluginListSection(rows: [load, catalog]))
        var searchRow = exteralessAIInputRow(id: "search", title: "Filter model IDs", text: search, multiline: false, updated: { [weak self] in self?.search = $0 })
        searchRow.input = PluginListInput(text: search, placeholder: "Type a filter and tap Apply", multiline: false, maxLength: 256, updated: { [weak self] in self?.search = $0 }, submitted: { [weak self] in self?.render() })
        var apply = PluginListRow(id: "applyFilter", title: "Apply filter")
        apply.action = { [weak self] in self?.view.endEditing(true); self?.render() }
        sections.append(PluginListSection(rows: [searchRow, apply]))
        let ids = models.filter { AIModelParameters.isTextGenerationModel($0) && (search.isEmpty || $0.localizedCaseInsensitiveContains(search)) }.sorted()
        let rows = ids.map { model -> PluginListRow in
            let info = integration.modelInfo(model)
            var detail: String?
            if let info { detail = info.name + (info.reasoning ? " · reasoning" : "") + (info.context > 0 ? " · context \(info.context)" : "") }
            var row = PluginListRow(id: model, title: model, detail: detail)
            row.accessory = model == service.model ? .checkmark : .none
            row.action = { [weak self] in self?.selected(model); self?.dismiss(animated: true) }
            return row
        }
        sections.append(PluginListSection(footer: ids.isEmpty ? "No models loaded or matching the filter. You can also enter an exact model ID in the provider editor." : "Model IDs come from the provider. Audio/image/embedding models are excluded from the text list.", rows: rows))
        setSections(sections)
    }

    private func loadModels() {
        let client = integration.client
        let service = self.service
        let key = apiKey
        perform(title: "Loading models…", operation: { try await client.listModels(service: service, apiKey: key) }, completion: { [weak self] models in self?.models = models })
    }
}

@MainActor
final class ExteralessAIRolesController: PluginListController {
    private let integration: ExteralessAIIntegration
    init(context: AccountContext, integration: ExteralessAIIntegration) { self.integration = integration; super.init(context: context) }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func render() {
        title = "Roles and System Prompts"
        let settings = integration.settings
        var sections = operationSections()
        var rows = settings.roles.map { role -> PluginListRow in
            var row = PluginListRow(id: role.name, title: role.name, detail: role.prompt)
            row.accessory = settings.selectedRole.name == role.name ? .checkmark : .none
            row.action = { [weak self] in
                self?.perform(title: "Selecting role…", operation: { try await ExteralessAIPersistence.run { try settings.store.set(.string(role.name), for: "ai.selectedRole") } }, completion: { _ in })
            }
            row.longAction = { [weak self] in
                guard let self else { return }
                let custom = !AIRole.suggestions.contains(where: { $0.name == role.name })
                self.push(ExteralessAIRoleEditor(context: self.context, integration: self.integration, role: custom ? role : AIRole(name: role.name + " Copy", prompt: role.prompt), replacing: custom ? role.name : nil))
            }
            if !AIRole.suggestions.contains(where: { $0.name == role.name }) {
                row.remove = { [weak self] in self?.perform(title: "Removing role…", operation: { try await ExteralessAIPersistence.run { try settings.remove(role: role) } }, completion: { _ in }) }
            }
            return row
        }
        var add = PluginListRow(id: "add", title: "Add custom role")
        add.style = .accent
        add.action = { [weak self] in
            guard let self else { return }
            self.push(ExteralessAIRoleEditor(context: self.context, integration: self.integration, role: AIRole(name: "", prompt: ""), replacing: nil))
        }
        rows.append(add)
        sections.append(PluginListSection(footer: "Tap to select. Long-press to edit a custom role or copy a built-in role. Text actions use the dedicated editor prompt.", rows: rows))
        setSections(sections)
    }
}

@MainActor
private final class ExteralessAIRoleEditor: PluginListController {
    private let integration: ExteralessAIIntegration
    private var role: AIRole
    private let replacing: String?
    init(context: AccountContext, integration: ExteralessAIIntegration, role: AIRole, replacing: String?) {
        self.integration = integration; self.role = role; self.replacing = replacing
        super.init(context: context)
        allowsRefresh = false
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func render() {
        title = "Edit role"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Save", style: .done, target: self, action: #selector(savePressed))
        let rows = [exteralessAIInputRow(id: "name", title: "Role name", text: role.name, multiline: false, updated: { [weak self] in self?.role.name = $0 }), exteralessAIInputRow(id: "prompt", title: "System prompt", text: role.prompt, multiline: true, updated: { [weak self] in self?.role.prompt = $0 })]
        setSections(operationSections() + [PluginListSection(footer: "Custom prompts stay in private secure storage and are sent only when using the selected role.", rows: rows)])
    }
    @objc private func savePressed() {
        let settings = integration.settings
        let role = self.role
        let replacing = self.replacing
        view.endEditing(true)
        perform(title: "Saving role…", operation: { try await ExteralessAIPersistence.run { try settings.save(role: role, replacing: replacing) } }, completion: { [weak self] _ in self?.dismiss(animated: true) })
    }
}

@MainActor
final class ExteralessAILLMController: PluginListController {
    private let integration: ExteralessAIIntegration
    private var prepared = false
    init(context: AccountContext, integration: ExteralessAIIntegration) { self.integration = integration; super.init(context: context) }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func refresh() {
        guard !isBusy else { return }
        prepared = false
        let integration = self.integration
        let context = self.context
        perform(title: "Opening secure settings…", operation: { try await integration.prepare(context: context) }, completion: { [weak self] _ in self?.prepared = true })
    }

    override func render() {
        title = "LLM Translation"
        guard prepared else { setSections(exteralessAIProviderPreparationSections(self)); return }
        let settings = integration.settings
        let store = settings.store
        let selected = AILLMPreset(rawValue: store.integer("ai.llmProviderPreset")) ?? .custom
        let displayedService = settings.llmService()
        let rows = AILLMPreset.allCases.map { preset -> PluginListRow in
            var row = PluginListRow(id: "preset.\(preset.rawValue)", title: preset.title, detail: preset.baseURL)
            row.accessory = preset == selected ? .checkmark : .none
            row.action = { [weak self] in
                self?.perform(title: "Selecting provider…", operation: { try await ExteralessAIPersistence.run { try store.set(.integer(Int64(preset.rawValue)), for: "ai.llmProviderPreset") } }, completion: { _ in })
            }
            return row
        }
        var sections = operationSections() + [PluginListSection(title: "Provider", rows: rows)]
        var editRows: [PluginListRow] = []
        if selected == .custom { editRows.append(settingRow("ai.llmApiUrl", title: "Custom base URL", multiline: false)) }
        let hasKey = !settings.llmAPIKeys(for: displayedService).isEmpty
        var key = PluginListRow(id: "key", title: "API key(s)", detail: hasKey ? "Stored securely" : "Required for this endpoint")
        key.action = { [weak self] in
            guard let self else { return }
            exteralessAIEditSecret(from: self, title: "API key(s), comma-separated", save: { [weak self] key in
                self?.perform(title: "Saving key…", operation: {
                    try await ExteralessAIPersistence.run {
                        let credential: AICredentialUpdate = key.isEmpty ? .remove : .replace(key)
                        if selected == .custom { try settings.saveCustomLLM(baseURL: displayedService.url, credential: credential) }
                        else { try settings.saveLLMKey(preset: selected, credential: credential) }
                    }
                }, completion: { _ in })
            })
        }
        editRows.append(key)
        if selected == .custom, !hasKey, store.readSnapshot().storedKeys.contains(selected.keySetting) {
            let baseURL = displayedService.url
            var rebind = PluginListRow(id: "bindKey", title: "Use stored key for this endpoint", detail: baseURL)
            rebind.action = { [weak self] in
                self?.perform(title: "Binding stored key…", operation: { try await ExteralessAIPersistence.run { try settings.saveCustomLLM(baseURL: baseURL, credential: .unchanged, authorizeDestinationChange: true) } }, completion: { _ in })
            }
            editRows.append(rebind)
        }
        editRows.append(settingRow(selected.modelSetting, title: "Model ID", multiline: false))
        var models = PluginListRow(id: "models", title: "Choose model from provider")
        models.action = { [weak self] in
            guard let self else { return }
            let service = settings.llmService()
            let key = settings.llmAPIKeys(for: service).first ?? ""
            self.push(ExteralessAIModelsController(context: self.context, integration: self.integration, service: service, apiKey: key, selected: { [weak self] model in
                self?.perform(title: "Selecting model…", operation: { try await ExteralessAIPersistence.run { try store.set(.string(model), for: selected.modelSetting) } }, completion: { _ in })
            }))
        }
        editRows.append(models)
        editRows.append(settingRow("ai.llmSystemPrompt", title: "System prompt", multiline: true))
        editRows.append(settingRow("ai.llmUserPrompt", title: "User prompt template", multiline: true))
        sections.append(PluginListSection(footer: "Empty prompts use the original translator instructions. The user template supports @text and @toLang. The selected model must be available for your provider/key.", rows: editRows))
        setSections(sections)
    }

    private func settingRow(_ key: String, title: String, multiline: Bool) -> PluginListRow {
        let settings = integration.settings
        let store = settings.store
        var row = PluginListRow(id: key, title: title, detail: key.contains("Prompt") ? (store.string(key).isEmpty ? "Original default" : "Custom") : store.string(key))
        row.accessory = .disclosure
        row.action = { [weak self] in
            guard let self else { return }
            self.push(ExteralessAITextSettingController(context: self.context, title: title, text: store.string(key), multiline: multiline, save: { text in
                if key.hasSuffix("Model") || key == "ai.llmModelName", !text.isEmpty { try AIRequestBuilder.validateModel(text) }
                try await ExteralessAIPersistence.run {
                    if key == "ai.llmApiUrl" { try settings.saveCustomLLM(baseURL: text, credential: .unchanged, authorizeDestinationChange: true) }
                    else { try store.set(.string(text), for: key) }
                }
            }))
        }
        return row
    }
}

@MainActor
private func exteralessAIProviderPreparationSections(_ controller: PluginListController) -> [PluginListSection] {
    var sections = controller.operationSections()
    if !controller.isBusy {
        var retry = PluginListRow(id: "prepareSettings", title: "Open provider settings")
        retry.action = { [weak controller] in controller?.refresh() }
        sections.append(PluginListSection(rows: [retry]))
    }
    return sections
}

@MainActor
final class ExteralessAITextSettingController: PluginListController {
    private var draft: String
    private let editorTitle: String
    private let multiline: Bool
    private let save: (String) async throws -> Void
    init(context: AccountContext, title: String, text: String, multiline: Bool, save: @escaping (String) async throws -> Void) {
        self.draft = text; self.editorTitle = title; self.multiline = multiline; self.save = save
        super.init(context: context)
        allowsRefresh = false
    }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func render() {
        title = editorTitle
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Save", style: .done, target: self, action: #selector(savePressed))
        navigationItem.rightBarButtonItem?.isEnabled = !isBusy
        let row = exteralessAIInputRow(id: "value", title: editorTitle, text: draft, multiline: multiline, updated: { [weak self] in self?.draft = $0 })
        setSections(operationSections() + [PluginListSection(rows: [row])])
    }
    @objc private func savePressed() {
        view.endEditing(true)
        let save = self.save
        let draft = self.draft
        perform(title: "Saving…", operation: { try await save(draft) }, completion: { [weak self] _ in self?.dismiss(animated: true) })
    }
}

@MainActor
func exteralessAIInputRow(id: String, title: String, text: String, multiline: Bool, updated: @escaping (String) -> Void) -> PluginListRow {
    var row = PluginListRow(id: id, title: title)
    row.input = PluginListInput(text: text, placeholder: title, multiline: multiline, maxLength: multiline ? AILimits.inputUTF16 : 512, updated: updated, submitted: {})
    return row
}

@MainActor
func exteralessAIEditSecret(from presenter: ViewController, title: String, save: @escaping (String) -> Void) {
    let alert = UIAlertController(title: title, message: "Enter a replacement. An empty value removes the stored key.", preferredStyle: .alert)
    alert.addTextField { field in
        field.isSecureTextEntry = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.textContentType = .password
        field.placeholder = "New key"
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Save", style: .default, handler: { [weak alert] _ in
        let value = alert?.textFields?.first?.text ?? ""
        alert?.textFields?.first?.text = ""
        save(value)
    }))
    presenter.present(alert, animated: true)
}

enum ExteralessAIPersistence {
    static func run<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .utility) { try Task.checkCancellation(); return try body() }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
