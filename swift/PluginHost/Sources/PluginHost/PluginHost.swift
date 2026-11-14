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

    /// Комплект Swift-сервисов моста, предоставляемых основным приложением.
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

    /// Capture synchronously in the native onCallback, BEFORE creating a Task or
    /// applying its delay. A Python handle is meaningful only in this interpreter
    /// lifetime. Tokens from another host or a reloaded interpreter are rejected.
    public struct CallbackOwner: Hashable, Sendable {
        public var pluginId: String { interpreter.pluginId }
        fileprivate let hostIdentity: UUID
        fileprivate let interpreter: InterpreterHandle
    }

    // MARK: - Внутреннее состояние (lock-защищённое)

    // Internal for deterministic lifecycle/overlap tests; all access remains locked.
    final class HostState: @unchecked Sendable {
        private let lock = NSLock()
        private var plugins: [Plugin] = []
        private var handles: [String: InterpreterHandle] = [:]
        private var inflight: [InterpreterHandle: Int] = [:]
        private var mutations: Set<String> = []
        private var loading: Set<String> = []
        private var unloading: [String: InterpreterHandle] = [:]
        private var batch: (id: UUID, owners: Set<InterpreterHandle>)?
        private var running = false
        private var starting = false
        private var stopping = false
        private var stopped = false

        var isRunning: Bool {
            lock.lock(); defer { lock.unlock() }
            return running
        }

        var isStopping: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopping
        }

        func shouldStart() throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !stopping else { throw PluginHostError.notRunning }
            guard !running, !starting else { return false }
            starting = true
            return true
        }

        func endStarting() {
            lock.lock(); starting = false; lock.unlock()
        }

        func markRunning() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard starting, !stopping else { return false }
            running = true
            return true
        }

        func beginStopping() -> [(Plugin, InterpreterHandle)]? {
            lock.lock(); defer { lock.unlock() }
            guard !stopping else { return nil }
            let active = plugins.compactMap { plugin -> (Plugin, InterpreterHandle)? in
                // Loading workers also need a bounded drain before destroyAll;
                // destroying a worker stuck in load_json would wait indefinitely.
                guard !plugin.notResponding, let handle = handles[plugin.id] else { return nil }
                return (plugin, handle)
            }
            stopping = true
            running = false
            handles.removeAll()
            batch = nil
            for index in plugins.indices { plugins[index].loaded = false }
            return active
        }

        var hasStopped: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }

        func finishStopping() {
            lock.lock(); stopped = true; lock.unlock()
        }

        func pluginList() -> [Plugin] { lock.lock(); defer { lock.unlock() }; return plugins }
        func plugin(id: String) -> Plugin? { pluginList().first { $0.id == id } }

        @discardableResult
        func upsert(_ plugin: Plugin) -> Plugin {
            lock.lock(); defer { lock.unlock() }
            var plugin = plugin
            if stopping { plugin.loaded = false }
            if let index = plugins.firstIndex(where: { $0.id == plugin.id }) {
                plugins[index] = plugin
            } else {
                plugins.append(plugin)
            }
            return plugin
        }

        func recomputeGate(_ gate: SubscriberGate, permissions: PermissionsModel) {
            // Снимок и публикация под тем же lock, что beginStopping:
            // старый снимок loaded-плагинов не откроет gate после stop.
            lock.lock(); defer { lock.unlock() }
            gate.reset()
            guard !stopping else { return }
            for plugin in plugins
            where plugin.isEnabled && plugin.loaded && !plugin.notResponding {
                for kind in ExtensionPointKind.allCases
                where plugin.handles(kind) && permissions.has(plugin.id, kind.requiredPermission) {
                    gate.add(kind, 1)
                }
            }
        }

        func removePlugin(id: String) {
            lock.lock(); defer { lock.unlock() }
            plugins.removeAll { $0.id == id }
            handles[id] = nil
        }

        func target(id: String, expected: InterpreterHandle? = nil,
                    allowLoading: Bool = false) -> (plugin: Plugin, handle: InterpreterHandle)? {
            lock.lock(); defer { lock.unlock() }
            guard !stopping, unloading[id] == nil, let handle = handles[id],
                  expected == nil || expected == handle,
                  let plugin = plugins.first(where: { $0.id == id }), !plugin.notResponding,
                  plugin.loaded || (allowLoading && loading.contains(id)) else { return nil }
            return (plugin, handle)
        }

        func handlesSnapshot() -> [InterpreterHandle] {
            lock.lock(); defer { lock.unlock() }
            return stopping ? [] : Array(handles.values)
        }

        func handle(for id: String) -> InterpreterHandle? {
            lock.lock(); defer { lock.unlock() }
            return handles[id]
        }

        func setHandle(_ handle: InterpreterHandle) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !stopping, loading.contains(handle.pluginId), handles[handle.pluginId] == nil,
                  unloading[handle.pluginId] == nil else { return false }
            handles[handle.pluginId] = handle
            return true
        }

        func isCurrent(_ handle: InterpreterHandle) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return !stopping && handles[handle.pluginId] == handle
        }

        func beginInvocation(_ handle: InterpreterHandle, allowUnloading: Bool = false) throws {
            lock.lock(); defer { lock.unlock() }
            try validateInvocation(handle, allowUnloading: allowUnloading)
            inflight[handle, default: 0] += 1
        }

        func checkInvocation(_ handle: InterpreterHandle, allowUnloading: Bool = false) throws {
            lock.lock(); defer { lock.unlock() }
            try validateInvocation(handle, allowUnloading: allowUnloading)
        }

        private func validateInvocation(_ handle: InterpreterHandle, allowUnloading: Bool) throws {
            guard !stopping || allowUnloading else { throw PluginHostError.notRunning }
            guard handles[handle.pluginId] == handle || (allowUnloading && unloading[handle.pluginId] == handle),
                  allowUnloading || unloading[handle.pluginId] == nil else {
                throw PluginHostError.superseded("Interpreter owner changed: \(handle.pluginId)")
            }
            guard let plugin = plugins.first(where: { $0.id == handle.pluginId }) else {
                throw PluginHostError.pluginNotFound(handle.pluginId)
            }
            guard !plugin.notResponding else { throw PluginHostError.pluginNotResponding(handle.pluginId) }
            guard plugin.loaded || loading.contains(handle.pluginId) || allowUnloading else {
                throw PluginHostError.pluginNotFound(handle.pluginId)
            }
        }

        func endInvocation(_ handle: InterpreterHandle) {
            lock.lock(); defer { lock.unlock() }
            guard let count = inflight[handle] else { return }
            if count == 1 { inflight.removeValue(forKey: handle) }
            else { inflight[handle] = count - 1 }
        }

        func inflightSnapshot() -> [InterpreterHandle] {
            lock.lock(); defer { lock.unlock() }
            return inflight.keys.filter { handles[$0.pluginId] == $0 }
        }

        func beginBatch() -> (id: UUID, targets: [(plugin: Plugin, handle: InterpreterHandle)]) {
            lock.lock(); defer { lock.unlock() }
            let id = UUID()
            guard !stopping else { return (id, []) }
            batch = (id, Set(handles.values))
            let targets: [(plugin: Plugin, handle: InterpreterHandle)] = plugins.compactMap { plugin in
                guard plugin.loaded, !plugin.notResponding, unloading[plugin.id] == nil,
                      let handle = handles[plugin.id] else { return nil }
                return (plugin, handle)
            }
            return (id, targets)
        }

        func endBatch(_ id: UUID) {
            lock.lock(); defer { lock.unlock() }
            if batch?.id == id { batch = nil }
        }

        func batchInflightSnapshot() -> [InterpreterHandle] {
            lock.lock(); defer { lock.unlock() }
            guard !stopping, let batch else { return [] }
            return inflight.keys.filter { batch.owners.contains($0) && handles[$0.pluginId] == $0 }
        }

        func beginMutation(_ id: String) throws {
            lock.lock(); defer { lock.unlock() }
            guard !mutations.contains(id), !loading.contains(id), unloading[id] == nil else {
                throw PluginHostError.runtimeFailure("Plugin operation already in progress: \(id)")
            }
            mutations.insert(id)
        }

        func endMutation(_ id: String) {
            lock.lock(); mutations.remove(id); lock.unlock()
        }

        func beginLoading(_ id: String, duringMutation: Bool = false) throws {
            lock.lock(); defer { lock.unlock() }
            guard !stopping else { throw PluginHostError.notRunning }
            guard !loading.contains(id), handles[id] == nil, unloading[id] == nil,
                  duringMutation || !mutations.contains(id) else {
                throw PluginHostError.runtimeFailure("Plugin is already active or loading: \(id)")
            }
            loading.insert(id)
            if let index = plugins.firstIndex(where: { $0.id == id }) {
                plugins[index].loaded = false
                plugins[index].notResponding = false
                plugins[index].loadError = nil
                plugins[index].loadDebug = nil
            }
        }

        func endLoading(_ id: String) {
            lock.lock(); loading.remove(id); lock.unlock()
        }

        func isLoading(_ id: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return loading.contains(id)
        }

        func publishLoaded(_ plugin: Plugin, handle: InterpreterHandle) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !stopping, loading.contains(plugin.id), handles[plugin.id] == handle,
                  unloading[plugin.id] == nil,
                  let index = plugins.firstIndex(where: { $0.id == plugin.id }),
                  !plugins[index].notResponding else { return false }
            plugins[index] = plugin
            return true
        }

        func failLoading(_ plugin: Plugin, expected: InterpreterHandle?) -> Plugin? {
            lock.lock(); defer { lock.unlock() }
            guard loading.contains(plugin.id), unloading[plugin.id] == nil,
                  handles[plugin.id] == expected || (stopping && handles[plugin.id] == nil),
                  let index = plugins.firstIndex(where: { $0.id == plugin.id }) else { return nil }
            var failed = plugin
            failed.loaded = false
            failed.notResponding = plugins[index].notResponding
            handles[plugin.id] = nil
            if let expected { inflight.removeValue(forKey: expected) }
            plugins[index] = failed
            return failed
        }

        func beginUnloading(id: String, expected: InterpreterHandle?, duringMutation: Bool = false) -> (plugin: Plugin, handle: InterpreterHandle)? {
            lock.lock(); defer { lock.unlock() }
            guard !stopping, unloading[id] == nil, let handle = handles[id],
                  duringMutation || !mutations.contains(id),
                  expected == nil || expected == handle,
                  let index = plugins.firstIndex(where: { $0.id == id }) else { return nil }
            let plugin = plugins[index]
            unloading[id] = handle
            plugins[index].loaded = false
            return (plugin, handle)
        }

        func ownsUnloading(_ handle: InterpreterHandle) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return unloading[handle.pluginId] == handle
                && (handles[handle.pluginId] == handle || (stopping && handles[handle.pluginId] == nil))
        }

        func finishUnloading(_ handle: InterpreterHandle, errorMessage: String?) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard unloading[handle.pluginId] == handle,
                  handles[handle.pluginId] == handle || (stopping && handles[handle.pluginId] == nil) else { return false }
            handles[handle.pluginId] = nil
            unloading[handle.pluginId] = nil
            inflight.removeValue(forKey: handle)
            if let index = plugins.firstIndex(where: { $0.id == handle.pluginId }) {
                plugins[index].loaded = false
                if let errorMessage {
                    plugins[index].loadError = errorMessage
                    plugins[index].loadDebug = errorMessage
                }
            }
            return true
        }

        func handle(watchdogKey: String) -> InterpreterHandle? {
            lock.lock(); defer { lock.unlock() }
            guard !stopping else { return nil }
            return handles.values.first { $0.hostWatchdogKey == watchdogKey }
        }

        func applyNotResponding(watchdogKey: String, value: Bool) -> String? {
            lock.lock(); defer { lock.unlock() }
            guard !stopping, let handle = handles.values.first(where: { $0.hostWatchdogKey == watchdogKey }),
                  let index = plugins.firstIndex(where: { $0.id == handle.pluginId }) else { return nil }
            plugins[index].notResponding = value
            if value { plugins[index].loaded = false }
            return handle.pluginId
        }

        func updateFlags(id: String, hasSettings: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let index = plugins.firstIndex(where: { $0.id == id }) else { return false }
            plugins[index].hasSettings = hasSettings
            return true
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
    private let callbackHostIdentity = UUID()
    private let persistenceLock = NSLock()
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
        for plugin in self.store.loadPlugins() {
            self.state.upsert(plugin)
        }
    }

    // MARK: - Старт/стоп

    /// Поднять движок: CPython → сторож → очередь → плагины.
    /// safeMode (PluginsConstants.KEY_SAFE_MODE): рантайм стартует без плагинов.
    public func start(safeMode: Bool = false) async throws {
        guard try state.shouldStart() else { return }
        defer { state.endStarting() }
        try await runtime.initialize(configuration.runtime)
        try await checkStartStillAllowed()
        try? FileManager.default.createDirectory(
            atPath: configuration.runtime.pluginRootDirectory,
            withIntermediateDirectories: true)

        await watchdog.start(
            limits: configuration.watchdog,
            observer: { [weak self] watchdogKey, isNotResponding in
                self?.applyNotResponding(watchdogKey, isNotResponding)
            },
            abandon: { [weak self] watchdogKey in
                await self?.abandonInterpreter(watchdogKey: watchdogKey)
            },
            footprint: { [weak self] in
                guard let self else { return [] }
                var snapshot: [(String, Int)] = []
                for handle in self.state.handlesSnapshot() {
                    let footprint = await self.interpreters.footprintKB(handle)
                    snapshot.append((handle.hostWatchdogKey, footprint))
                }
                return snapshot
            })
        try await checkStartStillAllowed()

        await queue.start(
            handler: { [weak self] event in
                guard let self else { throw PluginHostError.notRunning }
                return try await self.handleEvent(event)
            },
            onTimeout: { [weak self] event in
                await self?.handleBatchTimeout(event)
            },
            limits: configuration.queue)
        try await checkStartStillAllowed()

        if !safeMode {
            // Атрибуция падения прошлого процесса: выключить виновника ДО загрузки.
            let crashed = await watchdog.recoverAfterCrash()
            try await checkStartStillAllowed()
            if let crashed,
               var plugin = state.plugin(id: crashed) {
                plugin.enabled = false
                plugin.loadError = "plugin crashed the app"
                state.upsert(plugin)
                persistPlugins()
            }
            for plugin in state.pluginList() where plugin.isEnabled {
                await loadPlugin(plugin)
                try await checkStartStillAllowed()
            }
        }
        guard state.markRunning() else {
            await stop()
            throw PluginHostError.notRunning
        }
        notifyReload()
    }

    private func checkStartStillAllowed() async throws {
        guard !state.isStopping else {
            // start сервиса мог попасть в его actor уже после stop сервиса.
            // Повторный cleanup закрывает и этот порядок выполнения.
            await stop()
            throw PluginHostError.notRunning
        }
    }

    /// Остановить: очередь → сторож → интерпретаторы → CPython.
    /// Терминальная операция. При pending/abandoned CPython не финализируется.
    public func stop() async {
        let active = state.beginStopping()
        gate.reset()
        await queue.stop()
        await watchdog.stop()
        guard let active else {
            // Repeat the actor-service cleanup for a late start, but do not race
            // destroyAll against the first stop's bounded worker drains.
            if state.hasStopped {
                let canFinalize = await interpreters.canFinalizeProcess
                await runtime.shutdown(canFinalizeProcess: canFinalize)
            }
            return
        }
        for (plugin, handle) in active {
            // An already-retiring worker owns its unload hook. A FIFO barrier
            // still bounds its drain before destroyAll can mark it destroying.
            let script = state.ownsUnloading(handle) ? "None" : "_exteraless_runtime.unload()"
            do {
                _ = try await withDispatchTimeout(configuration.interpreters.callTimeout) {
                    try await self.interpreters.invoke(handle, script: script)
                }
            } catch is DispatchTimeoutError {
                await interpreters.abandon(handle)
                log?("PluginHost unload timed out: \(plugin.id)")
            } catch {
                log?("PluginHost unload \(plugin.id): \(error)")
            }
        }
        await interpreters.destroyAll()
        for plugin in state.pluginList() { bridge.releaseInstances(pluginId: plugin.id) }
        let canFinalize = await interpreters.canFinalizeProcess
        await runtime.shutdown(canFinalizeProcess: canFinalize)
        state.finishStopping()
        notifyReload()
    }

    // MARK: - Жизненный цикл плагинов

    /// Прочитать метаданные через AST SDK, не исполняя устанавливаемый файл.
    public func readPluginMetadata(sourceURL: URL) async throws -> Plugin {
        guard isRunning else { throw PluginHostError.notRunning }
        var policy = PythonInterpreterConfiguration()
        policy.allowThreads = false
        let inspector = try await interpreters.createInterpreter(
            for: "exteralessMetadataInspector",
            bootstrapScript: configuration.runtime.metadataBootstrapScript(),
            configuration: policy)
        do {
            let output = try await interpreters.invoke(inspector,
                script: PluginRuntimeScript.call("metadata_json", [sourceURL.path]))
            let metadata = try PluginRuntimeScript.metadata(output)
            await interpreters.destroy(inspector)
            return metadata
        } catch {
            await interpreters.destroy(inspector)
            throw error
        }
    }

    @discardableResult
    public func importPlugin(sourceURL: URL) async throws -> Plugin {
        let metadata = try await readPluginMetadata(sourceURL: sourceURL)
        return try await installPlugin(sourceURL: sourceURL, metadata: metadata)
    }

    /// Установить проверенный файл, затем загрузить его на worker плагина.
    @discardableResult
    public func installPlugin(sourceURL: URL, metadata: Plugin) async throws -> Plugin {
        guard Plugin.isValidID(metadata.id) else {
            throw PluginHostError.invalidPlugin("id \(metadata.id) не проходит валидацию ^[A-Za-z][A-Za-z0-9_-]{1,31}$")
        }
        try state.beginMutation(metadata.id)
        defer { state.endMutation(metadata.id) }
        let target = URL(fileURLWithPath: configuration.runtime.pluginRootDirectory)
            .appendingPathComponent(metadata.id + ".plugin")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sourceURL.standardizedFileURL != target.standardizedFileURL {
            let staged = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).incoming")
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: sourceURL, to: staged)
            await unloadPlugin(id: metadata.id, duringMutation: true)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: target)
            }
        } else {
            await unloadPlugin(id: metadata.id, duringMutation: true)
        }
        var plugin = metadata
        plugin.path = target.path
        plugin = state.upsert(plugin)
        persistPlugins()
        if plugin.enabled {
            await loadPlugin(plugin, duringMutation: true)
            plugin = state.plugin(id: plugin.id) ?? plugin
        }
        notifyReload()
        return plugin
    }

    /// Удалить плагин: интерпретатор, файл, модель, согласия.
    public func uninstallPlugin(id: String) async throws {
        try state.beginMutation(id)
        defer { state.endMutation(id) }
        await unloadPlugin(id: id, duringMutation: true)
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
        try state.beginMutation(id)
        defer { state.endMutation(id) }
        guard var plugin = state.plugin(id: id) else { throw PluginHostError.pluginNotFound(id) }
        guard plugin.enabled != enabled else { return }
        plugin.enabled = enabled
        state.upsert(plugin)
        persistPlugins()
        if enabled {
            await loadPlugin(plugin, duringMutation: true)
        } else {
            await unloadPlugin(id: id, duringMutation: true)
        }
        notifyReload()
    }

    /// Перезагрузить плагин (developer mode).
    public func reloadPlugin(id: String) async throws {
        try state.beginMutation(id)
        defer { state.endMutation(id) }
        await unloadPlugin(id: id, duringMutation: true)
        if let plugin = state.plugin(id: id) {
            await loadPlugin(plugin, duringMutation: true)
        }
        notifyReload()
    }

    /// Снимок списка плагинов (для UI).
    public func pluginList() -> [Plugin] { state.pluginList() }

    public func grantedPermissions(id: String) -> [PluginPermission] {
        PluginPermission.allCases.filter { permissions.has(id, $0) }
    }

    public func setGrantedPermissions(id: String, permissions grants: [PluginPermission]) throws {
        guard state.plugin(id: id) != nil else { throw PluginHostError.pluginNotFound(id) }
        permissions.setGranted(id, grants, to: store)
        recomputeGate()
        notifyReload()
    }

    public func deliverAppEvent(_ name: String) async throws {
        guard events.subscribers.hasSubscribers(.appEvent) else { return }
        _ = try await queue.submitAwaiting(.appEvent(AppEventPayload(name: name)))
    }

    public func settingsJSON(id: String, account: Int32) async throws -> String {
        guard let plugin = state.plugin(id: id), plugin.loaded else { throw PluginHostError.pluginNotFound(id) }
        return try await events.requestCreateSettings(CreateSettingsPayload(pluginId: id, account: account))
    }

    public func updateSetting(id: String, key: String, valueJSON: String) async throws {
        _ = try PluginRuntimeScript.jsonValue(valueJSON)
        guard let target = state.target(id: id) else { throw PluginHostError.pluginNotFound(id) }
        _ = try await invokePlugin(target.plugin, PluginRuntimeScript.call("setting_changed_json", [key, valueJSON]),
                                   expectedHandle: target.handle)
    }

    public func clickSetting(id: String, callbackId: String) async throws {
        guard let target = state.target(id: id) else { throw PluginHostError.pluginNotFound(id) }
        _ = try await invokePlugin(target.plugin, PluginRuntimeScript.call("setting_click_json", [callbackId]),
                                   expectedHandle: target.handle)
    }

    /// Synchronous and safe on the C callback worker, including on_plugin_load
    /// after setHandle and before plugin.loaded becomes true. Capture before delay.
    public func callbackOwner(id: String) -> CallbackOwner? {
        guard let target = state.target(id: id, allowLoading: true) else { return nil }
        return CallbackOwner(hostIdentity: callbackHostIdentity, interpreter: target.handle)
    }

    /// Immediate/unscheduled invocation (e.g. the strict native probe). Delayed
    /// callbacks must use the expectedOwner overload with a token captured at enqueue.
    public func invokeCallback(id: String, handle: Int64, method: String, argumentsJSON: String = "[]") async throws {
        guard let owner = callbackOwner(id: id) else { throw PluginHostError.pluginNotFound(id) }
        try await invokeCallback(id: id, handle: handle, method: method, argumentsJSON: argumentsJSON,
                                 expectedOwner: owner)
    }

    /// Stale tokens fail before Python entry. In particular, this path performs
    /// no completeCallback/release against the replacement interpreter's accounting;
    /// unload already retired the old owner's bridge objects and pending callbacks.
    public func invokeCallback(id: String, handle: Int64, method: String, argumentsJSON: String = "[]",
                               expectedOwner: CallbackOwner) async throws {
        guard expectedOwner.hostIdentity == callbackHostIdentity, expectedOwner.pluginId == id,
              let target = state.target(id: id, expected: expectedOwner.interpreter, allowLoading: true) else {
            throw PluginHostError.superseded("Callback interpreter owner expired: \(id)")
        }
        _ = try PluginRuntimeScript.jsonValue(argumentsJSON)
        let source = "_exteraless_runtime.invoke_handle_json(\(handle), \(PluginRuntimeScript.quote(method)), \(PluginRuntimeScript.quote(argumentsJSON)))"
        _ = try await invokePlugin(target.plugin, source, expectedHandle: target.handle)
    }

    /// Обновить hasSettings-флаг плагина (этап 5: после разбора create_settings).
    public func updatePluginFlags(id: String, hasSettings: Bool) {
        guard state.updateFlags(id: id, hasSettings: hasSettings) else { return }
        persistPlugins()
        recomputeGate()
    }

    // MARK: - Загрузка/выгрузка

    @discardableResult
    private func loadPlugin(_ plugin: Plugin, duringMutation: Bool = false) async -> Plugin {
        var plugin = plugin
        var created: InterpreterHandle?
        var publishedHandle = false
        do {
            try state.beginLoading(plugin.id, duringMutation: duringMutation)
        } catch {
            // A rejected duplicate owns no generation and must not publish a
            // failed copy over an active/in-progress load or release its handles.
            log?("PluginHost skipped load \(plugin.id): \(error)")
            return state.plugin(id: plugin.id) ?? plugin
        }
        defer { state.endLoading(plugin.id) }
        plugin = state.plugin(id: plugin.id) ?? plugin
        do {
            guard !state.isStopping else { throw PluginHostError.notRunning }
            guard let path = plugin.path else { throw PluginHostError.invalidPlugin("Plugin file path is missing") }
            // Загрузка — рискованная операция: маркер сторожа немедленно
            // (notePluginEnter(id, risky=true) в PluginsWatchdog.java).
            await watchdog.noteRiskyOperation(plugin.id)
            guard !state.isStopping else { throw PluginHostError.notRunning }
            let handle = try await interpreters.createInterpreter(
                for: plugin.id,
                bootstrapScript: configuration.runtime.bootstrapScript(interpreterPluginId: plugin.id))
            created = handle
            guard state.setHandle(handle) else {
                throw PluginHostError.notRunning
            }
            publishedHandle = true
            let output = try await invokePlugin(plugin, PluginRuntimeScript.call("load_json", [path]), expectedHandle: handle)
            plugin = try PluginRuntimeScript.applyLoadResult(output, to: plugin)
            guard state.publishLoaded(plugin, handle: handle) else {
                throw PluginHostError.superseded("Load owner was retired: \(plugin.id)")
            }
        } catch {
            var expectedForFailure = created
            if let created {
                if await unloadPlugin(id: plugin.id, expectedHandle: created, duringMutation: duringMutation) {
                    expectedForFailure = nil
                } else if !publishedHandle {
                    // A handle rejected at publication has no admitted callbacks.
                    // Published handles during stop are drained by stop itself.
                    await interpreters.destroy(created)
                }
            }
            plugin.loaded = false
            plugin.loadError = String(describing: error)
            plugin.loadDebug = String(describing: error)
            if let failed = state.failLoading(plugin, expected: expectedForFailure) {
                plugin = failed
                // The loading reservation is still held, so no replacement can
                // publish native objects between the state check and this release.
                bridge.releaseInstances(pluginId: plugin.id)
                notifyFailure(plugin.id, plugin.loadError ?? "load error")
            }
            if let created { await watchdog.clearNotResponding(created.hostWatchdogKey) }
        }
        await watchdog.scheduleMarkerClear()
        if state.isStopping { await watchdog.stop() }
        persistPlugins()
        recomputeGate()
        return state.plugin(id: plugin.id) ?? plugin
    }

    @discardableResult
    private func unloadPlugin(id: String, expectedHandle: InterpreterHandle? = nil,
                              errorMessage: String? = nil, duringMutation: Bool = false) async -> Bool {
        guard let target = state.beginUnloading(id: id, expected: expectedHandle, duringMutation: duringMutation) else { return false }
        recomputeGate()
        if !target.plugin.notResponding {
            do {
                _ = try await invokePlugin(target.plugin, "_exteraless_runtime.unload()",
                                           expectedHandle: target.handle, allowUnloading: true)
            } catch {
                log?("PluginHost unload \(id): \(error)")
            }
        }
        await interpreters.destroy(target.handle)
        guard state.ownsUnloading(target.handle) else { return false }
        // Keep the retirement reservation until the bridge has been cleared.
        // A new load cannot reuse this pluginId while cleanup is suspended.
        bridge.releaseInstances(pluginId: id)
        guard state.finishUnloading(target.handle, errorMessage: errorMessage) else { return false }
        persistPlugins()
        recomputeGate()
        if let errorMessage {
            log?("PluginHost \(id): \(errorMessage)")
            notifyFailure(id, errorMessage)
            notifyReload()
        }
        await watchdog.clearNotResponding(target.handle.hostWatchdogKey)
        return true
    }

    /// Бросить интерпретатор плагина (политика abandon).
    private func abandonInterpreter(watchdogKey: String) async {
        guard let handle = state.handle(watchdogKey: watchdogKey) else { return }
        await interpreters.abandon(handle)
    }

    // MARK: - Диспатч событий (обработчик очереди)

    private func handleEvent(_ event: PluginEvent) async throws -> PluginEventResult {
        let batch = state.beginBatch()
        defer { state.endBatch(batch.id) }
        let kind = event.kind
        let subscribers = batch.targets.filter { target in
            let plugin = target.plugin
            guard plugin.isEnabled else { return false }
            if case let .coalescedUpdates(_, items) = event {
                return items.contains { plugin.handles($0.kind) && permissions.has(plugin.id, $0.kind.requiredPermission) }
            }
            return plugin.handles(kind) && permissions.has(plugin.id, kind.requiredPermission)
        }
        switch event {
        case .createSettings(let payload):
            guard let target = subscribers.first(where: { $0.plugin.id == payload.pluginId }) else {
                return .settingsJSON("[]")
            }
            let output = try await invokePlugin(target.plugin, try PluginScriptBuilder.dispatch(for: event), expectedHandle: target.handle)
            return .settingsJSON(output)

        case .sendMessage(let payload):
            var result = PluginSendMessageResult()
            var currentParams = payload.paramsJSON
            for target in subscribers {
                let plugin = target.plugin
                do {
                    let currentEvent = PluginEvent.sendMessage(SendMessagePayload(
                        account: payload.account, paramsJSON: currentParams))
                    let output = try await invokePlugin(plugin, try PluginScriptBuilder.dispatch(for: currentEvent), expectedHandle: target.handle)
                    let decision = try PluginRuntimeScript.applyingSendResult(output, to: currentParams)
                    switch decision.strategy {
                    case .default:
                        break
                    case .cancel:
                        return .sendMessage(decision)
                    case .modify, .modifyFinal:
                        currentParams = decision.paramsJSON!
                        result = PluginSendMessageResult(strategy: decision.strategy, paramsJSON: currentParams)
                        if decision.strategy == .modifyFinal { return .sendMessage(result) }
                    }
                } catch {
                    await recordExecutionFailure(plugin, expectedHandle: target.handle, message: String(describing: error))
                }
            }
            return .sendMessage(result)

        case .coalescedUpdates(_, let items):
            for target in subscribers {
                let plugin = target.plugin
                do {
                    let interested = items.filter { plugin.handles($0.kind) }
                    _ = try await invokePlugin(plugin, try PluginScriptBuilder.batchDispatch(interested), expectedHandle: target.handle)
                } catch {
                    await recordExecutionFailure(plugin, expectedHandle: target.handle, message: String(describing: error))
                }
            }
            return .none

        case .update, .updates, .appEvent, .preRequest, .postRequest:
            // N апдейтов = один вход: батч уже собран очередью, диспатчим целиком.
            for target in subscribers {
                let plugin = target.plugin
                do {
                    _ = try await invokePlugin(plugin, try PluginScriptBuilder.dispatch(for: event), expectedHandle: target.handle)
                } catch {
                    await recordExecutionFailure(plugin, expectedHandle: target.handle, message: String(describing: error))
                }
            }
            return .none
        }
    }

    /// Вызов интерпретатора плагина с пер-плагинным таймаутом; таймаут →
    /// сторож (abandon, notResponding), остальные плагины продолжают.
    private func invokePlugin(_ plugin: Plugin, _ script: String, expectedHandle handle: InterpreterHandle,
                              allowUnloading: Bool = false) async throws -> String {
        try state.beginInvocation(handle, allowUnloading: allowUnloading)
        defer { state.endInvocation(handle) }
        do {
            let timeout = configuration.interpreters.callTimeout
            return try await withDispatchTimeout(timeout) {
                // Admission and detached execution may straddle unload. Recheck
                // the same handle, never resolve pluginId to a newer interpreter.
                try self.state.checkInvocation(handle, allowUnloading: allowUnloading)
                return try await self.interpreters.invoke(handle, script: script)
            }
        } catch is DispatchTimeoutError {
            await interpreters.abandon(handle)
            await reportTimeout(handle)
            throw PluginHostError.timeout(plugin.id)
        }
    }

    private func recordExecutionFailure(_ plugin: Plugin, expectedHandle: InterpreterHandle, message: String) async {
        _ = await unloadPlugin(id: plugin.id, expectedHandle: expectedHandle, errorMessage: message)
    }

    private func reportTimeout(_ handle: InterpreterHandle) async {
        guard state.isCurrent(handle) else { return }
        await watchdog.pluginTimedOut(handle.hostWatchdogKey)
        // Watchdog callbacks are keyed by generation too; a late completion of
        // its abandon action cannot mark or abandon a replacement interpreter.
        if !state.isCurrent(handle) {
            await watchdog.clearNotResponding(handle.hostWatchdogKey)
        }
    }

    /// Диспатч завис целиком: бросить все ещё исполняющиеся интерпретаторы.
    private func handleBatchTimeout(_ event: PluginEvent) async {
        log?("PluginHost: таймаут диспатча \(String(describing: event.kind))")
        for handle in state.batchInflightSnapshot() {
            await reportTimeout(handle)
        }
    }

    // MARK: - Гейт и уведомления

    private func recomputeGate() {
        state.recomputeGate(gate, permissions: permissions)
    }

    private func applyNotResponding(_ watchdogKey: String, _ isNotResponding: Bool) {
        guard let pluginId = state.applyNotResponding(watchdogKey: watchdogKey, value: isNotResponding) else { return }
        persistPlugins()
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
        // Take the snapshot AFTER serializing writers; an older caller must not
        // write its pre-reload snapshot after a newer generation has persisted.
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let plugins = state.pluginList()
        do {
            try store.savePlugins(plugins)
        } catch {
            log?("PluginHost: не сохранить plugins.json — \(error)")
        }
    }
}

