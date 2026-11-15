import Foundation

/// Configuration facade; all persistence (including Keychain) belongs to ClientSettings.
public struct AISettings: Sendable {
    public let store: ClientSettings

    public init(store: ClientSettings = .shared) { self.store = store }

    public func register() throws {
        // Decode/clamp the legacy enum before installing its strict option set.
        // These two unnamespaced Android preference keys are the only automatic
        // translation migration aliases; explicit native overrides still win.
        if !store.bool("ai.translatorModeWithOriginalMigrated") || !(0 ... 2).contains(store.integer("ai.translatorMode")) {
            try store.register(AITranslationModeMigration.preparationDefinitions)
            try store.migrateKey(from: "TranslatorMode", to: "ai.translatorMode")
            try store.migrateKey(from: "TranslatorModeWithOriginalMigrated", to: "ai.translatorModeWithOriginalMigrated")
            try AITranslationModeMigration.apply(store: store)
        }
        try store.register(AIFeatures.definitions)
        let definitions = try (services + [AIService.default]).map { try keyDefinition(for: $0) }
        // Re-read the selected storage on every preparation. configure/reload may
        // have introduced services whose secret keys this process has never seen.
        try store.register(definitions)
    }

    private func keyDefinition(for service: AIService) throws -> ClientSettingDefinition {
        guard Self.validIdentifier(service.id) else { throw AIError.configuration }
        return .init(key: service.keySetting, title: "Service API key", section: "AI credentials", defaultValue: .string(""), isSecret: true, androidSymbols: ["Service.key"])
    }

    private func registerKey(for service: AIService) throws {
        try store.register([keyDefinition(for: service)])
    }

    public var services: [AIService] { decode("ai.services", fallback: []) }
    public var roles: [AIRole] { AIRole.suggestions + decode("ai.roles", fallback: [AIRole]()) }
    public var selectedService: AIService {
        let services = self.services
        return services.first { $0.id == store.string("ai.selectedServiceId", default: "default") } ?? services.first ?? .default
    }
    public var selectedRole: AIRole {
        roles.first { $0.name == store.string("ai.selectedRole", default: "Assistant") } ?? AIRole.suggestions[0]
    }
    public func apiKey(for service: AIService) -> String {
        guard Self.validIdentifier(service.id),
              let destination = try? AICredentialDestination(settingKey: service.keySetting, baseURL: service.url, wireProtocol: service.wireProtocol) else { return "" }
        return AICredentialBinding.read(store.string(service.keySetting), destination: destination)
    }

    public func save(service: AIService, credential: AICredentialUpdate, authorizeDestinationChange: Bool = false) throws {
        Self.credentialMutationLock.lock()
        defer { Self.credentialMutationLock.unlock() }
        var service = service
        service.url = try AIRequestBuilder.normalizedBaseURL(service.url).absoluteString
        try AIRequestBuilder.validateModel(service.model)
        try register()
        try registerKey(for: service)
        var services = self.services
        if let index = services.firstIndex(where: { $0.id == service.id }) { services[index] = service }
        else { services.append(service) }
        let metadata = try Self.serviceMetadata(services)
        let destination = try AICredentialDestination(settingKey: service.keySetting, baseURL: service.url, wireProtocol: service.wireProtocol)
        let previous = store.string(service.keySetting)
        let previouslyStored = store.readSnapshot().storedKeys.contains(service.keySetting)
        let next = try AICredentialBinding.updated(credential, previous: previous, destination: destination, authorizeDestinationChange: authorizeDestinationChange)
        if let next {
            if next.isEmpty { try store.reset(service.keySetting) }
            else { try store.set(.string(next), for: service.keySetting) }
        }
        do { try store.applyPublic(["ai.services": metadata, "ai.selectedServiceId": .string(service.id)]) }
        catch {
            if next != nil {
                if previouslyStored { try? store.set(.string(previous), for: service.keySetting) }
                else { try? store.reset(service.keySetting) }
            }
            throw error
        }
    }

    public func remove(service: AIService) throws {
        Self.credentialMutationLock.lock()
        defer { Self.credentialMutationLock.unlock() }
        try register()
        try registerKey(for: service)
        let remaining = services.filter { $0.id != service.id }
        try store.reset(service.keySetting)
        try encode(remaining, key: "ai.services")
        if store.string("ai.selectedServiceId") == service.id {
            try store.set(.string(remaining.first?.id ?? "default"), for: "ai.selectedServiceId")
        }
    }

    public func save(role: AIRole, replacing name: String? = nil) throws {
        guard !role.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, role.name.count <= 80, role.prompt.utf16.count <= AILimits.inputUTF16 else { throw AIError.configuration }
        var custom: [AIRole] = decode("ai.roles", fallback: [])
        custom.removeAll { $0.name == name }
        guard !(AIRole.suggestions + custom).contains(where: { $0.name == role.name }) else { throw AIError.configuration }
        custom.append(role)
        try encode(custom, key: "ai.roles")
        try store.set(.string(role.name), for: "ai.selectedRole")
    }

