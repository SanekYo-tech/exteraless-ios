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
    case eventQueueFull
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
        case .eventQueueFull: return "превышен общий лимит событий или их памяти"
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
        /// Whole terminal unload/destruction wait budget, including already
        /// destroying interpreters left behind by timed-out maintenance.
        public var stopTimeout: TimeInterval

        public init(runtime: PythonRuntimeConfiguration = .standard(),
                    interpreters: PythonInterpreterLimits = PythonInterpreterLimits(),
                    watchdog: WatchdogLimits = WatchdogLimits(),
                    queue: PluginEventQueue.Limits = PluginEventQueue.Limits(),
                    storageDirectory: URL? = nil,
                    strictReflection: Bool = false,
                    stopTimeout: TimeInterval = 5) {
            self.runtime = runtime
            self.interpreters = interpreters
            self.watchdog = watchdog
            self.queue = queue
            self.storageDirectory = storageDirectory
            self.strictReflection = strictReflection
            self.stopTimeout = stopTimeout
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
        /// Random per-interpreter generation, bound into immutable C state before
        /// user code loads. It must not be derived from a guessable handle counter.
        public let wireToken: String
        fileprivate let hostIdentity: UUID
        fileprivate let interpreter: InterpreterHandle
    }

    // MARK: - Внутреннее состояние (lock-защищённое)

    // Internal for deterministic lifecycle/overlap tests; all access remains locked.
    final class HostState: @unchecked Sendable {
        private let lock = NSLock()
        private var plugins: [Plugin] = []
        private var handles: [String: InterpreterHandle] = [:]
        private var ownerTokens: [InterpreterHandle: String] = [:]
        private var inflight: [InterpreterHandle: Int] = [:]
        private var mutations: Set<String> = []
        private var loading: Set<String> = []
        private var unloading: [String: InterpreterHandle] = [:]
        private var running = false
        private var startedInSafeMode = false
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

        func markRunning(safeMode: Bool = false) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard starting, !stopping else { return false }
            running = true
            startedInSafeMode = safeMode
            return true
        }

        var resumesAllEnabledPlugins: Bool {
            lock.lock(); defer { lock.unlock() }
            return !startedInSafeMode
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
            for index in plugins.indices { plugins[index].loaded = false }
            return active
        }

        var hasStopped: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }

        func finishStopping() {
            lock.lock()
            stopped = true
            ownerTokens.removeAll()
            lock.unlock()
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
            for handle in ownerTokens.keys.filter({ $0.pluginId == id }) { ownerTokens[handle] = nil }
        }

        func target(id: String, expected: InterpreterHandle? = nil,
                    allowLoading: Bool = false) -> (plugin: Plugin, handle: InterpreterHandle, wireToken: String)? {
            lock.lock(); defer { lock.unlock() }
            guard !stopping, unloading[id] == nil, let handle = handles[id],
                  expected == nil || expected == handle,
                  let plugin = plugins.first(where: { $0.id == id }), !plugin.notResponding,
                  plugin.loaded || (allowLoading && loading.contains(id)),
                  let token = ownerTokens[handle] else { return nil }
            return (plugin, handle, token)
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
            ownerTokens[handle] = UUID().uuidString
            return true
        }

        func acceptsNativeOwner(pluginId: String, token: String?, bootstrapOperation: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return false }
            if let token {
                // Retiring workers can finish their native cleanup. Once retired,
                // the token is removed even if a Python thread had to be abandoned.
                return ownerTokens.contains { pair in
                    pair.key.pluginId == pluginId && pair.value == token
                        && (handles[pluginId] == pair.key || unloading[pluginId] == pair.key || stopping)
                }
            }
            // Bootstrap precedes publication of the interpreter handle. It can
            // discover runtime paths/constants, not create async native effects.
            return bootstrapOperation && !stopping && loading.contains(pluginId) && handles[pluginId] == nil
        }

        func isRetiringNativeOwner(pluginId: String, token: String?) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let token, let handle = unloading[pluginId] else { return false }
            return ownerTokens[handle] == token
        }

        func maintenanceTarget(_ handle: InterpreterHandle) -> (plugin: Plugin, retiring: Bool)? {
            lock.lock(); defer { lock.unlock() }
            guard !stopping, handles[handle.pluginId] == handle,
                  let plugin = plugins.first(where: { $0.id == handle.pluginId }) else { return nil }
            return (plugin, unloading[handle.pluginId] == handle)
        }

        func requireSettingsQuiescence() throws {
            lock.lock(); defer { lock.unlock() }
            guard !stopping, handles.isEmpty, ownerTokens.isEmpty, loading.isEmpty,
                  unloading.isEmpty, mutations.isEmpty, inflight.isEmpty else {
                throw PluginHostError.runtimeFailure("Host still owns work during settings maintenance")
            }
        }

        func restoreMaintenanceEnabledFlags(_ original: [Plugin]) throws {
            lock.lock(); defer { lock.unlock() }
            guard !stopping, handles.isEmpty, loading.isEmpty, unloading.isEmpty,
                  Set(plugins.map(\.id)) == Set(original.map(\.id)) else {
                throw PluginHostError.runtimeFailure("Plugin model changed during settings maintenance")
            }
            let enabled = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0.enabled) })
            for index in plugins.indices {
                plugins[index].enabled = enabled[plugins[index].id] ?? false
                plugins[index].loaded = false
            }
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

        func eventTargets() -> [(plugin: Plugin, handle: InterpreterHandle)] {
            lock.lock(); defer { lock.unlock() }
            guard !stopping else { return [] }
            let targets: [(plugin: Plugin, handle: InterpreterHandle)] = plugins.compactMap { plugin in
                guard plugin.loaded, !plugin.notResponding, unloading[plugin.id] == nil,
                      let handle = handles[plugin.id] else { return nil }
                return (plugin, handle)
            }
            return targets
        }

        func beginMutation(_ id: String) throws {
            lock.lock(); defer { lock.unlock() }
            guard !stopping else { throw PluginHostError.notRunning }
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
            if let expected {
                inflight.removeValue(forKey: expected)
                // stop owns the still-live worker's final unload/drain.
                if !stopping { ownerTokens.removeValue(forKey: expected) }
            }
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
            ownerTokens.removeValue(forKey: handle)
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
    private let lifecycle = PluginHostLifecycle()
    private let callbackHostIdentity = UUID()
    private let persistenceLock = NSLock()
    private let delegateBox = WeakDelegateBox()
    private let log: (@Sendable (String) -> Void)?

    /// Делегат UI-слоя (слабая ссылка, вызовы — на главном акторе).
    public var delegate: (any PluginHostDelegate)? {
        get { delegateBox.load() }
        set { delegateBox.store(newValue) }
    }

    public var isRunning: Bool { state.isRunning && lifecycle.isOpen }
    public var isSettingsMaintenanceActive: Bool { lifecycle.isMaintaining }
    private let tlOrigins = PluginTLOriginRegistry()

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
        self.bridge.ownerValidator = { [state = self.state, lifecycle = self.lifecycle] pluginId, token, bootstrap in
            guard lifecycle.permitsNativeWork || state.isStopping
                || (lifecycle.permitsNativeCleanup && state.isRetiringNativeOwner(pluginId: pluginId, token: token)) else { return false }
            return state.acceptsNativeOwner(pluginId: pluginId, token: token, bootstrapOperation: bootstrap)
        }
        self.bridge.effectOwnerValidator = { [state = self.state, lifecycle = self.lifecycle] pluginId, token in
            // Validation returns a Bool only: the effect itself never executes
            // while either lifecycle/state lock is held. Retirement/stop cleanup
            // authorization above is deliberately insufficient for new effects.
            var active = false
            lifecycle.publishEffectAdmission { open in
                if open { active = state.target(id: pluginId, allowLoading: true)?.wireToken == token }
            }
            return active
        }
        for plugin in self.store.loadPlugins() {
            self.state.upsert(plugin)
        }
    }

    // MARK: - Старт/стоп

    /// Поднять движок: CPython → сторож → очередь → плагины.
    /// safeMode (PluginsConstants.KEY_SAFE_MODE): рантайм стартует без плагинов.
    public func start(safeMode: Bool = false) async throws {
        let activity = try lifecycle.enter()
        defer { activity.finish() }
        guard try state.shouldStart() else { return }
        defer { state.endStarting() }
        try await runtime.initialize(configuration.runtime)
        try await checkStartStillAllowed()
        try? FileManager.default.createDirectory(
            atPath: configuration.runtime.pluginRootDirectory,
            withIntermediateDirectories: true)

        await startActorServices()
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
        guard state.markRunning(safeMode: safeMode) else {
            await stop()
            throw PluginHostError.notRunning
        }
        notifyReload()
    }

    private func startActorServices() async {
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
        await queue.startControlled(
            handler: { [weak self] event, execution in
                guard let self else { throw PluginHostError.notRunning }
                return try await self.handleEvent(event, execution: execution)
            },
            onTimeout: { [weak self] event, execution in
                await self?.handleBatchTimeout(event, execution: execution)
            },
            limits: configuration.queue)
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
        var loggedWaiting = false
        while true {
            switch lifecycle.requestStop() {
            case .wait(let signal):
                if !loggedWaiting {
                    loggedWaiting = true
                    log?("PluginHost: stop waiting for settings maintenance")
                }
                _ = try? await signal.wait(cancellable: false)
            case .inProgress:
                await queue.stop()
                await watchdog.stop()
                return
            case .finished:
                // A start admitted before stop can arrive late at these actors.
                await queue.stop()
                await watchdog.stop()
                let canFinalize = await interpreters.canFinalizeProcess
                await runtime.shutdown(canFinalizeProcess: canFinalize)
                return
            case .perform(let context):
                await performStop(maintenanceEpoch: context?.managerPaused == true ? context?.epoch : nil)
                lifecycle.finishStop()
                return
            }
        }
    }

    private func performStop(maintenanceEpoch: UUID?) async {
        let configured = configuration.stopTimeout
        let seconds = configured.isFinite && configured > 0 ? min(configured, 86_400) : 5
        let deadline = try! PluginLifecycleDeadline(seconds: seconds)
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
            guard let remaining = try? deadline.remaining() else { break }
            // An already-retiring worker owns its unload hook. A FIFO barrier
            // still bounds its drain before destroyAll can mark it destroying.
            let script = state.ownsUnloading(handle) ? "None" : "_exteraless_runtime.unload()"
            do {
                let callLimit = configuration.interpreters.callTimeout
                _ = try await withDispatchTimeout(min(remaining, callLimit > 0 ? callLimit : remaining)) {
                    try await self.interpreters.invoke(handle, script: script, shouldExecute: { true },
                                                       maintenanceEpoch: maintenanceEpoch)
                }
            } catch is DispatchTimeoutError {
                await interpreters.abandon(handle)
                log?("PluginHost unload timed out: \(plugin.id)")
            } catch {
                log?("PluginHost unload \(plugin.id): \(error)")
            }
        }
        await interpreters.destroyAll(timeout: (try? deadline.remaining()) ?? 0)
        for plugin in state.pluginList() {
            bridge.releaseInstances(pluginId: plugin.id)
            tlOrigins.retire(pluginId: plugin.id)
        }
        let canFinalize = await interpreters.canFinalizeProcess
        await runtime.shutdown(canFinalizeProcess: canFinalize)
        state.finishStopping()
        notifyReload()
    }

    // MARK: - Nonterminal settings maintenance

    /// Closes admission synchronously before the first await. The returned lease
    /// proves SDK unload, native destruction and owner-mailbox exit for every
    /// interpreter, including inspectors/pending/abandoned-state checks. It never
    /// initializes or finalizes the process runtime. Tools may mutate files only
    /// after this method returns successfully, and must always finish the lease.
    public func beginSettingsMaintenance(timeout: TimeInterval = 10) async throws -> PluginSettingsMaintenanceLease {
        try Task.checkCancellation()
        let deadline = try PluginLifecycleDeadline(seconds: timeout)
        let context = try lifecycle.beginMaintenance()
        recomputeGate()
        do {
            try await deadline.run { try await self.lifecycle.waitUntilIdle(context.attempt) }
            var current = try lifecycle.check(context.attempt)
            // An awaited barrier runs after the old queue's dispatch/timeout
            // continuations. Its runLoop reaches idle before stop/start can reuse
            // the actor; merely counting interpreter replies is not that barrier.
            if !current.servicesStopped, state.isRunning {
                let name = "__host_maintenance_\(context.attempt.uuidString)"
                _ = try await deadline.run {
                    try await self.queue.submitAwaiting(.appEvent(AppEventPayload(name: name)))
                }
            }
            if current.snapshot == nil {
                try lifecycle.update(context.attempt, snapshot: .init(plugins: state.pluginList(), wasRunning: state.isRunning,
                                                                      resumeAllEnabled: state.resumesAllEnabledPlugins))
            }
            _ = try lifecycle.check(context.attempt)
            await queue.stop()
            await watchdog.stop()
            try lifecycle.update(context.attempt, servicesStopped: true, stage: .quiescing)
            try Task.checkCancellation()
            try await interpreters.pauseForSettingsMaintenance(context.epoch)
            try lifecycle.update(context.attempt, managerPaused: true)
            current = try lifecycle.check(context.attempt)
            let pool = await interpreters.maintenanceState
            guard pool.pendingCreations == 0, pool.pendingInvocations == 0, pool.abandoned == 0 else {
                throw PluginHostError.runtimeFailure("Cannot prepare settings maintenance with pending or abandoned interpreter work")
            }
            for handle in state.handlesSnapshot() {
                _ = try lifecycle.check(context.attempt)
                try Task.checkCancellation()
                try await retireForSettingsMaintenance(handle, context: current, deadline: deadline)
            }
            try await interpreters.requireSettingsQuiescence(context.epoch)
            try state.requireSettingsQuiescence()
            try Task.checkCancellation()
            _ = try lifecycle.check(context.attempt)
            try lifecycle.hold(context.attempt)
            notifyReload()
            return PluginSettingsMaintenanceLease { [self] resume in
                try await self.finishSettingsMaintenance(context.attempt, resume: resume)
            }
        } catch {
            // No lease => no authorization for Tools to stage/apply files. Keep
            // the epoch/snapshot and closed admission for recovery or a retry.
            lifecycle.release(context.attempt, resume: false)
            recomputeGate()
            notifyReload()
            throw error
        }
    }

    private func retireForSettingsMaintenance(_ handle: InterpreterHandle, context: PluginHostLifecycle.Context,
                                              deadline: PluginLifecycleDeadline) async throws {
        guard let target = state.maintenanceTarget(handle) else {
            throw PluginHostError.superseded("Maintenance interpreter owner changed: \(handle.pluginId)")
        }
        var unloadError: PluginHostError?
        if !target.retiring {
            guard state.beginUnloading(id: handle.pluginId, expected: handle) != nil else {
                throw PluginHostError.runtimeFailure("Interpreter retirement is busy: \(handle.pluginId)")
            }
            if !target.plugin.notResponding {
                do {
                    let configured = configuration.interpreters.callTimeout
                    let timeout = min(try deadline.remaining(), configured > 0 ? configured : 5)
                    _ = try await invokePlugin(target.plugin, "_exteraless_runtime.unload()", expectedHandle: handle,
                                               allowUnloading: true, maintenanceEpoch: context.epoch, timeout: timeout)
                } catch {
                    unloadError = bridgePluginError(error)
                }
            }
        }
        try Task.checkCancellation()
        try await interpreters.destroyForSettingsMaintenance(handle, epoch: context.epoch, deadline: deadline)
        guard state.ownsUnloading(handle) else {
            throw PluginHostError.superseded("Maintenance retirement owner expired: \(handle.pluginId)")
        }
        bridge.releaseInstances(pluginId: handle.pluginId)
        tlOrigins.retire(pluginId: handle.pluginId)
        guard state.finishUnloading(handle, errorMessage: nil) else {
            throw PluginHostError.superseded("Maintenance retirement owner expired: \(handle.pluginId)")
        }
        if let unloadError { throw unloadError }
    }

    private func finishSettingsMaintenance(_ attempt: UUID, resume: Bool) async throws {
        let (context, resume) = try lifecycle.beginFinish(attempt, resume: resume)
        guard resume else {
            lifecycle.release(attempt, resume: false)
            recomputeGate()
            notifyReload()
            return
        }
        do {
            guard let snapshot = context.snapshot else {
                throw PluginHostError.internalInconsistency("Maintenance snapshot is missing")
            }
            try await interpreters.requireSettingsQuiescence(context.epoch)
            try state.requireSettingsQuiescence()
            try state.restoreMaintenanceEnabledFlags(snapshot.plugins)
            try await interpreters.resumeAfterSettingsMaintenance(context.epoch)
            try lifecycle.update(attempt, managerPaused: false)
            if snapshot.wasRunning {
                await startActorServices()
                try lifecycle.update(attempt, servicesStopped: false)
                // Ordinary startup retries the original enabled set (restored
                // settings may fix a prior load error). Safe mode does not start
                // previously inactive plugins merely because a backup finished.
                let active = Set(snapshot.plugins.filter { $0.enabled && (snapshot.resumeAllEnabled || $0.loaded) }.map(\.id))
                for plugin in state.pluginList() where active.contains(plugin.id) {
                    _ = try lifecycle.check(attempt)
                    await loadPlugin(plugin)
                }
            }
            _ = try lifecycle.check(attempt)
            lifecycle.release(attempt, resume: true)
            recomputeGate()
            notifyReload()
        } catch {
            try? lifecycle.update(attempt, stage: .recovery)
            await queue.stop()
            await watchdog.stop()
            try? lifecycle.update(attempt, servicesStopped: true)
            lifecycle.release(attempt, resume: false)
            recomputeGate()
            notifyReload()
            throw error
        }
    }

    // MARK: - Жизненный цикл плагинов

    /// Прочитать метаданные через AST SDK, не исполняя устанавливаемый файл.
    public func readPluginMetadata(sourceURL: URL) async throws -> Plugin {
        let activity = try lifecycle.enter()
        defer { activity.finish() }
        return try await readPluginMetadataImpl(sourceURL: sourceURL)
    }

    private func readPluginMetadataImpl(sourceURL: URL) async throws -> Plugin {
        guard state.isRunning else { throw PluginHostError.notRunning }
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
        let activity = try lifecycle.enter()
        defer { activity.finish() }
        let metadata = try await readPluginMetadataImpl(sourceURL: sourceURL)
        return try await installPluginImpl(sourceURL: sourceURL, metadata: metadata)
    }

    /// Установить проверенный файл, затем загрузить его на worker плагина.
    @discardableResult
    public func installPlugin(sourceURL: URL, metadata: Plugin) async throws -> Plugin {
        let activity = try lifecycle.enter()
        defer { activity.finish() }
        return try await installPluginImpl(sourceURL: sourceURL, metadata: metadata)
    }

    private func installPluginImpl(sourceURL: URL, metadata: Plugin) async throws -> Plugin {
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
        let activity = try lifecycle.enter()
        defer { activity.finish() }
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
        let activity = try lifecycle.enter()
        defer { activity.finish() }
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
        let activity = try lifecycle.enter()
        defer { activity.finish() }
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
        let activity = try lifecycle.enter()
        defer { activity.finish() }
        guard state.plugin(id: id) != nil else { throw PluginHostError.pluginNotFound(id) }
        permissions.setGranted(id, grants, to: store)
        recomputeGate()
        notifyReload()
    }

    public func deliverAppEvent(_ name: String) async throws {
        let activity = try lifecycle.enter()
        defer { activity.finish() }
        guard events.subscribers.hasSubscribers(.appEvent) else { return }
        _ = try await queue.submitAwaiting(.appEvent(AppEventPayload(name: name)))
    }

    public func settingsJSON(id: String, account: Int32) async throws -> String {
        let activity = try lifecycle.enter()
        defer { activity.finish() }
        guard let plugin = state.plugin(id: id), plugin.loaded else { throw PluginHostError.pluginNotFound(id) }
        return try await events.requestCreateSettings(CreateSettingsPayload(pluginId: id, account: account))
    }

    public func updateSetting(id: String, key: String, valueJSON: String,
                              expectedOwner: CallbackOwner? = nil, account: Int32? = nil,
                              shouldExecute: @escaping @Sendable () -> Bool = { true }) async throws {
        let activity = try lifecycle.enter()
        defer { activity.finish() }
        let target = try settingsTarget(id: id, expectedOwner: expectedOwner)
        guard shouldExecute() else { throw PluginHostError.superseded("Settings execution scope expired") }
        _ = try PluginRuntimeScript.jsonValue(valueJSON)
        _ = try await invokePlugin(target.plugin, try settingsScript("setting_changed_json", [key, valueJSON], account: account),
                                   expectedHandle: target.handle, shouldExecute: shouldExecute)
    }

    public func clickSetting(id: String, callbackId: String,
                             expectedOwner: CallbackOwner? = nil, account: Int32? = nil,
                             shouldExecute: @escaping @Sendable () -> Bool = { true }) async throws {
        let activity = try lifecycle.enter()
        defer { activity.finish() }
        let target = try settingsTarget(id: id, expectedOwner: expectedOwner)
        guard shouldExecute() else { throw PluginHostError.superseded("Settings execution scope expired") }
        _ = try await invokePlugin(target.plugin, try settingsScript("setting_click_json", [callbackId], account: account),
                                   expectedHandle: target.handle, shouldExecute: shouldExecute)
    }

    private func settingsTarget(id: String, expectedOwner: CallbackOwner?) throws -> (plugin: Plugin, handle: InterpreterHandle) {
        if let expectedOwner {
            guard expectedOwner.hostIdentity == callbackHostIdentity, expectedOwner.pluginId == id,
                  let target = state.target(id: id, expected: expectedOwner.interpreter),
                  target.wireToken == expectedOwner.wireToken else {
                throw PluginHostError.superseded("Settings interpreter owner expired: \(id)")
            }
            return (target.plugin, target.handle)
        }
        guard let target = state.target(id: id) else { throw PluginHostError.pluginNotFound(id) }
        return (target.plugin, target.handle)
    }

    private func settingsScript(_ method: String, _ arguments: [String], account: Int32?) throws -> String {
        let legacy = PluginRuntimeScript.call(method, arguments)
        guard let account else { return legacy }
        guard account >= 0 else { throw PluginHostError.invalidPlugin("Settings account must be a nonnegative Int32 index") }
        // Only the typed integer is Python syntax. User strings/JSON retain the
        // existing quoting, and a nil account preserves the legacy SDK arity.
        return String(legacy.dropLast()) + ", \(account))"
    }

    /// Synchronous and safe on the C callback worker, including on_plugin_load
    /// after setHandle and before plugin.loaded becomes true. Capture before delay.
    public func callbackOwner(id: String) -> CallbackOwner? {
        guard lifecycle.permitsCallbacks else { return nil }
        return currentCallbackOwner(id: id)
    }

    private func currentCallbackOwner(id: String) -> CallbackOwner? {
        guard let target = state.target(id: id, allowLoading: true) else { return nil }
        return CallbackOwner(wireToken: target.wireToken, hostIdentity: callbackHostIdentity, interpreter: target.handle)
    }

    /// Immediate/unscheduled invocation (e.g. the strict native probe). Delayed
    /// callbacks must use the expectedOwner overload with a token captured at enqueue.
    public func invokeCallback(id: String, handle: Int64, method: String, argumentsJSON: String = "[]",
                               shouldExecute: @escaping @Sendable () -> Bool = { true }) async throws {
        let activity = try lifecycle.enter(callback: true)
        defer { activity.finish() }
        guard let owner = currentCallbackOwner(id: id) else { throw PluginHostError.pluginNotFound(id) }
        _ = try await performCallbackResult(id: id, handle: handle, method: method, argumentsJSON: argumentsJSON,
                                            expectedOwner: owner, shouldExecute: shouldExecute, activity: activity)
    }

    /// Stale tokens fail before Python entry. In particular, this path performs
    /// no completeCallback/release against the replacement interpreter's accounting;
    /// unload already retired the old owner's bridge objects and pending callbacks.
    public func invokeCallback(id: String, handle: Int64, method: String, argumentsJSON: String = "[]",
                                 expectedOwner: CallbackOwner,
                                 shouldExecute: @escaping @Sendable () -> Bool = { true },
                                 tlOrigin: PluginTLInvocationOrigin? = nil) async throws {
        _ = try await invokeCallbackResult(id: id, handle: handle, method: method,
                                          argumentsJSON: argumentsJSON, expectedOwner: expectedOwner,
                                          shouldExecute: shouldExecute, tlOrigin: tlOrigin)
    }

    /// Result-bearing native barriers (e.g. an intent before-handler) await the
    /// actual Python return value, not the Bool saying a callback was queued.
    public func invokeCallbackResult(id: String, handle: Int64, method: String, argumentsJSON: String = "[]",
                                      expectedOwner: CallbackOwner,
                                      shouldExecute: @escaping @Sendable () -> Bool = { true },
                                      tlOrigin: PluginTLInvocationOrigin? = nil) async throws -> String {
        let activity = try reserveCallbackActivity(expectedOwner)
        defer { activity.finish() }
        return try await performCallbackResult(id: id, handle: handle, method: method, argumentsJSON: argumentsJSON,
                                               expectedOwner: expectedOwner, shouldExecute: shouldExecute, activity: activity, tlOrigin: tlOrigin)
    }

    /// A dispatcher reserves at FIFO admission, so maintenance also waits for work
    /// which has not reached the interpreter mailbox yet.
    func reserveCallbackActivity(_ owner: CallbackOwner) throws -> PluginHostActivity {
        let activity = try lifecycle.enter(callback: true)
        guard currentCallbackOwner(id: owner.pluginId) == owner else {
            activity.finish()
            throw PluginHostError.superseded("Callback interpreter owner expired: \(owner.pluginId)")
        }
        return activity
    }

    func performCallbackResult(id: String, handle: Int64, method: String, argumentsJSON: String,
                                expectedOwner: CallbackOwner, shouldExecute: @escaping @Sendable () -> Bool,
                                activity: PluginHostActivity, tlOrigin: PluginTLInvocationOrigin? = nil) async throws -> String {
        guard lifecycle.owns(activity) else { throw PluginHostError.superseded("Callback admission expired") }
        guard expectedOwner.hostIdentity == callbackHostIdentity, expectedOwner.pluginId == id,
              let target = state.target(id: id, expected: expectedOwner.interpreter, allowLoading: true),
              target.wireToken == expectedOwner.wireToken else {
            throw PluginHostError.superseded("Callback interpreter owner expired: \(id)")
        }
        _ = try PluginRuntimeScript.jsonValue(argumentsJSON)
        let source = "_exteraless_runtime.invoke_handle_json(\(handle), \(PluginRuntimeScript.quote(method)), \(PluginRuntimeScript.quote(argumentsJSON)))"
        return try await invokePlugin(target.plugin, source, expectedHandle: target.handle, shouldExecute: shouldExecute,
            tlOrigin: tlOrigin ?? tlOrigins.origin(owner: expectedOwner, handle: handle))
    }

    /// Release a provider's unique callback lease on its original interpreter.
    /// Providers sharing a Python callback must use distinct wrapper handles or
    /// retain it themselves until the final native owner releases the lease.
    public func releaseCallbackHandles(_ handles: [Int64], expectedOwner: CallbackOwner) async throws {
        let activity = try reserveCallbackActivity(expectedOwner)
        defer { activity.finish() }
        try await performCallbackRelease(handles, expectedOwner: expectedOwner, activity: activity)
    }

    func performCallbackRelease(_ handles: [Int64], expectedOwner: CallbackOwner,
                                activity: PluginHostActivity) async throws {
        guard lifecycle.owns(activity) else { throw PluginHostError.superseded("Callback release admission expired") }
        guard handles.count <= 4096, handles.allSatisfy({ $0 > 0 }) else {
            throw PluginHostError.runtimeFailure("Invalid or oversized callback release lease")
        }
        guard expectedOwner.hostIdentity == callbackHostIdentity,
              let target = state.target(id: expectedOwner.pluginId, expected: expectedOwner.interpreter,
                                        allowLoading: true), target.wireToken == expectedOwner.wireToken else {
            throw PluginHostError.superseded("Callback release owner expired: \(expectedOwner.pluginId)")
        }
        let ids = Set(handles).sorted().map(String.init).joined(separator: ",")
        let source = PluginRuntimeScript.call("release_handles_json", ["[\(ids)]"])
        _ = try await invokePlugin(target.plugin, source, expectedHandle: target.handle)
        tlOrigins.release(owner: expectedOwner, handles: handles)
    }

    /// Обновить hasSettings-флаг плагина (этап 5: после разбора create_settings).
    public func updatePluginFlags(id: String, hasSettings: Bool) {
        guard let activity = try? lifecycle.enter() else { return }
        defer { activity.finish() }
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
        var riskyOperation: PluginWatchdog.RiskyOperation?
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
            riskyOperation = await watchdog.noteRiskyOperation(plugin.id)
            guard !state.isStopping else { throw PluginHostError.notRunning }
            let handle = try await interpreters.createInterpreter(
                for: plugin.id,
                bootstrapScript: configuration.runtime.bootstrapScript(interpreterPluginId: plugin.id))
            created = handle
            guard state.setHandle(handle) else {
                throw PluginHostError.notRunning
            }
            publishedHandle = true
            guard let owner = currentCallbackOwner(id: plugin.id) else { throw PluginHostError.notRunning }
            let tokenJSON = try PluginRuntimeScript.encodeJSON(owner.wireToken)
            let bindSource = "_exteraless_bridge.xt_set_owner_token(\(PluginRuntimeScript.quote(owner.wireToken)))\n"
                + PluginRuntimeScript.call("bind_owner_json", [tokenJSON])
            _ = try await invokePlugin(plugin, bindSource, expectedHandle: handle)
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
                tlOrigins.retire(pluginId: plugin.id)
                notifyFailure(plugin.id, plugin.loadError ?? "load error")
            }
            if let created { await watchdog.clearNotResponding(created.hostWatchdogKey) }
        }
        if let riskyOperation { await watchdog.scheduleMarkerClear(riskyOperation) }
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
        tlOrigins.retire(pluginId: id)
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

    private func canInvokeTL(_ payload: PluginTLHostPayload, pluginId: String, handle: InterpreterHandle) -> Bool {
        guard payload.shouldExecute(), permissions.has(pluginId, payload.kind.requiredPermission),
              let target = state.target(id: pluginId, expected: handle), target.plugin.isEnabled,
              target.plugin.handles(payload.kind), !payload.originPluginIds.contains(pluginId) else { return false }
        return true
    }

    private func handleEvent(_ event: PluginEvent, execution: PluginEventExecution) async throws -> PluginEventResult {
        try execution.check()
        if case .appEvent(let payload) = event, lifecycle.isBarrier(payload.name) { return .none }
        let activity = try lifecycle.enter()
        defer { activity.finish() }
        let kind = event.kind
        let subscribers = state.eventTargets().filter { target in
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
            let output = try await invokePlugin(target.plugin, try PluginScriptBuilder.dispatch(for: event), expectedHandle: target.handle,
                                                batch: execution)
            return .settingsJSON(output)

        case .sendMessage(let payload):
            var result = PluginSendMessageResult()
            var currentParams = payload.paramsJSON
            let sendRoot = UUID().uuidString
            for target in subscribers {
                try execution.check()
                let plugin = target.plugin
                do {
                    let currentEvent = PluginEvent.sendMessage(SendMessagePayload(
                        account: payload.account, paramsJSON: currentParams))
                    let origin = try PluginTLInvocationOrigin(rootId: sendRoot, pluginIds: [plugin.id])
                    let output = try await invokePlugin(plugin, try PluginScriptBuilder.dispatch(for: currentEvent), expectedHandle: target.handle,
                        tlOrigin: origin, batch: execution)
                    try execution.check()
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
                    try execution.check()
                    await recordExecutionFailure(plugin, expectedHandle: target.handle, message: String(describing: error))
                }
            }
            return .sendMessage(result)

        case let .tlTransform(payload):
            try payload.validate()
            guard payload.shouldExecute() else { return .tlTransform(.init()) }
            let origin = try PluginTLInvocationOrigin(rootId: payload.originRootId ?? UUID().uuidString, pluginIds: payload.originPluginIds)
            var ordered: [(plugin: Plugin, handle: InterpreterHandle, priority: Int32)] = []
            for target in subscribers where !payload.originPluginIds.contains(target.plugin.id) {
                try execution.check()
                guard payload.shouldExecute() else { return .tlTransform(.init()) }
                do {
                    let queryOrigin = try origin.entering(target.plugin.id)
                    let source = PluginRuntimeScript.call("hook_priority_json",
                        [payload.kind.protocolName, payload.name, payload.canonicalName])
                    let output = try await invokePlugin(target.plugin, source, expectedHandle: target.handle,
                        shouldExecute: { [weak self] in self?.canInvokeTL(payload, pluginId: target.plugin.id, handle: target.handle) == true },
                        tlOrigin: queryOrigin, batch: execution)
                    try execution.check()
                    guard payload.shouldExecute() else { return .tlTransform(.init()) }
                    guard canInvokeTL(payload, pluginId: target.plugin.id, handle: target.handle) else { continue }
                    guard output.utf8.count <= 128 else {
                        log?("TL_HOOK_PRIORITY_INVALID: \(target.plugin.id)")
                        continue
                    }
                    let raw = try PluginRuntimeScript.jsonValue(output)
                    if raw is NSNull { continue }
                    let value = try PluginServiceArgument.integer(raw, name: "TL hook priority")
                    guard let priority = Int32(exactly: value) else {
                        log?("TL_HOOK_PRIORITY_INVALID: \(target.plugin.id)")
                        continue
                    }
                    ordered.append((target.plugin, target.handle, priority))
                } catch {
                    try execution.check()
                    // A query/decoder failure is not a plugin execution verdict.
                    // Never unload a replacement generation (or this owner's valid
                    // callback leases) because its priority could not be inspected.
                    if payload.shouldExecute() { log?("TL_HOOK_PRIORITY_UNAVAILABLE: \(target.plugin.id)") }
                }
            }
            ordered.sort { $0.priority == $1.priority ? $0.plugin.id < $1.plugin.id : $0.priority > $1.priority }
            var current = payload.valueJSON
            var decision = PluginTLHookDecision()
            for target in ordered {
                try execution.check()
                guard payload.shouldExecute() else { return .tlTransform(.init()) }
                var next = payload
                next.valueJSON = current
                let childOrigin: PluginTLInvocationOrigin
                do { childOrigin = try origin.entering(target.plugin.id) }
                catch { log?("TL_HOOK_ORIGIN_DEPTH_LIMIT: \(target.plugin.id)"); continue }
                let output: String
                do {
                    output = try await invokePlugin(target.plugin,
                        try PluginScriptBuilder.dispatch(for: .tlTransform(next)), expectedHandle: target.handle,
                        shouldExecute: { [weak self] in self?.canInvokeTL(payload, pluginId: target.plugin.id, handle: target.handle) == true },
                        tlOrigin: childOrigin, batch: execution)
                } catch {
                    try execution.check()
                    switch bridgePluginError(error) {
                    case .superseded, .notRunning, .pluginNotResponding:
                        break
                    default:
                        if canInvokeTL(payload, pluginId: target.plugin.id, handle: target.handle) {
                            await recordExecutionFailure(target.plugin, expectedHandle: target.handle, message: String(describing: error))
                        }
                    }
                    continue
                }
                try execution.check()
                guard payload.shouldExecute() else { return .tlTransform(.init()) }
                guard canInvokeTL(payload, pluginId: target.plugin.id, handle: target.handle) else { continue }
                do {
                    let value = try payload.decision(output)
                    switch value.strategy {
                    case .default: break
                    case .cancel:
                        if payload.canCancel { return .tlTransform(.init(strategy: .cancel)) }
                        log?("TL_HOOK_CANCEL_UNSUPPORTED: \(payload.canonicalName)")
                    case .modify, .modifyFinal:
                        guard let json = value.valueJSON else { continue }
                        current = json
                        decision = value
                        if value.strategy == .modifyFinal { return .tlTransform(decision) }
                    }
                } catch {
                    log?("TL_HOOK_INVALID_REPLACEMENT: \(payload.canonicalName)")
                }
            }
            return .tlTransform(decision)

        case .coalescedUpdates(_, let items):
            let observationRoot = UUID().uuidString
            for target in subscribers {
                try execution.check()
                let plugin = target.plugin
                do {
                    let interested = items.filter { plugin.handles($0.kind) }
                    let origin = try PluginTLInvocationOrigin(rootId: observationRoot, pluginIds: [plugin.id])
                    _ = try await invokePlugin(plugin, try PluginScriptBuilder.batchDispatch(interested), expectedHandle: target.handle,
                        tlOrigin: origin, batch: execution)
                } catch {
                    try execution.check()
                    await recordExecutionFailure(plugin, expectedHandle: target.handle, message: String(describing: error))
                }
            }
            return .none

        case .update, .updates, .appEvent, .preRequest, .postRequest:
            // N апдейтов = один вход: батч уже собран очередью, диспатчим целиком.
            let observationRoot = UUID().uuidString
            for target in subscribers {
                try execution.check()
                let plugin = target.plugin
                do {
                    let origin: PluginTLInvocationOrigin?
                    if kind == .appEvent { origin = nil }
                    else { origin = try PluginTLInvocationOrigin(rootId: observationRoot, pluginIds: [plugin.id]) }
                    _ = try await invokePlugin(plugin, try PluginScriptBuilder.dispatch(for: event), expectedHandle: target.handle,
                        tlOrigin: origin, batch: execution)
                } catch {
                    try execution.check()
                    await recordExecutionFailure(plugin, expectedHandle: target.handle, message: String(describing: error))
                }
            }
            return .none
        }
    }

    /// Вызов интерпретатора плагина с пер-плагинным таймаутом; таймаут →
    /// сторож (abandon, notResponding), остальные плагины продолжают.
    private func invokePlugin(_ plugin: Plugin, _ script: String, expectedHandle handle: InterpreterHandle,
                               allowUnloading: Bool = false,
                               shouldExecute: @escaping @Sendable () -> Bool = { true },
                                maintenanceEpoch: UUID? = nil, timeout overrideTimeout: TimeInterval? = nil,
                                tlOrigin: PluginTLInvocationOrigin? = nil, batch: PluginEventExecution? = nil) async throws -> String {
        try Task.checkCancellation()
        try batch?.check()
        try state.beginInvocation(handle, allowUnloading: allowUnloading)
        let retained = PluginInvocationRetention(batch: batch) { [state] in state.endInvocation(handle) }
        let invocationCancellation = PluginEventRevocation(external: { true })
        let originScope: PluginTLInvocationScope?
        if let tlOrigin, let target = state.target(id: plugin.id, expected: handle, allowLoading: true) {
            let owner = CallbackOwner(wireToken: target.wireToken, hostIdentity: callbackHostIdentity, interpreter: handle)
            originScope = PluginTLInvocationScope(owner: owner, origin: tlOrigin, registry: tlOrigins)
        } else { originScope = nil }
        defer { originScope?.close() }
        do {
            let timeout = overrideTimeout ?? configuration.interpreters.callTimeout
            return try await withTaskCancellationHandler(operation: {
              try await withDispatchTimeout(timeout) {
                defer { withExtendedLifetime(retained) {} }
                // Admission and detached execution may straddle unload. Recheck
                // the same handle, never resolve pluginId to a newer interpreter.
                try self.state.checkInvocation(handle, allowUnloading: allowUnloading)
                return try await self.interpreters.invoke(handle, script: script, shouldExecute: {
                    // Recheck after the FIFO wait, on the actual owner worker.
                    guard invocationCancellation.error == nil,
                          (try? self.state.checkInvocation(handle, allowUnloading: allowUnloading)) != nil,
                          shouldExecute(), retained.start(handle: handle) else {
                        PluginTLNativeOrigin.install(nil)
                        PluginNativeExecutionContext.install(nil)
                        return false
                    }
                    PluginTLNativeOrigin.install(originScope)
                    PluginNativeExecutionContext.install(batch?.revocation)
                    return true
                }, maintenanceEpoch: maintenanceEpoch, onExecutionFinished: {
                    retained.nativeFinished()
                    PluginTLNativeOrigin.install(nil)
                    PluginNativeExecutionContext.install(nil)
                })
              }
            }, onCancel: {
                invocationCancellation.revoke(.superseded("Plugin invocation cancelled"))
            })
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
    private func handleBatchTimeout(_ event: PluginEvent, execution: PluginEventExecution) async {
        log?("PluginHost: таймаут диспатча \(String(describing: event.kind))")
        for handle in execution.runningHandles {
            await interpreters.abandon(handle)
            await reportTimeout(handle)
        }
    }

    // MARK: - Гейт и уведомления

    private func recomputeGate() {
        lifecycle.publishEventAdmission { allowed in
            if allowed { state.recomputeGate(gate, permissions: permissions) }
            else { gate.reset() }
        }
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
        case let .tlTransform(payload):
            try payload.validate()
            var snapshot: [String: Any] = ["schemaVersion": 1, "observational": false, "phase": payload.phase,
                "metadata": try PluginRuntimeScript.jsonValue(payload.metadataJSON),
                "tl": try PluginRuntimeScript.jsonValue(payload.valueJSON), "canCancel": payload.canCancel]
            if let error = payload.errorJSON { snapshot["tlError"] = try PluginRuntimeScript.jsonValue(error) }
            var arguments: [String: Any] = ["account": payload.account, payload.valueField: snapshot]
            arguments["canonical_name"] = payload.canonicalName
            switch payload.kind {
            case .preRequest, .postRequest: arguments["request_name"] = payload.name
            case .update: arguments["update_name"] = payload.name
            case .updates: arguments["container_name"] = payload.name
            default: throw PluginHostError.runtimeFailure("Unsupported TL transform kind")
            }
            if payload.kind == .postRequest { arguments["error"] = try payload.errorJSON.map(PluginRuntimeScript.jsonValue) ?? NSNull() }
            return try call(payload.kind.protocolName, arguments)
        case .appEvent(let payload):
            return try call("on_app_event", ["event_type": payload.name])
        case .preRequest(let payload):
            return try call("pre_request_hook", [
                "request_name": payload.requestName,
                "account": payload.account,
                "request": try PluginRuntimeScript.jsonValue(payload.requestJSON),
            ])
        case .postRequest(let payload):
            let response: Any = try payload.responseJSON.map(PluginRuntimeScript.jsonValue) ?? NSNull()
            let error: Any
            if let nativeError = (response as? [String: Any])?["tlError"] { error = nativeError }
            else if let message = payload.errorMessage { error = message }
            else { error = NSNull() }
            return try call("post_request_hook", [
                "request_name": payload.requestName,
                "account": payload.account,
                "response": response,
                "error": error,
            ])
        case .update(let payload):
            return try call("on_update_hook", [
                "update_name": payload.updateName,
                "account": payload.account,
                "update": try PluginRuntimeScript.jsonValue(payload.updateJSON),
            ])
        case .updates(let payload):
            let values = try payload.updatesJSON.map(PluginRuntimeScript.jsonValue)
            // The native observer forwards one complete container snapshot in its
            // historical array envelope. SDK on_updates_hook consumes that TL object.
            let value: Any
            if values.count == 1, let snapshot = values[0] as? [String: Any], snapshot["schemaVersion"] != nil,
               snapshot["observational"] as? Bool == true, snapshot["tl"] != nil {
                value = snapshot
            } else { value = values }
            return try call("on_updates_hook", [
                "container_name": payload.containerName,
                "account": payload.account,
                "updates": value,
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
