import Foundation

/// Ошибки модуля PluginHost.
public enum PluginHostError: Error, Equatable, Sendable, LocalizedError {
    /// CPython не слинкован (SPM-сборка без Python.xcframework).
    case pythonNotLinked
    /// Движок не запущен.
    case notRunning
    /// Достигнут лимит суб-интерпретаторов (включая брошенные).
    case interpreterLimitReached(Int)
    /// Плагин не найден.
    case pluginNotFound(String)
    /// Плагин завис (notResponding) и больше не вызывается.
    case pluginNotResponding(String)
    /// Таймаут вызова.
    case timeout(String)
    /// Очередь остановлена.
    case queueStopped
    /// Событие замещено более новым (коалесценг очереди).
    case superseded(String)
    /// Плагин не прошёл валидацию (id и пр.).
    case invalidPlugin(String)
    /// Ошибка рантайма.
    case runtimeFailure(String)
    /// Внутреннее рассогласование (баг).
    case internalInconsistency(String)

    public var errorDescription: String? {
        switch self {
        case .pythonNotLinked: return "CPython не слинкован в эту сборку"
        case .notRunning: return "PluginHost не запущен"
        case .interpreterLimitReached(let n): return "достигнут лимит интерпретаторов (\(n))"
        case .pluginNotFound(let id): return "плагин \(id) не найден"
        case .pluginNotResponding(let id): return "плагин \(id) не отвечает и отключён"
        case .timeout(let what): return "таймаут вызова плагина (\(what))"
        case .queueStopped: return "очередь событий остановлена"
        case .superseded(let what): return "запрос замещён более новым (\(what))"
        case .invalidPlugin(let why): return "некорректный плагин: \(why)"
        case .runtimeFailure(let why): return "ошибка Python-рантайма: \(why)"
        case .internalInconsistency(let why): return "внутренняя ошибка: \(why)"
        }
    }
}

/// Колбэки в UI-слой Telegram-iOS. Методы изолированы на главном акторе
/// и вызываются из `notify` (`Task { @MainActor in }`).
///
/// Сам протокол не `@MainActor`: экзистенциал лежит в `WeakDelegateBox`
/// под NSLock и читается с фоновых задач. Изоляция на типе в Swift 6
/// сделала бы такую ссылку ошибкой. Конформеры по-прежнему зовут методы
/// только с главного актора (класс `@MainActor` подходит).
public protocol PluginHostDelegate: AnyObject, Sendable {
    /// Список плагинов изменился (установка/удаление/включение/ошибки).
    @MainActor func pluginHostDidReloadPlugins(_ host: PluginHost)
    /// Плагин завис: notResponding, вызовы прекращены (см. PluginWatchdog).
    @MainActor func pluginHost(_ host: PluginHost, didMarkNotResponding pluginId: String)
    /// Плагин восстановлен (перезагрузка сторожа).
    @MainActor func pluginHost(_ host: PluginHost, didRecover pluginId: String)
    /// Ошибка загрузки/исполнения плагина (loadError модели).
    @MainActor func pluginHost(_ host: PluginHost, pluginId: String, didFailWithError message: String)
}

extension PluginHostDelegate {
    @MainActor public func pluginHostDidReloadPlugins(_ host: PluginHost) {}
    @MainActor public func pluginHost(_ host: PluginHost, didMarkNotResponding pluginId: String) {}
    @MainActor public func pluginHost(_ host: PluginHost, didRecover pluginId: String) {}
    @MainActor public func pluginHost(_ host: PluginHost, pluginId: String, didFailWithError message: String) {}
}

/// Фасад плагин-системы: старт/стоп рантайма, жизненный цикл плагинов,
/// колбэки в UI. Композиция: PythonRuntime (процесс CPython) +
/// SubinterpreterManager (PEP 684) + PluginEventQueue (доставка) +
/// PluginWatchdog (сторож) + BridgeServices (мост) + гейты разрешений.
public final class PluginHost: @unchecked Sendable {

    // MARK: - Конфигурация

