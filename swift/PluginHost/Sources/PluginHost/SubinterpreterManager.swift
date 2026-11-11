import Foundation

/// Менеджер суб-интерпретаторов: PEP 684 (per-interpreter GIL), по одному
/// интерпретатору на плагин.
///
/// Политика зависаний (требование этапа 4): воркер, не вернувшийся из вызова,
/// БРОСАЕТСЯ (abandon) — интерпретатор и его поток утекают до конца процесса
/// (плагин помечается notResponding и больше не вызывается). Утечка памяти
/// одного интерпретатора допустима: альтернативы хуже — нельзя ни убить
/// поток CPython безопасно, ни звать Py_EndInterpreter из чужого потока.
/// Причина держится в счётчике abandoned: PluginHost не финализирует процесс
/// CPython, если есть брошенные интерпретаторы.
///
/// ПРИНЦИП: актор держит только бухгалтерию; все C-вызывы CPython исполняются
/// на выделенном потоке-владельце интерпретатора (thread affinity tstate).

// MARK: - Политика PEP 684

/// Настройки суб-интерпретатора — Swift-отражение C-структуры
/// `PyInterpreterConfig` (Include/internal/pycore_interp.h, Python 3.12).
public struct PythonInterpreterConfiguration: Hashable, Sendable {
    /// C-поле `use_main_obmalloc` = 0: свой обмаллокатор на интерпретатор.
    public var useMainObmalloc: Bool = false
    /// C-поле `allow_fork` = 0: fork из плагина запрещён (iOS и так нет).
    public var allowFork: Bool = false
    /// C-поле `allow_exec` = 0: exec запрещён.
    public var allowExec: Bool = false
    /// C-поле `allow_threads` = 1: dev_server SDK поднимает потоки.
    /// TODO(мак): если 1 вызывает проблемы с per-interpreter GIL — выставить 0
    /// и завести dev-сервер в отдельном конфиге.
    public var allowThreads: Bool = true
    /// C-поле `allow_daemon_threads` = 0.
    public var allowDaemonThreads: Bool = false
    /// C-поле `check_multi_interp_extensions` = 1: расширения обязаны
    /// поддерживать мульти-интерпретаторы (мост этапа 2 обязан).
    public var checkMultiInterpExtensions: Bool = true
    /// C-поле `gil` = `PyInterpreterConfig_OWN_GIL` (изолированный GIL).
    public var ownsGIL: Bool = true

    /// Политика для плагинов exteraless (значения выше — по умолчанию).
    public init() {}

    /// Отображение в C-структуру (реализация движка):
    /// use_main_obmalloc/allow_fork/allow_exec/allow_daemon_threads = 0,
    /// allow_threads = 1, check_multi_interp_extensions = 1,
    /// gil = PyInterpreterConfig_OWN_GIL.
    /// TODO(мак): сверить имена констант в PyInterpreterConfig (3.12).
}

/// Лимиты пула интерпретаторов.
public struct PythonInterpreterLimits: Sendable {
    /// Максимум живых интерпретаторов, СЧИТАЯ брошенные (abandoned): они
    /// продолжают потреблять память. Достигнут лимит — новые плагины не
    /// грузятся до перезапуска приложения (UI показывает «перезагрузите»).
    public var maxInterpreters: Int
    /// Таймаут одного вызова скрипта, секунды (по умолчанию 5 — как
    /// FREEZE_TIMEOUT_SECONDS в PluginsWatchdog.java).
    public var callTimeout: TimeInterval
    public init(maxInterpreters: Int = 16, callTimeout: TimeInterval = 5.0) {
        self.maxInterpreters = maxInterpreters
        self.callTimeout = callTimeout
    }
}

// MARK: - Дескрипторы

/// Публичный дескриптор интерпретатора плагина.
public struct InterpreterHandle: Hashable, Codable, Sendable {
    public let id: Int64
    public let pluginId: String
    init(id: Int64, pluginId: String) {
        self.id = id
        self.pluginId = pluginId
    }
}

/// Контекст вызова, доступный внутри воркерного потока интерпретатора.
public struct InterpreterCallContext: Sendable {
    public let engine: any CPythonEngine
    public let reference: InterpRef
    public let pluginId: String
}

// MARK: - Одноразовый ответ

/// Потокобезопасный одноразовый резюм: результат может прийти раньше await
/// (воркер успел) — тогда awaitValue возвращает сразу.
///
/// `CheckedContinuation` и `any Error` не Sendable. `resume` контрактно
/// безопасен с любого потока; NSLock сериализует запись. `nonisolated(unsafe)`
/// только гасит диагностику Swift 6, лок не убирает. Наружу уходит
/// `any Error & Sendable` (`PluginHostError` / `DispatchTimeoutError`).
final class OneShotResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var result: Result<T, any Error>?
    nonisolated(unsafe) private var continuation: CheckedContinuation<T, any Error>?
    private var isAwaited = false

    func succeed(_ value: T) { complete(.success(value)) }
    func fail(_ error: any Error & Sendable) { complete(.failure(error)) }

    private func complete(_ outcome: Result<T, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = outcome
        if let continuation {
            self.continuation = nil
            continuation.resume(with: outcome)
        }
    }

    func awaitValue() async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
            lock.lock()
            defer { lock.unlock() }
            if let result {
                cont.resume(with: result)
            } else if isAwaited {
                cont.resume(throwing: PluginHostError.internalInconsistency(
                    "OneShotResult: двойной await"))
            } else {
                isAwaited = true
                // Континуация убегает в другое поле и резюмится с воркера.
                nonisolated(unsafe) let escaped = cont
                continuation = escaped
            }
        }
    }
}