extension InterpreterHandle {
    /// Transient watchdog identity. Crash-recovery markers keep the real pluginId.
    var hostWatchdogKey: String { "\(pluginId)#\(id)" }
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

/// Native event payload -> JSON text -> platform loader. Values never become
/// Python syntax, preserving JSON null/booleans and arbitrary user strings.
enum PluginScriptBuilder {
    static func dispatch(for event: PluginEvent) throws -> String {
        switch event {
        case .appEvent(let payload):
            return try call("on_app_event", ["event_type": payload.name])
        case .preRequest(let payload):
            return try call("pre_request_hook", [
                "request_name": payload.requestName,
                "account": payload.account,
                "request": try PluginRuntimeScript.jsonValue(payload.requestJSON),
            ])
        case .postRequest(let payload):
            return try call("post_request_hook", [
                "request_name": payload.requestName,
                "account": payload.account,
                "response": try payload.responseJSON.map(PluginRuntimeScript.jsonValue) ?? NSNull(),
                "error": payload.errorMessage ?? "",
            ])
        case .update(let payload):
            return try call("on_update_hook", [
                "update_name": payload.updateName,
                "account": payload.account,
                "update": try PluginRuntimeScript.jsonValue(payload.updateJSON),
            ])
        case .updates(let payload):
            return try call("on_updates_hook", [
                "container_name": payload.containerName,
                "account": payload.account,
                "updates": try payload.updatesJSON.map(PluginRuntimeScript.jsonValue),
            ])
        case .coalescedUpdates(_, let items):
            return try batchDispatch(items)
        case .sendMessage(let payload):
            return try call("on_send_message_hook", [
                "account": payload.account,
                "params": try PluginRuntimeScript.jsonValue(payload.paramsJSON),
            ])
        case .createSettings(let payload):
            return try call("create_settings", ["account": payload.account])
        }
    }

    static func batchDispatch(_ events: [PluginEvent]) throws -> String {
        // A single interpreter entry, preserving on_update vs on_updates semantics.
        "[" + (try events.map { try dispatch(for: $0) }).joined(separator: ", ") + "]"
    }

    private static func call(_ hook: String, _ payload: [String: Any]) throws -> String {
        PluginRuntimeScript.call("dispatch_json", [hook, try PluginRuntimeScript.encodeJSON(payload)])
    }
}