    public struct Configuration: Sendable {
        public var runtime: PythonRuntimeConfiguration
        public var interpreters: PythonInterpreterLimits
        public var watchdog: WatchdogLimits
        public var queue: PluginEventQueue.Limits
        /// nil — Application Support/exteraless/plugins (умолчание).
        public var storageDirectory: URL?
        /// Строгий reflection-режим (по умолчанию permissive — принцип 3).
        public var strictReflection: Bool

        public init(runtime: PythonRuntimeConfiguration = .standard(),
                    interpreters: PythonInterpreterLimits = PythonInterpreterLimits(),
                    watchdog: WatchdogLimits = WatchdogLimits(),
                    queue: PluginEventQueue.Limits = PluginEventQueue.Limits(),
                    storageDirectory: URL? = nil,
                    strictReflection: Bool = false) {
            self.runtime = runtime
            self.interpreters = interpreters
            self.watchdog = watchdog
            self.queue = queue
            self.storageDirectory = storageDirectory
            self.strictReflection = strictReflection
        }
    }

    /// Комплект Swift-сервисов моста (заглушки v1, реализация — этап 5).
    /// `@unchecked Sendable`: `PluginUIService` не Sendable (`constructUI`
    /// принимает `[Any]`, см. протокол). Ссылки неизменяемы после init.
    public struct BridgeServiceSet: @unchecked Sendable {
        public var messages: (any PluginMessagesService)?
        public var settings: (any PluginSettingsService)?
        public var ui: (any PluginUIService)?
        public init(messages: (any PluginMessagesService)? = nil,
                    settings: (any PluginSettingsService)? = nil,
                    ui: (any PluginUIService)? = nil) {
            self.messages = messages
            self.settings = settings
            self.ui = ui
        }
    }

    // MARK: - Внутреннее состояние (lock-защищённое)

    private final class HostState: @unchecked Sendable {
        let lock = NSLock()
        private var plugins: [Plugin] = []
        private var handles: [String: InterpreterHandle] = [:]
        private var inflight: Set<String> = []
        var isRunning = false

        func pluginList() -> [Plugin] { lock.lock(); defer { lock.unlock() }; return plugins }
        func plugin(id: String) -> Plugin? { pluginList().first { $0.id == id } }

        func upsert(_ plugin: Plugin) {
            lock.lock(); defer { lock.unlock() }
            if let index = plugins.firstIndex(where: { $0.id == plugin.id }) {
                plugins[index] = plugin
            } else {
                plugins.append(plugin)
            }
        }

        func removePlugin(id: String) {
            lock.lock(); defer { lock.unlock() }
            plugins.removeAll { $0.id == id }
            handles[id] = nil
        }

        func handle(for id: String) -> InterpreterHandle? {
            lock.lock(); defer { lock.unlock() }
            return handles[id]
        }

        func setHandle(_ handle: InterpreterHandle) {
            lock.lock(); defer { lock.unlock() }
            handles[handle.pluginId] = handle
        }

        func removeHandle(for id: String) {
            lock.lock(); defer { lock.unlock() }
            handles[id] = nil
        }

        func markInflight(_ id: String, _ flag: Bool) {
            lock.lock(); defer { lock.unlock() }
            if flag { inflight.insert(id) } else { inflight.remove(id) }
        }