/// Ошибка из `@Sendable`-catch. `sending` забирает не-Sendable `any Error`
/// в эту функцию (SE-0430): `PluginHostError` возвращаем как есть, остальное
/// сводим к тексту. Вызывающий больше не использует `error`.
func bridgePluginError(_ error: sending any Error) -> PluginHostError {
    if let pluginError = error as? PluginHostError { return pluginError }
    return .runtimeFailure(String(describing: error))
}

// MARK: - Почтовый ящик воркера

/// Выделенный поток-владелец интерпретатора + FIFO задач. Поток никогда не
/// завершается принудительно: poisonOnly флаг лишь прекращает приём новых
/// задач; зависший в C-вызове воркер остаётся висеть (политика abandon).
final class InterpreterMailbox: @unchecked Sendable {
    struct Job {
        let id: Int64
        let closure: @Sendable (InterpreterCallContext) -> Void
    }

    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var poisoned = false
    private var nextJobId: Int64 = 0
    private var thread: Thread?

    var isPoisoned: Bool {
        condition.lock(); defer { condition.unlock() }
        return poisoned
    }

    /// Запустить воркер: `spawn` создаёт интерпретатор (Py_NewInterpreterFromConfig
    /// на ЭТОМ потоке) и возвращает контекст либо кидает.
    func start(name: String, spawn: @escaping @Sendable () throws -> InterpreterCallContext,
               onSpawnFailure: @escaping @Sendable (PluginHostError) -> Void) {
        precondition(thread == nil, "mailbox уже запущен")
        let thread = Thread { [weak self] in
            guard let self else { return }
            let context: InterpreterCallContext
            do {
                context = try spawn()
            } catch {
                // sending-параметр bridgePluginError забирает не-Sendable Error.
                onSpawnFailure(bridgePluginError(error))
                self.poisonSelf()
                return
            }
            self.serve(context: context)
        }
        thread.name = name
        thread.stackSize = 1 << 20 // 1 МиБ — хватает диспетчеру (Python сам растёт)
        thread.start()
        self.thread = thread
    }

    private func serve(context: InterpreterCallContext) {
        while true {
            condition.lock()
            while jobs.isEmpty && !poisoned { condition.wait() }
            if jobs.isEmpty && poisoned {
                condition.unlock()
                return
            }
            let job = jobs.removeFirst()
            condition.unlock()
            job.closure(context)
        }
    }

    /// Поставить задачу. false — ящик отравлен (плагин брошен).
    func submit(_ closure: @escaping @Sendable (InterpreterCallContext) -> Void) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !poisoned else { return false }
        nextJobId += 1
        jobs.append(Job(id: nextJobId, closure: closure))
        condition.signal()
        return true
    }

    /// Прекратить приём и разбудить поток (выход при пустой очереди).
    func poison() {
        condition.lock()
        poisoned = true
        condition.signal()
        condition.unlock()
    }

    private func poisonSelf() {
        condition.lock()
        poisoned = true
        jobs.removeAll()
        condition.signal()
        condition.unlock()
    }
}

// MARK: - Менеджер