    public func remove(role: AIRole) throws {
        var custom: [AIRole] = decode("ai.roles", fallback: [])
        custom.removeAll { $0.name == role.name }
        try encode(custom, key: "ai.roles")
        if store.string("ai.selectedRole") == role.name { try store.set(.string("Assistant"), for: "ai.selectedRole") }
    }

    public func registerHistory(accountId: String) throws {
        guard Self.validIdentifier(accountId) else { throw AIError.configuration }
        try store.register([.init(key: historyKey(accountId), title: "Private assistant history", section: "AI private data", defaultValue: .string(""), isSecret: true, androidSymbols: ["AiConfig.KEY_HISTORY"])])
    }

    public func history(accountId: String) -> [AIMessage] {
        guard store.bool("ai.saveHistory", default: true) else { return [] }
        return AILimits.trimHistory(decode(historyKey(accountId), fallback: []))
    }

    public func appendHistory(accountId: String, prompt: String, response: String) throws {
        guard store.bool("ai.saveHistory", default: true) else { return }
        try registerHistory(accountId: accountId)
        try encode(AILimits.trimHistory(history(accountId: accountId) + [.init(role: .user, content: prompt), .init(role: .assistant, content: response)]), key: historyKey(accountId))
    }

    public func clearHistory(accountId: String) throws {
        try registerHistory(accountId: accountId)
        try store.set(.string(""), for: historyKey(accountId))
    }

    public func llmService() -> AIService {
        let preset = AILLMPreset(rawValue: store.integer("ai.llmProviderPreset")) ?? .custom
        let model = store.string(preset.modelSetting).trimmingCharacters(in: .whitespacesAndNewlines)
        return AIService(id: "llm-\(preset.rawValue)", name: preset.title, url: preset == .custom ? store.string("ai.llmApiUrl") : preset.baseURL, model: model.isEmpty ? preset.defaultModel : model, wireProtocol: preset == .vertex ? .vertex : .openAI)
    }

    public func registerInputLanguage(chatId: String) throws {
        guard Self.validIdentifier(chatId) else { throw AIError.configuration }
        // Empty means inherit the current global value, not the global default at
        // the moment the chat key happened to be registered.
        try store.register([.init(key: "ai.translateInputLang_" + chatId, title: "Chat translation language", section: "Translation", defaultValue: .string(""), androidSymbols: ["Translator.setInputTranslateLangForChat"])])
    }

    public func inputLanguage(chatId: String?) throws -> String {
        if let chatId {
            try registerInputLanguage(chatId: chatId)
            let language = store.string("ai.translateInputLang_" + chatId)
            if !language.isEmpty { return language }
        }
        return store.string("ai.translateInputLang", default: "en")
    }

    public func setInputLanguage(_ language: String, chatId: String) throws {
        try registerInputLanguage(chatId: chatId)
        let key = "ai.translateInputLang_" + chatId
        try store.set(.string(language), for: key)
    }