        func inflightSnapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return Array(inflight)
        }
    }

    private final class WeakDelegateBox: @unchecked Sendable {
        private let lock = NSLock()
        private weak var delegate: (any PluginHostDelegate)?
        func store(_ value: (any PluginHostDelegate)?) {
            lock.lock(); delegate = value; lock.unlock()
        }
        func load() -> (any PluginHostDelegate)? {
            lock.lock(); defer { lock.unlock() }
            return delegate
        }
    }

    // MARK: - Компоненты

    public let configuration: Configuration
    public let events: PluginEventBus
    public let permissions: PermissionsModel
    public let security: SecurityGates
    /// Реестр моста: точка входа C-моста этапа 2 (`_exteraless_bridge`).
    public let bridge: BridgeServices

    private let runtime: PythonRuntime
    private let interpreters: SubinterpreterManager
    private let queue = PluginEventQueue()
    private let gate = SubscriberGate()
    private let store: PluginStore
    private let watchdog: PluginWatchdog
    private let state = HostState()
    private let delegateBox = WeakDelegateBox()
    private let log: (@Sendable (String) -> Void)?

    /// Делегат UI-слоя (слабая ссылка, вызовы — на главном акторе).
    public var delegate: (any PluginHostDelegate)? {
        get { delegateBox.load() }
        set { delegateBox.store(newValue) }
    }

    public var isRunning: Bool { state.isRunning }

    // MARK: - Инициализация

    /// - Parameters:
    ///   - engine: реализация CPythonEngine (nil → UnboundCPythonEngine, отказ).
    ///   - reflectionPolicy: политика из манифеста (nil → режим по конфигурации).
    public init(engine: (any CPythonEngine)? = nil,
                configuration: Configuration = Configuration(),
                services: BridgeServiceSet = BridgeServiceSet(),
                reflectionPolicy: ReflectionPolicy? = nil,
                unsafePermissionsMode: Bool = false,
                log: (@Sendable (String) -> Void)? = nil,
                delegate: (any PluginHostDelegate)? = nil) throws {
        let resolvedEngine = engine ?? UnboundCPythonEngine()
        self.configuration = configuration
        self.runtime = PythonRuntime(engine: resolvedEngine)
        self.interpreters = SubinterpreterManager(
            engine: resolvedEngine, limits: configuration.interpreters)
        self.store = try PluginStore(directory: configuration.storageDirectory)
        let permissionModel = PermissionsModel(unsafeMode: unsafePermissionsMode, log: log)
        permissionModel.load(from: self.store)
        self.permissions = permissionModel
        let policy = reflectionPolicy
            ?? ReflectionPolicy(mode: configuration.strictReflection ? .manifestOnly : .permissive)
        let gates = SecurityGates(policy: policy, permissions: permissionModel, log: log)
        self.security = gates
        self.bridge = BridgeServices(
            messages: services.messages, settings: services.settings, ui: services.ui,
            permissions: permissionModel, reflection: gates)
        self.watchdog = PluginWatchdog(store: self.store, log: log)
        self.events = PluginEventBus(subscribers: gate, queue: queue)
        self.log = log
        self.delegate = delegate
    }

    // MARK: - Старт/стоп

    /// Поднять движок: CPython → сторож → очередь → плагины.
    /// safeMode (PluginsConstants.KEY_SAFE_MODE): рантайм стартует без плагинов.
    public func start(safeMode: Bool = false) async throws {
        guard !state.isRunning else { return }
        try await runtime.initialize(configuration.runtime)
        try? FileManager.default.createDirectory(
            atPath: configuration.runtime.pluginRootDirectory,
            withIntermediateDirectories: true)

        await watchdog.start(
            limits: configuration.watchdog,
            observer: { [weak self] pluginId, isNotResponding in
                self?.applyNotResponding(pluginId, isNotResponding)
            },
            abandon: { [weak self] pluginId in
                await self?.abandonInterpreter(for: pluginId)
            },
            footprint: { [weak self] in
                guard let self else { return [] }
                return await self.interpreters.footprintSnapshot()
            })

        await queue.start(
            handler: { [weak self] event in
                guard let self else { throw PluginHostError.notRunning }
                return try await self.handleEvent(event)
            },
            onTimeout: { [weak self] event in
                await self?.handleBatchTimeout(event)
            },
            limits: configuration.queue)

        if !safeMode {
            // Атрибуция падения прошлого процесса: выключить виновника ДО загрузки.
            if let crashed = await watchdog.recoverAfterCrash(),
               var plugin = state.plugin(id: crashed) {
                plugin.enabled = false
                plugin.loadError = "plugin crashed the app"
                state.upsert(plugin)
                persistPlugins()
            }
            for plugin in state.pluginList() where plugin.isEnabled {
                await loadPlugin(plugin)
            }
        }
        state.isRunning = true
        notifyReload()
    }

    /// Остановить: очередь → сторож → интерпретаторы → CPython.
    /// Финализация CPython пропускается, если есть брошенные интерпретаторы.
    public func stop() async {
        await queue.stop()
        await watchdog.stop()
        await interpreters.destroyAll()
        let hasAbandoned = await interpreters.hasAbandoned
        await runtime.shutdown(canFinalizeProcess: !hasAbandoned)
        gate.reset()
        state.isRunning = false
        notifyReload()
    }

    // MARK: - Жизненный цикл плагинов

    /// Установить плагин: копия файла в каталог, метаданные в стор.
    /// Метаданные (AST) готовит Python-сторона; TODO(этап 5): парсинг метаданных
    /// в бутстрап-интерпретаторе прямо на устройстве (SDK metadata_parser).
    @discardableResult
    public func installPlugin(sourceURL: URL, metadata: Plugin) async throws -> Plugin {
        guard Plugin.isValidID(metadata.id) else {
            throw PluginHostError.invalidPlugin("id \(metadata.id) не проходит валидацию ^[A-Za-z][A-Za-z0-9_-]{1,31}$")
        }
        let target = URL(fileURLWithPath: configuration.runtime.pluginRootDirectory)
            .appendingPathComponent(metadata.id + ".plugin")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: sourceURL, to: target)
        var plugin = metadata
        plugin.path = target.path
        state.upsert(plugin)
        persistPlugins()
        if plugin.enabled {
            await loadPlugin(plugin)
            plugin = state.plugin(id: plugin.id) ?? plugin
        }
        notifyReload()
        return plugin
    }

    /// Удалить плагин: интерпретатор, файл, модель, согласия.
    public func uninstallPlugin(id: String) async throws {
        await unloadPlugin(id: id)
        if let plugin = state.plugin(id: id), let path = plugin.path {
            try? FileManager.default.removeItem(atPath: path)
        }
        state.removePlugin(id: id)
        persistPlugins()
        permissions.clear(id, in: store)
        notifyReload()
    }

    /// Включить/выключить плагин (персистентно).
    public func setPluginEnabled(id: String, _ enabled: Bool) async throws {
        guard var plugin = state.plugin(id: id) else { throw PluginHostError.pluginNotFound(id) }
        guard plugin.enabled != enabled else { return }
        plugin.enabled = enabled
        state.upsert(plugin)
        persistPlugins()
        if enabled {
            await loadPlugin(plugin)
        } else {
            await unloadPlugin(id: id)
        }
        notifyReload()
    }

    /// Перезагрузить плагин (developer mode).
    public func reloadPlugin(id: String) async throws {
        await unloadPlugin(id: id)
        if let plugin = state.plugin(id: id) {
            await loadPlugin(plugin)
        }
        await watchdog.clearNotResponding(id)
        notifyReload()
    }

    /// Снимок списка плагинов (для UI).
    public func pluginList() -> [Plugin] { state.pluginList() }

    /// Обновить hasSettings-флаг плагина (этап 5: после разбора create_settings).
    public func updatePluginFlags(id: String, hasSettings: Bool) {
        guard var plugin = state.plugin(id: id) else { return }
        plugin.hasSettings = hasSettings
        state.upsert(plugin)
        persistPlugins()
        recomputeGate()
    }

    // MARK: - Загрузка/выгрузка

    @discardableResult
    private func loadPlugin(_ plugin: Plugin) async -> Plugin {
        var plugin = plugin
        // Загрузка — рискованная операция: маркер сторожа немедленно
        // (notePluginEnter(id, risky=true) в PluginsWatchdog.java).
        await watchdog.noteRiskyOperation(plugin.id)
        do {
            let handle = try await interpreters.createInterpreter(
                for: plugin.id,
                bootstrapScript: configuration.runtime.bootstrapScript(interpreterPluginId: plugin.id))
            state.setHandle(handle)
            plugin.loaded = true
            plugin.loadError = nil
            plugin.notResponding = false
            // TODO(этап 5): диспатч загрузки через SDK-лоадер (plugin_loader.py),
            // снятие handles*-флагов и hasSettings по факту регистрации хуков.
        } catch {
            plugin.loaded = false
            plugin.loadError = String(describing: error)
            notifyFailure(plugin.id, plugin.loadError ?? "load error")
        }
        await watchdog.scheduleMarkerClear()
        state.upsert(plugin)
        persistPlugins()
        recomputeGate()
        return plugin
    }

    private func unloadPlugin(id: String) async {
        if let handle = state.handle(for: id) {
            await interpreters.destroy(handle)
        }
        state.removeHandle(for: id)
        if var plugin = state.plugin(id: id) {
            plugin.loaded = false
            state.upsert(plugin)
            persistPlugins()
        }
        recomputeGate()
    }

    /// Бросить интерпретатор плагина (политика abandon).
    private func abandonInterpreter(for pluginId: String) async {
        guard let handle = state.handle(for: pluginId) else { return }
        await interpreters.abandon(handle)
    }

    // MARK: - Диспатч событий (обработчик очереди)

    private func handleEvent(_ event: PluginEvent) async throws -> PluginEventResult {
        let kind = event.kind
        let subscribers = state.pluginList().filter {
            $0.isEnabled && $0.loaded && !$0.notResponding && $0.handles(kind)
        }
        switch event {
        case .createSettings(let payload):
            guard let plugin = subscribers.first(where: { $0.id == payload.pluginId }) else {
                return .settingsJSON("[]")
            }
            let output = try await invokePlugin(plugin, PluginScriptBuilder.dispatch(for: event))
            return .settingsJSON(output)

        case .sendMessage:
            var strategy = HookStrategy.default
            for plugin in subscribers {
                guard let output = try? await invokePlugin(
                    plugin, PluginScriptBuilder.dispatch(for: event)) else { continue }
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                // TODO(этап 5): порядок разрешения стратегий — как в
                // PythonPluginsEngine эталона (приоритеты хуков, MODIFY_FINAL).
                if let resolved = HookStrategy(rawValue: trimmed), resolved != .default {
                    strategy = resolved
                    break
                }
            }
            return .strategy(strategy)

        case .coalescedUpdates, .update, .updates, .appEvent, .preRequest, .postRequest:
            // N апдейтов = один вход: батч уже собран очередью, диспатчим целиком.
            for plugin in subscribers {
                _ = try? await invokePlugin(plugin, PluginScriptBuilder.dispatch(for: event))
            }
            return .none
        }
    }

    /// Вызов интерпретатора плагина с пер-плагинным таймаутом; таймаут →
    /// сторож (abandon, notResponding), остальные плагины продолжают.
    private func invokePlugin(_ plugin: Plugin, _ script: String) async throws -> String {
        guard let handle = state.handle(for: plugin.id) else {
            throw PluginHostError.pluginNotFound(plugin.id)
        }
        state.markInflight(plugin.id, true)
        defer { state.markInflight(plugin.id, false) }
        do {
            let timeout = configuration.interpreters.callTimeout
            return try await withDispatchTimeout(timeout) {
                try await self.interpreters.invoke(handle, script: script)
            }
        } catch is DispatchTimeoutError {
            await watchdog.pluginTimedOut(plugin.id)
            throw PluginHostError.timeout(plugin.id)
        }
    }

    /// Диспатч завис целиком: бросить все ещё исполняющиеся интерпретаторы.
    private func handleBatchTimeout(_ event: PluginEvent) async {
        log?("PluginHost: таймаут диспатча \(String(describing: event.kind))")
        for pluginId in state.inflightSnapshot() {
            await watchdog.pluginTimedOut(pluginId)
        }
    }

    // MARK: - Гейт и уведомления

    private func recomputeGate() {
        gate.reset()
        for plugin in state.pluginList()
        where plugin.isEnabled && plugin.loaded && !plugin.notResponding {
            for kind in ExtensionPointKind.allCases where plugin.handles(kind) {
                gate.add(kind, 1)
            }
        }
    }

    private func applyNotResponding(_ pluginId: String, _ isNotResponding: Bool) {
        if var plugin = state.plugin(id: pluginId) {
            plugin.notResponding = isNotResponding
            if isNotResponding {
                plugin.loaded = false
            }
            state.upsert(plugin)
            persistPlugins()
        }
        recomputeGate()
        if isNotResponding {
            notify { $0.pluginHost($1, didMarkNotResponding: pluginId) }
        } else {
            notify { $0.pluginHost($1, didRecover: pluginId) }
        }
    }

    private func notifyFailure(_ pluginId: String, _ message: String) {
        notify { $0.pluginHost($1, pluginId: pluginId, didFailWithError: message) }
    }

    private func notifyReload() {
        notify { $0.pluginHostDidReloadPlugins($1) }
    }

    private func notify(_ work: @escaping @MainActor (any PluginHostDelegate, PluginHost) -> Void) {
        let box = delegateBox
        Task { @MainActor in
            guard let delegate = box.load() else { return }
            work(delegate, self)
        }
    }

    private func persistPlugins() {
        let plugins = state.pluginList()
        do {
            try store.savePlugins(plugins)
        } catch {
            log?("PluginHost: не сохранить plugins.json — \(error)")
        }
    }
}