/// Актор-бухгалтер пула интерпретаторов.
public actor SubinterpreterManager {

    public struct Stats: Equatable, Sendable {
        public var created = 0
        public var destroyed = 0
        public var abandoned = 0
        public init() {}
    }

    private enum State {
        case ready
        case abandoned
    }

    private struct Managed {
        let handle: InterpreterHandle
        let mailbox: InterpreterMailbox
        var state: State
        let reference: InterpRef
        var pendingReplies: [OneShotResult<String>] = []
    }

    private let engine: any CPythonEngine
    private var limits: PythonInterpreterLimits
    private var interpreters: [Int64: Managed] = [:]
    private var nextInterpreterId: Int64 = 1
    public private(set) var stats = Stats()

    public init(engine: any CPythonEngine, limits: PythonInterpreterLimits = PythonInterpreterLimits()) {
        self.engine = engine
        self.limits = limits
    }

    public var activeCount: Int { interpreters.count }
    public var abandonedCount: Int {
        interpreters.values.filter { if case .abandoned = $0.state { return true }; return false }.count
    }
    /// Есть ли брошенные интерпретаторы (решает, финализировать ли процесс).
    public var hasAbandoned: Bool { abandonedCount > 0 }

    /// Создать интерпретатор плагина и выполнить бутстрап (virtualjava + мост).
    public func createInterpreter(
        for pluginId: String,
        bootstrapScript: String,
        configuration: PythonInterpreterConfiguration = PythonInterpreterConfiguration()
    ) async throws -> InterpreterHandle {
        guard interpreters.count < limits.maxInterpreters else {
            throw PluginHostError.interpreterLimitReached(limits.maxInterpreters)
        }
        let id = nextInterpreterId
        nextInterpreterId += 1
        let handle = InterpreterHandle(id: id, pluginId: pluginId)
        let mailbox = InterpreterMailbox()
        let spawnReply = OneShotResult<InterpRef>()

        mailbox.start(
            name: "plugin-\(id)-\(pluginId)",
            spawn: { [engine] () throws -> InterpreterCallContext in
                // Создание и бутстрап — на потоке-владельце: tstate от
                // Py_NewInterpreterFromConfig привязан к этому потоку.
                let reference = try engine.createInterpreter(configuration)
                _ = try engine.runScript(reference, bootstrapScript)
                spawnReply.succeed(reference)
                return InterpreterCallContext(engine: engine, reference: reference, pluginId: pluginId)
            },
            onSpawnFailure: { error in
                spawnReply.fail(error)
            })

        // Ждём завершения бутстрапа (включая время Py_NewInterpreterFromConfig).
        let reference = try await spawnReply.awaitValue()

        interpreters[id] = Managed(
            handle: handle, mailbox: mailbox, state: .ready,
            reference: reference, pendingReplies: [])
        stats.created += 1
        return handle
    }

    /// Выполнить скрипт в интерпретаторе. Таймаут — на стороне очереди
    /// (PluginEventQueue.withDispatchTimeout); здесь только отказ для
    /// брошенных интерпретаторов.
    public func invoke(_ handle: InterpreterHandle, script: String) async throws -> String {
        guard var managed = interpreters[handle.id] else {
            throw PluginHostError.pluginNotFound(handle.pluginId)
        }
        guard case .ready = managed.state else {
            throw PluginHostError.pluginNotResponding(handle.pluginId)
        }
        let reply = OneShotResult<String>()
        let accepted = managed.mailbox.submit { context in
            do {
                reply.succeed(try context.engine.runScript(context.reference, script))
            } catch {
                reply.fail(bridgePluginError(error))
            }
        }
        if !accepted {
            throw PluginHostError.pluginNotResponding(handle.pluginId)
        }
        managed.pendingReplies.append(reply)
        interpreters[handle.id] = managed
        defer {
            if var current = interpreters[handle.id] {
                current.pendingReplies.removeAll { $0 === reply }
                interpreters[handle.id] = current
            }
        }
        return try await reply.awaitValue()
    }

    /// Бросить зависший интерпретатор: пометить, отравить ящик, разбудить
    /// ожидающих. Интерпретатор и поток УТЕКАЮТ до конца процесса (осознанно).
    public func abandon(_ handle: InterpreterHandle) {
        guard var managed = interpreters[handle.id] else { return }
        guard case .ready = managed.state else { return }
        managed.state = .abandoned
        for reply in managed.pendingReplies {
            reply.fail(PluginHostError.pluginNotResponding(handle.pluginId))
        }
        managed.pendingReplies.removeAll()
        interpreters[handle.id] = managed
        managed.mailbox.poison()
        stats.abandoned += 1
    }

    /// Мягко уничтожить интерпретатор (вызывается только для .ready):
    /// Py_EndInterpreter исполняется на потоке-владельце, затем поток выходит.
    public func destroy(_ handle: InterpreterHandle) async {
        guard var managed = interpreters[handle.id] else { return }
        guard case .ready = managed.state else { return }
        let done = OneShotResult<Bool>()
        _ = managed.mailbox.submit { context in
            do {
                try context.engine.destroyInterpreter(context.reference)
                done.succeed(true)
            } catch {
                done.fail(bridgePluginError(error))
            }
        }
        managed.mailbox.poison()
        interpreters[handle.id] = nil
        stats.destroyed += 1
        _ = try? await done.awaitValue()
    }

    /// Приблизительный RSS интерпретатора, КБ (upper bound, см. CPythonEngine).
    public func footprintKB(_ handle: InterpreterHandle) -> Int {
        guard let managed = interpreters[handle.id] else { return 0 }
        return engine.interpreterFootprintKB(managed.reference)
    }

    /// Снимок footprint всех живых интерпретаторов (для RSS-свипа сторожа).
    public func footprintSnapshot() -> [(String, Int)] {
        interpreters.values.map {
            ($0.handle.pluginId, engine.interpreterFootprintKB($0.reference))
        }
    }

    /// Состояние интерпретатора плагина.
    public func isNotResponding(_ pluginId: String) -> Bool {
        for managed in interpreters.values {
            if managed.handle.pluginId == pluginId, case .abandoned = managed.state {
                return true
            }
        }
        return false
    }

    /// Разрушить всё (стоп движка).
    public func destroyAll() async {
        let all = interpreters.values.map(\.handle)
        for handle in all {
            await destroy(handle)
        }
    }
}