    /// Explicit service-only import. No Android preferences are read implicitly.
    /// Resolves the old Java hash against imported records BEFORE stripping keys
    /// and replacing absent IDs; the hash itself is never persisted on iOS.
    public func importAndroidServices(_ data: Data) throws {
        Self.credentialMutationLock.lock()
        defer { Self.credentialMutationLock.unlock() }
        guard data.count <= 2 * 1024 * 1024 else { throw AIError.inputTooLarge }
        struct LegacyService: Decodable {
            let id: String?
            let name: String?
            let url: String
            let model: String
            let key: String?
            let reasoningEffort: Int?
            let reasoningEnabled: Bool?
        }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) } catch { throw AIError.configuration }
        let envelope = root as? [String: Any]
        let servicesData: Data
        if let raw = envelope?["services"] as? String { servicesData = Data(raw.utf8) }
        else {
            let records = envelope?["services"] ?? root
            guard JSONSerialization.isValidJSONObject(records) else { throw AIError.configuration }
            servicesData = try JSONSerialization.data(withJSONObject: records)
        }
        guard let imported = try? JSONDecoder().decode([LegacyService].self, from: servicesData), !imported.isEmpty, imported.count <= AIFeatures.maximumServices else { throw AIError.configuration }
        let selectedId = envelope?["selectedServiceId"] as? String
        let effectiveId = selectedId.flatMap { id in imported.contains(where: { $0.id == id }) ? id : nil }
        let selectedHash = (envelope?["selectedService"] as? NSNumber)?.int32Value ?? Self.javaServiceHash(url: AIService.default.url, model: AIService.default.model, key: nil)
        var records: [(AIService, String, Bool)] = []
        var ids = Set<String>()
        for legacy in imported {
            let key = legacy.key ?? ""
            if !key.isEmpty { _ = try AIRequestBuilder.validatedKey(key) }
            let url = try AIRequestBuilder.normalizedBaseURL(legacy.url).absoluteString
            try AIRequestBuilder.validateModel(legacy.model)
            let id = legacy.id.flatMap { Self.validIdentifier($0) ? $0 : nil } ?? UUID().uuidString
            guard ids.insert(id).inserted else { throw AIError.configuration }
            let service = AIService(id: id, name: legacy.name ?? "", url: url, model: legacy.model, reasoningEffort: legacy.reasoningEffort ?? (legacy.reasoningEnabled == true ? 2 : 0))
            let selected = effectiveId.map { $0 == legacy.id } ?? (selectedHash == Self.javaServiceHash(url: legacy.url, model: legacy.model, key: legacy.key))
            let destination = try AICredentialDestination(settingKey: service.keySetting, baseURL: service.url, wireProtocol: service.wireProtocol)
            let credential = try AICredentialBinding.updated(key.isEmpty ? .remove : .replace(key), previous: "", destination: destination, authorizeDestinationChange: false) ?? ""
            records.append((service, credential, selected))
        }
        try register()
        let retained = services.filter { !ids.contains($0.id) }
        let metadata = try Self.serviceMetadata(retained + records.map { $0.0 })
        try store.register(records.map { try keyDefinition(for: $0.0) })
        // AICF-02: explicit defaults are overrides (SC-05). Snapshot presence as
        // well as values, so rollback restores absence through reset, not set("").
        let snapshot = store.readSnapshot()
        let previous = records.map { (key: $0.0.keySetting, value: store.string($0.0.keySetting), stored: snapshot.storedKeys.contains($0.0.keySetting)) }
        let publicKeys: Set<String> = ["ai.services", "ai.selectedServiceId"]
        let previousPublic = snapshot.values.filter { publicKeys.contains($0.key) && snapshot.storedKeys.contains($0.key) }
        let previouslyAbsentPublic = publicKeys.subtracting(snapshot.storedKeys)
        do {
            for (service, key, _) in records {
                if key.isEmpty { try store.reset(service.keySetting) }
                else { try store.set(.string(key), for: service.keySetting) }
            }
            let selected = records.first { $0.2 }?.0 ?? records[0].0
            try store.applyPublic(["ai.services": metadata, "ai.selectedServiceId": .string(selected.id)])
        } catch {
            try? store.applyPublic(previousPublic, resetting: previouslyAbsentPublic)
            for prior in previous {
                if prior.stored { try? store.set(.string(prior.value), for: prior.key) }
                else { try? store.reset(prior.key) }
            }
            throw error
        }
    }

    public static func javaServiceHash(url: String, model: String, key: String?) -> Int32 {
        var hash: UInt32 = 0
        for unit in (url + model + (key ?? "null")).utf16 { hash = hash &* 31 &+ UInt32(unit) }
        return Int32(bitPattern: hash)
    }

    private func historyKey(_ accountId: String) -> String { "ai.history." + accountId }
    private static func serviceMetadata(_ services: [AIService]) throws -> ClientSettingValue {
        guard services.count <= AIFeatures.maximumServices else { throw AIError.inputTooLarge }
        let value = try JSONDecoder().decode(ClientSettingValue.self, from: JSONEncoder().encode(services))
        return try AIFeatures.servicesDefinition.validatedValue(value)
    }
    private static func validIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 100 && id.utf8.allSatisfy { (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57).contains($0) || [45, 46, 95].contains($0) }
    }
    private func decode<T: Decodable>(_ key: String, fallback: T) -> T {
        guard let value = store.value(key) else { return fallback }
        let data: Data
        if case let .string(raw) = value { data = Data(raw.utf8) }
        else if let encoded = try? JSONEncoder().encode(value) { data = encoded }
        else { return fallback }
        guard let parsed = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return parsed
    }
    private func encode<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let setting: ClientSettingValue
        if key == "ai.roles" || key.hasPrefix("ai.history.") { setting = .string(String(decoding: data, as: UTF8.self)) }
        else { setting = try JSONDecoder().decode(ClientSettingValue.self, from: data) }
        try store.set(setting, for: key)
    }
}

/// Shared by the native integration and restart/retry fixtures. A failed secure
/// read is recoverable: no sticky boolean prevents a subsequent preparation.
public final class AISettingsRecovery: @unchecked Sendable {
    private let settings: AISettings
    private let lock = NSRecursiveLock()
    private var failed = false

    public init(settings: AISettings) { self.settings = settings }

    public var errorDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return failed ? "AI settings could not be opened. Retry after secure storage is available." : nil
    }

    public func prepare(accountId: String? = nil, chatId: String? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try settings.register()
            if let accountId {
                try settings.registerHistory(accountId: accountId)
                try AIManualTranslations.register(accountId: accountId, store: settings.store)
            }
            if let chatId { try settings.registerInputLanguage(chatId: chatId) }
            failed = false
        } catch {
            failed = true
            throw error
        }
    }
}