// MARK: - Флаги хуков плагина

extension Plugin {
    func handles(_ kind: ExtensionPointKind) -> Bool {
        switch kind {
        case .appEvent: return handlesAppEvent
        case .preRequest: return handlesPreRequest
        case .postRequest: return handlesPostRequest
        case .update: return handlesUpdate
        case .updates: return handlesUpdates
        case .sendMessage: return handlesSendMessage
        case .createSettings: return hasSettings
        }
    }
}

// MARK: - Скрипты диспатча (v1)

/// Построение Python-скриптов диспатча. TODO(этап 5): имя точки входа
/// (`__exteraless_dispatch__`) и формат аргументов фиксирует интеграция с
/// python/sdk/extera_utils/plugin_loader.py; сейчас — стаб контрактного слоя.
private enum PluginScriptBuilder {
    static func dispatch(for event: PluginEvent) -> String {
        switch event {
        case .appEvent(let payload):
            return call("on_app_event", [("event_type", quote(payload.name))])
        case .preRequest(let payload):
            return call("pre_request_hook", [
                ("request_name", quote(payload.requestName)),
                ("account", String(payload.account)),
                ("request", payload.requestJSON),
            ])
        case .postRequest(let payload):
            return call("post_request_hook", [
                ("request_name", quote(payload.requestName)),
                ("account", String(payload.account)),
                ("response", payload.responseJSON ?? "null"),
                ("error", quote(payload.errorMessage ?? "")),
            ])
        case .update(let payload):
            return call("on_update_hook", [
                ("update_name", quote(payload.updateName)),
                ("account", String(payload.account)),
                ("update", payload.updateJSON),
            ])
        case .updates(let payload):
            return call("on_updates_hook", [
                ("container_name", quote(payload.containerName)),
                ("account", String(payload.account)),
                ("updates", "[" + payload.updatesJSON.map(quote).joined(separator: ", ") + "]"),
            ])
        case .coalescedUpdates(let key, let items):
            // N апдейтов одним входом: сериализуем батч целиком.
            let batch = items.compactMap { item -> String? in
                guard case .update(let payload) = item else { return nil }
                return "{" + pair(("update_name", quote(payload.updateName)))
                    + ", " + pair(("account", String(payload.account)))
                    + ", " + pair(("update", payload.updateJSON)) + "}"
            }.joined(separator: ", ")
            return call("on_updates_hook", [
                ("container_name", quote(key.container)),
                ("account", String(key.account)),
                ("updates", "[\(batch)]"),
            ])
        case .sendMessage(let payload):
            return call("on_send_message_hook", [
                ("account", String(payload.account)),
                ("params", payload.paramsJSON),
            ])
        case .createSettings:
            return call("create_settings", [])
        }
    }

    /// Скрипт вызова точки входа с JSON-объектом аргументов.
    private static func call(_ hook: String, _ pairs: [(String, String)]) -> String {
        "__exteraless_dispatch__(\(quote(hook)), {" + pairs.map(pair).joined(separator: ", ") + "})"
    }

    private static func pair(_ entry: (String, String)) -> String {
        "\(quote(entry.0)): \(entry.1)"
    }

    /// JSON-строка (эскейп по минимуму; значения-JSON вставляются как есть).
    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
